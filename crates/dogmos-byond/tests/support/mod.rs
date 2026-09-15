//! Source inventory follows declared out-of-line modules, never orphan Rust files.

use std::{collections::BTreeSet, fs, path::Path};

pub fn shim_source(crate_root: &Path) -> String {
	fn read_module(path: &Path, visited: &mut BTreeSet<std::path::PathBuf>, output: &mut String) {
		assert!(
			visited.insert(path.to_owned()),
			"duplicate module {}",
			path.display()
		);
		let source = fs::read_to_string(path).unwrap();
		output.push_str(&source);
		output.push('\n');
		let directory = if matches!(
			path.file_stem().and_then(|s| s.to_str()),
			Some("lib" | "mod")
		) {
			path.parent().unwrap().to_owned()
		} else {
			path.with_extension("")
		};
		for line in source.lines() {
			let declaration = line
				.trim()
				.strip_prefix("pub(crate) ")
				.or_else(|| line.trim().strip_prefix("pub "))
				.unwrap_or(line.trim());
			let Some(name) = declaration
				.strip_prefix("mod ")
				.and_then(|s| s.strip_suffix(';'))
			else {
				continue;
			};
			if name == "tests" {
				continue;
			}
			assert!(name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_'));
			let flat = directory.join(format!("{name}.rs"));
			let nested = directory.join(name).join("mod.rs");
			assert_ne!(
				flat.is_file(),
				nested.is_file(),
				"module {name} must resolve once"
			);
			read_module(
				if flat.is_file() { &flat } else { &nested },
				visited,
				output,
			);
		}
	}
	let mut output = String::new();
	read_module(
		&crate_root.join("src/lib.rs"),
		&mut BTreeSet::new(),
		&mut output,
	);
	output
}
