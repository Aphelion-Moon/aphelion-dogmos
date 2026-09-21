#!/usr/bin/env python3
"""Reject direct atmosphere membership writers outside the reviewed ownership helpers.

This lexical guard follows simple list aliases; dynamic calls/reflection still require
source review. It does not replace DreamChecker, compilation or frontier runtime tests.
"""

from pathlib import Path
import re
import sys


AIR = "/datum/controller/subsystem/air"
REVIEWED = {
    AIR + "/dogmos_add_frontier_member",       # Ordered insertion plus journal note.
    AIR + "/dogmos_remove_frontier_member",    # Removal plus journal note.
    AIR + "/dogmos_clear_active_frontier",     # Bootstrap reset retaining list identity.
    AIR + "/dogmos_replace_active_frontier",   # Explicit replacement plus rescan.
    AIR + "/Recover",                         # Ownership transfer followed by rescan.
    "/datum/unit_test/dogmos_runtime_frontier_journal/Run",  # Private transport oracle.
}
TRIVIA = re.compile(r'"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|//[^\n]*|/\*[\s\S]*?\*/')
MUTATION = r"\s*(?:\[[^\]\n]+\]|\.len)?\s*(?:=(?!=)|\+=|-=|\|=|&=|\+\+|--)|\.(?:Add|Remove|Cut|Insert|Swap|Splice)\s*\("


def code_only(source):
    def mask(match):
        value = match.group()
        # Preserve a literal reflection key, not arbitrary code-looking strings.
        if value == '"active_turfs"':
            return value
        return "".join("\n" if char == "\n" else " " for char in value)
    return TRIVIA.sub(mask, source)


def check_source(path, source):
    if "active_turfs" not in source:
        return []
    owner, aliases, air_aliases = "", set(), set()
    errors = []
    for number, line in enumerate(code_only(source).splitlines(), 1):
        if line.startswith("/"):
            owner = line.split("(", 1)[0].strip().replace("/proc/", "/")
            aliases, air_aliases = set(), set()
        elif line.startswith("SUBSYSTEM_DEF(air)"):
            owner, aliases, air_aliases = AIR, set(), set()
        declaration = re.search(r"var/datum/controller/subsystem/air(?:/\w+)*/(\w+)\s*(?:=|$)", line)
        if declaration:
            air_aliases.add(declaration[1])
        prefixes = {"SSair", *air_aliases}
        if owner.startswith(AIR + "/") or owner == AIR:
            prefixes.add("src")
        references = [rf"\b{re.escape(prefix)}\.active_turfs" for prefix in prefixes]
        references.extend(rf'\b{re.escape(prefix)}\.vars\["active_turfs"\]' for prefix in prefixes)
        if "src" in prefixes:
            references.append(r"(?<![\w.])active_turfs")
        references.extend(rf"(?<![\w.]){re.escape(alias)}\b" for alias in aliases)
        reference = "(?:" + "|".join(references) + ")"
        write = re.search(reference + "(?:" + MUTATION + ")", line)
        if write and owner not in REVIEWED and not re.match(r"\s*var/(?:\w+/)*active_turfs\s*=", line):
            errors.append(f"{path}:{number}: unreviewed atmosphere membership writer in {owner or '<unknown>'}")
        assignment = re.search(r"\b(?:var/(?:\w+/)*)?(\w+)\s*=\s*(.+)$", line)
        if assignment:
            name, rhs = assignment[1], assignment[2].strip()
            if re.fullmatch(reference, rhs):
                aliases.add(name)
            else:
                aliases.discard(name)
    return errors


def check_repository(root):
    return [error for folder in ("code", "modular_aphelion", "modular_nova")
            for path in sorted((root / folder).rglob("*.dm"))
            for error in check_source(path.relative_to(root).as_posix(), path.read_text(encoding="utf-8-sig"))]


def main():
    root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[2]
    errors = check_repository(root)
    for error in errors:
        print(error)
    if not errors:
        print("Dogmos frontier membership writers are routed through reviewed helpers.")
    return bool(errors)


if __name__ == "__main__":
    sys.exit(main())
