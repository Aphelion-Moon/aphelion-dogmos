//! Pure validated DM adapters for stages.

use crate::dm_codec::{
	exact_u16, exact_u32, exact_words4, join_u32_words, join_u64_words, labeled_handle, numbered,
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
	use crate::adapter_layout::stages::frontier_begin as fields_layout;

	if fields.len() != fields_layout::LEN {
		return Err(eyre::eyre!(
			"frontier begin requires four epoch words and two count words"
		));
	}
	Ok(FrontierBeginRequest {
		epoch: join_u64_words(exact_words4(
			&fields[fields_layout::EPOCH.range()],
			"frontier epoch",
		)?),
		expected_count: join_u32_words(
			exact_u16(
				fields[fields_layout::EXPECTED_COUNT.offset],
				"frontier count word 0",
			)?,
			exact_u16(
				fields[fields_layout::EXPECTED_COUNT.offset + 1],
				"frontier count word 1",
			)?,
		),
	}
	.encode())
}

/// Encodes validated DM numeric fields as protocol bytes for frontier append.
///
/// Preserves field order and little-endian word identity; invalid lengths, tags or
/// numeric values return a caller-legible error. This adapter performs no BYOND call.
pub fn encode_production_frontier_append(fields: &[f32]) -> eyre::Result<Vec<u8>> {
	use crate::adapter_layout::mixtures::word_handle as words_layout;
	use crate::adapter_layout::stages::frontier_append_header as fields_layout;

	if fields.len() < fields_layout::LEN + words_layout::LEN
		|| !(fields.len() - fields_layout::LEN).is_multiple_of(words_layout::LEN)
	{
		return Err(eyre::eyre!(
			"frontier append requires epoch, offset, and at least one fixed four-word handle"
		));
	}
	let handle_count = (fields.len() - fields_layout::LEN) / words_layout::LEN;
	if handle_count > MAX_FRONTIER_APPEND_HANDLES {
		return Err(eyre::eyre!(
			"frontier append contains {handle_count} handles, maximum {MAX_FRONTIER_APPEND_HANDLES}"
		));
	}
	let handles = fields[fields_layout::LEN..]
		.as_chunks::<{ words_layout::LEN }>()
		.0
		.iter()
		.enumerate()
		.map(|(index, words)| {
			Ok(WireHandle {
				slot: join_u32_words(
					numbered(
						exact_u16(words[words_layout::SLOT.offset], "slot word 0"),
						"frontier handle",
						index,
					)?,
					numbered(
						exact_u16(words[words_layout::SLOT.offset + 1], "slot word 1"),
						"frontier handle",
						index,
					)?,
				),
				generation: join_u32_words(
					numbered(
						exact_u16(words[words_layout::GENERATION.offset], "generation word 0"),
						"frontier handle",
						index,
					)?,
					numbered(
						exact_u16(
							words[words_layout::GENERATION.offset + 1],
							"generation word 1",
						),
						"frontier handle",
						index,
					)?,
				),
			})
		})
		.collect::<eyre::Result<Vec<_>>>()?;
	Ok(FrontierAppendRequest {
		epoch: join_u64_words(exact_words4(
			&fields[fields_layout::EPOCH.range()],
			"frontier epoch",
		)?),
		offset: join_u32_words(
			exact_u16(
				fields[fields_layout::OFFSET.offset],
				"frontier offset word 0",
			)?,
			exact_u16(
				fields[fields_layout::OFFSET.offset + 1],
				"frontier offset word 1",
			)?,
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
	use crate::adapter_layout::mixtures::word_handle as words_layout;
	use crate::adapter_layout::stages::epoch as fields_layout;

	if fields.len() < fields_layout::LEN + words_layout::LEN
		|| !(fields.len() - fields_layout::LEN).is_multiple_of(words_layout::LEN)
	{
		return Err(eyre::eyre!(
			"{label} requires epoch and at least one fixed four-word handle"
		));
	}
	let handle_count = (fields.len() - fields_layout::LEN) / words_layout::LEN;
	if handle_count > MAX_FRONTIER_APPEND_HANDLES {
		return Err(eyre::eyre!(
			"{label} contains {handle_count} handles, maximum {MAX_FRONTIER_APPEND_HANDLES}"
		));
	}
	let handles = fields[fields_layout::LEN..]
		.as_chunks::<{ words_layout::LEN }>()
		.0
		.iter()
		.enumerate()
		.map(|(index, words)| {
			Ok(WireHandle {
				slot: join_u32_words(
					labeled_handle(
						exact_u16(words[words_layout::SLOT.offset], "slot word 0"),
						label,
						index,
					)?,
					labeled_handle(
						exact_u16(words[words_layout::SLOT.offset + 1], "slot word 1"),
						label,
						index,
					)?,
				),
				generation: join_u32_words(
					labeled_handle(
						exact_u16(words[words_layout::GENERATION.offset], "generation word 0"),
						label,
						index,
					)?,
					labeled_handle(
						exact_u16(
							words[words_layout::GENERATION.offset + 1],
							"generation word 1",
						),
						label,
						index,
					)?,
				),
			})
		})
		.collect::<eyre::Result<Vec<_>>>()?;
	Ok(FrontierMutateRequest {
		epoch: join_u64_words(exact_words4(
			&fields[fields_layout::EPOCH.range()],
			"frontier epoch",
		)?),
		handles,
	}
	.encode()?)
}

/// Encodes validated DM numeric fields as protocol bytes for simulation stage.
///
/// Preserves field order and little-endian word identity; invalid lengths, tags or
/// numeric values return a caller-legible error. This adapter performs no BYOND call.
pub fn encode_production_simulation_stage(
	fields: [f32; crate::adapter_layout::stages::stage_request::LEN],
) -> eyre::Result<[u8; dogmos_protocol::SIMULATION_STAGE_REQUEST_LEN]> {
	use crate::adapter_layout::stages::stage_request as fields_layout;

	Ok(SimulationStageRequest {
		stage: SimulationStage::try_from(exact_u32(
			fields[fields_layout::STAGE.offset],
			"simulation stage",
		)?)?,
		frontier_epoch: join_u64_words(exact_words4(
			&fields[fields_layout::FRONTIER_EPOCH.range()],
			"frontier epoch",
		)?),
		stage_epoch: join_u64_words(exact_words4(
			&fields[fields_layout::STAGE_EPOCH.range()],
			"stage epoch",
		)?),
		work_limit: join_u32_words(
			exact_u16(
				fields[fields_layout::WORK_LIMIT.offset],
				"stage work-limit word 0",
			)?,
			exact_u16(
				fields[fields_layout::WORK_LIMIT.offset + 1],
				"stage work-limit word 1",
			)?,
		),
		seconds_per_tick: ScalarValue(f64::from(fields[fields_layout::SECONDS_PER_TICK.offset])),
	}
	.encode()?)
}

/// Decodes protocol bytes into exact DM numeric fields for simulation stage.
///
/// Preserves field order and little-endian word identity; invalid lengths, tags or
/// numeric values return a caller-legible error. This adapter performs no BYOND call.
pub fn decode_production_simulation_stage(
	response: &[u8],
) -> eyre::Result<[f32; crate::adapter_layout::stages::stage_response::LEN]> {
	let response = SimulationStageResponse::decode(response)?;
	use crate::adapter_layout::stages::stage_response as layout;
	let mut fields = [0.0; layout::LEN];
	layout::WORK_ITEMS.write_u32(&mut fields, response.work_items);
	layout::CALLBACK_EVENTS.write_u32(&mut fields, response.callback_events);
	fields[layout::PENDING.offset] = f32::from(response.pending);
	layout::REMAINING.write_u32(&mut fields, response.remaining_estimate);
	layout::EQUALIZE_SEEDS.write_u32(&mut fields, response.produced_equalize_seeds);
	layout::GROUP_SEEDS.write_u32(&mut fields, response.produced_group_seeds);
	layout::HEAT_SEEDS.write_u32(&mut fields, response.produced_heat_seeds);
	Ok(fields)
}
