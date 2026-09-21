#!/usr/bin/env python3
"""Validate added markers and file-level ownership hints without rewriting history.

This additions-only check does not prove that every changed hunk is enclosed by
markers: existing surrounding markers and deletion-only edits need source review.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from dataclasses import dataclass

MODULE_ID = r"[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)*"
START = re.compile(rf"APHELION EDIT (ADDITION|REMOVAL) START - (?P<module>\S+)")
END = re.compile(r"APHELION EDIT (ADDITION|REMOVAL) END")
CHANGE = re.compile(rf"APHELION EDIT CHANGE - (?P<module>{MODULE_ID}) - ORIGINAL: .+")
IGNORED_SUFFIXES = (".md", ".py")
DOGMOS_OWNED_PATHS = (
	"code/modules/atmospherics/gasmixtures/",
	"code/modules/atmospherics/environmental/",
	"code/__DEFINES/dogmos_bindings.dm",
	"code/__DEFINES/dogmos_contract.dm",
)
CORE_SUFFIXES = (".dm", ".js", ".jsx", ".ts", ".tsx")


@dataclass(frozen=True)
class MarkerError:
	code: str
	path: str
	line: int
	message: str


@dataclass(frozen=True)
class DiffFile:
	path: str
	new_file: bool
	added_lines: tuple[tuple[int, str], ...]


def is_dogmos_owned(path: str) -> bool:
	return any(path == candidate or path.startswith(candidate) for candidate in DOGMOS_OWNED_PATHS)


def requires_aphelion_marker(path: str, *, new_file: bool) -> bool:
	if new_file or path.endswith(IGNORED_SUFFIXES) or is_dogmos_owned(path):
		return False
	if path.startswith(("modular_aphelion/", "modular_nova/")):
		return False
	return path.startswith(("code/", "tgui/")) and path.endswith(CORE_SUFFIXES)


def _header_path(value: str) -> str:
	if value == "/dev/null":
		return value
	if value.startswith(("a/", "b/")):
		return value[2:]
	return value


def parse_diff(diff_text: str) -> list[DiffFile]:
	files: list[DiffFile] = []
	source_path: str | None = None
	target_path: str | None = None
	line_number = 0
	new_file = False
	old_remaining = 0
	new_remaining = 0
	file_added_lines: list[tuple[int, str]] = []

	def finish_file() -> None:
		nonlocal source_path, target_path, new_file
		if source_path is None and target_path is None:
			return
		path = target_path if target_path != "/dev/null" else source_path
		files.append(DiffFile(path or "<diff>", new_file, tuple(file_added_lines)))
		source_path = None
		target_path = None
		new_file = False
		file_added_lines.clear()

	for raw_line in diff_text.splitlines():
		if raw_line.startswith("\\ No newline at end of file"):
			continue
		# Hunk counts distinguish content such as `--- text` from file headers.
		if old_remaining or new_remaining:
			if raw_line.startswith("+"):
				line_number += 1
				new_remaining -= 1
				file_added_lines.append((line_number, raw_line[1:]))
			elif raw_line.startswith("-"):
				old_remaining -= 1
			elif raw_line.startswith(" "):
				line_number += 1
				old_remaining -= 1
				new_remaining -= 1
			continue
		if raw_line.startswith("--- "):
			finish_file()
			source_path = _header_path(raw_line[4:])
			new_file = source_path == "/dev/null"
			continue
		if raw_line.startswith("+++ ") and source_path is not None and target_path is None:
			target_path = _header_path(raw_line[4:])
			line_number = 0
			continue
		match = re.match(r"^@@ -\d+(?:,(\d+))? \+(\d+)(?:,(\d+))? @@", raw_line)
		if match and target_path is not None:
			old_remaining = int(match.group(1) or "1")
			line_number = int(match.group(2)) - 1
			new_remaining = int(match.group(3) or "1")
	finish_file()
	return files


def validate_diff(diff_text: str, *, allow_nova_sync: bool = False) -> list[MarkerError]:
	errors: list[MarkerError] = []
	for changed_file in parse_diff(diff_text):
		path = changed_file.path
		open_markers: list[tuple[str, str, int]] = []
		for line_number, line in changed_file.added_lines:
			if path.endswith(IGNORED_SUFFIXES):
				continue
			if "NOVA EDIT" in line and not path.startswith("modular_nova/") and not allow_nova_sync:
				if "THIS IS A NOVA SECTOR UI FILE" not in line:
					errors.append(MarkerError("new_nova_marker", path, line_number, "new Meridian work must use APHELION EDIT"))
			start = START.search(line)
			if start:
				module = start.group("module")
				kind = start.group(1)
				if not re.fullmatch(MODULE_ID, module):
					errors.append(MarkerError("invalid_module_id", path, line_number, f"invalid module ID: {module}"))
				open_markers.append((kind, module, line_number))
				continue
			end = END.search(line)
			if end:
				kind = end.group(1)
				if not open_markers or open_markers[-1][0] != kind:
					errors.append(MarkerError("mismatched_marker", path, line_number, f"unmatched {kind} end marker"))
				else:
					open_markers.pop()
				continue
			if "APHELION EDIT CHANGE" in line and not CHANGE.search(line):
				errors.append(MarkerError("invalid_change_marker", path, line_number, "change marker requires module ID and ORIGINAL text"))

		for kind, module, opened_at in open_markers:
			errors.append(MarkerError("unclosed_marker", path, opened_at, f"unclosed {kind} marker for {module}"))
		if not requires_aphelion_marker(path, new_file=changed_file.new_file):
			continue
		substantive = [(line, text) for line, text in changed_file.added_lines if text.strip() and not text.lstrip().startswith(("//", "/*", "*", "*/"))]
		if substantive and not any("APHELION EDIT" in text for _, text in changed_file.added_lines):
			errors.append(MarkerError("unmarked_core_edit", path, substantive[0][0], "existing core edits require APHELION EDIT"))
	return errors


def main() -> int:
	parser = argparse.ArgumentParser()
	parser.add_argument("--base")
	parser.add_argument("--allow-nova-sync", action="store_true")
	args = parser.parse_args()
	if args.base:
		merge_base = subprocess.run(["git", "merge-base", args.base, "HEAD"], capture_output=True, text=True, check=False)
		if merge_base.returncode:
			print(merge_base.stderr, file=sys.stderr)
			return merge_base.returncode
		completed = subprocess.run(
			["git", "diff", "--no-ext-diff", "--unified=0", merge_base.stdout.strip(), "--"],
			capture_output=True,
			text=True,
			check=False,
		)
		if completed.returncode:
			print(completed.stderr, file=sys.stderr)
			return completed.returncode
		diff_text = completed.stdout
	else:
		diff_text = sys.stdin.read()
	errors = validate_diff(diff_text, allow_nova_sync=args.allow_nova_sync)
	for error in errors:
		print(f"{error.path}:{error.line}: {error.code}: {error.message}")
	return 1 if errors else 0


if __name__ == "__main__":
	sys.exit(main())
