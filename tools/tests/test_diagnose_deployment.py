"""Offline integration with the paired game's verifier; set DOGMOS_GAME_ROOT for a non-sibling checkout."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

TOOLS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS))
import diagnose_deployment
from dogmos_source_snapshot import canonical_bytes, capture_snapshot


class DeploymentDiagnosisTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        paired = Path(os.environ.get("DOGMOS_GAME_ROOT", TOOLS.parent.parent / "Meridian-Rift"))
        cls.verifier_path = paired / "tools/dogmos/verify_contract.py"
        if not cls.verifier_path.is_file():
            raise unittest.SkipTest("Set DOGMOS_GAME_ROOT to the paired Meridian-Rift checkout")
        cls.manifest_bytes = (paired / "dogmos.lock.json").read_bytes()
        spec = importlib.util.spec_from_file_location("paired_contract_fixture", cls.verifier_path)
        cls.verifier = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.verifier)

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        self.native, self.game, self.bundle = (root / name for name in ("native", "game", "bundle"))
        for repository in (self.native, self.game):
            repository.mkdir()
            (repository / "source.txt").write_bytes(b"fixture source\n")
            for arguments in (
                ("init", "-b", "master"),
                ("add", "."),
                ("-c", "user.name=Diagnosis Test", "-c", "user.email=diagnosis@example.invalid", "commit", "-m", "fixture"),
            ):
                subprocess.run(["git", *arguments], cwd=repository, check=True, capture_output=True)
        self.bundle.mkdir()
        verifier_copy = self.game / "tools/dogmos/verify_contract.py"
        verifier_copy.parent.mkdir(parents=True)
        shutil.copyfile(self.verifier_path, verifier_copy)
        encoded = canonical_bytes(capture_snapshot(self.native))
        digest = hashlib.sha256(encoded).hexdigest()
        # Only a PE architecture header is needed: this fixture never loads executable code.
        dll = bytearray(128)
        dll[:2] = b"MZ"
        struct.pack_into("<I", dll, 0x3C, 64)
        dll[64:68] = b"PE\0\0"
        struct.pack_into("<H", dll, 68, 0x014C)
        artifacts = {
            "dogmos.dll": bytes(dll),
            "dogmos.pdb": b"fixture symbols",
            "dogmos-source-snapshot.json": encoded,
            "dogmos_bindings.dm": (
                '#define DOGMOS_IN_PROCESS\n'
                f'#define DOGMOS_IN_PROCESS_IDENTITY "in-process:{digest}"\n'
                '#define DOGMOS_BYOND "libdogmos_in_process"\n'
            ).encode(),
        }
        self.manifest = json.loads(self.manifest_bytes)
        self.manifest.update(source_revision=json.loads(encoded)["source_revision"], source_sha256=digest,
                             artifacts={name: hashlib.sha256(data).hexdigest() for name, data in artifacts.items()})
        for name, data in artifacts.items():
            (self.bundle / name).write_bytes(data)
        # An undeclared symbol file must neither fail diagnosis nor replace declared symbols.
        (self.bundle / "unlisted.pdb").write_bytes(b"unrelated symbols")
        defines = self.game / "code/__DEFINES"
        defines.mkdir(parents=True)
        (self.game / "dogmos.dll").write_bytes(artifacts["dogmos.dll"])
        (defines / "dogmos_bindings.dm").write_bytes(artifacts["dogmos_bindings.dm"])
        (defines / "dogmos_contract.dm").write_bytes(self.verifier.render_contract_defines(self.manifest))
        (self.game / "dogmos.lock.json").write_bytes(canonical_bytes(self.manifest))

    def diagnose(self, target="i686-pc-windows-msvc"):
        return diagnose_deployment.diagnose(self.game, self.native, target, self.bundle)

    def test_matching_bundle_and_json_cli_use_the_paired_verifier(self):
        report = self.diagnose()
        self.assertTrue(report["ok"], report["errors"])
        self.assertEqual(report["installed_contract"], "verified")
        self.assertEqual(report["symbols"], "matching")
        self.assertEqual(report["runtime"], "not checked")
        self.assertEqual(report["artifacts"], self.manifest["artifacts"])
        self.assertEqual(report["qualification"], {
            "kind": "unqualified-in-process-playtest", "tests_run": False, "runtime_qualified": False,
        })
        result = subprocess.run([
            sys.executable, "-B", str(TOOLS / "diagnose_deployment.py"),
            "--game-root", str(self.game), "--native-root", str(self.native),
            "--target", "i686-pc-windows-msvc", "--bundle", str(self.bundle), "--json",
        ], capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), report)

    def test_requested_target_mismatch_is_reported(self):
        report = self.diagnose("i686-unknown-linux-gnu")
        self.assertFalse(report["ok"])
        self.assertEqual(report["target"], "i686-pc-windows-msvc")
        self.assertEqual(report["symbols"], "matching")
        self.assertEqual(report["errors"], [
            "Installed target i686-pc-windows-msvc differs from requested target i686-unknown-linux-gnu.",
        ])

    def test_missing_or_corrupt_declared_symbols_fail(self):
        symbols = self.bundle / "dogmos.pdb"
        for mutation in ("missing", "corrupt"):
            with self.subTest(mutation=mutation):
                if mutation == "missing":
                    symbols.unlink()
                else:
                    symbols.write_bytes(b"corrupt symbols")
                report = self.diagnose()
                self.assertFalse(report["ok"])
                self.assertEqual(report["symbols"], "missing or mismatched")
                self.assertEqual(report["errors"], ["Bundle artifact missing or mismatched: dogmos.pdb"])

    def test_installed_artifact_failure_is_reported(self):
        (self.game / "dogmos.dll").write_bytes(b"corrupt installed library")
        report = self.diagnose()
        self.assertFalse(report["ok"])
        self.assertEqual(report["symbols"], "not checked; provide --bundle")
        self.assertEqual(report["errors"], ["in-process artifact does not match lock: dogmos.dll"])


if __name__ == "__main__":
    unittest.main()
