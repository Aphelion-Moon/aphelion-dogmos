//! Fixed-size job ownership and receipts. Only the service actor advances the world.

use dogmos_core::{
	stage_job::{JobProgress, StageJobSpec, StageJobView},
	world::{DogmosWorld, WorldError},
};
use dogmos_protocol::{
	ProtocolError, StageJobCommit, StageJobResponse, StageJobStatus, StageJobSubmit,
};

#[derive(Debug)]
pub enum JobError {
	Busy,
	StaleStageEpoch,
	UnknownJob,
	InvalidUnit,
	IdentityExhausted,
	InvalidRequest(ProtocolError),
	Core(WorldError),
}

impl std::fmt::Display for JobError {
	fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
		match self {
			Self::Busy => f.write_str("another stage job is active"),
			Self::StaleStageEpoch => f.write_str("stage job epoch was already used"),
			Self::UnknownJob => f.write_str("stage job identity is unknown or stale"),
			Self::InvalidUnit => f.write_str("stage publication unit is not ready or is stale"),
			Self::IdentityExhausted => f.write_str("stage job identities exhausted"),
			Self::InvalidRequest(error) => write!(f, "invalid stage job request: {error}"),
			Self::Core(error) => write!(f, "stage job failed: {error}"),
		}
	}
}

impl std::error::Error for JobError {}

struct Job {
	request: StageJobSubmit,
	response: StageJobResponse,
	last_receipt: Option<StageJobResponse>,
}

impl Job {
	fn spec(&self) -> StageJobSpec {
		spec(self.request)
	}

	fn refresh(&mut self, view: StageJobView) {
		self.response.status = match view.progress {
			JobProgress::Running => StageJobStatus::Running,
			JobProgress::Ready { .. } => StageJobStatus::Ready,
			JobProgress::Retrying => StageJobStatus::Retrying,
			JobProgress::Done => StageJobStatus::Done,
		};
		self.response.unit = match view.progress {
			JobProgress::Ready { unit } => unit,
			_ => self.last_receipt.map_or(0, |receipt| receipt.unit),
		};
		self.response.work_items = view.work_items;
		self.response.remaining_estimate = view.remaining_estimate;
		if let Some((_, receipt)) = view.last_committed {
			self.response.produced_equalize_seeds = receipt.produced_equalize_seeds;
			self.response.produced_group_seeds = receipt.produced_group_seeds;
			self.response.produced_heat_seeds = receipt.produced_heat_seeds;
			self.response.callback_events = receipt.callback_events;
		}
	}
}

fn spec(request: StageJobSubmit) -> StageJobSpec {
	StageJobSpec {
		stage: crate::state::simulation_stage(request.stage),
		frontier_epoch: request.frontier_epoch,
		stage_epoch: request.stage_epoch,
		seconds_per_tick: request.seconds_per_tick.0,
	}
}

#[derive(Default)]
pub struct StageJobController {
	job: Option<Job>,
	last_job_id: u64,
	last_stage_epoch: u64,
}

impl StageJobController {
	pub fn submit(
		&mut self,
		world: &mut DogmosWorld,
		request: StageJobSubmit,
	) -> Result<StageJobResponse, JobError> {
		request.encode().map_err(JobError::InvalidRequest)?;
		if self.job.as_ref().is_some_and(|job| {
			!matches!(
				job.response.status,
				StageJobStatus::Done | StageJobStatus::Cancelled
			)
		}) {
			return Err(JobError::Busy);
		}
		if request.stage_epoch <= self.last_stage_epoch {
			return Err(JobError::StaleStageEpoch);
		}
		let id = self
			.last_job_id
			.checked_add(1)
			.ok_or(JobError::IdentityExhausted)?;
		// Admit and establish the lifecycle fence without spending a work quantum.
		world
			.prepare_job_chunk(spec(request), 1, || true, || false)
			.map_err(JobError::Core)?;
		let response = StageJobResponse {
			job: id,
			stage: request.stage,
			status: StageJobStatus::Accepted,
			unit: 0,
			work_items: 0,
			remaining_estimate: 0,
			committed_units: 0,
			produced_equalize_seeds: 0,
			produced_group_seeds: 0,
			produced_heat_seeds: 0,
			callback_events: 0,
		};
		self.job = Some(Job {
			request,
			response,
			last_receipt: None,
		});
		self.last_job_id = id;
		self.last_stage_epoch = request.stage_epoch;
		Ok(response)
	}

	pub fn poll(&self, id: u64) -> Result<StageJobResponse, JobError> {
		self.owned(id).map(|job| job.response)
	}

	pub fn runnable(&self) -> bool {
		self.job.as_ref().is_some_and(|job| {
			matches!(
				job.response.status,
				StageJobStatus::Accepted | StageJobStatus::Running | StageJobStatus::Retrying
			)
		})
	}

	pub fn active(&self) -> bool {
		self.job.as_ref().is_some_and(|job| {
			!matches!(
				job.response.status,
				StageJobStatus::Done | StageJobStatus::Cancelled
			)
		})
	}

	pub fn quantum(&self) -> Option<std::time::Duration> {
		self.job
			.as_ref()
			.map(|job| std::time::Duration::from_micros(u64::from(job.request.quantum_us)))
	}

	pub fn prepare(
		&mut self,
		world: &mut DogmosWorld,
		should_yield: impl FnMut() -> bool,
		should_cancel: impl FnMut() -> bool,
	) -> Result<StageJobResponse, JobError> {
		if !self.runnable() {
			return self
				.job
				.as_ref()
				.map(|job| job.response)
				.ok_or(JobError::UnknownJob);
		}
		let job = self.job.as_mut().unwrap();
		if let Err(error) = world.prepare_job_chunk(
			job.spec(),
			job.request.work_limit,
			should_yield,
			should_cancel,
		) {
			world.cancel_job_unpublished();
			job.response.status = StageJobStatus::Cancelled;
			job.response.unit = job.last_receipt.map_or(0, |receipt| receipt.unit);
			return Err(JobError::Core(error));
		}
		job.refresh(
			world
				.stage_job_view()
				.expect("successful preparation retains job state"),
		);
		Ok(job.response)
	}

	/// Returns the exact prior receipt without inspecting the world or reserving callbacks.
	pub fn replay(&self, request: StageJobCommit) -> Result<Option<StageJobResponse>, JobError> {
		let job = self.owned(request.job)?;
		if let Some(receipt) = job
			.last_receipt
			.filter(|receipt| receipt.unit == request.unit)
		{
			return Ok(Some(receipt));
		}
		if request.unit == 0
			|| job.response.status != StageJobStatus::Ready
			|| job.response.unit != request.unit
		{
			return Err(JobError::InvalidUnit);
		}
		Ok(None)
	}

	pub fn commit(
		&mut self,
		world: &mut DogmosWorld,
		request: StageJobCommit,
		event_limit: u32,
	) -> Result<StageJobResponse, JobError> {
		if let Some(receipt) = self.replay(request)? {
			return Ok(receipt);
		}
		let job = self.job.as_mut().unwrap();
		if let Err(error) = world.commit_job_unit_with_event_limit(request.unit, event_limit) {
			job.response.status = StageJobStatus::Cancelled;
			job.response.unit = job.last_receipt.map_or(0, |receipt| receipt.unit);
			return Err(JobError::Core(error));
		}
		let view = world
			.stage_job_view()
			.expect("successful commit retains job state");
		job.refresh(view);
		if view
			.last_committed
			.is_some_and(|(unit, _)| unit == request.unit)
		{
			job.response.unit = request.unit;
			job.response.committed_units = job.response.committed_units.saturating_add(1);
			job.last_receipt = Some(job.response);
		}
		Ok(job.response)
	}

	pub fn cancel(
		&mut self,
		world: &mut DogmosWorld,
		id: u64,
	) -> Result<StageJobResponse, JobError> {
		let response = self.owned(id)?.response;
		if matches!(
			response.status,
			StageJobStatus::Done | StageJobStatus::Cancelled
		) {
			return Ok(response);
		}
		world.cancel_job_unpublished();
		let job = self.job.as_mut().unwrap();
		job.response.status = StageJobStatus::Cancelled;
		job.response.unit = job.last_receipt.map_or(0, |receipt| receipt.unit);
		Ok(job.response)
	}

	fn owned(&self, id: u64) -> Result<&Job, JobError> {
		self.job
			.as_ref()
			.filter(|job| job.response.job == id)
			.ok_or(JobError::UnknownJob)
	}
}
