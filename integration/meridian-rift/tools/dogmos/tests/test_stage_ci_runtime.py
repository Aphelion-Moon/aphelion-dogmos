"""CI packaging regression tests; synthetic fixtures are not native runtime evidence."""

import importlib
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from tools.dogmos.tests.test_contract import ContractFixture
from tools.dogmos.verify_contract import INSTALLED_ARTIFACTS, render_contract_defines


class InstalledFixture(ContractFixture):
    """Reuse synthetic binary/manifest generation without git or native processes."""

    def __init__(self, root: Path) -> None:
        self.repository = root / "fixture"
        self.repository.mkdir()
        self.bundle = self.repository / "release-bundle"
        self.revision = "a" * 40
        self._write_bundle()
        self.installed = root / "installed"
        defines = self.installed / "code/__DEFINES"
        defines.mkdir(parents=True)
        (self.installed / "dogmos.lock.json").write_bytes(self.manifest_path.read_bytes())
        (defines / "dogmos_bindings.dm").write_bytes(
            (self.bundle / self.manifest["bindings"]["file"]).read_bytes()
        )
        (defines / "dogmos_contract.dm").write_bytes(render_contract_defines(self.manifest))
        for artifact in self.manifest["artifacts"]:
            name = INSTALLED_ARTIFACTS[artifact["platform"], artifact["role"]]
            (self.installed / name).write_bytes((self.bundle / artifact["file"]).read_bytes())


class CiRuntimeStagingTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.fixture = InstalledFixture(self.root)
        self.destination = self.root / "ci_test"
        self.destination.mkdir()

    def stager(self):
        self.assertTrue(
            (REPOSITORY_ROOT / "tools/dogmos/stage_ci_runtime.py").is_file(),
            "runtime staging helper is missing",
        )
        return importlib.import_module("tools.dogmos.stage_ci_runtime")

    def test_stages_complete_verified_linux_pair(self) -> None:
        self.stager().stage_runtime(self.fixture.installed, self.destination)
        self.assertEqual({p.name for p in self.destination.iterdir()}, {"dogmosd", "libdogmos.so"})
        for name in ("dogmosd", "libdogmos.so"):
            self.assertEqual(
                (self.destination / name).read_bytes(),
                (self.fixture.installed / name).read_bytes(),
            )


    def test_requests_service_execute_permission(self) -> None:
        stager = self.stager()
        with patch.object(Path, "chmod", autospec=True) as chmod:
            stager.stage_runtime(self.fixture.installed, self.destination)
        self.assertEqual(chmod.call_count, 1)
        path, mode = chmod.call_args.args
        self.assertEqual(path, self.destination / "dogmosd")
        self.assertEqual(mode & 0o111, 0o111)

    @unittest.skipUnless(os.name == "posix", "requires real POSIX permission semantics")
    def test_service_is_executable_on_posix(self) -> None:
        self.stager().stage_runtime(self.fixture.installed, self.destination)
        self.assertEqual(stat.S_IMODE((self.destination / "dogmosd").stat().st_mode) & 0o111, 0o111)
        self.assertTrue(os.access(self.destination / "dogmosd", os.X_OK))

    def test_rejects_corruption_during_copy(self) -> None:
        stager = self.stager()
        original = stager.shutil.copyfile

        def corrupt(source, destination):
            original(source, destination)
            Path(destination).write_bytes(b"corrupt destination")

        with patch.object(stager.shutil, "copyfile", side_effect=corrupt):
            with self.assertRaisesRegex(ValueError, "hash or size mismatch"):
                stager.stage_runtime(self.fixture.installed, self.destination)

    def test_rejects_missing_corrupt_and_mismatched_source_pair_before_copy(self) -> None:
        stager = self.stager()
        for name in ("dogmosd", "libdogmos.so"):
            path = self.fixture.installed / name
            valid = path.read_bytes()
            for replacement in (None, b"", b"corrupt", (self.fixture.installed / "dogmos.dll").read_bytes()):
                with self.subTest(name=name, replacement=replacement):
                    if replacement is None:
                        path.unlink()
                    else:
                        path.write_bytes(replacement)
                    try:
                        with self.assertRaises(ValueError):
                            stager.stage_runtime(self.fixture.installed, self.destination)
                        self.assertEqual(list(self.destination.iterdir()), [])
                    finally:
                        path.write_bytes(valid)

    def test_contract_drift_rejected_before_destination_changes(self) -> None:
        stager = self.stager()
        for relative in ("dogmos.lock.json", "code/__DEFINES/dogmos_bindings.dm",
                         "code/__DEFINES/dogmos_contract.dm", "dogmos.dll", "dogmosd.exe"):
            path = self.fixture.installed / relative
            valid = path.read_bytes()
            with self.subTest(relative=relative):
                path.write_bytes(b"drift")
                try:
                    with self.assertRaises(ValueError):
                        stager.stage_runtime(self.fixture.installed, self.destination)
                    self.assertEqual(list(self.destination.iterdir()), [])
                finally:
                    path.write_bytes(valid)

    def test_same_architecture_other_release_service_rejected(self) -> None:
        path = self.fixture.installed / "dogmosd"
        binary = bytearray(path.read_bytes())
        binary[-1] ^= 1
        path.write_bytes(binary)
        with self.assertRaisesRegex(ValueError, "does not match lock"):
            self.stager().stage_runtime(self.fixture.installed, self.destination)
        self.assertEqual(list(self.destination.iterdir()), [])

    def test_cli_fails_on_copy_and_permission_errors(self) -> None:
        stager = self.stager()
        argv = ["stage_ci_runtime.py", "--root", str(self.fixture.installed),
                "--destination", str(self.destination)]
        for target, name in ((stager.shutil, "copyfile"), (Path, "chmod")):
            with self.subTest(operation=name):
                with patch.object(target, name, side_effect=OSError("fixture I/O failure")):
                    with patch.object(sys, "argv", argv), patch.object(sys, "stderr") as stderr:
                        self.assertEqual(stager.main(), 1)
                        self.assertTrue(stderr.write.called)

    def test_staging_is_repeatable_and_preserves_other_files(self) -> None:
        sentinel = self.destination / "tgstation.dmb"
        sentinel.write_bytes(b"synthetic game sentinel")
        source = {name: (self.fixture.installed / name).read_bytes()
                  for name in INSTALLED_ARTIFACTS.values()}
        self.stager().stage_runtime(self.fixture.installed, self.destination)
        self.stager().stage_runtime(self.fixture.installed, self.destination)
        self.assertEqual(sentinel.read_bytes(), b"synthetic game sentinel")
        self.assertEqual(source, {name: (self.fixture.installed / name).read_bytes() for name in source})

    def test_cli_stages_pair_and_rejects_invalid_input(self) -> None:
        command = [sys.executable, str(REPOSITORY_ROOT / "tools/dogmos/stage_ci_runtime.py"),
                   "--root", str(self.fixture.installed), "--destination", str(self.destination)]
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((self.destination / "dogmosd").is_file())
        (self.fixture.installed / "dogmosd").write_bytes(b"corrupt")
        result = subprocess.run(command, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Dogmos runtime staging failed", result.stderr)


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]


class CiRuntimeLauncherTests(unittest.TestCase):
    def test_launcher_stages_runtime_before_dreamdaemon(self) -> None:
        launcher = (REPOSITORY_ROOT / "tools/ci/run_server.sh").read_text()
        hook = "python3 tools/dogmos/stage_ci_runtime.py --root . --destination ci_test"
        self.assertIn(hook, launcher, "CI launches without staging the Linux Dogmos pair")
        self.assertLess(launcher.index("tools/deploy.sh ci_test"), launcher.index(hook))
        self.assertLess(launcher.index(hook), launcher.index("cd ci_test"))
        self.assertIn("set -euo pipefail", launcher)


if __name__ == "__main__":
    unittest.main()
