#!/usr/bin/env python3
"""Validate aphelion-dogmos agent guidance and source anchors."""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

REQUIRED_GUIDES = (
	"docs/agent/README.md",
	"docs/agent/source-authority.md",
	"docs/agent/architecture-and-ownership.md",
	"docs/agent/gameplay-events.md",
	"docs/agent/performance-and-memory.md",
	"docs/agent/numerical-invariants.md",
	"docs/agent/ffi-and-generated-bindings.md",
	"docs/agent/verification.md",
	"docs/agent/release-and-artifacts.md",
	"docs/agent/upstream-drift.md",
)
LINK = re.compile(r"\[[^]]+\]\(([^)]+)\)")
REVISION = re.compile(r"[0-9a-f]{40}")


def git(root: Path, *arguments: str) -> subprocess.CompletedProcess[str]:
	return subprocess.run(
		["git", "-C", root, *arguments],
		capture_output=True,
		text=True,
		check=False,
	)


def extract_revision(text: str, label: str) -> str | None:
	match = re.search(rf"^{re.escape(label)}: `([^`]+)`$", text, re.MULTILINE)
	if match and REVISION.fullmatch(match.group(1)):
		return match.group(1)
	return None


def check_repository(root: Path) -> list[str]:
	errors: list[str] = []
	agents = root / "AGENTS.md"
	agent_text = agents.read_text(encoding="utf-8") if agents.is_file() else ""
	if not agents.is_file():
		errors.append("missing AGENTS.md")

	for relative in REQUIRED_GUIDES:
		path = root / relative
		if not path.is_file():
			errors.append(f"missing {relative}")
		if relative not in agent_text:
			errors.append(f"AGENTS.md must link {relative}")

	# Keep new component/API onboarding linked to real source after module moves.
	# This ratchet covers maintained boundary docs, not archived audits or all Markdown.
	checked = [agents, *(root / relative for relative in REQUIRED_GUIDES), root / "README.md",
		*(root / "crates").glob("*/README.md"), *(root / "docs" / "architecture").glob("*.md")]
	for source in checked:
		if not source.is_file():
			continue
		for target in LINK.findall(source.read_text(encoding="utf-8")):
			if "://" in target or target.startswith("#") or target.startswith("mailto:"):
				continue
			path_target = target.split("#", 1)[0]
			if path_target and not (source.parent / path_target).resolve().exists():
				errors.append(f"broken local link in {source.relative_to(root)}: {target}")

	authority = root / "docs/agent/source-authority.md"
	if authority.is_file():
		text = authority.read_text(encoding="utf-8")
		local_revision = extract_revision(text, "Reviewed local revision")
		if local_revision is None:
			errors.append("docs/agent/source-authority.md lacks full Reviewed local revision")
		else:
			head = git(root, "rev-parse", "HEAD")
			if head.returncode != 0:
				errors.append("unable to resolve repository HEAD")
			elif git(root, "merge-base", "--is-ancestor", local_revision, head.stdout.strip()).returncode != 0:
				errors.append("Reviewed local revision is not an ancestor of repository HEAD")
		if extract_revision(text, "Reviewed Auxmos revision") is None:
			errors.append("docs/agent/source-authority.md lacks full Reviewed Auxmos revision")
		if not re.search(r"Reviewed on: `\d{4}-\d{2}-\d{2}`", text):
			errors.append("docs/agent/source-authority.md lacks Reviewed on date")

	bindings = root / "docs/agent/ffi-and-generated-bindings.md"
	if bindings.is_file():
		text = bindings.read_text(encoding="utf-8").lower()
		if not all(term in text for term in ("generated bindings", "never hand-edit", "regenerate")):
			errors.append("docs/agent/ffi-and-generated-bindings.md lacks generated binding policy")

	ownership = root / "docs/agent/architecture-and-ownership.md"
	if ownership.is_file():
		text = ownership.read_text(encoding="utf-8").lower()
		if not all(term in text for term in ("in-process", "dreamdaemon", "byondapi", "main thread")):
			errors.append("architecture guide lacks in-process ownership")
		if "dll allocations are outside dreamdaemon" in text:
			errors.append("architecture guide misstates in-process DLL memory")
	events = root / "docs/agent/gameplay-events.md"
	if events.is_file():
		text = events.read_text(encoding="utf-8").lower()
		if not all(term in text for term in ("main-thread", "callback", "pressure", "reaction")):
			errors.append("gameplay guide lacks the main-thread callback contract")

	return errors


def main() -> int:
	root = Path(__file__).resolve().parents[1]
	errors = check_repository(root)
	for error in errors:
		print(error)
	return 1 if errors else 0


if __name__ == "__main__":
	sys.exit(main())
