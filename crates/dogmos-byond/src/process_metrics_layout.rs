//! Authority for the process-metrics DM adapter, distinct from service wire telemetry.
//!
//! The typed field order drives encoding, one-based DM offsets and generated reference
//! comments in bindings.dm. Each f32 list element carries an exact u16 word. Sampling,
//! validation, limits and runtime policy remain with their existing owners.

use super::{append_u32_words, append_u64_words};
use dogmos_process_metrics::{
	CurrentProcessMetrics, PROCESS_PRIVATE_BYTES_AVAILABLE, PROCESS_VIRTUAL_BYTES_AVAILABLE,
	PROCESS_WORKING_SET_AVAILABLE,
};
use dogmos_protocol::{
	ServiceTelemetry, SERVICE_PROCESS_ALL_AVAILABLE, SERVICE_PROCESS_CPU_AVAILABLE,
	SERVICE_PROCESS_RSS_AVAILABLE,
};
use std::fmt::Write;

const LAYOUT_VERSION: u32 = 1;
const HOST_AVAILABLE_FLAGS: u32 = PROCESS_PRIVATE_BYTES_AVAILABLE
	| PROCESS_VIRTUAL_BYTES_AVAILABLE
	| PROCESS_WORKING_SET_AVAILABLE;

/// A field's typed selector fixes its word width for both encoding and documentation.
enum Field {
	U32 {
		name: &'static str,
		description: &'static str,
		value: fn(&CurrentProcessMetrics, &ServiceTelemetry) -> u32,
	},
	U64 {
		name: &'static str,
		description: &'static str,
		value: fn(&CurrentProcessMetrics, &ServiceTelemetry) -> u64,
	},
}

impl Field {
	const fn words(&self) -> usize {
		match self {
			Self::U32 { .. } => 2,
			Self::U64 { .. } => 4,
		}
	}

	fn name(&self) -> &'static str {
		match self {
			Self::U32 { name, .. } | Self::U64 { name, .. } => name,
		}
	}

	fn description(&self) -> &'static str {
		match self {
			Self::U32 { description, .. } | Self::U64 { description, .. } => description,
		}
	}
}

const FIELDS: [Field; 9] = [
	Field::U32 {
		name: "DOGMOS_PROCESS_LAYOUT_WORD",
		description: "Adapter layout version (must match DOGMOS_PROCESS_METRICS_LAYOUT_VERSION).",
		value: |_, _| LAYOUT_VERSION,
	},
	Field::U32 {
		name: "DOGMOS_PROCESS_HOST_FLAGS_WORD",
		description: "DreamDaemon availability flags; host CPU is not included in this adapter.",
		value: |host, _| host.available_flags & HOST_AVAILABLE_FLAGS,
	},
	Field::U32 {
		name: "DOGMOS_PROCESS_SERVICE_FLAGS_WORD",
		description: "dogmosd availability flags, independent of DreamDaemon flags.",
		value: |_, service| service.service_process_available_flags,
	},
	Field::U32 {
		name: "DOGMOS_PROCESS_RESERVED_WORD",
		description: "Reserved; must be zero.",
		value: |_, _| 0,
	},
	Field::U64 {
		name: "DOGMOS_PROCESS_HOST_PRIVATE_BYTES_WORD",
		description: "DreamDaemon private/committed bytes (platform sampler semantics).",
		value: |host, _| host.private_bytes,
	},
	Field::U64 {
		name: "DOGMOS_PROCESS_HOST_VIRTUAL_BYTES_WORD",
		description: "DreamDaemon virtual address-space bytes.",
		value: |host, _| host.virtual_bytes,
	},
	Field::U64 {
		name: "DOGMOS_PROCESS_HOST_WORKING_SET_BYTES_WORD",
		description: "DreamDaemon working-set/resident bytes.",
		value: |host, _| host.working_set_bytes,
	},
	Field::U64 {
		name: "DOGMOS_PROCESS_SERVICE_RSS_BYTES_WORD",
		description: "dogmosd resident bytes; never added to DreamDaemon memory.",
		value: |_, service| service.service_rss_bytes,
	},
	Field::U64 {
		name: "DOGMOS_PROCESS_SERVICE_CPU_MILLISECONDS_WORD",
		description: "dogmosd cumulative CPU milliseconds (not elapsed wall time).",
		value: |_, service| service.service_cpu_total_milliseconds,
	},
];

const WORD_COUNT: usize = {
	let mut total = 0;
	let mut index = 0;
	while index < FIELDS.len() {
		total += FIELDS[index].words();
		index += 1;
	}
	total
};

pub(super) fn encode(host: CurrentProcessMetrics, service: &ServiceTelemetry) -> Vec<f32> {
	let mut words = Vec::with_capacity(WORD_COUNT);
	for field in &FIELDS {
		match field {
			Field::U32 { value, .. } => append_u32_words(&mut words, value(&host, service)),
			Field::U64 { value, .. } => append_u64_words(&mut words, value(&host, service)),
		}
	}
	debug_assert_eq!(words.len(), WORD_COUNT);
	words
}

/// Emits the same typed layout consumed by encode; runtime limits are not generated here.
pub(super) fn dm_definitions() -> String {
	let mut output = String::from("/*\n * Generated process-metrics DM adapter reference.\n * Authority: dogmos-byond/src/process_metrics_layout.rs; regenerate with generate_bindings.\n");
	writeln!(
		output,
		" * /proc/dogmos_process_metrics returns {WORD_COUNT} exact u16 words in an f32 list."
	)
	.unwrap();
	output.push_str(" * Scalar words are low-first; positions below are one-based DM list indices.\n * Unknown availability bits are rejected; an unavailable counter must be zero.\n");
	let mut offset = 1;
	for field in &FIELDS {
		writeln!(
			output,
			" * Words {}-{} (u{}): {} - {}",
			offset,
			offset + field.words() - 1,
			field.words() * 16,
			field.name(),
			field.description()
		)
		.unwrap();
		offset += field.words();
	}
	output.push_str(" */\n");
	for (name, value) in [
		("DOGMOS_PROCESS_METRICS_WORDS", WORD_COUNT as u32),
		("DOGMOS_PROCESS_METRICS_LAYOUT_VERSION", LAYOUT_VERSION),
		("DOGMOS_PROCESS_WORD_BASE", u32::from(u16::MAX) + 1),
		("DOGMOS_PROCESS_WORD_MAX", u32::from(u16::MAX)),
	] {
		writeln!(output, "#define {name} {value}").unwrap();
	}
	let mut offset = 1;
	for field in &FIELDS {
		writeln!(output, "#define {} {offset}", field.name()).unwrap();
		offset += field.words();
	}
	for (name, value) in [
		(
			"DOGMOS_DREAMDAEMON_PRIVATE_BYTES_AVAILABLE",
			PROCESS_PRIVATE_BYTES_AVAILABLE,
		),
		(
			"DOGMOS_DREAMDAEMON_VIRTUAL_BYTES_AVAILABLE",
			PROCESS_VIRTUAL_BYTES_AVAILABLE,
		),
		(
			"DOGMOS_DREAMDAEMON_WORKING_SET_BYTES_AVAILABLE",
			PROCESS_WORKING_SET_AVAILABLE,
		),
		("DOGMOS_DREAMDAEMON_ALL_AVAILABLE", HOST_AVAILABLE_FLAGS),
		(
			"DOGMOS_SERVICE_RSS_BYTES_AVAILABLE",
			SERVICE_PROCESS_RSS_AVAILABLE,
		),
		(
			"DOGMOS_SERVICE_CPU_MILLISECONDS_AVAILABLE",
			SERVICE_PROCESS_CPU_AVAILABLE,
		),
		(
			"DOGMOS_SERVICE_ALL_AVAILABLE",
			SERVICE_PROCESS_ALL_AVAILABLE,
		),
	] {
		writeln!(output, "#define {name} {value}").unwrap();
	}
	output
}
