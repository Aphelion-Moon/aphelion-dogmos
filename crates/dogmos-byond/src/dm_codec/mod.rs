//! Shared validation of exact DM numbers/words and bounded record shapes. No BYOND calls.

pub(crate) mod callbacks;
#[cfg(any(feature = "diagnostic-bindings", test))]
pub(crate) mod diagnostics;
pub(crate) mod metadata;
pub(crate) mod mixtures;
pub(crate) mod stages;
pub(crate) mod topology;

use crate::session_limits::SESSION_CONTROL_PAYLOAD_BYTES;
use dogmos_protocol::{
	MIXTURE_ADJUSTMENT_LEN, MIXTURE_ADJUST_MULTIPLE_HEADER_LEN, MIXTURE_SNAPSHOT_RECORD_LEN,
	MIXTURE_STATE_MUTATION_LEN, PIPENET_RECONCILE_SNAPSHOT_LEN, REACTION_METADATA_RECORD_LEN,
	TURF_ADJACENCY_MUTATION_LEN, TURF_HEAT_ADJACENCY_MUTATION_LEN, TURF_HEAT_MUTATION_LEN,
	TURF_LIFECYCLE_MUTATION_LEN,
};

pub(crate) const PRODUCTION_MAX_CALLBACK_EVENTS: u32 = 256;

pub(crate) const PRODUCTION_CALLBACK_EVENT_FIELDS: usize =
	crate::adapter_layout::callbacks::callback_event::LEN;

pub(crate) const PRODUCTION_CALLBACK_HEADER_FIELDS: usize =
	crate::adapter_layout::callbacks::callback_header::LEN;

pub(crate) const PRODUCTION_CONTINUATION_TOKEN_FIELDS: usize =
	crate::adapter_layout::callbacks::continuation_token::LEN;

pub(crate) const PRODUCTION_MAX_REACTION_METADATA: usize =
	(SESSION_CONTROL_PAYLOAD_BYTES - 4) / REACTION_METADATA_RECORD_LEN;

pub(crate) const PRODUCTION_REACTION_REQUIREMENT_FIELDS: usize =
	crate::adapter_layout::metadata::reaction_requirement::LEN;

pub(crate) const PRODUCTION_REACTION_METADATA_FIELDS: usize =
	crate::adapter_layout::metadata::reaction_metadata::LEN;

pub(crate) const PRODUCTION_GAS_PRODUCT_FIELDS: usize =
	crate::adapter_layout::metadata::gas_product::LEN;

pub(crate) const PRODUCTION_GAS_METADATA_FIELDS: usize =
	crate::adapter_layout::metadata::gas_metadata::LEN;

pub(crate) const PRODUCTION_MAX_TURF_HEAT_ADJACENCY_MUTATIONS: usize =
	(SESSION_CONTROL_PAYLOAD_BYTES - 4) / TURF_HEAT_ADJACENCY_MUTATION_LEN;

pub(crate) const PRODUCTION_TURF_HEAT_ADJACENCY_FIELDS: usize =
	crate::adapter_layout::topology::turf_heat_adjacency::LEN;

pub(crate) const PRODUCTION_MAX_TURF_HEAT_MUTATIONS: usize =
	(SESSION_CONTROL_PAYLOAD_BYTES - 4) / TURF_HEAT_MUTATION_LEN;

pub(crate) const PRODUCTION_TURF_HEAT_FIELDS: usize =
	crate::adapter_layout::topology::turf_heat::LEN;

pub(crate) const PRODUCTION_MAX_TURF_ADJACENCY_MUTATIONS: usize =
	(SESSION_CONTROL_PAYLOAD_BYTES - 4) / TURF_ADJACENCY_MUTATION_LEN;

pub(crate) const PRODUCTION_TURF_ADJACENCY_FIELDS: usize =
	crate::adapter_layout::topology::turf_adjacency::LEN;

pub(crate) const PRODUCTION_MAX_TURF_LIFECYCLE_MUTATIONS: usize =
	(SESSION_CONTROL_PAYLOAD_BYTES - 4) / TURF_LIFECYCLE_MUTATION_LEN;

pub(crate) const PRODUCTION_TURF_LIFECYCLE_FIELDS: usize =
	crate::adapter_layout::topology::turf_lifecycle::LEN;

pub(crate) const PRODUCTION_MAX_MIXTURE_STATE_MUTATIONS: usize =
	(SESSION_CONTROL_PAYLOAD_BYTES - 4) / MIXTURE_STATE_MUTATION_LEN;

pub(crate) const PRODUCTION_MAX_MIXTURE_SNAPSHOT_BATCH: usize =
	(SESSION_CONTROL_PAYLOAD_BYTES - 4) / MIXTURE_SNAPSHOT_RECORD_LEN;

pub(crate) const PRODUCTION_MAX_PIPENET_RECONCILE_MIXTURES: usize =
	(SESSION_CONTROL_PAYLOAD_BYTES - 4) / PIPENET_RECONCILE_SNAPSHOT_LEN;

pub(crate) const PRODUCTION_PIPENET_RESPONSE_FIELDS: usize =
	crate::adapter_layout::mixtures::pipenet_record::LEN;

pub(crate) const PRODUCTION_MIXTURE_STATE_FIELDS: usize =
	crate::adapter_layout::mixtures::mixture_state::LEN;

pub(crate) const PRODUCTION_MAX_MIXTURE_ADJUSTMENTS: usize =
	(SESSION_CONTROL_PAYLOAD_BYTES - MIXTURE_ADJUST_MULTIPLE_HEADER_LEN) / MIXTURE_ADJUSTMENT_LEN;

pub(crate) const PRODUCTION_MAX_BATCH_OPERATIONS: usize = 4096;

pub(crate) const MAX_EXACT_BYOND_INTEGER: f32 = 16_777_216.0;

pub(crate) fn decode_counted_response(response: &[u8], label: &str) -> eyre::Result<u32> {
	let response: [u8; 4] = response.try_into().map_err(|_| {
		eyre::eyre!(
			"Dogmos {label} response was {} bytes, expected 4",
			response.len()
		)
	})?;
	Ok(u32::from_le_bytes(response))
}

pub(crate) fn exact_u32(number: f32, field: &str) -> eyre::Result<u32> {
	if !number.is_finite()
		|| number < 0.0
		|| number > MAX_EXACT_BYOND_INTEGER
		|| number.fract() != 0.0
	{
		return Err(eyre::eyre!(
			"{field} must be an exact non-negative BYOND integer"
		));
	}
	Ok(number as u32)
}

pub(crate) fn exact_u16(number: f32, field: &str) -> eyre::Result<u16> {
	let number = exact_u32(number, field)?;
	u16::try_from(number).map_err(|_| eyre::eyre!("{field} exceeds the u16 wire range"))
}

pub(crate) fn exact_bool(number: f32, field: &str) -> eyre::Result<bool> {
	match exact_u32(number, field)? {
		0 => Ok(false),
		1 => Ok(true),
		actual => Err(eyre::eyre!("{field} must be 0 or 1, got {actual}")),
	}
}

pub(crate) fn indexed<T>(result: eyre::Result<T>, family: &str, index: usize) -> eyre::Result<T> {
	result.map_err(|error| eyre::eyre!("{family} entry {index} {error}"))
}

pub(crate) fn numbered<T>(result: eyre::Result<T>, family: &str, index: usize) -> eyre::Result<T> {
	result.map_err(|error| eyre::eyre!("{family} {index} {error}"))
}

pub(crate) fn labeled_handle<T>(
	result: eyre::Result<T>,
	label: &str,
	index: usize,
) -> eyre::Result<T> {
	result.map_err(|error| eyre::eyre!("{label} handle {index} {error}"))
}

pub(crate) fn validate_fixed_records(
	values: &[f32],
	record_fields: usize,
	maximum_records: usize,
	label: &str,
) -> eyre::Result<()> {
	if !values.len().is_multiple_of(record_fields) {
		return Err(eyre::eyre!(
			"{label} requires fixed {record_fields}-field records"
		));
	}
	let record_count = values.len() / record_fields;
	if record_count > maximum_records {
		return Err(eyre::eyre!(
			"{label} contains {record_count} operations, maximum {maximum_records}"
		));
	}
	Ok(())
}

pub(crate) fn fixed_batch_capacity(
	record_count: usize,
	record_len: usize,
	label: &str,
) -> eyre::Result<usize> {
	4_usize
		.checked_add(
			record_count
				.checked_mul(record_len)
				.ok_or_else(|| eyre::eyre!("{label} is too large"))?,
		)
		.ok_or_else(|| eyre::eyre!("{label} is too large"))
}

pub(crate) fn split_u32_words(value: u32) -> [u16; 2] {
	[value as u16, (value >> 16) as u16]
}

pub(crate) fn join_u32_words(low: u16, high: u16) -> u32 {
	u32::from(low) | (u32::from(high) << 16)
}

pub(crate) fn append_u32_words(output: &mut Vec<f32>, value: u32) {
	output.extend(split_u32_words(value).map(f32::from));
}

pub(crate) fn append_u64_words(output: &mut Vec<f32>, value: u64) {
	output.extend(split_u64_words(value).map(f32::from));
}

pub(crate) fn split_u64_words(value: u64) -> [u16; 4] {
	[
		value as u16,
		(value >> 16) as u16,
		(value >> 32) as u16,
		(value >> 48) as u16,
	]
}

pub(crate) fn join_u64_words(words: [u16; 4]) -> u64 {
	u64::from(words[0])
		| (u64::from(words[1]) << 16)
		| (u64::from(words[2]) << 32)
		| (u64::from(words[3]) << 48)
}

pub(crate) fn exact_words4(words: &[f32], field: &str) -> eyre::Result<[u16; 4]> {
	if words.len() != 4 {
		return Err(eyre::eyre!("{field} requires four 16-bit words"));
	}
	Ok([
		exact_u16(words[0], "word 0").map_err(|error| eyre::eyre!("{field} {error}"))?,
		exact_u16(words[1], "word 1").map_err(|error| eyre::eyre!("{field} {error}"))?,
		exact_u16(words[2], "word 2").map_err(|error| eyre::eyre!("{field} {error}"))?,
		exact_u16(words[3], "word 3").map_err(|error| eyre::eyre!("{field} {error}"))?,
	])
}

pub(crate) fn finite_byond_scalar(value: f64, field: &str) -> eyre::Result<f32> {
	let value = value as f32;
	if !value.is_finite() {
		return Err(eyre::eyre!(
			"{field} is outside the finite BYOND number range"
		));
	}
	Ok(value)
}

pub(crate) fn finite_indexed_byond_scalar(
	value: f64,
	prefix: &'static str,
	index: usize,
) -> eyre::Result<f32> {
	let value = value as f32;
	if !value.is_finite() {
		return Err(eyre::eyre!(
			"{prefix} {index} is outside the finite BYOND number range"
		));
	}
	Ok(value)
}

/// Inlines exact_u32()'s check instead of calling it with a &format!(...) label: that label was
/// built unconditionally on every call to bounded_number_list()/bounded_string_list() - both on
/// the hot decode path for every DM proc call - even though it's only read in the error branch.
pub(crate) fn checked_declared_length(number: f32, field: &str) -> eyre::Result<usize> {
	if !number.is_finite()
		|| number < 0.0
		|| number > MAX_EXACT_BYOND_INTEGER
		|| number.fract() != 0.0
	{
		return Err(eyre::eyre!(
			"{field} length must be an exact non-negative BYOND integer"
		));
	}
	Ok(number as u32 as usize)
}

pub(crate) fn hex_lower(bytes: &[u8]) -> String {
	const HEX: &[u8; 16] = b"0123456789abcdef";
	let mut output = String::with_capacity(bytes.len() * 2);
	for byte in bytes {
		output.push(HEX[usize::from(byte >> 4)] as char);
		output.push(HEX[usize::from(byte & 0x0f)] as char);
	}
	output
}
