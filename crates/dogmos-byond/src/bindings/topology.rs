//! Main-thread service bindings for topology.

use crate::bindings::values::{bounded_number_list, production_number_list};
use crate::bindings::{production_counted_request, production_request_with_response};
use crate::dm_codec::topology::{
	decode_production_turf_heat_snapshot, encode_production_turf_adjacency_batch,
	encode_production_turf_heat_adjacency_batch, encode_production_turf_heat_batch,
	encode_production_turf_lifecycle_batch,
};
use crate::dm_codec::{
	exact_u32, PRODUCTION_MAX_TURF_ADJACENCY_MUTATIONS,
	PRODUCTION_MAX_TURF_HEAT_ADJACENCY_MUTATIONS, PRODUCTION_MAX_TURF_HEAT_MUTATIONS,
	PRODUCTION_MAX_TURF_LIFECYCLE_MUTATIONS, PRODUCTION_TURF_ADJACENCY_FIELDS,
	PRODUCTION_TURF_HEAT_ADJACENCY_FIELDS, PRODUCTION_TURF_HEAT_FIELDS,
	PRODUCTION_TURF_LIFECYCLE_FIELDS,
};
use byondapi::prelude::ByondValue;
use dogmos_protocol::{OperationKind, TurfHeatSnapshotRequest, WireHandle, TURF_HEAT_SNAPSHOT_LEN};

#[auxmacros::bind("/proc/dogmos_turf_lifecycle_batch")]
fn dogmos_turf_lifecycle_batch(entries: ByondValue) -> eyre::Result<ByondValue> {
	let values = bounded_number_list(
		entries,
		"turf lifecycle batch",
		PRODUCTION_MAX_TURF_LIFECYCLE_MUTATIONS * PRODUCTION_TURF_LIFECYCLE_FIELDS,
	)?;
	let request = encode_production_turf_lifecycle_batch(&values)?;
	production_counted_request(
		OperationKind::TurfLifecycleBatch,
		&request,
		"turf lifecycle",
	)
}

#[auxmacros::bind("/proc/dogmos_turf_adjacency_batch")]
fn dogmos_turf_adjacency_batch(entries: ByondValue) -> eyre::Result<ByondValue> {
	let values = bounded_number_list(
		entries,
		"turf adjacency batch",
		PRODUCTION_MAX_TURF_ADJACENCY_MUTATIONS * PRODUCTION_TURF_ADJACENCY_FIELDS,
	)?;
	let request = encode_production_turf_adjacency_batch(&values)?;
	production_counted_request(
		OperationKind::TurfAdjacencyBatch,
		&request,
		"turf adjacency",
	)
}

#[auxmacros::bind("/proc/dogmos_turf_heat_batch")]
fn dogmos_turf_heat_batch(entries: ByondValue) -> eyre::Result<ByondValue> {
	let values = bounded_number_list(
		entries,
		"turf heat batch",
		PRODUCTION_MAX_TURF_HEAT_MUTATIONS * PRODUCTION_TURF_HEAT_FIELDS,
	)?;
	let request = encode_production_turf_heat_batch(&values)?;
	production_counted_request(OperationKind::TurfHeatBatch, &request, "turf heat")
}

#[auxmacros::bind("/proc/dogmos_turf_heat_snapshot")]
fn dogmos_turf_heat_snapshot(fields: ByondValue) -> eyre::Result<ByondValue> {
	let fields = bounded_number_list(fields, "turf heat snapshot", 2)?;
	if fields.len() != 2 {
		return Err(eyre::eyre!(
			"turf heat snapshot requires exactly slot and generation"
		));
	}
	let request = TurfHeatSnapshotRequest {
		turf: WireHandle {
			slot: exact_u32(fields[0], "turf heat snapshot slot")?,
			generation: exact_u32(fields[1], "turf heat snapshot generation")?,
		},
	}
	.encode();
	let fields = production_request_with_response(
		OperationKind::TurfHeatSnapshot,
		&request,
		TURF_HEAT_SNAPSHOT_LEN,
		decode_production_turf_heat_snapshot,
	)?;
	production_number_list(&fields)
}

#[auxmacros::bind("/proc/dogmos_turf_heat_adjacency_batch")]
fn dogmos_turf_heat_adjacency_batch(entries: ByondValue) -> eyre::Result<ByondValue> {
	let values = bounded_number_list(
		entries,
		"turf heat adjacency batch",
		PRODUCTION_MAX_TURF_HEAT_ADJACENCY_MUTATIONS * PRODUCTION_TURF_HEAT_ADJACENCY_FIELDS,
	)?;
	let request = encode_production_turf_heat_adjacency_batch(&values)?;
	production_counted_request(
		OperationKind::TurfHeatAdjacencyBatch,
		&request,
		"turf heat adjacency",
	)
}
