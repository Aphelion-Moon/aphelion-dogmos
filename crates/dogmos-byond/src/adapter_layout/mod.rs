//! Authority for DM numeric-list layouts, independent of protocol byte layouts and policy.
//!
//! Field offsets are zero-based in Rust and generated one-based for DM. Wider unsigned
//! integers use exact little-endian u16 words; scalar/enum/boolean fields retain their
//! existing validation in dm_codec/protocol. No version word is added to legacy lists:
//! their shape remains selected by the matching ABI/protocol/artifact contract.

use std::fmt::Write;

#[derive(Clone, Copy)]
pub(crate) struct Field {
	pub name: &'static str,
	pub offset: usize,
	pub width: usize,
	pub encoding: &'static str,
	pub unit: &'static str,
	pub meaning: &'static str,
}

impl Field {
	pub const fn end(self) -> usize {
		self.offset + self.width
	}
	pub const fn range(self) -> std::ops::Range<usize> {
		self.offset..self.end()
	}
	pub fn write_u32(self, output: &mut [f32], value: u32) {
		output[self.range()]
			.copy_from_slice(&crate::dm_codec::split_u32_words(value).map(f32::from));
	}
	pub fn write_u64(self, output: &mut [f32], value: u64) {
		output[self.range()]
			.copy_from_slice(&crate::dm_codec::split_u64_words(value).map(f32::from));
	}
}

pub(crate) struct Layout {
	pub name: &'static str,
	pub width: usize,
	pub fields: &'static [Field],
}

macro_rules! record_layout {
	($module:ident, $name:literal; $(($field:ident, $width:expr, $encoding:literal, $unit:literal, $meaning:literal)),+ $(,)?) => {
		pub(crate) mod $module {
			use crate::adapter_layout::{Field, Layout};
			record_layout!(@fields 0; $(($field, $width, $encoding, $unit, $meaning)),+);
			pub const LEN: usize = 0 $(+ $width)+;
			pub const LAYOUT: Layout = Layout { name: $name, width: LEN, fields: &[$($field),+] };
		}
	};
	(@fields $offset:expr; ($field:ident, $width:expr, $encoding:literal, $unit:literal, $meaning:literal) $(, $rest:tt)*) => {
		pub const $field: Field = Field { name: stringify!($field), offset: $offset, width: $width, encoding: $encoding, unit: $unit, meaning: $meaning };
		record_layout!(@fields ($offset + $width); $($rest),*);
	};
	(@fields $offset:expr;) => {};
}

pub(crate) mod callbacks;
pub(crate) mod metadata;
pub(crate) mod mixtures;
pub(crate) mod stages;
pub(crate) mod telemetry;
pub(crate) mod topology;

pub(crate) fn dm_definitions() -> String {
	let mut output = String::from("// Generated DM adapter layouts. Do not edit. Positions are one-based; widths count list elements.\n// u16 words encode unsigned integers little-endian. Finite scalars retain existing domain validation.\n// No implicit padding or new version fields; the matched ABI/protocol contract selects these legacy shapes.\n");
	for layout in mixtures::LAYOUTS
		.iter()
		.chain(metadata::LAYOUTS)
		.chain(topology::LAYOUTS)
		.chain(callbacks::LAYOUTS)
		.chain(stages::LAYOUTS)
		.chain(telemetry::LAYOUTS)
	{
		writeln!(
			output,
			"\n#define DOGMOS_DM_{}_FIELDS {}",
			layout.name, layout.width
		)
		.unwrap();
		for field in layout.fields {
			writeln!(
				output,
				"// {}: {}; {}; {}. Width {} (through field {}).",
				field.name,
				field.encoding,
				field.unit,
				field.meaning,
				field.width,
				field.end()
			)
			.unwrap();
			writeln!(
				output,
				"#define DOGMOS_DM_{}_{} {}",
				layout.name,
				field.name,
				field.offset + 1
			)
			.unwrap();
		}
	}
	output.push_str(&legacy_definitions());
	output
}

fn legacy_definitions() -> String {
	let mut output = String::from("\n// Existing DM names retained exactly. Callback event aliases are zero-relative offsets.\n");
	for (name, value) in legacy_values() {
		writeln!(output, "#define {name} {value}").unwrap();
	}
	output
}

pub(crate) fn legacy_values() -> Vec<(&'static str, usize)> {
	use callbacks::{callback_event as e, callback_header as h};
	use mixtures::mixture_snapshot as m;
	use stages::{job_response as j, stage_response as s};
	use telemetry::service_telemetry as t;
	vec![
		("DOGMOS_SERVICE_TELEMETRY_WORDS", t::LEN),
		("DOGMOS_JOB_TELEMETRY_START", t::JOB.offset + 1),
		("DOGMOS_JOB_TELEMETRY_STATUS", t::JOB_STATUS.offset + 1),
		("DOGMOS_JOB_TELEMETRY_COUNTERS", t::JOB_AGE.offset + 1),
		("DOGMOS_JOB_RESPONSE_FIELDS", j::LEN),
		("DOGMOS_JOB_STATUS", j::STATUS.offset + 1),
		("DOGMOS_JOB_STAGE", j::STAGE.offset + 1),
		("DOGMOS_CALLBACK_HEADER_FIELDS", h::LEN),
		("DOGMOS_CALLBACK_EVENT_FIELDS", e::LEN),
		("DOGMOS_CALLBACK_EVENT_START", h::LEN + 1),
		("DOGMOS_CALLBACK_TRANSACTION_WORD", e::TRANSACTION.offset),
		("DOGMOS_CALLBACK_SCOPE_FIELD", e::SCOPE.offset),
		("DOGMOS_CALLBACK_KIND_FIELD", e::KIND.offset),
		("DOGMOS_CALLBACK_SUBJECT_SLOT_FIELD", e::SUBJECT_SLOT.offset),
		(
			"DOGMOS_CALLBACK_SUBJECT_GENERATION_FIELD",
			e::SUBJECT_GENERATION.offset,
		),
		("DOGMOS_CALLBACK_TARGET_SLOT_FIELD", e::TARGET_SLOT.offset),
		(
			"DOGMOS_CALLBACK_TARGET_GENERATION_FIELD",
			e::TARGET_GENERATION.offset,
		),
		("DOGMOS_CALLBACK_VALUES_FIELD", e::VALUES.offset),
		("DOGMOS_CALLBACK_AUX_FIELD", e::AUX.offset),
		("DOGMOS_CALLBACK_CONTINUATION_TOKEN_FIELD", e::TOKEN.offset),
		(
			"DOGMOS_TURF_LIFECYCLE_FIELDS",
			topology::turf_lifecycle::LEN,
		),
		(
			"DOGMOS_TURF_ADJACENCY_FIELDS",
			topology::turf_adjacency::LEN,
		),
		("DOGMOS_TURF_HEAT_FIELDS", topology::turf_heat::LEN),
		(
			"DOGMOS_TURF_HEAT_ADJACENCY_FIELDS",
			topology::turf_heat_adjacency::LEN,
		),
		("DOGMOS_MIXTURE_SNAPSHOT_FIELDS", m::LEN),
		(
			"DOGMOS_MIXTURE_SNAPSHOT_REVISION_LOW",
			m::REVISION.offset + 1,
		),
		(
			"DOGMOS_MIXTURE_SNAPSHOT_REVISION_HIGH",
			m::REVISION.offset + 2,
		),
		("DOGMOS_MIXTURE_SNAPSHOT_GAS_COUNT", m::GAS_COUNT.offset + 1),
		(
			"DOGMOS_MIXTURE_SNAPSHOT_TEMPERATURE",
			m::TEMPERATURE.offset + 1,
		),
		("DOGMOS_MIXTURE_SNAPSHOT_VOLUME", m::VOLUME.offset + 1),
		(
			"DOGMOS_MIXTURE_SNAPSHOT_TOTAL_MOLES",
			m::TOTAL_MOLES.offset + 1,
		),
		("DOGMOS_MIXTURE_SNAPSHOT_PRESSURE", m::PRESSURE.offset + 1),
		(
			"DOGMOS_MIXTURE_SNAPSHOT_HEAT_CAPACITY",
			m::HEAT_CAPACITY.offset + 1,
		),
		("DOGMOS_MIXTURE_SNAPSHOT_IMMUTABLE", m::IMMUTABLE.offset + 1),
		("DOGMOS_MIXTURE_SNAPSHOT_GASES_START", m::GASES.offset + 1),
		(
			"DOGMOS_PIPENET_RECONCILE_RECORD_FIELDS",
			mixtures::pipenet_record::LEN,
		),
		("DOGMOS_STAGE_RESPONSE_FIELDS", s::LEN),
		("DOGMOS_STAGE_RESPONSE_PENDING", s::PENDING.offset + 1),
	]
}

#[cfg(test)]
mod tests;
