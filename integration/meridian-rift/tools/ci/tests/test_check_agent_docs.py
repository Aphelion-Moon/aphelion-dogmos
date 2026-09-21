import subprocess
import tempfile
import unittest
from pathlib import Path

from tools.ci.check_agent_docs import REQUIRED_GUIDES, check_repository


class AgentDocumentTests(unittest.TestCase):
	def initialize_repository(self, root: Path) -> str:
		subprocess.run(["git", "init", "--quiet", root], check=True)
		subprocess.run(["git", "-C", root, "config", "user.name", "Dogmos Tests"], check=True)
		subprocess.run(["git", "-C", root, "config", "user.email", "dogmos-tests@example.invalid"], check=True)
		(root / "source.txt").write_text("reviewed\n", encoding="utf-8")
		subprocess.run(["git", "-C", root, "add", "source.txt"], check=True)
		subprocess.run(["git", "-C", root, "commit", "--quiet", "-m", "reviewed source"], check=True)
		return subprocess.run(
			["git", "-C", root, "rev-parse", "HEAD"],
			check=True,
			capture_output=True,
			text=True,
		).stdout.strip()

	def write_valid_guidance(self, root: Path, game_revision: str) -> None:
		(root / "docs" / "agent").mkdir(parents=True, exist_ok=True)
		links = "\n".join(f"- [{Path(guide).stem}]({guide})" for guide in REQUIRED_GUIDES)
		(root / "AGENTS.md").write_text(
			"# Meridian-Rift agent instructions\n\n"
			f"{links}\n\n"
			"Unrelated infrastructure changes require explicit user approval naming the exact file: "
			"BUILD.cmd, Cargo.toml, .github/workflows, release, Docker, and TGS. "
			"Authorized work includes rebuilding artifacts, regenerating bindings and lock data, "
			"and verified local synchronization without separate per-file approval.\n",
			encoding="utf-8",
		)
		guides = {guide: f"# {Path(guide).stem}\n" for guide in REQUIRED_GUIDES}
		guides["docs/agent/source-authority.md"] = (
			"# Source authority\n\n"
			f"Reviewed game revision: `{game_revision}`\n\n"
			"Reviewed Nova revision: `c4846461cc82bce6a87e6efe6ea0c08e440838c6`\n\n"
			"Reviewed Rust revision: `e0405c0398aba8851dca507cfcd27d4a898dff4c`\n\n"
			"Reviewed on: `2026-08-26`\n"
		)
		guides["docs/agent/native-artifacts.md"] = (
			"# Native artifacts\n\n"
			"dogmos.lock.json pairs dogmos.dll, libdogmos.so, dogmosd.exe, dogmosd, and protocol version.\n"
		)
		guides["docs/agent/dogmos-integration.md"] = (
			"# Dogmos integration\n\n"
			"The ownership exception is code/modules/atmospherics/gasmixtures/** and "
			"code/modules/atmospherics/environmental/** plus "
			"code/__DEFINES/dogmos_bindings.dm and code/__DEFINES/dogmos_contract.dm. "
			"Outside it use APHELION EDIT and preserve NOVA EDIT.\n"
		)
		guides["docs/agent/dogmos-gameplay-events.md"] = (
			"# Dogmos gameplay events\n\n"
			"Use a 64-byte envelope so the 64 KiB shim buffer holds 1,023 complete records. "
			"Required kinds include reaction finished, pressure difference, decompression floor rip, "
			"and visual state changed. Reject the complete simulation-stage result under backpressure. "
			"Only DreamDaemon memory is the footprint target.\n"
		)
		guides["docs/agent/dogmos-performance-and-memory.md"] = (
			"# Dogmos performance and memory\n\n"
			"Only DreamDaemon memory is the footprint target. Report dogmosd separately. "
			"A DLL allocation remains a DreamDaemon allocation.\n"
		)
		guides["docs/agent/dogmos-verification.md"] = (
			"# Dogmos verification\n\n"
			"Call dm_parse_environment before Meridian-MCP analysis and Tracy. "
			"PowerShell owns DreamMaker, DreamDaemon, Rust, process memory, Docker, and tests.\n"
		)
		for relative, text in guides.items():
			(root / relative).write_text(text, encoding="utf-8")

	def valid_fixture(self) -> tuple[Path, list[str]]:
		temporary = tempfile.TemporaryDirectory()
		self.addCleanup(temporary.cleanup)
		root = Path(temporary.name)
		revision = self.initialize_repository(root)
		self.write_valid_guidance(root, revision)
		return root, check_repository(root)

	def test_missing_dogmos_guides_are_reported(self) -> None:
		with tempfile.TemporaryDirectory() as temporary:
			root = Path(temporary)
			self.initialize_repository(root)
			(root / "AGENTS.md").write_text("# Meridian Rift\n", encoding="utf-8")
			errors = check_repository(root)
			self.assertTrue(any("dogmos-service-lifecycle.md" in error for error in errors))

	def test_native_artifact_contract_is_required(self) -> None:
		root, errors = self.valid_fixture()
		self.assertEqual(errors, [])
		guide = root / "docs" / "agent" / "native-artifacts.md"
		guide.write_text("# Native artifacts\n\nOnly dogmos.dll is required.\n", encoding="utf-8")
		self.assertTrue(any("paired native artifact contract" in error for error in check_repository(root)))

	def test_source_authority_requires_full_revisions(self) -> None:
		root, errors = self.valid_fixture()
		self.assertEqual(errors, [])
		authority = root / "docs" / "agent" / "source-authority.md"
		authority.write_text(
			authority.read_text(encoding="utf-8").replace(
				"e0405c0398aba8851dca507cfcd27d4a898dff4c",
				"short",
			),
			encoding="utf-8",
		)
		self.assertTrue(any("Reviewed Rust revision" in error for error in check_repository(root)))

	def test_dogmos_ownership_exception_is_required(self) -> None:
		root, errors = self.valid_fixture()
		self.assertEqual(errors, [])
		guide = root / "docs" / "agent" / "dogmos-integration.md"
		guide.write_text("# Dogmos integration\n", encoding="utf-8")
		self.assertTrue(any("Dogmos ownership exception" in error for error in check_repository(root)))

	def test_gameplay_event_contract_is_required(self) -> None:
		root, errors = self.valid_fixture()
		self.assertEqual(errors, [])
		guide = root / "docs" / "agent" / "dogmos-gameplay-events.md"
		guide.write_text("# Dogmos gameplay events\n", encoding="utf-8")
		self.assertTrue(any("bounded gameplay-event contract" in error for error in check_repository(root)))

	def test_mcp_powershell_and_memory_boundaries_are_required(self) -> None:
		root, errors = self.valid_fixture()
		self.assertEqual(errors, [])
		(root / "docs" / "agent" / "dogmos-verification.md").write_text("# Verification\n", encoding="utf-8")
		(root / "docs" / "agent" / "dogmos-performance-and-memory.md").write_text("# Memory\n", encoding="utf-8")
		fixture_errors = check_repository(root)
		self.assertTrue(any("MCP/PowerShell boundary" in error for error in fixture_errors))
		self.assertTrue(any("DreamDaemon memory policy" in error for error in fixture_errors))

	def test_public_tech_memo_links_are_checked(self) -> None:
		root, errors = self.valid_fixture()
		self.assertEqual(errors, [])
		memo = root / "docs" / "tech-memos" / "dogmos.md"
		memo.parent.mkdir(parents=True)
		memo.write_text("# Dogmos\n\n[Missing architecture note](missing.md)\n", encoding="utf-8")
		self.assertTrue(any("broken local link" in error for error in check_repository(root)))

	def test_checked_in_repository_documents_are_current(self) -> None:
		root = Path(__file__).resolve().parents[3]
		self.assertEqual(check_repository(root), [])


if __name__ == "__main__":
	unittest.main()
