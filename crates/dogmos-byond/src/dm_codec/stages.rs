//! Pure validated DM adapters for stages.

use crate::dm_codec::{
	append_u32_words, exact_u16, exact_u32, exact_words4, join_u32_words, join_u64_words,
	labeled_handle, numbered,
};
use dogmos_protocol::{
	FrontierAppendRequest, FrontierBeginRequest, FrontierMutateRequest, ScalarValue,
	SimulationStage, SimulationStageRequest, SimulationStageResponse, WireHandle,
	MAX_FRONTIER_APPEND_HANDLES,
};

/// Encodes validated DM numeric fields as protocol bytes for frontier begin.
///
/// Preserves field order and little-endian word identity; invalid lengths, tags or
/// numeric values return a caller-legible error. This adapter performs no BYOND call.
pub fn encode_production_frontier_begin(fields: &[f32]) -> eyre::Result<[u8; 16]> {
	if fields.len() != 6 {
		return Err(eyre::eyre!(
			"frontier begin requires four epoch words and two count words"
		));
	}
	Ok(FrontierBeginRequest {
		epoch: join_u64_words(exact_words4(&fields[..4], "frontier epoch")?),
		expected_count: join_u32_words(
			exact_u16(fields[4], "frontier count word 0")?,
			exact_u16(fields[5], "frontier count word 1")?,
		),
	}
	.encode())
}

/// Encodes validated DM numeric fields as protocol bytes for frontier append.
///
/// Preserves field order and little-endian word identity; invalid lengths, tags or
/// numeric values return a caller-legible error. This adapter performs no BYOND call.
pub fn encode_production_frontier_append(fields: &[f32]) -> eyre::Result<Vec<u8>> {
	if fields.len() < 10 || !(fields.len() - 6).is_multiple_of(4) {
		return Err(eyre::eyre!(
			"frontier append requires epoch, offset, and at least one fixed four-word handle"
		));
	}
	let handle_count = (fields.len() - 6) / 4;
	if handle_count > MAX_FRONTIER_APPEND_HANDLES {
		return Err(eyre::eyre!(
			"frontier append contains {handle_count} handles, maximum {MAX_FRONTIER_APPEND_HANDLES}"
		));
	}
	let handles = fields[6..]
		.as_chunks::<4>()
		.0
		.iter()
		.enumerate()
		.map(|(index, words)| {
			Ok(WireHandle {
				slot: join_u32_words(
					numbered(exact_u16(words[0], "slot word 0"), "frontier handle", index)?,
					numbered(exact_u16(words[1], "slot word 1"), "frontier handle", index)?,
				),
				generation: join_u32_words(
					numbered(
						exact_u16(words[2], "generation word 0"),
						"frontier handle",
						index,
					)?,
					numbered(
						exact_u16(words[3], "generation word 1"),
						"frontier handle",
						index,
					)?,
				),
			})
		})
		.collect::<eyre::Result<Vec<_>>>()?;
	Ok(FrontierAppendRequest {
		epoch: join_u64_words(exact_words4(&fields[..4], "frontier epoch")?),
		offset: join_u32_words(
			exact_u16(fields[4], "frontier offset word 0")?,
			exact_u16(fields[5], "frontier offset word 1")?,
		),
		handles,
	}
	.encode()?)
}

/// Encodes validated DM numeric fields as protocol bytes for frontier mutate.
///
/// Preserves field order and little-endian word identity; invalid lengths, tags or
/// numeric values return a caller-legible error. This adapter performs no BYOND call.
pub fn encode_production_frontier_mutate(fields: &[f32], label: &str) -> eyre::Result<Vec<u8>> {
	if fields.len() < 8 || !(fields.len() - 4).is_multiple_of(4) {
		return Err(eyre::eyre!(
			"{label} requires epoch and at least one fixed four-word handle"
		));
	}
	let handle_count = (fields.len() - 4) / 4;
	if handle_count > MAX_FRONTIER_APPEND_HANDLES {
		return Err(eyre::eyre!(
			"{label} contains {handle_count} handles, maximum {MAX_FRONTIER_APPEND_HANDLES}"
		));
	}
	let handles = fields[4..]
		.as_chunks::<4>()
		.0
		.iter()
		.enumerate()
		.map(|(index, words)| {
			Ok(WireHandle {
				slot: join_u32_words(
					labeled_handle(exact_u16(words[0], "slot word 0"), label, index)?,
					labeled_handle(exact_u16(words[1], "slot word 1"), label, index)?,
				),
				generation: join_u32_words(
					labeled_handle(exact_u16(words[2], "generation word 0"), label, index)?,
					labeled_handle(exact_u16(words[3], "generation word 1"), label, index)?,
				),
			})
		})
		.collect::<eyre::Result<Vec<_>>>()?;
	Ok(FrontierMutateRequest {
		epoch: join_u64_words(exact_words4(&fields[..4], "frontier epoch")?),
		handles,
	}
	.encode()?)
}

/// Encodes validated DM numeric fields as protocol bytes for simulation stage.
///
/// Preserves field order and little-endian word identity; invalid lengths, tags or
/// numeric values return a caller-legible error. This adapter performs no BYOND call.
pub fn encode_production_simulation_stage(
	fields: [f32; 12],
) -> eyre::Result<[u8; dogmos_protocol::SIMULATION_STAGE_REQUEST_LEN]> {
	Ok(SimulationStageRequest {
		stage: SimulationStage::try_from(exact_u32(fields[0], "simulation stage")?)?,
		frontier_epoch: join_u64_words(exact_words4(&fields[1..5], "frontier epoch")?),
		stage_epoch: join_u64_words(exact_words4(&fields[5..9], "stage epoch")?),
		work_limit: join_u32_words(
			exact_u16(fields[9], "stage work-limit word 0")?,
			exact_u16(fields[10], "stage work-limit word 1")?,
		),
		seconds_per_tick: ScalarValue(f64::from(fields[11])),
	}
	.encode()?)
}

/// Decodes protocol bytes into exact DM numeric fields for simulation stage.
///
/// Preserves field order and little-endian word identity; invalid lengths, tags or
/// numeric values return a caller-legible error. This adapter performs no BYOND call.
pub fn decode_production_simulation_stage(response: &[u8]) -> eyre::Result<[f32; 13]> {
	let response = SimulationStageResponse::decode(response)?;
	let mut fields = Vec::with_capacity(13);
	append_u32_words(&mut fields, response.work_items);
	append_u32_words(&mut fields, response.callback_events);
	fields.push(f32::from(response.pending));
	append_u32_words(&mut fields, response.remaining_estimate);
	append_u32_words(&mut fields, response.produced_equalize_seeds);
	append_u32_words(&mut fields, response.produced_group_seeds);
	append_u32_words(&mut fields, response.produced_heat_seeds);
	Ok(fields
		.try_into()
		.expect("stage response has thirteen fields"))
}
