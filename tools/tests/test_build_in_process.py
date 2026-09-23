"""A failed native build must keep its actual diagnostic in both the log and CI output."""
import contextlib
import io
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

TOOLS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS))
import build_in_process


class BuildDiagnosticsTests(unittest.TestCase):
    def test_failed_compiler_output_is_retained_and_reported(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            log = root / 'build.log'
            stderr = io.StringIO()
            command = [sys.executable, '-c', "import sys; print('compiler detail', file=sys.stderr); sys.exit(17)"]
            with contextlib.redirect_stderr(stderr):
                with self.assertRaises(subprocess.CalledProcessError) as raised:
                    build_in_process.run_build(command, root, None, log)
            self.assertEqual(raised.exception.returncode, 17)
            self.assertIn('compiler detail', stderr.getvalue())
            self.assertIn('compiler detail', log.read_text())


if __name__ == '__main__':
    unittest.main()
