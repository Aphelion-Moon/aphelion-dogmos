//! Pure validated DM adapters for mixtures.

use crate::dm_codec::{
	exact_u16, exact_u32, finite_byond_scalar, finite_indexed_byond_scalar, fixed_batch_capacity,
	indexed, join_u32_words, PRODUCTION_MAX_BATCH_OPERATIONS, PRODUCTION_MAX_MIXTURE_ADJUSTMENTS,
	PRODUCTION_MAX_MIXTURE_SNAPSHOT_BATCH, PRODUCTION_MAX_MIXTURE_STATE_MUTATIONS,
	PRODUCTION_MAX_PIPENET_RECONCILE_MIXTURES, PRODUCTION_MIXTURE_STATE_FIELDS,
	PRODUCTION_PIPENET_RESPONSE_FIELDS,
};
use dogmos_protocol::{
	decode_pipenet_reconcile_response, encode_adjust_multiple_request, encode_lifecycle_batch,
	encode_mixture_snapshot_batch_request, encode_mixture_state_batch,
	encode_pipenet_reconcile_request, mixture_snapshot_batch_records, LifecycleAction,
	LifecycleMutation, MixtureAdjustment, MixtureCommandRequest, MixtureSnapshot,
	MixtureStateMutation, ScalarValue, WireHandle, LIFECYCLE_MUTATION_LEN, MAX_GAS_SLOTS,
	MAX_MIXTURE_SNAPSHOT_BATCH, MAX_PIPENET_RECONCILE_MIXTURES, MIXTURE_COMMAND_REQUEST_LEN,
	MIXTURE_STATE_MUTATION_LEN,
};

/// Encodes validated DM numeric fields as protocol bytes for mixture command.
///
/// Preserves field order and little-endian word identity; invalid lengths, tags or
/// numeric values return a caller-legible error. This adapter performs no BYOND call.
pub fn encode_production_mixture_command(
	fields: [f32; crate::adapter_layout::mixtures::mixture_command::LEN],
) -> eyre::Result<[u8; MIXTURE_COMMAND_REQUEST_LEN]> {
	use crate::adapter_layout::mixtures::mixture_command as fields_layout;

	encode_dm_mixture_command(DmMixtureCommandFields {
		kind: exact_u16(fields[fields_layout::KIND.offset], "mixture command kind")?,
		flags: exact_u16(fields[fields_layout::FLAGS.offset], "mixture command flags")?,
		primary: WireHandle {
			slot: exact_u32(
				fields[fields_layout::PRIMARY_SLOT.offset],
				"primary mixture slot",
			)?,
			generation: exact_u32(
				fields[fields_layout::PRIMARY_GENERATION.offset],
				"primary mixture generation",
			)?,
		},
		secondary: WireHandle {
			slot: exact_u32(
				fields[fields_layout::SECONDARY_SLOT.offset],
				"secondary mixture slot",
			)?,
			generation: exact_u32(
				fields[fields_layout::SECONDARY_GENERATION.offset],
				"secondary mixture generation",
			)?,
		},
		scalars: [
			fields[fields_layout::SCALARS.offset],
			fields[fields_layout::SCALARS.offset + 1],
			fields[fields_layout::SCALARS.offset + 2],
		],
		gas_id: exact_u16(fields[fields_layout::GAS_ID.offset], "gas id")?,
		aux: exact_u32(
			fields[fields_layout::AUX.offset],
			"mixture command auxiliary value",
		)?,
	})
}

/// Encodes validated DM numeric fields as protocol bytes for mixture adjust multiple.
///
/// Preserves field order and little-endian word identity; invalid lengths, tags or
/// numeric values return a caller-legible error. This adapter performs no BYOND call.
pub fn encode_production_mixture_adjust_multiple(values: &[f32]) -> eyre::Result<Vec<u8>> {
	use crate::adapter_layout::mixtures::adjustment as entry_layout;
	use crate::adapter_layout::mixtures::handle as values_layout;

	if values.len() < values_layout::LEN
		|| !(values.len() - values_layout::LEN).is_multiple_of(entry_layout::LEN)
	{
		return Err(eyre::eyre!(
			"mixture multi-adjust requires slot, generation, and gas/delta pairs"
		));
	}
	let adjustment_count = (values.len() - values_layout::LEN) / entry_layout::LEN;
	if adjustment_count > PRODUCTION_MAX_MIXTURE_ADJUSTMENTS {
		return Err(eyre::eyre!(
			"mixture multi-adjust contains {adjustment_count} adjustments, maximum {PRODUCTION_MAX_MIXTURE_ADJUSTMENTS}"
		));
	}
	let handle = WireHandle {
		slot: exact_u32(
			values[values_layout::SLOT.offset],
			"multi-adjust mixture slot",
		)?,
		generation: exact_u32(
			values[values_layout::GENERATION.offset],
			"multi-adjust mixture generation",
		)?,
	};
	let adjustments = values[values_layout::LEN..]
		.as_chunks::<{ entry_layout::LEN }>()
		.0
		.iter()
		.enumerate()
		.map(|(index, entry)| {
			// Avoids a &format!(...) allocation per adjustment (this can run once per gas type in
			// a batched multi-adjust call, which is the whole point of batching) - only format
			// the "entry N" label if the value actually fails validation.
			let gas_id = exact_u32(
				entry[entry_layout::GAS_ID.offset],
				"multi-adjust entry gas id",
			)
			.and_then(|value| {
				u16::try_from(value).map_err(|_| eyre::eyre!("value exceeds the u16 wire range"))
			})
			.map_err(|error| eyre::eyre!("multi-adjust entry {index} gas id: {error}"))?;
			Ok(MixtureAdjustment {
				gas_id,
				delta: ScalarValue(f64::from(entry[entry_layout::DELTA.offset])),
			})
		})
		.collect::<eyre::Result<Vec<_>>>()?;
	let mut output = Vec::new();
	encode_adjust_multiple_request(handle, &adjustments, &mut output)?;
	Ok(output)
}

/// Decodes protocol bytes into exact DM numeric fields for mixture snapshot.
///
/// Preserves field order and little-endian word identity; invalid lengths, tags or
/// numeric values return a caller-legible error. This adapter performs no BYOND call.
pub fn decode_production_mixture_snapshot(response: &[u8]) -> eyre::Result<Vec<f32>> {
	let snapshot = MixtureSnapshot::decode(response)?;
	let mut fields = Vec::with_capacity(crate::adapter_layout::mixtures::mixture_snapshot::LEN);
	append_production_mixture_snapshot(&mut fields, snapshot)?;
	Ok(fields)
}

pub(crate) fn append_production_mixture_snapshot(
	fields: &mut Vec<f32>,
	snapshot: MixtureSnapshot,
) -> eyre::Result<()> {
	use crate::adapter_layout::mixtures::mixture_snapshot as layout;
	let mut record = [0.0; layout::LEN];
	layout::REVISION.write_u32(&mut record, snapshot.revision);
	record[layout::GAS_COUNT.offset] = snapshot.gas_count as f32;
	record[layout::TEMPERATURE.offset] =
		finite_byond_scalar(snapshot.temperature.0, "mixture snapshot temperature")?;
	record[layout::VOLUME.offset] =
		finite_byond_scalar(snapshot.volume.0, "mixture snapshot volume")?;
	record[layout::MINIMUM_HEAT_CAPACITY.offset] = finite_byond_scalar(
		snapshot.minimum_heat_capacity.0,
		"mixture snapshot minimum heat capacity",
	)?;
	record[layout::TOTAL_MOLES.offset] =
		finite_byond_scalar(snapshot.total_moles.0, "mixture snapshot total moles")?;
	record[layout::PRESSURE.offset] =
		finite_byond_scalar(snapshot.pressure.0, "mixture snapshot pressure")?;
	record[layout::HEAT_CAPACITY.offset] =
		finite_byond_scalar(snapshot.heat_capacity.0, "mixture snapshot heat capacity")?;
	record[layout::IMMUTABLE.offset] = f32::from(snapshot.immutable);
	for (index, gas) in snapshot.gases.into_iter().enumerate() {
		record[layout::GASES.offset + index] =
			finite_indexed_byond_scalar(gas.0, "mixture snapshot gas", index)?;
	}
	fields.extend(record);
	Ok(())
}

/// Encodes validated DM numeric fields as protocol bytes for pipenet reconcile.
///
/// Preserves field order and little-endian word identity; invalid lengths, tags or
/// numeric values return a caller-legible error. This adapter performs no BYOND call.
pub fn encode_production_pipenet_reconcile(values: &[f32]) -> eyre::Result<Vec<u8>> {
	if !values
		.len()
		.is_multiple_of(crate::adapter_layout::mixtures::handle::LEN)
	{
		return Err(eyre::eyre!(
			"pipenet reconcile requires slot and generation pairs"
		));
	}
	let operation_count = values.len() / crate::adapter_layout::mixtures::handle::LEN;
	if operation_count > PRODUCTION_MAX_PIPENET_RECONCILE_MIXTURES {
		return Err(eyre::eyre!(
			"pipenet reconcile contains {operation_count} mixtures, maximum {PRODUCTION_MAX_PIPENET_RECONCILE_MIXTURES}"
		));
	}
	let handles = handles_from_slot_generation_pairs(values, "pipenet reconcile")?;
	let mut output = Vec::with_capacity(4 + handles.len() * 8);
	encode_pipenet_reconcile_request(&handles, &mut output)?;
	Ok(output)
}

/// Reads a flat DM list of `slot, generation` pairs into wire handles.
pub(crate) fn handles_from_slot_generation_pairs(
	values: &[f32],
	context: &'static str,
) -> eyre::Result<Vec<WireHandle>> {
	use crate::adapter_layout::mixtures::handle as entry_layout;

	values
		.as_chunks::<{ entry_layout::LEN }>()
		.0
		.iter()
		.enumerate()
		.map(|(index, entry)| {
			Ok(WireHandle {
				slot: indexed(
					exact_u32(entry[entry_layout::SLOT.offset], "slot"),
					context,
					index,
				)?,
				generation: indexed(
					exact_u32(entry[entry_layout::GENERATION.offset], "generation"),
					context,
					index,
				)?,
			})
		})
		.collect()
}

/// Decodes protocol bytes into exact DM numeric fields for pipenet reconcile.
///
/// Preserves field order and little-endian word identity; invalid lengths, tags or
/// numeric values return a caller-legible error. This adapter performs no BYOND call.
pub fn decode_production_pipenet_reconcile(response: &[u8]) -> eyre::Result<Vec<f32>> {
	let entries =
		decode_pipenet_reconcile_response(response, MAX_PIPENET_RECONCILE_MIXTURES as u32)?;
	let mut fields = Vec::with_capacity(entries.len() * PRODUCTION_PIPENET_RESPONSE_FIELDS);
	for entry in entries {
		let mut prefix = [0.0; crate::adapter_layout::mixtures::pipenet_record::SNAPSHOT.offset];
		prefix[crate::adapter_layout::mixtures::pipenet_record::SLOT.offset] =
			entry.handle.slot as f32;
		prefix[crate::adapter_layout::mixtures::pipenet_record::GENERATION.offset] =
			entry.handle.generation as f32;
		fields.extend(prefix);
		append_production_mixture_snapshot(&mut fields, entry.snapshot)?;
	}
	Ok(fields)
}

/// Encodes validated DM numeric fields as protocol bytes for mixture snapshot batch.
///
/// Preserves field order and little-endian word identity; invalid lengths, tags or
/// numeric values return a caller-legible error. This adapter performs no BYOND call.
pub fn encode_production_mixture_snapshot_batch(values: &[f32]) -> eyre::Result<Vec<u8>> {
	if !values
		.len()
		.is_multiple_of(crate::adapter_layout::mixtures::handle::LEN)
	{
		return Err(eyre::eyre!(
			"mixture snapshot batch requires slot and generation pairs"
		));
	}
	let operation_count = values.len() / crate::adapter_layout::mixtures::handle::LEN;
	if operation_count > PRODUCTION_MAX_MIXTURE_SNAPSHOT_BATCH {
		return Err(eyre::eyre!(
			"mixture snapshot batch contains {operation_count} mixtures, maximum {PRODUCTION_MAX_MIXTURE_SNAPSHOT_BATCH}"
		));
	}
	let handles = handles_from_slot_generation_pairs(values, "mixture snapshot batch")?;
	let mut output = Vec::with_capacity(4 + handles.len() * 8);
	encode_mixture_snapshot_batch_request(&handles, &mut output)?;
	Ok(output)
}

/// Decodes protocol bytes into exact DM numeric fields for mixture snapshot batch.
///
/// Preserves field order and little-endian word identity; invalid lengths, tags or
/// numeric values return a caller-legible error. This adapter performs no BYOND call.
pub fn decode_production_mixture_snapshot_batch(response: &[u8]) -> eyre::Result<Vec<f32>> {
	let entries = mixture_snapshot_batch_records(response, MAX_MIXTURE_SNAPSHOT_BATCH as u32)?;
	let mut fields = Vec::with_capacity(entries.len() * PRODUCTION_PIPENET_RESPONSE_FIELDS);
	for entry in entries {
		let entry = entry?;
		let mut prefix = [0.0; crate::adapter_layout::mixtures::pipenet_record::SNAPSHOT.offset];
		prefix[crate::adapter_layout::mixtures::pipenet_record::SLOT.offset] =
			entry.handle.slot as f32;
		prefix[crate::adapter_layout::mixtures::pipenet_record::GENERATION.offset] =
			entry.handle.generation as f32;
		fields.extend(prefix);
		append_production_mixture_snapshot(&mut fields, entry.snapshot)?;
	}
	Ok(fields)
}

/// Encodes validated DM numeric fields as protocol bytes for mixture state batch.
///
/// Preserves field order and little-endian word identity; invalid lengths, tags or
/// numeric values return a caller-legible error. This adapter performs no BYOND call.
pub fn encode_production_mixture_state_batch(values: &[f32]) -> eyre::Result<Vec<u8>> {
	if !values.len().is_multiple_of(PRODUCTION_MIXTURE_STATE_FIELDS) {
		return Err(eyre::eyre!(
			"mixture state batch requires fixed {PRODUCTION_MIXTURE_STATE_FIELDS}-field records"
		));
	}
	let operation_count = values.len() / PRODUCTION_MIXTURE_STATE_FIELDS;
	if operation_count > PRODUCTION_MAX_MIXTURE_STATE_MUTATIONS {
		return Err(eyre::eyre!(
			"mixture state batch contains {operation_count} operations, maximum {PRODUCTION_MAX_MIXTURE_STATE_MUTATIONS}"
		));
	}
	let mutations = production_mixture_state_mutations(values)?;
	let capacity = fixed_batch_capacity(
		mutations.len(),
		MIXTURE_STATE_MUTATION_LEN,
		"mixture state batch",
	)?;
	let mut output = Vec::with_capacity(capacity);
	encode_mixture_state_batch(&mutations, &mut output)?;
	debug_assert_eq!(output.len(), capacity);
	Ok(output)
}

pub(crate) fn production_mixture_state_mutations(
	values: &[f32],
) -> eyre::Result<Vec<MixtureStateMutation>> {
	use crate::adapter_layout::mixtures::mixture_state as entry_layout;

	if !values.len().is_multiple_of(PRODUCTION_MIXTURE_STATE_FIELDS) {
		return Err(eyre::eyre!(
			"mixture state batch requires fixed {PRODUCTION_MIXTURE_STATE_FIELDS}-field records"
		));
	}
	values
		.as_chunks::<PRODUCTION_MIXTURE_STATE_FIELDS>()
		.0
		.iter()
		.enumerate()
		.map(|(index, entry)| {
			let mut gases = [ScalarValue(0.0); MAX_GAS_SLOTS];
			for (gas_index, gas) in gases.iter_mut().enumerate() {
				*gas = ScalarValue(f64::from(entry[entry_layout::GASES.offset + gas_index]));
			}
			Ok(MixtureStateMutation {
				handle: WireHandle {
					slot: indexed(
						exact_u32(entry[entry_layout::SLOT.offset], "slot"),
						"mixture state",
						index,
					)?,
					generation: indexed(
						exact_u32(entry[entry_layout::GENERATION.offset], "generation"),
						"mixture state",
						index,
					)?,
				},
				expected_revision: join_u32_words(
					indexed(
						exact_u16(entry[entry_layout::REVISION.offset], "revision low word"),
						"mixture state",
						index,
					)?,
					indexed(
						exact_u16(
							entry[entry_layout::REVISION.offset + 1],
							"revision high word",
						),
						"mixture state",
						index,
					)?,
				),
				temperature: ScalarValue(f64::from(entry[entry_layout::TEMPERATURE.offset])),
				volume: ScalarValue(f64::from(entry[entry_layout::VOLUME.offset])),
				gases,
			})
		})
		.collect::<eyre::Result<Vec<_>>>()
}

#[derive(Clone, Copy, Debug)]
pub(crate) struct DmMixtureCommandFields {
	pub(crate) kind: u16,
	pub(crate) flags: u16,
	pub(crate) primary: WireHandle,
	pub(crate) secondary: WireHandle,
	pub(crate) scalars: [f32; 3],
	pub(crate) gas_id: u16,
	pub(crate) aux: u32,
}

/// Encodes validated DM numeric fields as protocol bytes for mixture lifecycle batch.
///
/// Preserves field order and little-endian word identity; invalid lengths, tags or
/// numeric values return a caller-legible error. This adapter performs no BYOND call.
pub fn encode_production_mixture_lifecycle_batch(values: &[f32]) -> eyre::Result<Vec<u8>> {
	use crate::adapter_layout::mixtures::mixture_lifecycle as entry_layout;

	if !values
		.len()
		.is_multiple_of(crate::adapter_layout::mixtures::mixture_lifecycle::LEN)
	{
		return Err(eyre::eyre!(
			"mixture lifecycle batch requires action, slot, generation triples"
		));
	}
	let operation_count = values.len() / crate::adapter_layout::mixtures::mixture_lifecycle::LEN;
	if operation_count > PRODUCTION_MAX_BATCH_OPERATIONS {
		return Err(eyre::eyre!(
			"mixture lifecycle batch contains {operation_count} operations, maximum {PRODUCTION_MAX_BATCH_OPERATIONS}"
		));
	}
	let mutations = values
		.as_chunks::<{ crate::adapter_layout::mixtures::mixture_lifecycle::LEN }>()
		.0
		.iter()
		.enumerate()
		.map(|(index, entry)| {
			let action = LifecycleAction::try_from(indexed(
				exact_u32(entry[entry_layout::ACTION.offset], "action"),
				"mixture lifecycle",
				index,
			)?)?;
			Ok(LifecycleMutation {
				action,
				handle: WireHandle {
					slot: indexed(
						exact_u32(entry[entry_layout::SLOT.offset], "slot"),
						"mixture lifecycle",
						index,
					)?,
					generation: indexed(
						exact_u32(entry[entry_layout::GENERATION.offset], "generation"),
						"mixture lifecycle",
						index,
					)?,
				},
			})
		})
		.collect::<eyre::Result<Vec<_>>>()?;
	let capacity = fixed_batch_capacity(
		mutations.len(),
		LIFECYCLE_MUTATION_LEN,
		"mixture lifecycle batch",
	)?;
	let mut output = Vec::with_capacity(capacity);
	encode_lifecycle_batch(&mutations, &mut output)?;
	debug_assert_eq!(output.len(), capacity);
	Ok(output)
}

pub(crate) fn encode_dm_mixture_command(
	fields: DmMixtureCommandFields,
) -> eyre::Result<[u8; MIXTURE_COMMAND_REQUEST_LEN]> {
	let mut bytes = [0_u8; MIXTURE_COMMAND_REQUEST_LEN];
	bytes[0..2].copy_from_slice(&fields.kind.to_le_bytes());
	bytes[2..4].copy_from_slice(&fields.flags.to_le_bytes());
	bytes[4..12].copy_from_slice(&fields.primary.encode());
	bytes[12..20].copy_from_slice(&fields.secondary.encode());
	for (index, scalar) in fields.scalars.into_iter().enumerate() {
		let offset = 20 + index * 8;
		bytes[offset..offset + 8].copy_from_slice(&ScalarValue(f64::from(scalar)).encode()?);
	}
	bytes[44..46].copy_from_slice(&fields.gas_id.to_le_bytes());
	bytes[48..52].copy_from_slice(&fields.aux.to_le_bytes());
	Ok(MixtureCommandRequest::decode(&bytes)?.encode()?)
}
