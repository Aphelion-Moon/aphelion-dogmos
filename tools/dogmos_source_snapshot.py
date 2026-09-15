"""Exact working-tree identity for explicitly local, uncommitted qualification builds."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import subprocess


class SnapshotError(ValueError):
    pass


def canonical_bytes(value: dict) -> bytes:
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")


def local_fingerprint(encoded: bytes) -> str:
    validate_snapshot(encoded)
    return hashlib.sha256(b"dogmos-local-qualification-v1\0" + hashlib.sha256(encoded).digest()).hexdigest()


def _git(root: Path, *arguments: str) -> bytes:
    return subprocess.run(
        ["git", *arguments], cwd=root, check=True, capture_output=True
    ).stdout


def _safe_path(name: object) -> str:
    if not isinstance(name, str) or not name:
        raise SnapshotError("invalid source path")
    path = PurePosixPath(name)
    if (path.is_absolute() or path.as_posix() != name or ":" in name or "\\" in name
            or any(part in ("..", ".git") for part in path.parts)
            or any(ord(character) < 32 for character in name)):
        raise SnapshotError(f"unsafe source path: {name!r}")
    return name


def _duplicate_guard(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise SnapshotError(f"duplicate snapshot key: {key}")
        result[key] = value
    return result


def validate_snapshot(encoded: bytes) -> dict:
    try:
        snapshot = json.loads(encoded.decode("utf-8"), object_pairs_hook=_duplicate_guard)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise SnapshotError(f"invalid source snapshot: {error}") from error
    if not isinstance(snapshot, dict) or canonical_bytes(snapshot) != encoded:
        raise SnapshotError("source snapshot is not canonical JSON")
    if set(snapshot) != {"schema_version", "source_revision", "files"} or snapshot["schema_version"] != 1:
        raise SnapshotError("unsupported source snapshot schema")
    if not isinstance(snapshot["source_revision"], str) or not re.fullmatch(r"[0-9a-f]{40}", snapshot["source_revision"]):
        raise SnapshotError("invalid source snapshot base revision")
    entries = snapshot["files"]
    if not isinstance(entries, list) or not entries:
        raise SnapshotError("empty source snapshot")
    paths = []
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) != {"path", "sha256", "size"}:
            raise SnapshotError("invalid source file record")
        paths.append(_safe_path(entry["path"]))
        if type(entry["size"]) is not int or entry["size"] < 0:
            raise SnapshotError("invalid source file size")
        if not isinstance(entry["sha256"], str) or not re.fullmatch(r"[0-9a-f]{64}", entry["sha256"]):
            raise SnapshotError("invalid source file digest")
    if paths != sorted(set(paths)):
        raise SnapshotError("source paths must be sorted and unique")
    return snapshot


def capture_snapshot(repository_root: Path) -> dict:
    root = Path(repository_root).resolve(strict=True)
    if Path(_git(root, "rev-parse", "--show-toplevel").decode().strip()).resolve() != root:
        raise SnapshotError("snapshot requires the repository root")
    revision = _git(root, "rev-parse", "--verify", "HEAD").decode().strip()
    names = _git(root, "ls-files", "-z", "--cached", "--others", "--exclude-standard")
    entries = []
    for name in sorted(set(names.decode("utf-8").rstrip("\0").split("\0"))):
        relative = PurePosixPath(_safe_path(name))
        path = root / relative
        # Check every ancestor: a directory link must never redirect source reads.
        for ancestor in (path, *path.parents):
            if ancestor == root:
                break
            if ancestor.is_symlink() or (hasattr(ancestor, "is_junction") and ancestor.is_junction()):
                raise SnapshotError(f"source links are unsupported: {name}")
        if not path.exists():
            continue  # A tracked deletion is represented by absence from the inventory.
        if not path.is_file():
            raise SnapshotError(f"source entry is not a regular file: {name}")
        data = path.read_bytes()
        entries.append({"path": name, "sha256": hashlib.sha256(data).hexdigest(), "size": len(data)})
    snapshot = {"schema_version": 1, "source_revision": revision, "files": entries}
    return validate_snapshot(canonical_bytes(snapshot))


def verify_snapshot(repository_root: Path, encoded: bytes) -> dict:
    snapshot = validate_snapshot(encoded)
    if canonical_bytes(capture_snapshot(repository_root)) != encoded:
        raise SnapshotError("source inventory changed since the qualification snapshot")
    return snapshot


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("capture", "verify", "identity"))
    parser.add_argument("--repository-root", type=Path, required=True)
    parser.add_argument("--snapshot", type=Path, required=True)
    arguments = parser.parse_args()
    try:
        if arguments.command == "capture":
            encoded = canonical_bytes(capture_snapshot(arguments.repository_root))
            # Keep captures under an ignored output directory to avoid self-reference.
            relative = arguments.snapshot.resolve().relative_to(arguments.repository_root.resolve())
            ignored = subprocess.run(
                ["git", "check-ignore", "--quiet", "--", relative.as_posix()],
                cwd=arguments.repository_root, capture_output=True,
            )
            if ignored.returncode != 0:
                raise SnapshotError("snapshot output must be ignored by this repository")
            with arguments.snapshot.open("xb") as output:
                output.write(encoded)
        else:
            encoded = arguments.snapshot.read_bytes()
            verify_snapshot(arguments.repository_root, encoded)
        snapshot = validate_snapshot(encoded)
        print(json.dumps({"source_revision": snapshot["source_revision"],
                          "feature_fingerprint": local_fingerprint(encoded),
                          "source_sha256": hashlib.sha256(encoded).hexdigest(),
                          "files": len(snapshot["files"]), "qualification": "local-source-snapshot-v1"}))
        return 0
    except (SnapshotError, OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Dogmos source snapshot failed: {error}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
