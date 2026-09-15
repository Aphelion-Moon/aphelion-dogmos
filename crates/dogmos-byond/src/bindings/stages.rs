//! Main-thread service bindings for stages.

use crate::adapter_layout::{mixtures::word_handle, stages as layout};
use crate::bindings::production_request_with_response;
use crate::bindings::values::{bounded_number_list, production_number_list};
use crate::dm_codec::stages::{
	decode_production_simulation_stage, encode_production_frontier_append,
	encode_production_frontier_begin, encode_production_frontier_mutate,
	encode_production_simulation_stage,
};
use crate::dm_codec::{exact_words4, join_u64_words};
use crate::stage_jobs;
use byondapi::prelude::ByondValue;
use dogmos_protocol::{
	FrontierAppendResponse, FrontierBeginResponse, FrontierCommitRequest, FrontierCommitResponse,
	FrontierMutateResponse, OperationKind, MAX_FRONTIER_APPEND_HANDLES,
	SIMULATION_STAGE_RESPONSE_LEN,
};

#[auxmacros::bind("/proc/dogmos_frontier_begin")]
fn dogmos_frontier_begin(fields: ByondValue) -> eyre::Result<ByondValue> {
	let fields = bounded_number_list(fields, "frontier begin", layout::frontier_begin::LEN)?;
	let request = encode_production_frontier_begin(&fields)?;
	let epoch =
		production_request_with_response(OperationKind::FrontierBegin, &request, 8, |response| {
			Ok(FrontierBeginResponse::decode(response)?.epoch)
		})?;
	let mut output = ByondValue::new_list()?;
	let mut epoch_fields = [0.0; layout::epoch::LEN];
	layout::epoch::EPOCH.write_u64(&mut epoch_fields, epoch);
	for word in epoch_fields {
		output.push_list(word.into())?;
	}
	Ok(output)
}

#[auxmacros::bind("/proc/dogmos_frontier_append")]
fn dogmos_frontier_append(records: ByondValue) -> eyre::Result<ByondValue> {
	let records = bounded_number_list(
		records,
		"frontier append",
		layout::frontier_append_header::LEN + MAX_FRONTIER_APPEND_HANDLES * word_handle::LEN,
	)?;
	let request = encode_production_frontier_append(&records)?;
	let accepted =
		production_request_with_response(OperationKind::FrontierAppend, &request, 4, |response| {
			Ok(FrontierAppendResponse::decode(response)?.accepted_count)
		})?;
	let mut output = ByondValue::new_list()?;
	let mut count_fields = [0.0; layout::word_count::LEN];
	layout::word_count::COUNT.write_u32(&mut count_fields, accepted);
	for word in count_fields {
		output.push_list(word.into())?;
	}
	Ok(output)
}

#[auxmacros::bind("/proc/dogmos_frontier_add")]
fn dogmos_frontier_add(records: ByondValue) -> eyre::Result<ByondValue> {
	let records = bounded_number_list(
		records,
		"frontier add",
		layout::epoch::LEN + MAX_FRONTIER_APPEND_HANDLES * word_handle::LEN,
	)?;
	let request = encode_production_frontier_mutate(&records, "frontier add")?;
	let count =
		production_request_with_response(OperationKind::FrontierAdd, &request, 4, |response| {
			Ok(FrontierMutateResponse::decode(response)?.count)
		})?;
	let mut output = ByondValue::new_list()?;
	let mut count_fields = [0.0; layout::word_count::LEN];
	layout::word_count::COUNT.write_u32(&mut count_fields, count);
	for word in count_fields {
		output.push_list(word.into())?;
	}
	Ok(output)
}

#[auxmacros::bind("/proc/dogmos_frontier_remove")]
fn dogmos_frontier_remove(records: ByondValue) -> eyre::Result<ByondValue> {
	let records = bounded_number_list(
		records,
		"frontier remove",
		layout::epoch::LEN + MAX_FRONTIER_APPEND_HANDLES * word_handle::LEN,
	)?;
	let request = encode_production_frontier_mutate(&records, "frontier remove")?;
	let count =
		production_request_with_response(OperationKind::FrontierRemove, &request, 4, |response| {
			Ok(FrontierMutateResponse::decode(response)?.count)
		})?;
	let mut output = ByondValue::new_list()?;
	let mut count_fields = [0.0; layout::word_count::LEN];
	layout::word_count::COUNT.write_u32(&mut count_fields, count);
	for word in count_fields {
		output.push_list(word.into())?;
	}
	Ok(output)
}

#[auxmacros::bind("/proc/dogmos_frontier_commit")]
fn dogmos_frontier_commit(fields: ByondValue) -> eyre::Result<ByondValue> {
	let fields = bounded_number_list(fields, "frontier commit", layout::epoch::LEN)?;
	if fields.len() != layout::epoch::LEN {
		return Err(eyre::eyre!("frontier commit requires four epoch words"));
	}
	let request = FrontierCommitRequest {
		epoch: join_u64_words(exact_words4(&fields, "frontier epoch")?),
	}
	.encode();
	let response = production_request_with_response(
		OperationKind::FrontierCommit,
		&request,
		16,
		|response| Ok(FrontierCommitResponse::decode(response)?),
	)?;
	let mut output_fields = [0.0; layout::frontier_commit_response::LEN];
	layout::frontier_commit_response::EPOCH.write_u64(&mut output_fields, response.epoch);
	layout::frontier_commit_response::COUNT.write_u32(&mut output_fields, response.count);
	let mut output = ByondValue::new_list()?;
	for field in output_fields {
		output.push_list(field.into())?;
	}
	Ok(output)
}

#[auxmacros::bind("/proc/dogmos_simulation_stage")]
fn dogmos_simulation_stage(fields: ByondValue) -> eyre::Result<ByondValue> {
	let fields = bounded_number_list(fields, "simulation stage", layout::stage_request::LEN)?;
	if fields.len() != layout::stage_request::LEN {
		return Err(eyre::eyre!(
			"simulation stage requires stage, frontier epoch, stage epoch, work limit, and seconds-per-tick"
		));
	}
	let request = encode_production_simulation_stage(fields.try_into().unwrap())?;
	let fields = production_request_with_response(
		OperationKind::SimulationStage,
		&request,
		SIMULATION_STAGE_RESPONSE_LEN,
		decode_production_simulation_stage,
	)?;
	production_number_list(&fields)
}

#[auxmacros::bind("/proc/dogmos_stage_job_submit")]
fn dogmos_stage_job_submit(fields: ByondValue) -> eyre::Result<ByondValue> {
	production_stage_job_control(
		OperationKind::StageJobSubmit,
		fields,
		stage_jobs::encode_submit,
	)
}

#[auxmacros::bind("/proc/dogmos_stage_job_poll")]
fn dogmos_stage_job_poll(fields: ByondValue) -> eyre::Result<ByondValue> {
	production_stage_job_control(OperationKind::StageJobPoll, fields, stage_jobs::encode_poll)
}

#[auxmacros::bind("/proc/dogmos_stage_job_commit")]
fn dogmos_stage_job_commit(fields: ByondValue) -> eyre::Result<ByondValue> {
	production_stage_job_control(
		OperationKind::StageJobCommit,
		fields,
		stage_jobs::encode_commit,
	)
}

#[auxmacros::bind("/proc/dogmos_stage_job_cancel")]
fn dogmos_stage_job_cancel(fields: ByondValue) -> eyre::Result<ByondValue> {
	production_stage_job_control(
		OperationKind::StageJobCancel,
		fields,
		stage_jobs::encode_cancel,
	)
}

pub(crate) fn production_stage_job_control<const FIELDS: usize, const BYTES: usize>(
	operation: OperationKind,
	fields: ByondValue,
	encode: impl FnOnce([f32; FIELDS]) -> eyre::Result<[u8; BYTES]>,
) -> eyre::Result<ByondValue> {
	let fields = bounded_number_list(fields, "stage job control", FIELDS)?;
	let fields = fields
		.try_into()
		.map_err(|_| eyre::eyre!("{operation:?} requires exactly {FIELDS} numeric fields"))?;
	let request = encode(fields)?;
	let response = production_request_with_response(
		operation,
		&request,
		dogmos_protocol::STAGE_JOB_RESPONSE_LEN,
		|bytes| stage_jobs::decode_response_to(operation, &request, bytes),
	)?;
	production_number_list(&response)
}
