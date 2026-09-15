//! Prepare-only stage execution with explicit publication by the world owner.

use crate::world::{StageChunkRequest, StageChunkResult, WorldStage};

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct StageJobSpec {
	pub stage: WorldStage,
	pub frontier_epoch: u64,
	pub stage_epoch: u64,
	pub seconds_per_tick: f64,
}

impl StageJobSpec {
	pub(crate) fn request(self, work_limit: u32) -> StageChunkRequest {
		StageChunkRequest {
			stage: self.stage,
			frontier_epoch: self.frontier_epoch,
			stage_epoch: self.stage_epoch,
			seconds_per_tick: self.seconds_per_tick,
			work_limit,
		}
	}
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum JobProgress {
	Running,
	Ready { unit: u64 },
	Retrying,
	Done,
}

/// Fixed-size status for the service actor. Reading it performs no stage work.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct StageJobView {
	pub progress: JobProgress,
	pub work_items: u32,
	pub remaining_estimate: u32,
	pub last_committed: Option<(u64, StageChunkResult)>,
}

pub(crate) struct StageJobState {
	pub(crate) spec: StageJobSpec,
	pub(crate) ready_unit: Option<u64>,
	pub(crate) last_receipt: Option<(u64, StageChunkResult)>,
	pub(crate) work_items: u32,
	pub(crate) remaining_estimate: u32,
	pub(crate) publication_permitted: bool,
	pub(crate) unit_committed: bool,
	pub(crate) done: bool,
	pub(crate) retrying: bool,
}

impl StageJobState {
	pub(crate) fn new(spec: StageJobSpec) -> Self {
		Self {
			spec,
			ready_unit: None,
			last_receipt: None,
			work_items: 0,
			remaining_estimate: 0,
			publication_permitted: false,
			unit_committed: false,
			done: false,
			retrying: false,
		}
	}
}
