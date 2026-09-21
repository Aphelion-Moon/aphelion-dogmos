"""Keep the deployed engine independent of the archived worker packages."""
from pathlib import Path
import subprocess
import json
import unittest

ROOT = Path(__file__).resolve().parents[2]

class InProcessOnlyTests(unittest.TestCase):
    def test_workspace_contains_only_in_process_components(self):
        data = json.loads(subprocess.check_output([
            'cargo', '+1.98.0', 'metadata', '--locked', '--offline', '--format-version', '1', '--no-deps'
        ], cwd=ROOT))
        self.assertEqual({p['name'] for p in data['packages']}, {
            'dogmos', 'auxcallback', 'auxmacros', 'dogmos-core', 'dogmos-perf', 'dogmos-process-metrics'
        })

if __name__ == '__main__':
    unittest.main()
