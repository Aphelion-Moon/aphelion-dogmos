import subprocess
import tempfile
import unittest
from pathlib import Path

from tools.check_dependency_direction import check_repository


class DependencyDirectionTests(unittest.TestCase):
	def write_crate(self, root: Path, name: str, manifest: str, source: str) -> None:
		crate = root / "crates" / name
		(crate / "src").mkdir(parents=True)
		(crate / "Cargo.toml").write_text(manifest, encoding="utf-8")
		(crate / "src" / "lib.rs").write_text(source, encoding="utf-8")

	def fixture(self) -> Path:
		temporary = tempfile.TemporaryDirectory()
		self.addCleanup(temporary.cleanup)
		root = Path(temporary.name)
		for name in ("dogmos-core", "dogmos-protocol"):
			self.write_crate(
				root,
				name,
				f'[package]\nname = "{name}"\nversion = "0.0.0"\nedition = "2021"\n',
				"pub struct Handle { pub slot: u32, pub generation: u32 }\n",
			)
		return root

	def test_valid_boundary_is_accepted(self) -> None:
		self.assertEqual(check_repository(self.fixture()), [])

	def test_byond_dependency_is_rejected(self) -> None:
		root = self.fixture()
		manifest = root / "crates" / "dogmos-core" / "Cargo.toml"
		manifest.write_text(
			manifest.read_text(encoding="utf-8") + "\n[dependencies]\nbyondapi = \"0.5\"\n",
			encoding="utf-8",
		)
		self.assertTrue(any("depends on byondapi" in error for error in check_repository(root)))

	def test_dm_call_symbols_are_rejected(self) -> None:
		root = self.fixture()
		source = root / "crates" / "dogmos-protocol" / "src" / "lib.rs"
		source.write_text("fn invalid(value: ByondValue) { call_global_id(value); }\n", encoding="utf-8")
		errors = check_repository(root)
		self.assertTrue(any("ByondValue" in error for error in errors))
		self.assertTrue(any("call_global_id" in error for error in errors))

	def test_pointer_sized_public_boundary_fields_are_rejected(self) -> None:
		root = self.fixture()
		source = root / "crates" / "dogmos-core" / "src" / "lib.rs"
		source.write_text("pub struct Handle {\n\tpub slot: usize,\n}\n", encoding="utf-8")
		self.assertTrue(any("public boundary field uses usize" in error for error in check_repository(root)))

	def test_checked_in_repository_obeys_the_boundary(self) -> None:
		root = Path(__file__).resolve().parents[2]
		self.assertEqual(check_repository(root), [])

	def graph_fixture(self, consumer: str, dependency: str, *, transitive: bool = False) -> Path:
		root = self.fixture()
		(root / "Cargo.toml").write_text('[workspace]\nmembers = ["crates/*"]\nresolver = "2"\n', encoding="utf-8")
		for name in ("byondapi", "bridge", consumer):
			if not (root / "crates" / name).exists():
				self.write_crate(root, name, f'[package]\nname = "{name}"\nversion = "0.0.0"\nedition = "2021"\n', "")
		manifest = root / "crates" / consumer / "Cargo.toml"
		manifest.write_text(manifest.read_text(encoding="utf-8") + dependency, encoding="utf-8")
		if transitive:
			bridge = root / "crates" / "bridge" / "Cargo.toml"
			bridge.write_text(bridge.read_text(encoding="utf-8") + '\n[dependencies]\nrenamed = { package = "byondapi", path = "../byondapi" }\n', encoding="utf-8")
		completed = subprocess.run(["cargo", "generate-lockfile", "--offline"], cwd=root, capture_output=True, text=True)
		self.assertEqual(completed.returncode, 0, completed.stderr)
		return root

	def test_resolved_alias_cannot_hide_byondapi(self) -> None:
		root = self.graph_fixture("dogmos-core", '\n[dependencies]\nnative = { package = "byondapi", path = "../byondapi" }\n')
		self.assertTrue(any("dogmos-core -> byondapi" in error for error in check_repository(root)))

	def test_resolved_transitive_path_is_reported(self) -> None:
		root = self.graph_fixture("dogmos-protocol", '\n[dependencies]\nbridge = { path = "../bridge" }\n', transitive=True)
		self.assertTrue(any("dogmos-protocol -> bridge -> byondapi" in error for error in check_repository(root)))

	def test_server_is_also_byond_free(self) -> None:
		root = self.graph_fixture("dogmos-server", '\n[dependencies]\nbridge = { path = "../bridge" }\n', transitive=True)
		self.assertTrue(any("dogmos-server -> bridge -> byondapi" in error for error in check_repository(root)))

	def test_selected_target_controls_resolved_edges(self) -> None:
		root = self.graph_fixture("dogmos-core", '\n[target.\'cfg(unix)\'.dependencies]\nnative = { package = "byondapi", path = "../byondapi" }\n')
		self.assertEqual(check_repository(root, target="i686-pc-windows-msvc"), [])
		self.assertTrue(any("dogmos-core -> byondapi" in error for error in check_repository(root, target="i686-unknown-linux-gnu")))

	def test_selected_feature_controls_resolved_edges(self) -> None:
		root = self.graph_fixture("dogmos-core", '\n[dependencies]\nnative = { package = "byondapi", path = "../byondapi", optional = true }\n[features]\nnative-bindings = ["dep:native"]\n')
		self.assertEqual(check_repository(root, no_default_features=True), [])
		self.assertTrue(any("dogmos-core -> byondapi" in error for error in check_repository(root, features=("dogmos-core/native-bindings",))))

	def test_resolution_failure_cannot_pass_as_an_empty_graph(self) -> None:
		root = self.graph_fixture("dogmos-core", "")
		manifest = root / "crates" / "dogmos-core" / "Cargo.toml"
		manifest.write_text(manifest.read_text(encoding="utf-8") + '\n[dependencies]\nmissing = { path = "../missing" }\n', encoding="utf-8")
		self.assertTrue(any("Cargo dependency resolution failed" in error for error in check_repository(root)))

	def test_explicit_legacy_and_shim_exceptions_remain_allowed(self) -> None:
		for consumer in ("dogmos", "dogmos-byond", "auxcallback"):
			with self.subTest(consumer=consumer):
				root = self.graph_fixture(consumer, '\n[dependencies]\nnative = { package = "byondapi", path = "../byondapi" }\n')
				self.assertEqual(check_repository(root), [])

	def test_only_the_existing_i686_server_test_edge_is_allowed(self) -> None:
		for section, allowed in (
			('target.\'cfg(all(windows, target_arch = "x86"))\'.dev-dependencies', True),
			('dependencies', False), ('build-dependencies', False), ('dev-dependencies', False),
		):
			with self.subTest(section=section):
				root = self.graph_fixture("dogmos-byond", '\n[dependencies]\nnative = { package = "byondapi", path = "../byondapi" }\n')
				self.write_crate(root, "dogmos-server", f'[package]\nname = "dogmos-server"\nversion = "0.0.0"\n[{section}]\nclient = {{ package = "dogmos-byond", path = "../dogmos-byond" }}\n', "")
				completed = subprocess.run(["cargo", "generate-lockfile", "--offline"], cwd=root, capture_output=True, text=True)
				self.assertEqual(completed.returncode, 0, completed.stderr)
				errors = check_repository(root)
				if allowed:
					self.assertEqual(errors, [])
				else:
					self.assertTrue(any("dogmos-server -> dogmos-byond -> byondapi" in error for error in errors))


if __name__ == "__main__":
	unittest.main()
