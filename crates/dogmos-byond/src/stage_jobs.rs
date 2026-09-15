//! Fixed-size conversion between exact DM words and stage job control frames.

use super::{
	exact_u16, exact_u32, exact_words4, join_u32_words, join_u64_words, split_u32_words,
	split_u64_words,
};
use dogmos_protocol::{
	OperationKind, ScalarValue, SimulationStage, StageJobCancel, StageJobCommit, StageJobPoll,
	StageJobResponse, StageJobStatus, StageJobSubmit, STAGE_JOB_CANCEL_LEN, STAGE_JOB_COMMIT_LEN,
	STAGE_JOB_POLL_LEN, STAGE_JOB_SUBMIT_LEN,
};

pub fn encode_submit(fields: [f32; 13]) -> eyre::Result<[u8; STAGE_JOB_SUBMIT_LEN]> {
	Ok(StageJobSubmit {
		stage: SimulationStage::try_from(exact_u32(fields[0], "stage job stage")?)?,
		frontier_epoch: join_u64_words(exact_words4(&fields[1..5], "frontier epoch")?),
		stage_epoch: join_u64_words(exact_words4(&fields[5..9], "stage epoch")?),
		work_limit: join_u32_words(
			exact_u16(fields[9], "stage work-limit word 0")?,
			exact_u16(fields[10], "stage work-limit word 1")?,
		),
		seconds_per_tick: ScalarValue(f64::from(fields[11])),
		quantum_us: exact_u32(fields[12], "stage quantum microseconds")?,
	}
	.encode()?)
}

fn identity(words: &[f32], label: &str) -> eyre::Result<u64> {
	let value = join_u64_words(exact_words4(words, label)?);
	if value == 0 {
		return Err(eyre::eyre!("{label} must be nonzero"));
	}
	Ok(value)
}

pub fn encode_poll(fields: [f32; 4]) -> eyre::Result<[u8; STAGE_JOB_POLL_LEN]> {
	Ok(StageJobPoll {
		job: identity(&fields, "stage job")?,
	}
	.encode())
}

pub fn encode_commit(fields: [f32; 8]) -> eyre::Result<[u8; STAGE_JOB_COMMIT_LEN]> {
	Ok(StageJobCommit {
		job: identity(&fields[..4], "stage job")?,
		unit: identity(&fields[4..], "stage publication unit")?,
	}
	.encode())
}

pub fn encode_cancel(fields: [f32; 4]) -> eyre::Result<[u8; STAGE_JOB_CANCEL_LEN]> {
	Ok(StageJobCancel {
		job: identity(&fields, "stage job")?,
	}
	.encode())
}

pub fn decode_response(bytes: &[u8]) -> eyre::Result<[f32; 26]> {
	let response = StageJobResponse::decode(bytes)?;
	let published_counts = response.produced_equalize_seeds != 0
		|| response.produced_group_seeds != 0
		|| response.produced_heat_seeds != 0
		|| response.callback_events != 0;
	if response.committed_units == 0
		&& (published_counts || (response.unit != 0 && response.status != StageJobStatus::Ready))
		|| response.committed_units != 0 && response.unit == 0
	{
		return Err(eyre::eyre!(
			"stage job response has inconsistent publication ownership"
		));
	}
	if response.status == StageJobStatus::Accepted
		&& (response.work_items != 0
			|| response.remaining_estimate != 0
			|| response.committed_units != 0
			|| response.unit != 0)
	{
		return Err(eyre::eyre!(
			"stage admission response already contains work or publication"
		));
	}
	let mut fields = [0.0; 26];
	fields[..4].copy_from_slice(&split_u64_words(response.job).map(f32::from));
	fields[4] = f32::from(response.status as u16);
	fields[5] = response.stage as u32 as f32;
	fields[6..10].copy_from_slice(&split_u64_words(response.unit).map(f32::from));
	fields[10..12].copy_from_slice(&split_u32_words(response.work_items).map(f32::from));
	fields[12..14].copy_from_slice(&split_u32_words(response.remaining_estimate).map(f32::from));
	fields[14..18].copy_from_slice(&split_u64_words(response.committed_units).map(f32::from));
	for (chunk, count) in fields[18..].as_chunks_mut::<2>().0.iter_mut().zip([
		response.produced_equalize_seeds,
		response.produced_group_seeds,
		response.produced_heat_seeds,
		response.callback_events,
	]) {
		chunk.copy_from_slice(&split_u32_words(count).map(f32::from));
	}
	Ok(fields)
}

pub fn decode_response_to(
	operation: OperationKind,
	request: &[u8],
	bytes: &[u8],
) -> eyre::Result<[f32; 26]> {
	let response = StageJobResponse::decode(bytes)?;
	let matches = match operation {
		OperationKind::StageJobSubmit => {
			let request = StageJobSubmit::decode(request)?;
			response.status == StageJobStatus::Accepted && response.stage == request.stage
		}
		OperationKind::StageJobPoll => response.job == StageJobPoll::decode(request)?.job,
		OperationKind::StageJobCancel => {
			response.job == StageJobCancel::decode(request)?.job
				&& matches!(
					response.status,
					StageJobStatus::Done | StageJobStatus::Cancelled
				)
		}
		OperationKind::StageJobCommit => {
			let request = StageJobCommit::decode(request)?;
			response.job == request.job
				&& match response.status {
					StageJobStatus::Retrying => response.unit != request.unit,
					StageJobStatus::Running | StageJobStatus::Done => {
						response.unit == request.unit && response.committed_units != 0
					}
					_ => false,
				}
		}
		_ => false,
	};
	if !matches {
		return Err(eyre::eyre!(
			"stage job response does not match its control request"
		));
	}
	decode_response(bytes)
}
