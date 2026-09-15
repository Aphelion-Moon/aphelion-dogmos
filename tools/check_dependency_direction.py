#!/usr/bin/env python3
"""Enforce the BYOND-free Dogmos core and wire-protocol boundary."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import tomllib
from collections import deque
from pathlib import Path

BOUNDARY_CRATES = ("dogmos-core", "dogmos-protocol")
BYOND_CONSUMERS = frozenset(("dogmos-byond", "dogmos", "auxcallback"))
DEPENDENCY_SECTIONS = ("dependencies", "dev-dependencies", "build-dependencies")
FORBIDDEN_SOURCE = (
	(re.compile(r"\bbyondapi\s*::"), "byondapi path"),
	(re.compile(r"\bByondValue\b"), "ByondValue"),
	(re.compile(r"\bcall_global_id\s*\("), "call_global_id"),
	(re.compile(r"\bnew_ref\s*\("), "new_ref"),
)
PUBLIC_USIZE_FIELD = re.compile(r"^\s*pub\s+[A-Za-z_][A-Za-z0-9_]*\s*:\s*[^,]*\busize\b")


def dependency_tables(document: dict) -> list[tuple[str, dict]]:
	tables: list[tuple[str, dict]] = []
	for section in DEPENDENCY_SECTIONS:
		value = document.get(section)
		if isinstance(value, dict):
			tables.append((section, value))
	for target_name, target in document.get("target", {}).items():
		if not isinstance(target, dict):
			continue
		for section in DEPENDENCY_SECTIONS:
			value = target.get(section)
			if isinstance(value, dict):
				tables.append((f"target.{target_name}.{section}", value))
	return tables


def check_crate(root: Path, crate_name: str) -> list[str]:
	errors: list[str] = []
	crate = root / "crates" / crate_name
	manifest = crate / "Cargo.toml"
	if not manifest.is_file():
		return [f"missing boundary crate manifest: {manifest.relative_to(root)}"]

	document = tomllib.loads(manifest.read_text(encoding="utf-8"))
	for section, dependencies in dependency_tables(document):
		if "byondapi" in dependencies:
			errors.append(f"{manifest.relative_to(root)}: {section} depends on byondapi")

	source_root = crate / "src"
	for source in sorted(source_root.rglob("*.rs")):
		for line_number, line in enumerate(source.read_text(encoding="utf-8").splitlines(), 1):
			code = line.split("//", 1)[0]
			for pattern, label in FORBIDDEN_SOURCE:
				if pattern.search(code):
					errors.append(
						f"{source.relative_to(root)}:{line_number}: forbidden {label} in {crate_name}"
					)
			if PUBLIC_USIZE_FIELD.search(code):
				errors.append(
					f"{source.relative_to(root)}:{line_number}: public boundary field uses usize"
				)
	return errors


def check_resolved_graph(metadata: dict) -> list[str]:
	"""Report shortest forbidden paths using Cargo package IDs, not dependency aliases."""
	packages = {package["id"]: package["name"] for package in metadata["packages"]}
	if metadata.get("resolve") is None:
		return ["Cargo metadata did not provide a resolved dependency graph"]
	nodes = {node["id"]: node for node in metadata["resolve"]["nodes"]}
	errors: list[str] = []
	for member in sorted(metadata["workspace_members"]):
		name = packages[member]
		# byondapi itself is the target package, not a consumer (also used by fixtures).
		if name in BYOND_CONSUMERS or name == "byondapi":
			continue
		queue = deque([(member, [name])])
		visited = {member}
		while queue:
			current, path = queue.popleft()
			for dependency in nodes[current]["deps"]:
				package_id = dependency["pkg"]
				kinds = dependency["dep_kinds"]
				if kinds and all(kind["kind"] == "dev" for kind in kinds):
					# Dependency tests are not linked into their consumers. Check each
					# workspace member's own test graph separately instead.
					if current != member:
						continue
					# Existing Windows i686 process tests exercise the shim client.
					# Any normal/build edge or wider target remains forbidden.
					if (name, packages[package_id]) == ("dogmos-server", "dogmos-byond") and all(
						kind["target"] == 'cfg(all(windows, target_arch = "x86"))' for kind in kinds
					):
						continue
				if package_id in visited:
					continue
				visited.add(package_id)
				next_path = [*path, packages[package_id]]
				if packages[package_id] == "byondapi":
					errors.append("forbidden resolved dependency: " + " -> ".join(next_path))
				else:
					queue.append((package_id, next_path))
	return errors


def check_repository(
	root: Path, *, target: str | None = None, features: tuple[str, ...] = (),
	no_default_features: bool = False,
) -> list[str]:
	errors: list[str] = []
	for crate_name in BOUNDARY_CRATES:
		errors.extend(check_crate(root, crate_name))
	if (root / "Cargo.toml").is_file():
		arguments = ["cargo", "metadata", "--locked", "--format-version", "1"]
		if target:
			arguments += ["--filter-platform", target]
		if features:
			arguments += ["--features", ",".join(features)]
		if no_default_features:
			arguments.append("--no-default-features")
		try:
			completed = subprocess.run(arguments, cwd=root, capture_output=True, text=True, encoding="utf-8", timeout=120)
			if completed.returncode:
				errors.append("Cargo dependency resolution failed: " + completed.stderr.strip())
			else:
				errors.extend(check_resolved_graph(json.loads(completed.stdout)))
		except (OSError, subprocess.TimeoutExpired, ValueError, KeyError) as error:
			errors.append(f"Unable to inspect the resolved Cargo graph: {error}")
	return errors


def main() -> int:
	parser = argparse.ArgumentParser(description=__doc__)
	parser.add_argument("--target", help="Cargo target triple; omitted means all target dependencies")
	parser.add_argument("--features", action="append", default=[], help="Cargo feature selection")
	parser.add_argument("--no-default-features", action="store_true")
	args = parser.parse_args()
	root = Path(__file__).resolve().parents[1]
	errors = check_repository(root, target=args.target, features=tuple(args.features), no_default_features=args.no_default_features)
	for error in errors:
		print(error)
	return 1 if errors else 0


if __name__ == "__main__":
	sys.exit(main())
