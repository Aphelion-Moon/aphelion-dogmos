//! Main-thread service bindings for mixtures.

use crate::bindings::values::{
	bounded_number_list, mixture_command_response_value, production_number_list,
};
use crate::bindings::{production_request_with_response, SERVICE_SESSION};
use crate::dm_codec::mixtures::{
	decode_production_mixture_snapshot, decode_production_mixture_snapshot_batch,
	decode_production_pipenet_reconcile, encode_production_mixture_adjust_multiple,
	encode_production_mixture_command, encode_production_mixture_lifecycle_batch,
	encode_production_mixture_snapshot_batch, encode_production_mixture_state_batch,
	encode_production_pipenet_reconcile, production_mixture_state_mutations,
};
use crate::dm_codec::{
	decode_counted_response, exact_u32, PRODUCTION_MAX_BATCH_OPERATIONS,
	PRODUCTION_MAX_MIXTURE_ADJUSTMENTS, PRODUCTION_MAX_MIXTURE_SNAPSHOT_BATCH,
	PRODUCTION_MAX_MIXTURE_STATE_MUTATIONS, PRODUCTION_MAX_PIPENET_RECONCILE_MIXTURES,
	PRODUCTION_MIXTURE_STATE_FIELDS,
};
use crate::session_limits::SESSION_REQUEST_TIMEOUT;
use byondapi::prelude::ByondValue;
use dogmos_protocol::{
	MixtureCommandResponse, MixtureSnapshotRequest, MixtureStateUploadAbortRequest,
	MixtureStateUploadAppendRequest, MixtureStateUploadAppendResponse,
	MixtureStateUploadBeginRequest, MixtureStateUploadBeginResponse,
	MixtureStateUploadCommitRequest, MixtureStateUploadCommitResponse, OperationKind, WireHandle,
	MIXTURE_COMMAND_RESPONSE_LEN, MIXTURE_SNAPSHOT_LEN, MIXTURE_SNAPSHOT_RECORD_LEN,
	PIPENET_RECONCILE_SNAPSHOT_LEN,
};
use std::time::{Duration, Instant};

#[auxmacros::bind("/proc/dogmos_mixture_command")]
fn dogmos_mixture_command(fields: ByondValue) -> eyre::Result<ByondValue> {
	let fields = bounded_number_list(fields, "mixture command", 11)?;
	if fields.len() != 11 {
		return Err(eyre::eyre!(
			"mixture command requires exactly 11 numeric fields"
		));
	}
	let request = encode_production_mixture_command(fields.try_into().unwrap())?;
	let response = production_request_with_response(
		OperationKind::MixtureCommand,
		&request,
		MIXTURE_COMMAND_RESPONSE_LEN,
		|response| {
			if response.len() != MIXTURE_COMMAND_RESPONSE_LEN {
				return Err(eyre::eyre!(
					"Dogmos mixture command response was {} bytes, expected {MIXTURE_COMMAND_RESPONSE_LEN}",
					response.len()
				));
			}
			Ok(MixtureCommandResponse::decode(response)?)
		},
	)?;
	mixture_command_response_value(response)
}

#[auxmacros::bind("/proc/dogmos_mixture_adjust_multiple")]
fn dogmos_mixture_adjust_multiple(fields: ByondValue) -> eyre::Result<ByondValue> {
	let fields = bounded_number_list(
		fields,
		"mixture multi-adjust command",
		2 + PRODUCTION_MAX_MIXTURE_ADJUSTMENTS * 2,
	)?;
	let request = encode_production_mixture_adjust_multiple(&fields)?;
	let response = production_request_with_response(
		OperationKind::MixtureAdjustMultiple,
		&request,
		MIXTURE_COMMAND_RESPONSE_LEN,
		|response| {
			if response.len() != MIXTURE_COMMAND_RESPONSE_LEN {
				return Err(eyre::eyre!(
					"Dogmos mixture multi-adjust response was {} bytes, expected {MIXTURE_COMMAND_RESPONSE_LEN}",
					response.len()
				));
			}
			Ok(MixtureCommandResponse::decode(response)?)
		},
	)?;
	mixture_command_response_value(response)
}

#[auxmacros::bind("/proc/dogmos_mixture_lifecycle_batch")]
fn dogmos_mixture_lifecycle_batch(entries: ByondValue) -> eyre::Result<ByondValue> {
	let values = bounded_number_list(
		entries,
		"mixture lifecycle batch",
		PRODUCTION_MAX_BATCH_OPERATIONS * 3,
	)?;
	let request = encode_production_mixture_lifecycle_batch(&values)?;
	let count = production_request_with_response(
		OperationKind::MixtureLifecycleBatch,
		&request,
		4,
		|response| decode_counted_response(response, "mixture lifecycle"),
	)?;
	Ok((count as f32).into())
}

#[auxmacros::bind("/proc/dogmos_mixture_snapshot")]
fn dogmos_mixture_snapshot(fields: ByondValue) -> eyre::Result<ByondValue> {
	let fields = bounded_number_list(fields, "mixture snapshot", 2)?;
	if fields.len() != 2 {
		return Err(eyre::eyre!(
			"mixture snapshot requires exactly slot and generation"
		));
	}
	let request = MixtureSnapshotRequest {
		handle: WireHandle {
			slot: exact_u32(fields[0], "mixture snapshot slot")?,
			generation: exact_u32(fields[1], "mixture snapshot generation")?,
		},
	}
	.encode();
	let fields = production_request_with_response(
		OperationKind::MixtureSnapshot,
		&request,
		MIXTURE_SNAPSHOT_LEN,
		decode_production_mixture_snapshot,
	)?;
	production_number_list(&fields)
}

#[auxmacros::bind("/proc/dogmos_pipenet_reconcile")]
fn dogmos_pipenet_reconcile(entries: ByondValue) -> eyre::Result<ByondValue> {
	let values = bounded_number_list(
		entries,
		"pipenet reconcile",
		PRODUCTION_MAX_PIPENET_RECONCILE_MIXTURES * 2,
	)?;
	let operation_count = values.len() / 2;
	let request = encode_production_pipenet_reconcile(&values)?;
	let response_capacity = 4 + operation_count * PIPENET_RECONCILE_SNAPSHOT_LEN;
	let fields = production_request_with_response(
		OperationKind::PipenetReconcile,
		&request,
		response_capacity,
		decode_production_pipenet_reconcile,
	)?;
	production_number_list(&fields)
}

#[auxmacros::bind("/proc/dogmos_mixture_snapshot_batch")]
fn dogmos_mixture_snapshot_batch(entries: ByondValue) -> eyre::Result<ByondValue> {
	let values = bounded_number_list(
		entries,
		"mixture snapshot batch",
		PRODUCTION_MAX_MIXTURE_SNAPSHOT_BATCH * 2,
	)?;
	let operation_count = values.len() / 2;
	let request = encode_production_mixture_snapshot_batch(&values)?;
	let response_capacity = 4 + operation_count * MIXTURE_SNAPSHOT_RECORD_LEN;
	let fields = production_request_with_response(
		OperationKind::MixtureSnapshotBatch,
		&request,
		response_capacity,
		decode_production_mixture_snapshot_batch,
	)?;
	production_number_list(&fields)
}

#[auxmacros::bind("/proc/dogmos_mixture_state_batch")]
fn dogmos_mixture_state_batch(entries: ByondValue) -> eyre::Result<ByondValue> {
	let values = bounded_number_list(
		entries,
		"mixture state batch",
		PRODUCTION_MAX_BATCH_OPERATIONS * PRODUCTION_MIXTURE_STATE_FIELDS,
	)?;
	let operation_count = values.len() / PRODUCTION_MIXTURE_STATE_FIELDS;
	if operation_count > PRODUCTION_MAX_MIXTURE_STATE_MUTATIONS {
		let count = production_mixture_state_upload(&values)?;
		return Ok((count as f32).into());
	}
	let request = encode_production_mixture_state_batch(&values)?;
	let count = production_request_with_response(
		OperationKind::MixtureStateBatch,
		&request,
		4,
		|response| decode_counted_response(response, "mixture state"),
	)?;
	Ok((count as f32).into())
}

pub(crate) fn production_mixture_state_upload(values: &[f32]) -> eyre::Result<u32> {
	if !values.len().is_multiple_of(PRODUCTION_MIXTURE_STATE_FIELDS) {
		return Err(eyre::eyre!(
			"mixture state batch requires fixed {PRODUCTION_MIXTURE_STATE_FIELDS}-field records"
		));
	}
	let operation_count = values.len() / PRODUCTION_MIXTURE_STATE_FIELDS;
	if operation_count == 0 || operation_count > PRODUCTION_MAX_BATCH_OPERATIONS {
		return Err(eyre::eyre!(
			"mixture state upload contains {operation_count} operations, maximum {PRODUCTION_MAX_BATCH_OPERATIONS}"
		));
	}
	let chunk_field_count =
		PRODUCTION_MAX_MIXTURE_STATE_MUTATIONS * PRODUCTION_MIXTURE_STATE_FIELDS;
	for chunk in values.chunks(chunk_field_count) {
		drop(production_mixture_state_mutations(chunk)?);
	}

	let mut session = SERVICE_SESSION
		.lock()
		.map_err(|_| eyre::eyre!("Dogmos production service session lock is poisoned"))?;
	let session = session
		.as_mut()
		.ok_or_else(|| eyre::eyre!("Dogmos production service session is not running"))?;
	let deadline = Instant::now()
		.checked_add(SESSION_REQUEST_TIMEOUT)
		.ok_or_else(|| eyre::eyre!("Dogmos mixture state upload deadline overflowed"))?;
	let begin = MixtureStateUploadBeginRequest {
		expected_count: operation_count as u32,
	}
	.encode()?;
	let upload_id = session.request_with_response_timeout(
		OperationKind::MixtureStateUploadBegin,
		&begin,
		8,
		remaining_upload_timeout(deadline)?,
		|response| -> eyre::Result<u64> {
			Ok(MixtureStateUploadBeginResponse::decode(response)?.upload_id)
		},
	)?;

	let upload_result = (|| {
		let mut offset = 0_u32;
		for chunk in values.chunks(chunk_field_count) {
			let mutations = production_mixture_state_mutations(chunk)?;
			let request = MixtureStateUploadAppendRequest {
				upload_id,
				offset,
				mutations,
			}
			.encode()?;
			let accepted_count = session.request_with_response_timeout(
				OperationKind::MixtureStateUploadAppend,
				&request,
				4,
				remaining_upload_timeout(deadline)?,
				|response| -> eyre::Result<u32> {
					Ok(MixtureStateUploadAppendResponse::decode(response)?.accepted_count)
				},
			)?;
			let expected_count = (chunk.len() / PRODUCTION_MIXTURE_STATE_FIELDS) as u32;
			if accepted_count != expected_count {
				return Err(eyre::eyre!(
					"Dogmos mixture state upload accepted {accepted_count} operations at offset {offset}, expected {expected_count}"
				));
			}
			offset = offset
				.checked_add(accepted_count)
				.ok_or_else(|| eyre::eyre!("Dogmos mixture state upload offset overflowed"))?;
		}
		let commit = MixtureStateUploadCommitRequest { upload_id }.encode();
		let committed_count = session.request_with_response_timeout(
			OperationKind::MixtureStateUploadCommit,
			&commit,
			4,
			remaining_upload_timeout(deadline)?,
			|response| -> eyre::Result<u32> {
				Ok(MixtureStateUploadCommitResponse::decode(response)?.committed_count)
			},
		)?;
		if committed_count != operation_count as u32 {
			return Err(eyre::eyre!(
				"Dogmos mixture state upload committed {committed_count} operations, expected {operation_count}"
			));
		}
		Ok(committed_count)
	})();
	if upload_result.is_err() {
		if let Ok(timeout) = remaining_upload_timeout(deadline) {
			let abort = MixtureStateUploadAbortRequest { upload_id }.encode();
			let _ = session.request_with_response_timeout(
				OperationKind::MixtureStateUploadAbort,
				&abort,
				0,
				timeout,
				|_| Ok::<(), eyre::Report>(()),
			);
		}
	}
	upload_result
}

pub(crate) fn remaining_upload_timeout(deadline: Instant) -> eyre::Result<Duration> {
	let remaining = deadline.saturating_duration_since(Instant::now());
	if remaining.is_zero() {
		return Err(eyre::eyre!("Dogmos mixture state upload deadline elapsed"));
	}
	Ok(remaining)
}
