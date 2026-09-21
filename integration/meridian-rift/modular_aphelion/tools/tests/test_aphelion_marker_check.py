import unittest
from itertools import permutations

from modular_aphelion.tools.aphelion_marker_check import parse_diff, validate_diff


def diff(*lines: str, path: str = "code/example.dm", new_file: bool = False) -> str:
	header = ["--- /dev/null" if new_file else f"--- a/{path}", f"+++ b/{path}"]
	return "\n".join([*header, "@@ -1,0 +1,%d @@" % len(lines), *(f"+{line}" for line in lines)])


class MarkerCheckTests(unittest.TestCase):
	def test_header_like_hunk_lines_remain_file_content(self) -> None:
		patch = "\n".join([
			"--- a/code/existing.dm",
			"+++ b/code/existing.dm",
			"@@ -10,2 +10,2 @@",
			"--- removed_text",
			"+++ added_text",
			" unchanged()",
			diff("/datum/new_example", path="code/new.dm", new_file=True),
		])
		files = parse_diff(patch)
		self.assertEqual([(item.path, item.new_file) for item in files], [
			("code/existing.dm", False), ("code/new.dm", True),
		])
		self.assertEqual(files[0].added_lines, ((10, "++ added_text"),))
		self.assertEqual([(error.code, error.path, error.line) for error in validate_diff(patch)], [
			("unmarked_core_edit", "code/existing.dm", 10),
		])

	def test_no_newline_marker_does_not_advance_destination_line(self) -> None:
		patch = "\n".join([
			"--- a/code/existing.dm", "+++ b/code/existing.dm",
			"@@ -8 +8 @@", "-old_behavior()", "\\ No newline at end of file",
			"+changed_behavior()", "\\ No newline at end of file",
		])
		self.assertEqual(parse_diff(patch)[0].added_lines, ((8, "changed_behavior()"),))

	def test_modified_then_new_file_keeps_previous_file_status(self) -> None:
		patch = "\n".join([
			diff("changed_behavior()", path="code/existing.dm"),
			diff("/datum/new_example", path="code/new.dm", new_file=True),
		])
		errors = {(error.code, error.path) for error in validate_diff(patch)}
		self.assertIn(("unmarked_core_edit", "code/existing.dm"), errors)

	def test_new_then_marked_modified_file_keeps_new_file_status(self) -> None:
		patch = "\n".join([
			diff("/datum/new_example", path="code/new.dm", new_file=True),
			diff(
				"// APHELION EDIT ADDITION START - DOGMOS",
				"changed_behavior()",
				"// APHELION EDIT ADDITION END",
				path="code/existing.dm",
			),
		])
		self.assertEqual(validate_diff(patch), [])

	def test_accepts_canonical_aphelion_markers(self) -> None:
		self.assertEqual(validate_diff(diff(
			"// APHELION EDIT ADDITION START - DOGMOS",
			"new_behavior()",
			"// APHELION EDIT ADDITION END",
		)), [])

	def test_rejects_unmarked_existing_core_edit(self) -> None:
		errors = validate_diff(diff("changed_behavior()"))
		self.assertIn("unmarked_core_edit", {error.code for error in errors})

	def test_accepts_narrow_dogmos_atmosphere_exception(self) -> None:
		for path in (
			"code/modules/atmospherics/gasmixtures/gas_mixture.dm",
			"code/modules/atmospherics/environmental/LINDA_system.dm",
			"code/__DEFINES/dogmos_bindings.dm",
			"code/__DEFINES/dogmos_contract.dm",
		):
			with self.subTest(path=path):
				self.assertEqual(validate_diff(diff("changed_behavior()", path=path)), [])

	def test_exception_does_not_cover_unrelated_atmos_machinery(self) -> None:
		errors = validate_diff(diff("changed_behavior()", path="code/modules/atmospherics/machinery/atmosmachinery.dm"))
		self.assertIn("unmarked_core_edit", {error.code for error in errors})

	def test_accepts_new_aphelion_owned_file_without_inline_markers(self) -> None:
		self.assertEqual(validate_diff(diff("/datum/unit_test/dogmos_example", new_file=True)), [])

	def test_rejects_new_nova_marker_outside_nova(self) -> None:
		errors = validate_diff(diff("// NOVA EDIT ADDITION START - NEW_FEATURE"))
		self.assertIn("new_nova_marker", {error.code for error in errors})

	def test_reports_invalid_or_unclosed_aphelion_markers(self) -> None:
		errors = validate_diff(diff("// APHELION EDIT ADDITION START - bad-id"))
		self.assertEqual({error.code for error in errors}, {"invalid_module_id", "unclosed_marker"})

	def test_handles_mixed_modification_addition_and_deletion(self) -> None:
		deletion = "\n".join([
			"--- a/code/deleted.dm",
			"+++ /dev/null",
			"@@ -4,1 +0,0 @@",
			"-deleted_behavior()",
		])
		patch = "\n".join([
			diff("changed_behavior()", path="code/existing.dm"),
			diff("/datum/new_example", path="code/new.dm", new_file=True),
			deletion,
		])
		errors = {(error.code, error.path) for error in validate_diff(patch)}
		self.assertEqual(errors, {("unmarked_core_edit", "code/existing.dm")})

	def test_mixed_file_classification_is_independent_of_order(self) -> None:
		patches = (
			diff("changed_behavior()", path="code/existing.dm"),
			diff("/datum/new_example", path="code/new.dm", new_file=True),
			"--- a/code/deleted.dm\n+++ /dev/null\n@@ -1 +0,0 @@\n-deleted_behavior()",
		)
		for ordered in permutations(patches):
			with self.subTest(order=ordered):
				errors = {(error.code, error.path) for error in validate_diff("\n".join(ordered))}
				self.assertEqual(errors, {("unmarked_core_edit", "code/existing.dm")})

	def test_rename_uses_destination_path_and_preserves_line_number(self) -> None:
		patch = "\n".join([
			"diff --git a/code/old.dm b/code/renamed.dm",
			"similarity index 90%",
			"rename from code/old.dm",
			"rename to code/renamed.dm",
			"--- a/code/old.dm",
			"+++ b/code/renamed.dm",
			"@@ -20,0 +21,1 @@",
			"+changed_behavior()",
		])
		errors = validate_diff(patch)
		self.assertEqual([(error.code, error.path, error.line) for error in errors], [
			("unmarked_core_edit", "code/renamed.dm", 21),
		])

	def test_multiple_hunks_are_classified_at_file_level(self) -> None:
		patch = "\n".join([
			"--- a/code/example.dm",
			"+++ b/code/example.dm",
			"@@ -2,0 +3,1 @@",
			"+// APHELION EDIT CHANGE - DOGMOS - ORIGINAL: old_behavior()",
			"@@ -99,0 +101,1 @@",
			"+changed_elsewhere()",
		])
		self.assertEqual(validate_diff(patch), [])

	def test_incomplete_marker_is_closed_only_within_its_file(self) -> None:
		patch = "\n".join([
			diff("// APHELION EDIT ADDITION START - DOGMOS", path="code/first.dm"),
			diff("// APHELION EDIT ADDITION END", path="code/second.dm"),
		])
		errors = {(error.code, error.path) for error in validate_diff(patch)}
		self.assertEqual(errors, {
			("unclosed_marker", "code/first.dm"),
			("mismatched_marker", "code/second.dm"),
		})


if __name__ == "__main__":
	unittest.main()
