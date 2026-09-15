//! Deterministic binding generation; no service-session or runtime state.

use std::{fs, path::Path};

/// Generate canonical DM bindings in `bindings.dm` in the current working directory.
///
/// This is the maintained `generate_bindings` example's entry point. It collects the
/// registered exports, preserves their proc/symbol identity, sorts their blocks and
/// normalizes the deployed library selection and line endings.
/// Appends the maintained DM adapter layouts and process-metrics reference.
///
/// # Panics
///
/// Panics if generation or file I/O fails, or the upstream generator emits an
/// unsupported `load_ext`/`call_ext` pair. This build-time API is not an FFI entry point.
pub fn generate_bindings_file() {
	byondapi::generate_bindings("dogmos");
	let bindings_path = Path::new("bindings.dm");
	let generated =
		fs::read_to_string(bindings_path).expect("generated bindings should be readable");
	fs::write(bindings_path, render_bindings(&generated))
		.expect("normalized bindings should be writable");
}

fn render_bindings(bindings: &str) -> String {
	let mut output = normalize_generated_bindings(bindings);
	output.push('\n');
	output.push_str(&crate::process_metrics_layout::dm_definitions());
	output.push('\n');
	output.push_str(&crate::adapter_layout::dm_definitions());
	output
}

fn normalize_generated_bindings(bindings: &str) -> String {
	let normalized = bindings.replace("\r\n", "\n").replace('\r', "\n");
	let lines = normalized.lines().map(str::trim_end).collect::<Vec<_>>();
	let define_index = lines
		.iter()
		.position(|line| line.starts_with("#define "))
		.unwrap_or(lines.len());
	let header_end = define_index.saturating_add(1).min(lines.len());
	let generated_state = "/* This comment bypasses grep checks */ /var/__dogmos";
	let mut header = if let Some(state_index) = lines[..header_end]
		.iter()
		.position(|line| *line == generated_state)
	{
		let mut canonical = lines[..state_index].to_vec();
		while canonical.last().is_some_and(|line| line.is_empty()) {
			canonical.pop();
		}
		canonical.push("");
		canonical.push("#define DOGMOS (world.system_type == UNIX ? \"libdogmos\" : \"dogmos\")");
		canonical
	} else {
		lines[..header_end].to_vec()
	};
	while header.last().is_some_and(|line| line.is_empty()) {
		header.pop();
	}

	let mut blocks = lines[header_end..]
		.split(|line| line.is_empty())
		.filter(|block| !block.is_empty())
		.map(normalize_generated_binding_block)
		.collect::<Vec<_>>();
	blocks.sort_by(|left, right| {
		binding_sort_key(left)
			.cmp(binding_sort_key(right))
			.then_with(|| left.cmp(right))
	});

	let mut output = header.join("\n");
	if !blocks.is_empty() {
		output.push_str("\n\n");
		output.push_str(&blocks.join("\n\n"));
	}
	output.push('\n');
	output
}

fn normalize_generated_binding_block(block: &[&str]) -> String {
	const LOAD_PREFIX: &str = "\tvar/static/loaded = load_ext(DOGMOS, ";
	const RETURN_PREFIX: &str = "\treturn call_ext(loaded)";

	let mut output = Vec::with_capacity(block.len());
	let mut index = 0;
	while index < block.len() {
		let line = block[index];
		if let Some(load_argument) = line
			.strip_prefix(LOAD_PREFIX)
			.and_then(|value| value.strip_suffix(')'))
		{
			let invocation = block
				.get(index + 1)
				.and_then(|value| value.strip_prefix(RETURN_PREFIX))
				.expect("generated load_ext must be followed by call_ext");
			output.push(format!(
				"\treturn call_ext(DOGMOS, {load_argument}){invocation}"
			));
			index += 2;
			continue;
		}
		output.push(line.to_owned());
		index += 1;
	}
	output.join("\n")
}

fn binding_sort_key(block: &str) -> &str {
	block
		.lines()
		.find(|line| line.starts_with('/') || line.starts_with("#define "))
		.unwrap_or(block)
}

#[cfg(test)]
mod tests {
	use super::{normalize_generated_bindings, render_bindings};

	#[test]
	fn generated_process_metrics_definitions_preserve_the_literal_dm_contract() {
		let output =
			render_bindings("header\n#define DOGMOS value\n\n/proc/example()\n\treturn 1\n");
		let definitions = output
			.lines()
			.filter(|line| {
				line.starts_with("#define DOGMOS_PROCESS_")
					|| line.starts_with("#define DOGMOS_DREAMDAEMON_")
					|| (line.starts_with("#define DOGMOS_SERVICE_")
						&& line
							.split_whitespace()
							.nth(1)
							.is_some_and(|name| name.ends_with("_AVAILABLE")))
			})
			.collect::<Vec<_>>();
		assert_eq!(
			definitions,
			vec![
				"#define DOGMOS_PROCESS_METRICS_WORDS 28",
				"#define DOGMOS_PROCESS_METRICS_LAYOUT_VERSION 1",
				"#define DOGMOS_PROCESS_WORD_BASE 65536",
				"#define DOGMOS_PROCESS_WORD_MAX 65535",
				"#define DOGMOS_PROCESS_LAYOUT_WORD 1",
				"#define DOGMOS_PROCESS_HOST_FLAGS_WORD 3",
				"#define DOGMOS_PROCESS_SERVICE_FLAGS_WORD 5",
				"#define DOGMOS_PROCESS_RESERVED_WORD 7",
				"#define DOGMOS_PROCESS_HOST_PRIVATE_BYTES_WORD 9",
				"#define DOGMOS_PROCESS_HOST_VIRTUAL_BYTES_WORD 13",
				"#define DOGMOS_PROCESS_HOST_WORKING_SET_BYTES_WORD 17",
				"#define DOGMOS_PROCESS_SERVICE_RSS_BYTES_WORD 21",
				"#define DOGMOS_PROCESS_SERVICE_CPU_MILLISECONDS_WORD 25",
				"#define DOGMOS_DREAMDAEMON_PRIVATE_BYTES_AVAILABLE 1",
				"#define DOGMOS_DREAMDAEMON_VIRTUAL_BYTES_AVAILABLE 2",
				"#define DOGMOS_DREAMDAEMON_WORKING_SET_BYTES_AVAILABLE 4",
				"#define DOGMOS_DREAMDAEMON_ALL_AVAILABLE 7",
				"#define DOGMOS_SERVICE_RSS_BYTES_AVAILABLE 1",
				"#define DOGMOS_SERVICE_CPU_MILLISECONDS_AVAILABLE 2",
				"#define DOGMOS_SERVICE_ALL_AVAILABLE 3",
			]
		);
	}

	#[test]
	fn generated_bindings_are_sorted_with_canonical_whitespace() {
		let generated = "header  \r\n#define DOGMOS value\r\n\r\n/proc/zeta()\r\n\treturn 2 \r\n\r\n/// Alpha\r\n/proc/alpha()\r\n\treturn 1\r\n\r\n";
		let expected = "header\n#define DOGMOS value\n\n/// Alpha\n/proc/alpha()\n\treturn 1\n\n/proc/zeta()\n\treturn 2\n";

		assert_eq!(normalize_generated_bindings(generated), expected);
	}

	#[test]
	fn generated_bindings_use_the_deployed_library_and_opendream_compatible_calls() {
		let generated = "generated header\n\n/* This comment bypasses grep checks */ /var/__dogmos\n\n/proc/__detect_dogmos()\n\tif (world.system_type == UNIX)\n\t\treturn __dogmos = \"libdogmos\"\n\telse\n\t\treturn __dogmos = \"dogmos\"\n\n#define DOGMOS (__dogmos || __detect_dogmos())\n\n/proc/dogmos_example(value)\n\tvar/static/loaded = load_ext(DOGMOS, \"byond:dogmos_example_ffi\")\n\treturn call_ext(loaded)(value)\n";
		let expected = "generated header\n\n#define DOGMOS (world.system_type == UNIX ? \"libdogmos\" : \"dogmos\")\n\n/proc/dogmos_example(value)\n\treturn call_ext(DOGMOS, \"byond:dogmos_example_ffi\")(value)\n";

		assert_eq!(normalize_generated_bindings(generated), expected);
	}
}
