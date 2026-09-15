//! Pure validated DM adapters for topology.

use crate::dm_codec::{
	exact_bool, exact_u32, finite_byond_scalar, fixed_batch_capacity, indexed,
	validate_fixed_records, PRODUCTION_MAX_TURF_ADJACENCY_MUTATIONS,
	PRODUCTION_MAX_TURF_HEAT_ADJACENCY_MUTATIONS, PRODUCTION_MAX_TURF_HEAT_MUTATIONS,
	PRODUCTION_MAX_TURF_LIFECYCLE_MUTATIONS, PRODUCTION_TURF_ADJACENCY_FIELDS,
	PRODUCTION_TURF_HEAT_ADJACENCY_FIELDS, PRODUCTION_TURF_HEAT_FIELDS,
	PRODUCTION_TURF_LIFECYCLE_FIELDS,
};
use dogmos_protocol::{
	encode_turf_adjacency_batch, encode_turf_heat_adjacency_batch, encode_turf_heat_batch,
	encode_turf_lifecycle_batch, LifecycleAction, ScalarValue, TurfAdjacencyMutation,
	TurfHeatAdjacencyMutation, TurfHeatMutation, TurfHeatSnapshot, TurfHeatState,
	TurfLifecycleMutation, WireHandle, TURF_ADJACENCY_MUTATION_LEN,
	TURF_HEAT_ADJACENCY_MUTATION_LEN, TURF_HEAT_MUTATION_LEN, TURF_LIFECYCLE_MUTATION_LEN,
};

/// Encodes validated DM numeric fields as protocol bytes for turf lifecycle batch.
///
/// Preserves field order and little-endian word identity; invalid lengths, tags or
/// numeric values return a caller-legible error. This adapter performs no BYOND call.
pub fn encode_production_turf_lifecycle_batch(values: &[f32]) -> eyre::Result<Vec<u8>> {
	validate_fixed_records(
		values,
		PRODUCTION_TURF_LIFECYCLE_FIELDS,
		PRODUCTION_MAX_TURF_LIFECYCLE_MUTATIONS,
		"turf lifecycle batch",
	)?;
	let mutations = values
		.as_chunks::<PRODUCTION_TURF_LIFECYCLE_FIELDS>()
		.0
		.iter()
		.enumerate()
		.map(|(index, entry)| {
			let action = LifecycleAction::try_from(indexed(
				exact_u32(entry[0], "action"),
				"turf lifecycle",
				index,
			)?)?;
			let mixture_present = indexed(
				exact_bool(entry[3], "mixture-present flag"),
				"turf lifecycle",
				index,
			)?;
			let mixture = WireHandle {
				slot: indexed(exact_u32(entry[4], "mixture slot"), "turf lifecycle", index)?,
				generation: indexed(
					exact_u32(entry[5], "mixture generation"),
					"turf lifecycle",
					index,
				)?,
			};
			if !mixture_present
				&& mixture
					!= (WireHandle {
						slot: 0,
						generation: 0,
					}) {
				return Err(eyre::eyre!(
					"turf lifecycle entry {index} has a mixture handle while the present flag is false"
				));
			}
			Ok(TurfLifecycleMutation {
				action,
				turf: WireHandle {
					slot: indexed(exact_u32(entry[1], "slot"), "turf lifecycle", index)?,
					generation: indexed(
						exact_u32(entry[2], "generation"),
						"turf lifecycle",
						index,
					)?,
				},
				mixture: mixture_present.then_some(mixture),
			})
		})
		.collect::<eyre::Result<Vec<_>>>()?;
	let capacity = fixed_batch_capacity(
		mutations.len(),
		TURF_LIFECYCLE_MUTATION_LEN,
		"turf lifecycle batch",
	)?;
	let mut output = Vec::with_capacity(capacity);
	encode_turf_lifecycle_batch(&mutations, &mut output)?;
	debug_assert_eq!(output.len(), capacity);
	Ok(output)
}

/// Encodes validated DM numeric fields as protocol bytes for turf adjacency batch.
///
/// Preserves field order and little-endian word identity; invalid lengths, tags or
/// numeric values return a caller-legible error. This adapter performs no BYOND call.
pub fn encode_production_turf_adjacency_batch(values: &[f32]) -> eyre::Result<Vec<u8>> {
	validate_fixed_records(
		values,
		PRODUCTION_TURF_ADJACENCY_FIELDS,
		PRODUCTION_MAX_TURF_ADJACENCY_MUTATIONS,
		"turf adjacency batch",
	)?;
	let mutations = values
		.as_chunks::<PRODUCTION_TURF_ADJACENCY_FIELDS>()
		.0
		.iter()
		.enumerate()
		.map(|(index, entry)| {
			Ok(TurfAdjacencyMutation {
				left: WireHandle {
					slot: indexed(exact_u32(entry[0], "left slot"), "turf adjacency", index)?,
					generation: indexed(
						exact_u32(entry[1], "left generation"),
						"turf adjacency",
						index,
					)?,
				},
				right: WireHandle {
					slot: indexed(exact_u32(entry[2], "right slot"), "turf adjacency", index)?,
					generation: indexed(
						exact_u32(entry[3], "right generation"),
						"turf adjacency",
						index,
					)?,
				},
				connected: indexed(
					exact_bool(entry[4], "connected flag"),
					"turf adjacency",
					index,
				)?,
				firelock: indexed(
					exact_bool(entry[5], "firelock flag"),
					"turf adjacency",
					index,
				)?,
			})
		})
		.collect::<eyre::Result<Vec<_>>>()?;
	let capacity = fixed_batch_capacity(
		mutations.len(),
		TURF_ADJACENCY_MUTATION_LEN,
		"turf adjacency batch",
	)?;
	let mut output = Vec::with_capacity(capacity);
	encode_turf_adjacency_batch(&mutations, &mut output)?;
	debug_assert_eq!(output.len(), capacity);
	Ok(output)
}

/// Encodes validated DM numeric fields as protocol bytes for turf heat batch.
///
/// Preserves field order and little-endian word identity; invalid lengths, tags or
/// numeric values return a caller-legible error. This adapter performs no BYOND call.
pub fn encode_production_turf_heat_batch(values: &[f32]) -> eyre::Result<Vec<u8>> {
	validate_fixed_records(
		values,
		PRODUCTION_TURF_HEAT_FIELDS,
		PRODUCTION_MAX_TURF_HEAT_MUTATIONS,
		"turf heat batch",
	)?;
	let mutations = values
		.as_chunks::<PRODUCTION_TURF_HEAT_FIELDS>()
		.0
		.iter()
		.enumerate()
		.map(|(index, entry)| {
			let state_present = indexed(
				exact_bool(entry[2], "state-present flag"),
				"turf heat",
				index,
			)?;
			let adjacent_to_space = indexed(
				exact_bool(entry[6], "adjacent-to-space flag"),
				"turf heat",
				index,
			)?;
			if !state_present
				&& (entry[3] != 0.0 || entry[4] != 0.0 || entry[5] != 0.0 || adjacent_to_space)
			{
				return Err(eyre::eyre!(
					"turf heat entry {index} has state fields while the present flag is false"
				));
			}
			Ok(TurfHeatMutation {
				turf: WireHandle {
					slot: indexed(exact_u32(entry[0], "slot"), "turf heat", index)?,
					generation: indexed(exact_u32(entry[1], "generation"), "turf heat", index)?,
				},
				state: state_present.then_some(TurfHeatState {
					temperature: ScalarValue(f64::from(entry[3])),
					thermal_conductivity: ScalarValue(f64::from(entry[4])),
					heat_capacity: ScalarValue(f64::from(entry[5])),
					adjacent_to_space,
				}),
			})
		})
		.collect::<eyre::Result<Vec<_>>>()?;
	let capacity =
		fixed_batch_capacity(mutations.len(), TURF_HEAT_MUTATION_LEN, "turf heat batch")?;
	let mut output = Vec::with_capacity(capacity);
	encode_turf_heat_batch(&mutations, &mut output)?;
	debug_assert_eq!(output.len(), capacity);
	Ok(output)
}

/// Decodes protocol bytes into exact DM numeric fields for turf heat snapshot.
///
/// Preserves field order and little-endian word identity; invalid lengths, tags or
/// numeric values return a caller-legible error. This adapter performs no BYOND call.
pub fn decode_production_turf_heat_snapshot(response: &[u8]) -> eyre::Result<[f32; 5]> {
	let snapshot = TurfHeatSnapshot::decode(response)?;
	let Some(state) = snapshot.state else {
		return Ok([0.0; 5]);
	};
	Ok([
		1.0,
		finite_byond_scalar(state.temperature.0, "turf heat snapshot temperature")?,
		finite_byond_scalar(
			state.thermal_conductivity.0,
			"turf heat snapshot thermal conductivity",
		)?,
		finite_byond_scalar(state.heat_capacity.0, "turf heat snapshot heat capacity")?,
		f32::from(state.adjacent_to_space),
	])
}

/// Encodes validated DM numeric fields as protocol bytes for turf heat adjacency batch.
///
/// Preserves field order and little-endian word identity; invalid lengths, tags or
/// numeric values return a caller-legible error. This adapter performs no BYOND call.
pub fn encode_production_turf_heat_adjacency_batch(values: &[f32]) -> eyre::Result<Vec<u8>> {
	validate_fixed_records(
		values,
		PRODUCTION_TURF_HEAT_ADJACENCY_FIELDS,
		PRODUCTION_MAX_TURF_HEAT_ADJACENCY_MUTATIONS,
		"turf heat adjacency batch",
	)?;
	let mutations = values
		.as_chunks::<PRODUCTION_TURF_HEAT_ADJACENCY_FIELDS>()
		.0
		.iter()
		.enumerate()
		.map(|(index, entry)| {
			Ok(TurfHeatAdjacencyMutation {
				left: WireHandle {
					slot: indexed(
						exact_u32(entry[0], "left slot"),
						"turf heat adjacency",
						index,
					)?,
					generation: indexed(
						exact_u32(entry[1], "left generation"),
						"turf heat adjacency",
						index,
					)?,
				},
				right: WireHandle {
					slot: indexed(
						exact_u32(entry[2], "right slot"),
						"turf heat adjacency",
						index,
					)?,
					generation: indexed(
						exact_u32(entry[3], "right generation"),
						"turf heat adjacency",
						index,
					)?,
				},
				connected: indexed(
					exact_bool(entry[4], "connected flag"),
					"turf heat adjacency",
					index,
				)?,
			})
		})
		.collect::<eyre::Result<Vec<_>>>()?;
	let capacity = fixed_batch_capacity(
		mutations.len(),
		TURF_HEAT_ADJACENCY_MUTATION_LEN,
		"turf heat adjacency batch",
	)?;
	let mut output = Vec::with_capacity(capacity);
	encode_turf_heat_adjacency_batch(&mutations, &mut output)?;
	debug_assert_eq!(output.len(), capacity);
	Ok(output)
}
