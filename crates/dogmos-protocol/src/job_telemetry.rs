//! Bounded job observations. Counters are cumulative; age belongs to the latest job.

use crate::{read_u16, read_u32, read_u64, require_exact_len, ProtocolError, StageJobStatus};

pub const STAGE_JOB_TELEMETRY_LEN: usize = 112;

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct StageJobTelemetry {
	pub job: u64,
	/// Zero means no admitted job; otherwise the StageJobStatus wire value.
	pub status: u16,
	pub age_nanoseconds: u64,
	pub prepare_calls: u64,
	pub prepare_total_nanoseconds: u64,
	pub prepare_max_nanoseconds: u64,
	pub prepare_last_nanoseconds: u64,
	pub commit_calls: u64,
	pub commit_total_nanoseconds: u64,
	pub commit_max_nanoseconds: u64,
	pub commit_last_nanoseconds: u64,
	/// Includes every unpublished commit retry, not only revision conflicts.
	pub publication_retries: u64,
	pub completed_jobs: u64,
	pub cancelled_jobs: u64,
}

impl StageJobTelemetry {
	/// Fixed wire order, also consumed by the exact-word BYOND adapter.
	pub fn counters(self) -> [u64; 12] {
		[
			self.age_nanoseconds,
			self.prepare_calls,
			self.prepare_total_nanoseconds,
			self.prepare_max_nanoseconds,
			self.prepare_last_nanoseconds,
			self.commit_calls,
			self.commit_total_nanoseconds,
			self.commit_max_nanoseconds,
			self.commit_last_nanoseconds,
			self.publication_retries,
			self.completed_jobs,
			self.cancelled_jobs,
		]
	}

	pub fn encode(self) -> [u8; STAGE_JOB_TELEMETRY_LEN] {
		let mut output = [0; STAGE_JOB_TELEMETRY_LEN];
		output[..8].copy_from_slice(&self.job.to_le_bytes());
		output[8..10].copy_from_slice(&self.status.to_le_bytes());
		for (index, counter) in self.counters().into_iter().enumerate() {
			output[16 + index * 8..24 + index * 8].copy_from_slice(&counter.to_le_bytes());
		}
		output
	}

	pub fn decode(input: &[u8]) -> Result<Self, ProtocolError> {
		require_exact_len(input, STAGE_JOB_TELEMETRY_LEN)?;
		let job = read_u64(input, 0);
		let status = read_u16(input, 8);
		if status != 0 {
			StageJobStatus::try_from(status)?;
		}
		let reserved = u32::from(read_u16(input, 10)) | read_u32(input, 12);
		if reserved != 0 {
			return Err(ProtocolError::ReservedStageJobField(reserved));
		}
		let age_nanoseconds = read_u64(input, 16);
		if (job == 0) != (status == 0) || (job == 0 && age_nanoseconds != 0) {
			return Err(ProtocolError::InvalidStageJobIdentity(
				"telemetry job/status",
			));
		}
		Ok(Self {
			job,
			status,
			age_nanoseconds,
			prepare_calls: read_u64(input, 24),
			prepare_total_nanoseconds: read_u64(input, 32),
			prepare_max_nanoseconds: read_u64(input, 40),
			prepare_last_nanoseconds: read_u64(input, 48),
			commit_calls: read_u64(input, 56),
			commit_total_nanoseconds: read_u64(input, 64),
			commit_max_nanoseconds: read_u64(input, 72),
			commit_last_nanoseconds: read_u64(input, 80),
			publication_retries: read_u64(input, 88),
			completed_jobs: read_u64(input, 96),
			cancelled_jobs: read_u64(input, 104),
		})
	}
}
