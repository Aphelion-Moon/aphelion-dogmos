//! Main-thread service bindings for stages.

use crate::bindings::production_request_with_response;
use crate::bindings::values::{bounded_number_list, production_number_list};
use crate::dm_codec::stages::{
	decode_production_simulation_stage, encode_production_frontier_append,
	encode_production_frontier_begin, encode_production_frontier_mutate,
	encode_production_simulation_stage,
};
use crate::dm_codec::{
	append_u32_words, append_u64_words, exact_words4, join_u64_words, split_u32_words,
	split_u64_words,
};
use crate::stage_jobs;
use byondapi::prelude::ByondValue;
use dogmos_protocol::{
	FrontierAppendResponse, FrontierBeginResponse, FrontierCommitRequest, FrontierCommitResponse,
	FrontierMutateResponse, OperationKind, MAX_FRONTIER_APPEND_HANDLES,
	SIMULATION_STAGE_RESPONSE_LEN,
};

#[auxmacros::bind("/proc/dogmos_frontier_begin")]
fn dogmos_frontier_begin(fields: ByondValue) -> eyre::Result<ByondValue> {
	let fields = bounded_number_list(fields, "frontier begin", 6)?;
	let request = encode_production_frontier_begin(&fields)?;
	let epoch =
		production_request_with_response(OperationKind::FrontierBegin, &request, 8, |response| {
			Ok(FrontierBeginResponse::decode(response)?.epoch)
		})?;
	let mut output = ByondValue::new_list()?;
	for word in split_u64_words(epoch) {
		output.push_list(f32::from(word).into())?;
	}
	Ok(output)
}

#[auxmacros::bind("/proc/dogmos_frontier_append")]
fn dogmos_frontier_append(records: ByondValue) -> eyre::Result<ByondValue> {
	let records = bounded_number_list(
		records,
		"frontier append",
		6 + MAX_FRONTIER_APPEND_HANDLES * 4,
	)?;
	let request = encode_production_frontier_append(&records)?;
	let accepted =
		production_request_with_response(OperationKind::FrontierAppend, &request, 4, |response| {
			Ok(FrontierAppendResponse::decode(response)?.accepted_count)
		})?;
	let mut output = ByondValue::new_list()?;
	for word in split_u32_words(accepted) {
		output.push_list(f32::from(word).into())?;
	}
	Ok(output)
}

#[auxmacros::bind("/proc/dogmos_frontier_add")]
fn dogmos_frontier_add(records: ByondValue) -> eyre::Result<ByondValue> {
	let records =
		bounded_number_list(records, "frontier add", 4 + MAX_FRONTIER_APPEND_HANDLES * 4)?;
	let request = encode_production_frontier_mutate(&records, "frontier add")?;
	let count =
		production_request_with_response(OperationKind::FrontierAdd, &request, 4, |response| {
			Ok(FrontierMutateResponse::decode(response)?.count)
		})?;
	let mut output = ByondValue::new_list()?;
	for word in split_u32_words(count) {
		output.push_list(f32::from(word).into())?;
	}
	Ok(output)
}

#[auxmacros::bind("/proc/dogmos_frontier_remove")]
fn dogmos_frontier_remove(records: ByondValue) -> eyre::Result<ByondValue> {
	let records = bounded_number_list(
		records,
		"frontier remove",
		4 + MAX_FRONTIER_APPEND_HANDLES * 4,
	)?;
	let request = encode_production_frontier_mutate(&records, "frontier remove")?;
	let count =
		production_request_with_response(OperationKind::FrontierRemove, &request, 4, |response| {
			Ok(FrontierMutateResponse::decode(response)?.count)
		})?;
	let mut output = ByondValue::new_list()?;
	for word in split_u32_words(count) {
		output.push_list(f32::from(word).into())?;
	}
	Ok(output)
}

#[auxmacros::bind("/proc/dogmos_frontier_commit")]
fn dogmos_frontier_commit(fields: ByondValue) -> eyre::Result<ByondValue> {
	let fields = bounded_number_list(fields, "frontier commit", 4)?;
	if fields.len() != 4 {
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
	let mut output_fields = Vec::with_capacity(6);
	append_u64_words(&mut output_fields, response.epoch);
	append_u32_words(&mut output_fields, response.count);
	let mut output = ByondValue::new_list()?;
	for field in output_fields {
		output.push_list(field.into())?;
	}
	Ok(output)
}

#[auxmacros::bind("/proc/dogmos_simulation_stage")]
fn dogmos_simulation_stage(fields: ByondValue) -> eyre::Result<ByondValue> {
	let fields = bounded_number_list(fields, "simulation stage", 12)?;
	if fields.len() != 12 {
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
