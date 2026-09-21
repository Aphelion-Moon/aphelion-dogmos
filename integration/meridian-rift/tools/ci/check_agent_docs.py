#!/usr/bin/env python3
"""Validate Meridian-Rift's local and Dogmos-specific agent guidance."""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

REQUIRED_GUIDES = (
	"docs/agent/README.md",
	"docs/agent/source-authority.md",
	"docs/agent/placement-and-markers.md",
	"docs/agent/verification.md",
	"docs/agent/meridian-mcp.md",
	"docs/agent/generated-content.md",
	"docs/agent/upstream-drift.md",
	"docs/agent/dogmos-integration.md",
	"docs/agent/dogmos-gameplay-events.md",
	"docs/agent/dogmos-service-lifecycle.md",
	"docs/agent/dogmos-performance-and-memory.md",
	"docs/agent/dogmos-verification.md",
	"docs/agent/native-artifacts.md",
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
	public_documents = tuple(sorted((root / "docs" / "tech-memos").glob("*.md")))
	if not agents.is_file():
		errors.append("missing AGENTS.md")
	for relative in REQUIRED_GUIDES:
		path = root / relative
		if not path.is_file():
			errors.append(f"missing {relative}")
		if relative not in agent_text:
			errors.append(f"AGENTS.md must link {relative}")

	for source in (agents, *(root / relative for relative in REQUIRED_GUIDES), *public_documents):
		if not source.is_file():
			continue
		for target in LINK.findall(source.read_text(encoding="utf-8")):
			if "://" in target or target.startswith("#") or target.startswith("mailto:"):
				continue
			path_target = target.split("#", 1)[0]
			if path_target and not (source.parent / path_target).resolve().exists():
				errors.append(f"broken local link in {source.relative_to(root)}: {target}")

	protected_terms = ("BUILD.cmd", ".github/workflows", "Docker", "TGS", "explicit user approval")
	if any(term not in agent_text for term in protected_terms):
		errors.append("AGENTS.md lacks the protected-infrastructure policy")

	authority = root / "docs/agent/source-authority.md"
	if authority.is_file():
		text = authority.read_text(encoding="utf-8")
		game_revision = extract_revision(text, "Reviewed game revision")
		if game_revision is None:
			errors.append("docs/agent/source-authority.md lacks full Reviewed game revision")
		else:
			head = git(root, "rev-parse", "HEAD")
			if head.returncode != 0:
				errors.append("unable to resolve repository HEAD")
			elif git(root, "merge-base", "--is-ancestor", game_revision, head.stdout.strip()).returncode != 0:
				errors.append("Reviewed game revision is not an ancestor of repository HEAD")
		for label in ("Reviewed Nova revision", "Reviewed Rust revision"):
			if extract_revision(text, label) is None:
				errors.append(f"docs/agent/source-authority.md lacks full {label}")
		if not re.search(r"Reviewed on: `\d{4}-\d{2}-\d{2}`", text):
			errors.append("docs/agent/source-authority.md lacks Reviewed on date")

	artifacts = root / "docs/agent/native-artifacts.md"
	if artifacts.is_file():
		text = artifacts.read_text(encoding="utf-8").lower()
		required = ("dogmos.lock.json", "dogmos.dll", "libdogmos.so", "dogmosd.exe", "dogmosd", "protocol version")
		if any(term not in text for term in required):
			errors.append("docs/agent/native-artifacts.md lacks the paired native artifact contract")

	integration = root / "docs/agent/dogmos-integration.md"
	if integration.is_file():
		text = integration.read_text(encoding="utf-8")
		required = (
			"code/modules/atmospherics/gasmixtures/**",
			"code/modules/atmospherics/environmental/**",
			"code/__DEFINES/dogmos_bindings.dm",
			"code/__DEFINES/dogmos_contract.dm",
			"APHELION EDIT",
			"NOVA EDIT",
		)
		if any(term not in text for term in required):
			errors.append("docs/agent/dogmos-integration.md lacks the narrow Dogmos ownership exception")

	events = root / "docs/agent/dogmos-gameplay-events.md"
	if events.is_file():
		text = events.read_text(encoding="utf-8").lower()
		required = (
			"64-byte envelope",
			"1,023 complete records",
			"reaction finished",
			"pressure difference",
			"decompression floor rip",
			"visual state changed",
			"complete simulation-stage result",
			"only dreamdaemon memory",
		)
		if any(term not in text for term in required):
			errors.append("docs/agent/dogmos-gameplay-events.md lacks the bounded gameplay-event contract")

	verification = root / "docs/agent/dogmos-verification.md"
	if verification.is_file():
		text = verification.read_text(encoding="utf-8")
		required = ("dm_parse_environment", "Meridian-MCP", "PowerShell", "DreamMaker", "DreamDaemon")
		if any(term not in text for term in required):
			errors.append("docs/agent/dogmos-verification.md lacks the MCP/PowerShell boundary")

	memory = root / "docs/agent/dogmos-performance-and-memory.md"
	if memory.is_file():
		text = memory.read_text(encoding="utf-8").lower()
		required = ("only dreamdaemon memory", "dogmosd", "separately", "dll allocation", "dreamdaemon allocation")
		if any(term not in text for term in required):
			errors.append("docs/agent/dogmos-performance-and-memory.md lacks the DreamDaemon memory policy")

	return errors


def main() -> int:
	root = Path(__file__).resolve().parents[2]
	errors = check_repository(root)
	for error in errors:
		print(error)
	return 1 if errors else 0


if __name__ == "__main__":
	sys.exit(main())
