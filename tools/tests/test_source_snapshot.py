import json
from pathlib import Path
import subprocess
import tempfile
import unittest

from tools.dogmos_source_snapshot import (
    SnapshotError,
    capture_snapshot,
    canonical_bytes,
    local_fingerprint,
    validate_snapshot,
    verify_snapshot,
)


class SourceSnapshotTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.git("init", "-b", "master")
        self.git("config", "user.email", "snapshot@example.invalid")
        self.git("config", "user.name", "Snapshot Test")
        (self.root / ".gitignore").write_bytes(b"target/\n")
        (self.root / "source.rs").write_bytes(b"original\r\n")
        self.git("add", ".")
        self.git("commit", "-m", "fixture")

    def git(self, *arguments):
        return subprocess.run(
            ["git", *arguments], cwd=self.root, check=True, capture_output=True
        ).stdout

    def test_canonical_snapshot_preserves_raw_bytes_and_untracked_source(self):
        (self.root / "source.rs").write_bytes(b"modified\r\n")
        (self.root / "new.rs").write_bytes(b"untracked\n")
        (self.root / "target").mkdir()
        (self.root / "target" / "ignored").write_bytes(b"not an input")
        snapshot = capture_snapshot(self.root)
        encoded = canonical_bytes(snapshot)
        self.assertEqual(snapshot, validate_snapshot(encoded))
        self.assertEqual(encoded, canonical_bytes(capture_snapshot(self.root)))
        self.assertEqual([entry["path"] for entry in snapshot["files"]],
                         [".gitignore", "new.rs", "source.rs"])
        self.assertEqual(snapshot["files"][2]["size"], 10)
        self.assertEqual(snapshot["source_revision"], self.git("rev-parse", "HEAD").decode().strip())
        verify_snapshot(self.root, encoded)
        self.assertEqual(len(local_fingerprint(encoded)), 64)
        (self.root / "source.rs").write_bytes(b"modified\n")
        with self.assertRaisesRegex(SnapshotError, "changed"):
            verify_snapshot(self.root, encoded)
        self.assertNotEqual(local_fingerprint(encoded), local_fingerprint(canonical_bytes(capture_snapshot(self.root))))

    def test_added_deleted_and_changed_files_reject(self):
        encoded = canonical_bytes(capture_snapshot(self.root))
        (self.root / "new.rs").write_bytes(b"new")
        with self.assertRaisesRegex(SnapshotError, "changed"):
            verify_snapshot(self.root, encoded)
        (self.root / "new.rs").unlink()
        (self.root / "source.rs").unlink()
        with self.assertRaisesRegex(SnapshotError, "changed"):
            verify_snapshot(self.root, encoded)

    def test_links_are_rejected_when_supported(self):
        link = self.root / "linked.rs"
        try:
            link.symlink_to(self.root / "source.rs")
        except OSError:
            self.skipTest("OS does not permit symlinks")
        with self.assertRaisesRegex(SnapshotError, "link"):
            capture_snapshot(self.root)

    def test_manifest_rejects_unsafe_duplicate_and_noncanonical_paths(self):
        original = capture_snapshot(self.root)
        for path in ("../escape", "C:/escape", "/escape", "a\\b", "./a", "a//b", "a/../b"):
            with self.subTest(path=path):
                snapshot = json.loads(json.dumps(original))
                snapshot["files"][0]["path"] = path
                with self.assertRaises(SnapshotError):
                    validate_snapshot(canonical_bytes(snapshot))
        snapshot = json.loads(json.dumps(original))
        snapshot["files"].append(snapshot["files"][0])
        with self.assertRaises(SnapshotError):
            validate_snapshot(canonical_bytes(snapshot))
        with self.assertRaises(SnapshotError):
            validate_snapshot(canonical_bytes(original).replace(b"\n", b"\r\n"))


if __name__ == "__main__":
    unittest.main()
