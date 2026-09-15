use super::*;
use crate::stage_job::{JobProgress, StageJobSpec, StageJobState, StageJobView};

impl DogmosWorld {
	pub fn stage_job_view(&self) -> Option<StageJobView> {
		let job = self.stage_job.as_ref()?;
		let progress = if job.done {
			JobProgress::Done
		} else if let Some(unit) = job.ready_unit {
			JobProgress::Ready { unit }
		} else if job.retrying {
			JobProgress::Retrying
		} else {
			JobProgress::Running
		};
		Some(StageJobView {
			progress,
			work_items: job.work_items,
			remaining_estimate: job.remaining_estimate,
			last_committed: job.last_receipt,
		})
	}
	/// Advances preparation without publishing tentative gas or events.
	/// Scheduling yield and fatal cancellation are independent decisions.
	pub fn prepare_job_chunk(
		&mut self,
		spec: StageJobSpec,
		work_limit: u32,
		mut should_yield: impl FnMut() -> bool,
		mut should_cancel: impl FnMut() -> bool,
	) -> Result<JobProgress, WorldError> {
		if work_limit == 0 || work_limit > MAX_STAGE_WORK_LIMIT {
			return Err(WorldError::InvalidStageWorkLimit(work_limit));
		}
		if !spec.seconds_per_tick.is_finite() || spec.seconds_per_tick <= 0.0 {
			return Err(WorldError::InvalidSecondsPerTick);
		}
		if spec.stage_epoch == 0 {
			return Err(WorldError::State("stage job epoch must be nonzero".into()));
		}
		if self.frontier.committed_epoch() != Some(spec.frontier_epoch) {
			return Err(WorldError::StageConflict(
				StageConflictReason::FrontierEpoch {
					requested: spec.frontier_epoch,
					committed: self.frontier.committed_epoch(),
				},
			));
		}
		if let Some(job) = &self.stage_job {
			if job.spec != spec {
				if !job.done || spec.stage_epoch <= job.spec.stage_epoch {
					return Err(WorldError::State("another stage job owns the world".into()));
				}
				self.stage_job = None;
			}
		}
		if self.stage_job.is_none() {
			if self.stage_cursor.is_some() {
				return Err(WorldError::State(
					"a synchronous stage owns the world".into(),
				));
			}
			self.stage_job = Some(StageJobState::new(spec));
		}
		if self.stage_job.as_ref().unwrap().done {
			return Ok(JobProgress::Done);
		}
		if should_cancel() {
			self.cancel_job_unpublished();
			return Err(WorldError::Cancelled);
		}
		if let Some(unit) = self.stage_job.as_ref().unwrap().ready_unit {
			return Ok(JobProgress::Ready { unit });
		}
		for _ in 0..work_limit {
			if should_cancel() {
				self.cancel_job_unpublished();
				return Err(WorldError::Cancelled);
			}
			if should_yield() {
				break;
			}
			let result = self.process_stage_chunk_cancellable_inner(
				spec.request(1),
				self.max_events as usize,
				&mut should_cancel,
			);
			let chunk = match result {
				Ok(chunk) => chunk,
				Err(error) => {
					self.cancel_job_unpublished();
					return Err(error);
				}
			};
			let job = self.stage_job.as_mut().unwrap();
			job.work_items = job.work_items.saturating_add(chunk.work_items);
			job.remaining_estimate = chunk.remaining_estimate;
			job.retrying = false;
			if let Some(unit) = job.ready_unit {
				return Ok(JobProgress::Ready { unit });
			}
			if !chunk.pending {
				if matches!(spec.stage, WorldStage::Equalize | WorldStage::ExcitedGroups) {
					// Traversal may finish after the final component receipt. No values or
					// events are published by this completion-only step.
					job.done = true;
					return Ok(JobProgress::Done);
				}
				self.cancel_job_unpublished();
				return Err(WorldError::State(
					"stage preparation bypassed explicit publication".into(),
				));
			}
		}
		Ok(if self.stage_job.as_ref().unwrap().retrying {
			JobProgress::Retrying
		} else {
			JobProgress::Running
		})
	}

	/// Publishes one ready unit, retaining its exact receipt for duplicate commit requests.
	pub fn commit_job_unit(&mut self, unit: u64) -> Result<StageChunkResult, WorldError> {
		self.commit_job_unit_with_event_limit(unit, self.max_events)
	}

	/// The service may have queued callbacks since preparation. Admit against its
	/// current available outbox capacity before publishing any tentative value.
	pub fn commit_job_unit_with_event_limit(
		&mut self,
		unit: u64,
		max_events: u32,
	) -> Result<StageChunkResult, WorldError> {
		let job = self
			.stage_job
			.as_mut()
			.ok_or_else(|| WorldError::State("no stage job owns this unit".into()))?;
		if let Some((previous_unit, receipt)) = job.last_receipt {
			if unit == previous_unit {
				return Ok(receipt);
			}
		}
		if job.ready_unit != Some(unit) {
			return Err(WorldError::State(
				"stage publication unit is not ready or is stale".into(),
			));
		}
		job.publication_permitted = true;
		job.unit_committed = false;
		let request = job.spec.request(1);
		let result = self.process_stage_chunk_cancellable_inner(
			request,
			max_events.min(self.max_events) as usize,
			|| false,
		);
		let mut receipt = match result {
			Ok(receipt) => receipt,
			Err(error) => {
				self.cancel_job_unpublished();
				return Err(error);
			}
		};
		let job = self.stage_job.as_mut().unwrap();
		job.publication_permitted = false;
		job.ready_unit = None;
		receipt.work_items = job.work_items.saturating_add(receipt.work_items);
		job.work_items = receipt.work_items;
		job.remaining_estimate = receipt.remaining_estimate;
		job.retrying = receipt.pending && !job.unit_committed;
		job.done = !receipt.pending;
		if job.done || job.unit_committed {
			job.last_receipt = Some((unit, receipt));
		}
		Ok(receipt)
	}

	/// Cancels unpublished work. Already published records remain authoritative.
	pub fn cancel_job_unpublished(&mut self) {
		if self.stage_job.take().is_some() {
			self.abort_stage();
		}
	}

	pub(super) fn defer_job_publication(&mut self) -> Result<bool, WorldError> {
		let Some(job) = self.stage_job.as_mut() else {
			return Ok(false);
		};
		if job.publication_permitted {
			return Ok(false);
		}
		if job.ready_unit.is_none() {
			self.next_stage_job_unit =
				self.next_stage_job_unit.checked_add(1).ok_or_else(|| {
					WorldError::State("stage publication unit identifiers exhausted".into())
				})?;
			job.ready_unit = Some(self.next_stage_job_unit);
		}
		Ok(true)
	}
}
