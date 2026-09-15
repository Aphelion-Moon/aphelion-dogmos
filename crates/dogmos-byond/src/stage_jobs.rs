//! Fixed-size conversion between exact DM words and stage job control frames.

use crate::dm_codec::{exact_u16, exact_u32, exact_words4, join_u32_words, join_u64_words};
use dogmos_protocol::{
	OperationKind, ScalarValue, SimulationStage, StageJobCancel, StageJobCommit, StageJobPoll,
	StageJobResponse, StageJobStatus, StageJobSubmit, STAGE_JOB_CANCEL_LEN, STAGE_JOB_COMMIT_LEN,
	STAGE_JOB_POLL_LEN, STAGE_JOB_SUBMIT_LEN,
};

pub fn encode_submit(
	fields: [f32; crate::adapter_layout::stages::job_submit::LEN],
) -> eyre::Result<[u8; STAGE_JOB_SUBMIT_LEN]> {
	use crate::adapter_layout::stages::job_submit as fields_layout;

	Ok(StageJobSubmit {
		stage: SimulationStage::try_from(exact_u32(
			fields[fields_layout::STAGE.offset],
			"stage job stage",
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
		quantum_us: exact_u32(
			fields[fields_layout::QUANTUM_US.offset],
			"stage quantum microseconds",
		)?,
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

pub fn encode_poll(
	fields: [f32; crate::adapter_layout::stages::job_identity::LEN],
) -> eyre::Result<[u8; STAGE_JOB_POLL_LEN]> {
	Ok(StageJobPoll {
		job: identity(
			&fields[crate::adapter_layout::stages::job_identity::JOB.range()],
			"stage job",
		)?,
	}
	.encode())
}

pub fn encode_commit(
	fields: [f32; crate::adapter_layout::stages::job_commit::LEN],
) -> eyre::Result<[u8; STAGE_JOB_COMMIT_LEN]> {
	use crate::adapter_layout::stages::job_commit as fields_layout;

	Ok(StageJobCommit {
		job: identity(&fields[fields_layout::JOB.range()], "stage job")?,
		unit: identity(
			&fields[fields_layout::UNIT.range()],
			"stage publication unit",
		)?,
	}
	.encode())
}

pub fn encode_cancel(
	fields: [f32; crate::adapter_layout::stages::job_identity::LEN],
) -> eyre::Result<[u8; STAGE_JOB_CANCEL_LEN]> {
	Ok(StageJobCancel {
		job: identity(
			&fields[crate::adapter_layout::stages::job_identity::JOB.range()],
			"stage job",
		)?,
	}
	.encode())
}

pub fn decode_response(
	bytes: &[u8],
) -> eyre::Result<[f32; crate::adapter_layout::stages::job_response::LEN]> {
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
	use crate::adapter_layout::stages::job_response as layout;
	let mut fields = [0.0; layout::LEN];
	layout::JOB.write_u64(&mut fields, response.job);
	fields[layout::STATUS.offset] = response.status as u32 as f32;
	fields[layout::STAGE.offset] = response.stage as u32 as f32;
	layout::UNIT.write_u64(&mut fields, response.unit);
	layout::WORK_ITEMS.write_u32(&mut fields, response.work_items);
	layout::REMAINING.write_u32(&mut fields, response.remaining_estimate);
	layout::COMMITTED_UNITS.write_u64(&mut fields, response.committed_units);
	layout::EQUALIZE_SEEDS.write_u32(&mut fields, response.produced_equalize_seeds);
	layout::GROUP_SEEDS.write_u32(&mut fields, response.produced_group_seeds);
	layout::HEAT_SEEDS.write_u32(&mut fields, response.produced_heat_seeds);
	layout::CALLBACK_EVENTS.write_u32(&mut fields, response.callback_events);
	Ok(fields)
}

pub fn decode_response_to(
	operation: OperationKind,
	request: &[u8],
	bytes: &[u8],
) -> eyre::Result<[f32; crate::adapter_layout::stages::job_response::LEN]> {
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
