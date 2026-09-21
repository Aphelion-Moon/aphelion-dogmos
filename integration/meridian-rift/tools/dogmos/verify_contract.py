from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import struct
import subprocess
from typing import Any


HEX_40 = re.compile(r"^[0-9a-f]{40}$")
HEX_64 = re.compile(r"^[0-9a-f]{64}$")
EXPECTED_ARTIFACTS = {
    ("linux", "service"): ("x86_64-unknown-linux-gnu", "x86_64", "elf"),
    ("linux", "shim"): ("i686-unknown-linux-gnu", "i686", "elf"),
    ("windows", "service"): ("x86_64-pc-windows-msvc", "x86_64", "pe"),
    ("windows", "shim"): ("i686-pc-windows-msvc", "i686", "pe"),
}
INSTALLED_ARTIFACTS = {
    ("linux", "service"): "dogmosd",
    ("linux", "shim"): "libdogmos.so",
    ("windows", "service"): "dogmosd.exe",
    ("windows", "shim"): "dogmos.dll",
}


class ContractError(ValueError):
    pass


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _duplicate_guard(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result = {}
    for key, value in pairs:
        if key in result:
            raise ContractError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _safe_name(name: Any, description: str) -> str:
    if not isinstance(name, str) or not name:
        raise ContractError(f"invalid {description} path")
    path = PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts or "\\" in name:
        raise ContractError(f"unsafe {description} path: {name!r}")
    if path.as_posix() != name or name.startswith("./"):
        raise ContractError(f"noncanonical {description} path: {name!r}")
    return name


def _required_file(path: Path, description: str) -> bytes:
    if not path.is_file():
        raise ContractError(f"missing {description}: {path}")
    data = path.read_bytes()
    if not data:
        raise ContractError(f"empty {description}: {path}")
    return data


def _detect_architecture(data: bytes) -> tuple[str, str]:
    if data.startswith(b"MZ"):
        if len(data) < 64:
            raise ContractError("truncated PE artifact")
        offset = struct.unpack_from("<I", data, 0x3C)[0]
        if offset > len(data) - 6 or data[offset : offset + 4] != b"PE\0\0":
            raise ContractError("invalid PE artifact")
        machine = struct.unpack_from("<H", data, offset + 4)[0]
        architecture = {0x014C: "i686", 0x8664: "x86_64"}.get(machine)
        if architecture is None:
            raise ContractError(f"unsupported PE machine 0x{machine:04x}")
        return "pe", architecture
    if data.startswith(b"\x7fELF"):
        if len(data) < 20 or data[5] != 1:
            raise ContractError("invalid or non-little-endian ELF artifact")
        architecture = {(1, 3): "i686", (2, 62): "x86_64"}.get(
            (data[4], struct.unpack_from("<H", data, 18)[0])
        )
        if architecture is None:
            raise ContractError("unsupported ELF class or machine")
        return "elf", architecture
    raise ContractError("artifact is neither PE nor ELF")


def _decode_manifest(data: bytes) -> dict[str, Any]:
    if b"\r" in data or not data.endswith(b"\n") or data.endswith(b"\n\n"):
        raise ContractError("manifest must use LF and exactly one terminal LF")
    try:
        manifest = json.loads(data.decode("utf-8"), object_pairs_hook=_duplicate_guard)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ContractError(f"invalid manifest JSON: {error}") from error
    if not isinstance(manifest, dict):
        raise ContractError("manifest root must be an object")
    canonical = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode()
    if canonical != data:
        raise ContractError("manifest JSON is not canonical")
    return manifest


def _validate_record(record: Any, description: str) -> None:
    if not isinstance(record, dict):
        raise ContractError(f"invalid {description} record")
    _safe_name(record.get("file"), description)
    digest = record.get("sha256")
    if not isinstance(digest, str) or not HEX_64.fullmatch(digest):
        raise ContractError(f"invalid {description} digest")
    if not isinstance(record.get("size"), int) or record["size"] <= 0:
        raise ContractError(f"invalid {description} size")


def _validate_structure(manifest: dict[str, Any], *, allow_local_qualification: bool = False) -> None:
    if manifest.get("schema_version") != 1:
        raise ContractError("unsupported Dogmos contract schema")
    if manifest.get("build_profile") != "release":
        raise ContractError("Dogmos contract is not a release build")
    revision = manifest.get("source_revision")
    if not isinstance(revision, str) or not HEX_40.fullmatch(revision):
        raise ContractError("Dogmos contract has an invalid source revision")
    capabilities = manifest.get("capabilities")
    if not isinstance(capabilities, dict):
        raise ContractError("Dogmos contract has no capabilities")
    features = capabilities.get("features")
    if not isinstance(features, list) or features != sorted(set(features)):
        raise ContractError("Dogmos features must be sorted and unique")
    fingerprint = capabilities.get("feature_fingerprint")
    if not isinstance(fingerprint, str) or not HEX_64.fullmatch(fingerprint):
        raise ContractError("Dogmos feature fingerprint is invalid")
    if "qualification" in manifest:
        if not allow_local_qualification:
            raise ContractError("local qualification bundles are not production releases")
        qualification = manifest["qualification"]
        if (not isinstance(qualification, dict)
                or set(qualification) != {"kind", "source_snapshot"}
                or qualification["kind"] != "local-source-snapshot-v1"):
            raise ContractError("invalid local qualification marker")
        record = qualification["source_snapshot"]
        _validate_record(record, "local source snapshot")
        if record["file"] != "dogmos-source-snapshot.json":
            raise ContractError("invalid local source snapshot filename")
        expected = _sha256(b"dogmos-local-qualification-v1\0" + bytes.fromhex(record["sha256"]))
        if fingerprint != expected:
            raise ContractError("local source snapshot handshake fingerprint mismatch")
    toolchain = manifest.get("toolchain")
    if not isinstance(toolchain, dict):
        raise ContractError("Dogmos contract has no toolchain")
    if not re.fullmatch(r"\d+\.\d+\.\d+", toolchain.get("rust", "")):
        raise ContractError("Dogmos Rust version is invalid")
    if not re.fullmatch(r"\d+\.\d+", toolchain.get("byond", "")):
        raise ContractError("Dogmos BYOND version is invalid")
    if not HEX_40.fullmatch(toolchain.get("byondapi_revision", "")):
        raise ContractError("Dogmos byondapi revision is invalid")
    versions = manifest.get("versions")
    if not isinstance(versions, dict) or set(versions) != {
        "abi",
        "dogmos-byond",
        "dogmos-server",
        "protocol",
        "workspace",
    }:
        raise ContractError("Dogmos contract version fields are invalid")
    if not isinstance(versions["abi"], int) or not isinstance(
        versions["protocol"], int
    ):
        raise ContractError("Dogmos ABI and protocol versions must be integers")
    for package in ("dogmos-byond", "dogmos-server", "workspace"):
        if not re.fullmatch(r"\d+\.\d+\.\d+", versions[package]):
            raise ContractError(f"Dogmos {package} version is invalid")
    _validate_record(manifest.get("bindings"), "bindings")
    artifacts = manifest.get("artifacts")
    if not isinstance(artifacts, list) or len(artifacts) != 4:
        raise ContractError("Dogmos contract requires four platform artifacts")
    pairs = []
    names = {manifest["bindings"]["file"]}
    for artifact in artifacts:
        _validate_record(artifact, "artifact")
        pair = (artifact.get("platform"), artifact.get("role"))
        expected = EXPECTED_ARTIFACTS.get(pair)
        if expected is None or pair in pairs:
            raise ContractError(f"unexpected or duplicate artifact pair: {pair}")
        pairs.append(pair)
        target, architecture, artifact_format = expected
        if (
            artifact.get("target"),
            artifact.get("architecture"),
            artifact.get("format"),
        ) != (target, architecture, artifact_format):
            raise ContractError(f"artifact identity mismatch: {pair}")
        _validate_record(artifact.get("symbols"), "symbols")
        for name in (artifact["file"], artifact["symbols"]["file"]):
            if name in names:
                raise ContractError(f"duplicate contract path: {name}")
            names.add(name)
    if pairs != sorted(EXPECTED_ARTIFACTS):
        raise ContractError("Dogmos artifacts are not in canonical order")


def _verify_record(record: dict[str, Any], root: Path, description: str) -> bytes:
    data = _required_file(root / PurePosixPath(record["file"]), description)
    if len(data) != record["size"] or _sha256(data) != record["sha256"]:
        raise ContractError(f"{description} hash or size mismatch: {record['file']}")
    return data


def _local_source_snapshot(manifest: dict[str, Any], bundle_root: Path) -> dict[str, Any]:
    record = manifest["qualification"]["source_snapshot"]
    encoded = _verify_record(record, bundle_root, "local source snapshot")
    try:
        snapshot = json.loads(encoded.decode("utf-8"), object_pairs_hook=_duplicate_guard)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ContractError(f"invalid local source snapshot: {error}") from error
    if (not isinstance(snapshot, dict)
            or set(snapshot) != {"schema_version", "source_revision", "files"}
            or snapshot["schema_version"] != 1
            or snapshot["source_revision"] != manifest["source_revision"]
            or (json.dumps(snapshot, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode() != encoded):
        raise ContractError("invalid local source snapshot schema, base revision or canonical bytes")
    entries = snapshot["files"]
    if not isinstance(entries, list) or not entries:
        raise ContractError("empty local source snapshot")
    names = []
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) != {"path", "size", "sha256"}:
            raise ContractError("invalid local source record")
        name = _safe_name(entry["path"], "source")
        if ":" in name or ".git" in PurePosixPath(name).parts or any(ord(c) < 32 for c in name):
            raise ContractError("unsafe local source path")
        if (type(entry["size"]) is not int or entry["size"] < 0
                or not isinstance(entry["sha256"], str) or not HEX_64.fullmatch(entry["sha256"])):
            raise ContractError("invalid local source size or digest")
        names.append(name)
    if names != sorted(set(names)):
        raise ContractError("local source paths must be sorted and unique")
    return snapshot


def verify_local_source(manifest: dict[str, Any], bundle_root: Path, repository_root: Path) -> None:
    snapshot = _local_source_snapshot(manifest, bundle_root)
    root = repository_root.resolve(strict=True)

    def git(*arguments: str) -> bytes:
        return subprocess.run(["git", *arguments], cwd=root, check=True, capture_output=True).stdout

    if Path(git("rev-parse", "--show-toplevel").decode().strip()).resolve() != root:
        raise ContractError("local source verification requires the repository root")
    if git("rev-parse", "--verify", "HEAD").decode().strip() != snapshot["source_revision"]:
        raise ContractError("local source base revision changed")
    listed = git("ls-files", "-z", "--cached", "--others", "--exclude-standard")
    current = []
    for name in sorted(set(listed.decode("utf-8").rstrip("\0").split("\0"))):
        if ":" in name or ".git" in PurePosixPath(name).parts or any(ord(c) < 32 for c in name):
            raise ContractError("unsafe local source inventory path")
        path = root / PurePosixPath(_safe_name(name, "source"))
        for ancestor in (path, *path.parents):
            if ancestor == root:
                break
            if ancestor.is_symlink() or (hasattr(ancestor, "is_junction") and ancestor.is_junction()):
                raise ContractError(f"local source link is unsupported: {name}")
        if not path.exists():
            continue
        if not path.is_file():
            raise ContractError(f"local source entry is not a regular file: {name}")
        data = path.read_bytes()
        current.append({"path": name, "size": len(data), "sha256": _sha256(data)})
    if current != snapshot["files"]:
        raise ContractError("local source inventory changed since the qualification snapshot")


def validate_release(data: bytes, bundle_root: Path, *, allow_local_qualification: bool = False) -> dict[str, Any]:
    manifest = _decode_manifest(data)
    _validate_structure(manifest, allow_local_qualification=allow_local_qualification)
    bundle_root = Path(bundle_root)
    if "qualification" in manifest:
        _local_source_snapshot(manifest, bundle_root)
    _verify_record(manifest["bindings"], bundle_root, "bindings")
    for artifact in manifest["artifacts"]:
        binary = _verify_record(artifact, bundle_root, "artifact")
        detected = _detect_architecture(binary)
        if detected != (artifact["format"], artifact["architecture"]):
            raise ContractError(
                f"artifact byte architecture mismatch: {artifact['platform']}/{artifact['role']}"
            )
        _verify_record(artifact["symbols"], bundle_root, "symbols")
    return manifest


def _artifact(manifest: dict[str, Any], platform: str, role: str) -> dict[str, Any]:
    return next(
        artifact
        for artifact in manifest["artifacts"]
        if artifact["platform"] == platform and artifact["role"] == role
    )


def render_contract_defines(manifest: dict[str, Any]) -> bytes:
    if manifest.get("kind") == "unqualified-in-process-playtest":
        validate_in_process_manifest(manifest)
        return ("// Generated by tools/dogmos/verify_contract.py. Do not edit.\n"
                f'#define DOGMOS_CONTRACT_SOURCE_REVISION "{manifest["source_revision"]}"\n'
                f'#define DOGMOS_CONTRACT_SOURCE_SHA256 "{manifest["source_sha256"]}"\n'
                f'#define DOGMOS_CONTRACT_BINDINGS_SHA256 "{manifest["artifacts"]["dogmos_bindings.dm"]}"\n'
                f'#define DOGMOS_CONTRACT_WINDOWS_NATIVE_SHA256 "{manifest["artifacts"]["dogmos.dll"]}"\n'
                '#define DOGMOS_CONTRACT_UNQUALIFIED_IN_PROCESS 1\n').encode()
    values = manifest["versions"]
    capabilities = manifest["capabilities"]
    lines = [
        "// Generated by tools/dogmos/verify_contract.py. Do not edit.",
        f"#define DOGMOS_CONTRACT_SCHEMA_VERSION {manifest['schema_version']}",
        f"#define DOGMOS_CONTRACT_ABI_VERSION {values['abi']}",
        f"#define DOGMOS_CONTRACT_PROTOCOL_VERSION {values['protocol']}",
        f'#define DOGMOS_CONTRACT_SOURCE_REVISION "{manifest["source_revision"]}"',
        f'#define DOGMOS_CONTRACT_FEATURE_FINGERPRINT "{capabilities["feature_fingerprint"]}"',
        f'#define DOGMOS_CONTRACT_BYOND_VERSION "{manifest["toolchain"]["byond"]}"',
        f'#define DOGMOS_CONTRACT_BINDINGS_SHA256 "{manifest["bindings"]["sha256"]}"',
    ]
    for platform, role in sorted(EXPECTED_ARTIFACTS):
        artifact = _artifact(manifest, platform, role)
        macro = f"DOGMOS_CONTRACT_{platform}_{role}_SHA256".upper()
        lines.append(f'#define {macro} "{artifact["sha256"]}"')
    if "qualification" in manifest:
        lines.append("#define DOGMOS_CONTRACT_LOCAL_QUALIFICATION 1")
    return ("\n".join(lines) + "\n").encode()


def validate_in_process_manifest(manifest: dict[str, Any]) -> None:
    """Accept only the explicitly selected Windows compile-only native candidate."""
    if (manifest.get("schema_version") != 1
            or manifest.get("kind") != "unqualified-in-process-playtest"
            or manifest.get("backend") != "in-process"
            or manifest.get("target") != "i686-pc-windows-msvc"
            or manifest.get("toolchain") != "1.98.0"
            or manifest.get("tests_run") is not False
            or manifest.get("runtime_qualified") is not False):
        raise ContractError("unsupported in-process play-test contract")
    for key, pattern in (("source_revision", HEX_40), ("source_sha256", HEX_64)):
        if not isinstance(manifest.get(key), str) or not pattern.fullmatch(manifest[key]):
            raise ContractError(f"invalid in-process {key}")
    features = ["aphelion_reactions", "katmos", "katmos_slow_decompression",
                "superconductivity", "turf_processing"]
    if manifest.get("features") != features:
        raise ContractError("in-process feature selection differs from the play-test contract")
    arguments = ["+1.98.0", "build", "-p", "dogmos", "--lib", "--example", "generate_bindings",
                 "--release", "--locked", "--target", "i686-pc-windows-msvc",
                 "--no-default-features", "--features", ",".join(features)]
    if manifest.get("cargo_arguments") != arguments:
        raise ContractError("in-process build arguments differ from the play-test contract")
    artifacts = manifest.get("artifacts")
    if not isinstance(artifacts, dict) or set(artifacts) != {
            "dogmos.dll", "dogmos.pdb", "dogmos_bindings.dm", "dogmos-source-snapshot.json"}:
        raise ContractError("invalid in-process artifact set")
    if any(not isinstance(value, str) or not HEX_64.fullmatch(value) for value in artifacts.values()):
        raise ContractError("invalid in-process artifact digest")
    if artifacts["dogmos-source-snapshot.json"] != manifest["source_sha256"]:
        raise ContractError("in-process snapshot identity mismatch")


def verify_in_process_bytes(manifest: dict[str, Any], dll: bytes, bindings: bytes) -> None:
    validate_in_process_manifest(manifest)
    for name, data in (("dogmos.dll", dll), ("dogmos_bindings.dm", bindings)):
        if _sha256(data) != manifest["artifacts"][name]:
            raise ContractError(f"in-process artifact does not match lock: {name}")
    if _detect_architecture(dll) != ("pe", "i686"):
        raise ContractError("in-process DLL is not Windows i686")
    identity = f'#define DOGMOS_IN_PROCESS_IDENTITY "in-process:{manifest["source_sha256"]}"'
    if (b"#define DOGMOS_IN_PROCESS\n" not in bindings
            or identity.encode() not in bindings
            or b'"libdogmos_in_process"' not in bindings
            or b'"libdogmos"' in bindings):
        raise ContractError("generated bindings select the wrong backend or source identity")


def verify_installed(root: Path) -> dict[str, Any]:
    root = Path(root)
    lock_bytes = _required_file(root / "dogmos.lock.json", "Dogmos lock")
    manifest = _decode_manifest(lock_bytes)
    if manifest.get("kind") == "unqualified-in-process-playtest":
        verify_in_process_bytes(manifest, _required_file(root / "dogmos.dll", "native DLL"),
                                _required_file(root / "code/__DEFINES/dogmos_bindings.dm", "bindings"))
        if _required_file(root / "code/__DEFINES/dogmos_contract.dm", "contract") != render_contract_defines(manifest):
            raise ContractError("generated in-process contract defines drifted from the lock")
        return manifest
    # Installed verification checks bytes and identity for local development/test
    # runners too. Accepting a local install is an explicit synchronization action;
    # release validation continues to reject it by default.
    _validate_structure(manifest, allow_local_qualification=True)
    bindings_path = root / "code" / "__DEFINES" / "dogmos_bindings.dm"
    bindings = _required_file(bindings_path, "installed bindings")
    if (
        len(bindings) != manifest["bindings"]["size"]
        or _sha256(bindings) != manifest["bindings"]["sha256"]
    ):
        raise ContractError("installed bindings do not match dogmos.lock.json")
    for pair, relative_path in INSTALLED_ARTIFACTS.items():
        artifact = _artifact(manifest, *pair)
        binary = _required_file(root / relative_path, f"installed {pair}")
        if len(binary) != artifact["size"] or _sha256(binary) != artifact["sha256"]:
            raise ContractError(f"installed artifact does not match lock: {relative_path}")
        if _detect_architecture(binary) != (
            artifact["format"],
            artifact["architecture"],
        ):
            raise ContractError(f"installed artifact architecture mismatch: {relative_path}")
    defines = _required_file(
        root / "code" / "__DEFINES" / "dogmos_contract.dm",
        "generated Dogmos contract defines",
    )
    if defines != render_contract_defines(manifest):
        raise ContractError("generated Dogmos contract defines drifted from the lock")
    return manifest


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Verify a Meridian-Rift Dogmos contract")
    commands = parser.add_subparsers(dest="command", required=True)
    release = commands.add_parser("validate-release")
    release.add_argument("--manifest", type=Path, required=True)
    release.add_argument("--bundle-root", type=Path, required=True)
    release.add_argument("--allow-local-qualification", action="store_true")
    local_source = commands.add_parser("verify-local-source")
    local_source.add_argument("--manifest", type=Path, required=True)
    local_source.add_argument("--bundle-root", type=Path, required=True)
    local_source.add_argument("--repository-root", type=Path, required=True)
    render = commands.add_parser("render-defines")
    render.add_argument("--manifest", type=Path, required=True)
    render.add_argument("--bundle-root", type=Path, required=True)
    render.add_argument("--output", type=Path, required=True)
    render.add_argument("--allow-local-qualification", action="store_true")
    installed = commands.add_parser("verify-installed")
    installed.add_argument("--root", type=Path, required=True)
    return parser


def main() -> int:
    arguments = _parser().parse_args()
    try:
        if arguments.command == "verify-installed":
            verify_installed(arguments.root)
            return 0
        manifest_bytes = arguments.manifest.read_bytes()
        manifest = validate_release(manifest_bytes, arguments.bundle_root,
                                    allow_local_qualification=arguments.command == "verify-local-source"
                                    or arguments.allow_local_qualification)
        if arguments.command == "verify-local-source":
            if "qualification" not in manifest:
                raise ContractError("local source verification requires a qualification bundle")
            verify_local_source(manifest, arguments.bundle_root, arguments.repository_root)
        if arguments.command == "render-defines":
            arguments.output.write_bytes(render_contract_defines(manifest))
        return 0
    except (ContractError, OSError, subprocess.CalledProcessError) as error:
        print(f"Dogmos contract verification failed: {error}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
