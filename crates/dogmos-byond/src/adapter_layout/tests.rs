//! Independent compatibility fixtures: legacy DM literals predate this layout authority.
use super::*;

#[test]
fn legacy_dm_definitions_preserve_preexisting_literals() {
	assert_eq!(
		legacy_values(),
		vec![
			("DOGMOS_SERVICE_TELEMETRY_WORDS", 236),
			("DOGMOS_JOB_TELEMETRY_START", 183),
			("DOGMOS_JOB_TELEMETRY_STATUS", 187),
			("DOGMOS_JOB_TELEMETRY_COUNTERS", 189),
			("DOGMOS_JOB_RESPONSE_FIELDS", 26),
			("DOGMOS_JOB_STATUS", 5),
			("DOGMOS_JOB_STAGE", 6),
			("DOGMOS_CALLBACK_HEADER_FIELDS", 12),
			("DOGMOS_CALLBACK_EVENT_FIELDS", 36),
			("DOGMOS_CALLBACK_EVENT_START", 13),
			("DOGMOS_CALLBACK_TRANSACTION_WORD", 4),
			("DOGMOS_CALLBACK_SCOPE_FIELD", 8),
			("DOGMOS_CALLBACK_KIND_FIELD", 9),
			("DOGMOS_CALLBACK_SUBJECT_SLOT_FIELD", 11),
			("DOGMOS_CALLBACK_SUBJECT_GENERATION_FIELD", 13),
			("DOGMOS_CALLBACK_TARGET_SLOT_FIELD", 15),
			("DOGMOS_CALLBACK_TARGET_GENERATION_FIELD", 17),
			("DOGMOS_CALLBACK_VALUES_FIELD", 19),
			("DOGMOS_CALLBACK_AUX_FIELD", 23),
			("DOGMOS_CALLBACK_CONTINUATION_TOKEN_FIELD", 26),
			("DOGMOS_TURF_LIFECYCLE_FIELDS", 6),
			("DOGMOS_TURF_ADJACENCY_FIELDS", 6),
			("DOGMOS_TURF_HEAT_FIELDS", 7),
			("DOGMOS_TURF_HEAT_ADJACENCY_FIELDS", 5),
			("DOGMOS_MIXTURE_SNAPSHOT_FIELDS", 42),
			("DOGMOS_MIXTURE_SNAPSHOT_REVISION_LOW", 1),
			("DOGMOS_MIXTURE_SNAPSHOT_REVISION_HIGH", 2),
			("DOGMOS_MIXTURE_SNAPSHOT_GAS_COUNT", 3),
			("DOGMOS_MIXTURE_SNAPSHOT_TEMPERATURE", 4),
			("DOGMOS_MIXTURE_SNAPSHOT_VOLUME", 5),
			("DOGMOS_MIXTURE_SNAPSHOT_TOTAL_MOLES", 7),
			("DOGMOS_MIXTURE_SNAPSHOT_PRESSURE", 8),
			("DOGMOS_MIXTURE_SNAPSHOT_HEAT_CAPACITY", 9),
			("DOGMOS_MIXTURE_SNAPSHOT_IMMUTABLE", 10),
			("DOGMOS_MIXTURE_SNAPSHOT_GASES_START", 11),
			("DOGMOS_PIPENET_RECONCILE_RECORD_FIELDS", 44),
			("DOGMOS_STAGE_RESPONSE_FIELDS", 13),
			("DOGMOS_STAGE_RESPONSE_PENDING", 5),
		]
	);
}

#[test]
fn record_widths_preserve_literal_adapter_shapes() {
	let layouts = mixtures::LAYOUTS
		.iter()
		.chain(metadata::LAYOUTS)
		.chain(topology::LAYOUTS)
		.chain(callbacks::LAYOUTS)
		.chain(stages::LAYOUTS)
		.chain(telemetry::LAYOUTS);
	let actual = layouts
		.map(|layout| (layout.name, layout.width))
		.collect::<Vec<_>>();
	assert_eq!(
		actual,
		vec![
			("HANDLE", 2),
			("WORD_HANDLE", 4),
			("MIXTURE_COMMAND", 11),
			("MIXTURE_RESPONSE", 4),
			("REACTION_RESPONSE", 8),
			("ADJUSTMENT", 2),
			("MIXTURE_LIFECYCLE", 3),
			("MIXTURE_STATE", 38),
			("MIXTURE_SNAPSHOT", 42),
			("PIPENET_RECORD", 44),
			("GAS_METADATA", 13),
			("GAS_PRODUCT", 3),
			("REACTION_METADATA", 12),
			("REACTION_REQUIREMENT", 3),
			("TURF_LIFECYCLE", 6),
			("TURF_ADJACENCY", 6),
			("TURF_HEAT_ADJACENCY", 5),
			("TURF_HEAT", 7),
			("HEAT_SNAPSHOT", 5),
			("CALLBACK_REQUEST", 7),
			("CALLBACK_HEADER", 12),
			("CONTINUATION_TOKEN", 10),
			("CALLBACK_EVENT", 36),
			("CONTINUATION_COMMAND", 21),
			("CONTINUATION_RESUME", 11),
			("EPOCH", 4),
			("WORD_COUNT", 2),
			("FRONTIER_BEGIN", 6),
			("FRONTIER_APPEND_HEADER", 6),
			("FRONTIER_COMMIT_RESPONSE", 6),
			("STAGE_REQUEST", 12),
			("STAGE_RESPONSE", 13),
			("JOB_SUBMIT", 13),
			("JOB_IDENTITY", 4),
			("JOB_COMMIT", 8),
			("JOB_RESPONSE", 26),
			("SERVICE_TELEMETRY", 236),
		]
	);
}

#[test]
fn generated_positions_are_one_based_and_legacy_callback_offsets_stay_zero_relative() {
	let definitions = dm_definitions();
	for expected in [
		"#define DOGMOS_DM_CALLBACK_EVENT_SEQUENCE 1",
		"#define DOGMOS_DM_CALLBACK_EVENT_TRANSACTION 5",
		"#define DOGMOS_CALLBACK_TRANSACTION_WORD 4",
		"#define DOGMOS_DM_CALLBACK_EVENT_TOKEN 27",
		"#define DOGMOS_CALLBACK_CONTINUATION_TOKEN_FIELD 26",
		"#define DOGMOS_DM_MIXTURE_SNAPSHOT_GASES 11",
		"#define DOGMOS_DM_SERVICE_TELEMETRY_JOB 183",
		"#define DOGMOS_DM_SERVICE_TELEMETRY_CANCELLED_JOBS 233",
	] {
		assert!(
			definitions.lines().any(|line| line == expected),
			"missing literal {expected}"
		);
	}
	assert_eq!(definitions, dm_definitions());
	let names = definitions
		.lines()
		.filter(|line| line.starts_with("#define "))
		.map(|line| line.split_whitespace().nth(1).unwrap())
		.collect::<Vec<_>>();
	let unique = names.iter().collect::<std::collections::BTreeSet<_>>();
	assert_eq!(
		names.len(),
		unique.len(),
		"generated macro names must be unique"
	);
}
