import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW_ROOT = ROOT / ".github" / "workflows"
WORKFLOW_NAMES = ("check.yml", "build.yml", "release.yml")


class WorkflowTests(unittest.TestCase):
	def load_workflow(self, name: str) -> tuple[dict, str]:
		text = (WORKFLOW_ROOT / name).read_text(encoding="utf-8")
		return yaml.load(text, Loader=yaml.BaseLoader), text

	def all_steps(self, workflow: dict) -> list[dict]:
		return [
			step
			for job in workflow["jobs"].values()
			for step in job.get("steps", [])
		]

	def test_workflows_use_current_checkout_and_exact_rust_toolchain(self) -> None:
		for name in WORKFLOW_NAMES:
			with self.subTest(workflow=name):
				workflow, _ = self.load_workflow(name)
				uses = [step["uses"] for step in self.all_steps(workflow) if "uses" in step]
				self.assertIn("actions/checkout@v7", uses)
				self.assertIn("dtolnay/rust-toolchain@1.98.0", uses)
				self.assertFalse(any(action.startswith("actions-rs/") for action in uses))

	def test_check_workflow_runs_the_same_authoritative_gates(self) -> None:
		workflow, _ = self.load_workflow("check.yml")
		runs = "\n".join(step.get("run", "") for step in self.all_steps(workflow))
		matrix = workflow["jobs"]["check"]["strategy"]["matrix"]["include"]
		self.assertEqual({(entry["shim"], entry["service"]) for entry in matrix}, {
			("i686-pc-windows-msvc", "x86_64-pc-windows-msvc"),
			("i686-unknown-linux-gnu", "x86_64-unknown-linux-gnu"),
		})
		for entry in matrix:
			resolved = runs.replace("${{ matrix.shim }}", entry["shim"]).replace("${{ matrix.service }}", entry["service"])
			self.assertIn("cargo +1.98.0 fmt --all -- --check", resolved)
			self.assertIn(f"cargo +1.98.0 clippy --workspace --locked --target {entry['shim']} --all-targets -- -D warnings", resolved)
			self.assertIn(f"cargo +1.98.0 test --workspace --locked --target {entry['shim']}", resolved)
			self.assertIn(f"tools/check_feature_matrix.ps1 -Target '{entry['shim']}'", resolved)
			self.assertIn(f"cargo +1.98.0 test -p dogmos-server --locked --target '{entry['service']}'", resolved)
			self.assertIn("--features diagnostic-bindings", resolved)
			self.assertIn("git diff --exit-code -- bindings.dm", resolved)
			self.assertIn("tools/check_dependency_direction.py", resolved)
		self.assertEqual(workflow["jobs"]["paired-artifacts"]["uses"], "./.github/workflows/build.yml")

	def test_build_workflow_runs_for_the_dogmos_branch(self) -> None:
		workflow, text = self.load_workflow("build.yml")
		branches = workflow["on"]["push"]["branches"]
		self.assertIn("dogmos", branches)
		for target in (
			"i686-pc-windows-msvc",
			"x86_64-pc-windows-msvc",
			"i686-unknown-linux-gnu",
			"x86_64-unknown-linux-gnu",
		):
			self.assertIn(target, text)
		for artifact in (
			"dogmos.dll",
			"dogmos.pdb",
			"dogmosd.exe",
			"dogmosd.pdb",
			"libdogmos.so",
			"libdogmos.so.debug",
			"linux/dogmosd",
			"linux/dogmosd.debug",
			"dogmos_bindings.dm",
			"dogmos-release-manifest.json",
		):
			self.assertIn(artifact, text)
		self.assertIn("tools/dogmos_contract.py generate", text)
		self.assertIn("tools/dogmos_contract.py verify", text)
		self.assertNotRegex(text, r"(?m)^\s+ref:\s*(dogmos|master)\s*$")
		for command in ("cargo +1.98.0 build", "cargo +1.98.0 run"):
			for line in (line.strip() for line in text.splitlines() if command in line):
				self.assertIn("--locked", line)
		uses = [step["uses"] for step in self.all_steps(workflow) if "uses" in step]
		self.assertIn("actions/upload-artifact@v7", uses)
		self.assertIn("actions/download-artifact@v8", uses)

	def test_release_uses_dogmos_artifact_names_and_official_upload_path(self) -> None:
		workflow, text = self.load_workflow("release.yml")
		uses = [step["uses"] for step in self.all_steps(workflow) if "uses" in step]
		self.assertIn("actions/attest-build-provenance@v4", uses)
		self.assertIn("actions/download-artifact@v8", uses)
		self.assertIn("dogmos.dll", text)
		self.assertIn("dogmos.pdb", text)
		self.assertIn("dogmosd.exe", text)
		self.assertIn("dogmosd.pdb", text)
		self.assertIn("libdogmos.so", text)
		self.assertIn("dogmosd.debug", text)
		self.assertIn("dogmos_bindings.dm", text)
		self.assertIn("dogmos-release-manifest.json", text)
		self.assertIn("tools/dogmos_contract.py verify", text)
		self.assertIn("gh release upload", text)
		self.assertNotIn("auxmos", text.lower())
		self.assertFalse(any("svenstaro" in action for action in uses))


if __name__ == "__main__":
	unittest.main()
