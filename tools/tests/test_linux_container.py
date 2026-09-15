import json
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from tools.test_linux_container import elf_class, qualify


class LinuxContainerTests(unittest.TestCase):
    def test_rejects_wrong_elf_architecture(self):
        with tempfile.TemporaryDirectory() as temporary:
            probe = Path(temporary) / "probe"
            header = bytearray(20)
            header[:6] = b"\x7fELF\x01\x01"
            struct.pack_into("<H", header, 18, 62)  # x64 machine cannot be an i686 ELF.
            probe.write_bytes(header)
            with self.assertRaises(ValueError):
                elf_class(probe)

    def test_timeout_removes_only_owned_container_and_preserves_diagnostics(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "linux").mkdir()
            (root / "dogmos-release-manifest.json").write_text(json.dumps({"source_revision": "fixture"}))
            probe = root / "probe"
            probe.write_bytes(b"probe")
            calls = []

            def invoke(arguments, **kwargs):
                calls.append(arguments)
                if arguments[:2] == ["docker", "create"]:
                    return subprocess.CompletedProcess(arguments, 0, "owned-exact-id\n", "")
                if arguments[:2] == ["docker", "start"]:
                    raise subprocess.TimeoutExpired(arguments, 180, output=b"partial diagnostic\n")
                return subprocess.CompletedProcess(arguments, 0, "", "")

            with patch("tools.test_linux_container.elf_class", side_effect=[1, 2, 1]), patch("tools.test_linux_container.run", side_effect=invoke):
                with self.assertRaises(subprocess.TimeoutExpired):
                    qualify(root, probe, root / "result", "sha256:" + "a" * 64, allow_local_qualification=True)
            self.assertIn("--allow-local-qualification", calls[0])
            self.assertIn(["docker", "rm", "--force", "owned-exact-id"], calls)
            self.assertIn(["docker", "ps", "--all", "--quiet", "--filter", "id=owned-exact-id"], calls)
            report = json.loads((root / "result/result.json").read_text())
            self.assertFalse(report["passed"])
            self.assertTrue(report["container_removed"])
            self.assertEqual((root / "result/stdout.log").read_text(), "partial diagnostic\n")

    def test_unapproved_local_bundle_fails_before_container_creation(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with patch("tools.test_linux_container.run", side_effect=subprocess.CalledProcessError(1, "verify")) as invoke:
                with self.assertRaises(subprocess.CalledProcessError):
                    qualify(root, root / "probe", root / "result", "sha256:" + "a" * 64)
            self.assertEqual(invoke.call_count, 1)
            self.assertNotIn("--allow-local-qualification", invoke.call_args.args[0])


if __name__ == "__main__":
    unittest.main()
