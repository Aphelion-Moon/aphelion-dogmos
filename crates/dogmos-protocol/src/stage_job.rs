//! Fixed-width job control frames. Admission and publication remain distinct operations.

use crate::{
	read_u16, read_u32, read_u64, require_exact_len, ProtocolError, ScalarValue, SimulationStage,
	MAX_STAGE_WORK_ITEMS,
};

pub const STAGE_JOB_SUBMIT_LEN: usize = 40;
pub const STAGE_JOB_POLL_LEN: usize = 8;
pub const STAGE_JOB_COMMIT_LEN: usize = 16;
pub const STAGE_JOB_CANCEL_LEN: usize = 16;
pub const STAGE_JOB_RESPONSE_LEN: usize = 64;
pub const MAX_STAGE_JOB_QUANTUM_US: u32 = 1000;

fn nonzero(value: u64, field: &'static str) -> Result<(), ProtocolError> {
	if value == 0 {
		return Err(ProtocolError::InvalidStageJobIdentity(field));
	}
	Ok(())
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct StageJobSubmit {
	pub stage: SimulationStage,
	pub work_limit: u32,
	pub frontier_epoch: u64,
	pub stage_epoch: u64,
	pub seconds_per_tick: ScalarValue,
	pub quantum_us: u32,
}

impl StageJobSubmit {
	fn validate(self) -> Result<(), ProtocolError> {
		if self.work_limit == 0 || self.work_limit > MAX_STAGE_WORK_ITEMS {
			return Err(ProtocolError::InvalidStageWorkLimit(self.work_limit));
		}
		if self.quantum_us == 0 || self.quantum_us > MAX_STAGE_JOB_QUANTUM_US {
			return Err(ProtocolError::InvalidStageJobQuantum(self.quantum_us));
		}
		nonzero(self.frontier_epoch, "frontier epoch")?;
		nonzero(self.stage_epoch, "stage epoch")?;
		if !self.seconds_per_tick.0.is_finite() || self.seconds_per_tick.0 <= 0.0 {
			return Err(ProtocolError::InvalidStageJobSeconds);
		}
		Ok(())
	}
	pub fn encode(self) -> Result<[u8; STAGE_JOB_SUBMIT_LEN], ProtocolError> {
		self.validate()?;
		let mut output = [0; STAGE_JOB_SUBMIT_LEN];
		output[0..2].copy_from_slice(&(self.stage as u16).to_le_bytes());
		output[4..8].copy_from_slice(&self.work_limit.to_le_bytes());
		output[8..16].copy_from_slice(&self.frontier_epoch.to_le_bytes());
		output[16..24].copy_from_slice(&self.stage_epoch.to_le_bytes());
		output[24..32].copy_from_slice(&self.seconds_per_tick.encode()?);
		output[32..36].copy_from_slice(&self.quantum_us.to_le_bytes());
		Ok(output)
	}
	pub fn decode(input: &[u8]) -> Result<Self, ProtocolError> {
		require_exact_len(input, STAGE_JOB_SUBMIT_LEN)?;
		let reserved = u32::from(read_u16(input, 2)) | read_u32(input, 36);
		if reserved != 0 {
			return Err(ProtocolError::ReservedStageJobField(reserved));
		}
		let request = Self {
			stage: SimulationStage::try_from(u32::from(read_u16(input, 0)))?,
			work_limit: read_u32(input, 4),
			frontier_epoch: read_u64(input, 8),
			stage_epoch: read_u64(input, 16),
			seconds_per_tick: ScalarValue::decode(&input[24..32])?,
			quantum_us: read_u32(input, 32),
		};
		request.validate()?;
		Ok(request)
	}
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct StageJobPoll {
	pub job: u64,
}

impl StageJobPoll {
	pub const fn encode(self) -> [u8; STAGE_JOB_POLL_LEN] {
		self.job.to_le_bytes()
	}
	pub fn decode(input: &[u8]) -> Result<Self, ProtocolError> {
		require_exact_len(input, STAGE_JOB_POLL_LEN)?;
		let job = read_u64(input, 0);
		nonzero(job, "job")?;
		Ok(Self { job })
	}
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct StageJobCommit {
	pub job: u64,
	pub unit: u64,
}

impl StageJobCommit {
	pub fn encode(self) -> [u8; STAGE_JOB_COMMIT_LEN] {
		let mut output = [0; STAGE_JOB_COMMIT_LEN];
		output[..8].copy_from_slice(&self.job.to_le_bytes());
		output[8..16].copy_from_slice(&self.unit.to_le_bytes());
		output
	}
	pub fn decode(input: &[u8]) -> Result<Self, ProtocolError> {
		require_exact_len(input, STAGE_JOB_COMMIT_LEN)?;
		let (job, unit) = (read_u64(input, 0), read_u64(input, 8));
		nonzero(job, "job")?;
		nonzero(unit, "unit")?;
		Ok(Self { job, unit })
	}
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct StageJobCancel {
	pub job: u64,
}

impl StageJobCancel {
	pub fn encode(self) -> [u8; STAGE_JOB_CANCEL_LEN] {
		let mut output = [0; STAGE_JOB_CANCEL_LEN];
		output[..8].copy_from_slice(&self.job.to_le_bytes());
		output
	}
	pub fn decode(input: &[u8]) -> Result<Self, ProtocolError> {
		require_exact_len(input, STAGE_JOB_CANCEL_LEN)?;
		let reserved = read_u32(input, 8) | read_u32(input, 12);
		if reserved != 0 {
			return Err(ProtocolError::ReservedStageJobField(reserved));
		}
		let job = read_u64(input, 0);
		nonzero(job, "job")?;
		Ok(Self { job })
	}
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u16)]
pub enum StageJobStatus {
	Accepted = 1,
	Running = 2,
	Ready = 3,
	Retrying = 4,
	Done = 5,
	Cancelled = 6,
}

impl TryFrom<u16> for StageJobStatus {
	type Error = ProtocolError;
	fn try_from(value: u16) -> Result<Self, Self::Error> {
		match value {
			1 => Ok(Self::Accepted),
			2 => Ok(Self::Running),
			3 => Ok(Self::Ready),
			4 => Ok(Self::Retrying),
			5 => Ok(Self::Done),
			6 => Ok(Self::Cancelled),
			other => Err(ProtocolError::UnknownStageJobStatus(other)),
		}
	}
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct StageJobResponse {
	pub job: u64,
	pub status: StageJobStatus,
	pub stage: SimulationStage,
	pub unit: u64,
	pub work_items: u32,
	pub remaining_estimate: u32,
	pub committed_units: u64,
	pub produced_equalize_seeds: u32,
	pub produced_group_seeds: u32,
	pub produced_heat_seeds: u32,
	pub callback_events: u32,
}

impl StageJobResponse {
	fn validate(self) -> Result<(), ProtocolError> {
		nonzero(self.job, "job")?;
		if self.status == StageJobStatus::Ready {
			nonzero(self.unit, "ready unit")?;
		}
		Ok(())
	}
	pub fn encode(self) -> Result<[u8; STAGE_JOB_RESPONSE_LEN], ProtocolError> {
		self.validate()?;
		let mut output = [0; STAGE_JOB_RESPONSE_LEN];
		output[..8].copy_from_slice(&self.job.to_le_bytes());
		output[8..10].copy_from_slice(&(self.status as u16).to_le_bytes());
		output[10..12].copy_from_slice(&(self.stage as u16).to_le_bytes());
		output[16..24].copy_from_slice(&self.unit.to_le_bytes());
		output[24..28].copy_from_slice(&self.work_items.to_le_bytes());
		output[28..32].copy_from_slice(&self.remaining_estimate.to_le_bytes());
		output[32..40].copy_from_slice(&self.committed_units.to_le_bytes());
		output[40..44].copy_from_slice(&self.produced_equalize_seeds.to_le_bytes());
		output[44..48].copy_from_slice(&self.produced_group_seeds.to_le_bytes());
		output[48..52].copy_from_slice(&self.produced_heat_seeds.to_le_bytes());
		output[52..56].copy_from_slice(&self.callback_events.to_le_bytes());
		// Detail is zero in protocol 15. Failures use the existing typed frame errors.
		Ok(output)
	}
	pub fn decode(input: &[u8]) -> Result<Self, ProtocolError> {
		require_exact_len(input, STAGE_JOB_RESPONSE_LEN)?;
		let reserved = read_u32(input, 12) | read_u32(input, 56) | read_u32(input, 60);
		if reserved != 0 {
			return Err(ProtocolError::ReservedStageJobField(reserved));
		}
		let response = Self {
			job: read_u64(input, 0),
			status: StageJobStatus::try_from(read_u16(input, 8))?,
			stage: SimulationStage::try_from(u32::from(read_u16(input, 10)))?,
			unit: read_u64(input, 16),
			work_items: read_u32(input, 24),
			remaining_estimate: read_u32(input, 28),
			committed_units: read_u64(input, 32),
			produced_equalize_seeds: read_u32(input, 40),
			produced_group_seeds: read_u32(input, 44),
			produced_heat_seeds: read_u32(input, 48),
			callback_events: read_u32(input, 52),
		};
		response.validate()?;
		Ok(response)
	}
}
