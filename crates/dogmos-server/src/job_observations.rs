//! Fixed-size timing/counter state, separate from job ownership and numerical state.

use dogmos_protocol::{StageJobStatus, StageJobTelemetry};

#[derive(Default)]
pub(crate) struct JobObservations {
	values: StageJobTelemetry,
	admitted_at: Option<u64>,
	terminal_age: Option<u64>,
}

impl JobObservations {
	pub fn job_id(&self) -> u64 {
		self.values.job
	}

	pub fn admit(&mut self, job: u64, now_nanoseconds: u64) {
		self.values.job = job;
		self.values.status = StageJobStatus::Accepted as u16;
		self.admitted_at = Some(now_nanoseconds);
		self.terminal_age = None;
	}

	pub fn status(&mut self, status: StageJobStatus, now_nanoseconds: u64) {
		if self.terminal_age.is_some() {
			return;
		}
		self.values.status = status as u16;
		if matches!(status, StageJobStatus::Done | StageJobStatus::Cancelled) {
			self.terminal_age = Some(self.age(now_nanoseconds));
			let count = if status == StageJobStatus::Done {
				&mut self.values.completed_jobs
			} else {
				&mut self.values.cancelled_jobs
			};
			*count = count.saturating_add(1);
		}
	}

	pub fn record_prepare(&mut self, nanoseconds: u64) {
		self.values.prepare_calls = self.values.prepare_calls.saturating_add(1);
		self.values.prepare_total_nanoseconds = self
			.values
			.prepare_total_nanoseconds
			.saturating_add(nanoseconds);
		self.values.prepare_max_nanoseconds = self.values.prepare_max_nanoseconds.max(nanoseconds);
		self.values.prepare_last_nanoseconds = nanoseconds;
	}

	pub fn record_commit(&mut self, nanoseconds: u64, retried: bool) {
		self.values.commit_calls = self.values.commit_calls.saturating_add(1);
		self.values.commit_total_nanoseconds = self
			.values
			.commit_total_nanoseconds
			.saturating_add(nanoseconds);
		self.values.commit_max_nanoseconds = self.values.commit_max_nanoseconds.max(nanoseconds);
		self.values.commit_last_nanoseconds = nanoseconds;
		if retried {
			self.values.publication_retries = self.values.publication_retries.saturating_add(1);
		}
	}

	pub fn snapshot(&self, now_nanoseconds: u64) -> StageJobTelemetry {
		StageJobTelemetry {
			age_nanoseconds: self.age(now_nanoseconds),
			..self.values
		}
	}

	fn age(&self, now_nanoseconds: u64) -> u64 {
		self.terminal_age.unwrap_or_else(|| {
			self.admitted_at
				.map_or(0, |start| now_nanoseconds.saturating_sub(start))
		})
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	use dogmos_protocol::StageJobStatus;

	#[test]
	fn deterministic_observations_freeze_terminal_age_and_preserve_world_counters() {
		let mut observations = JobObservations::default();
		assert_eq!(observations.snapshot(99).job, 0);
		observations.admit(0x0001_0002_0003_0004, 100);
		observations.record_prepare(5);
		observations.record_prepare(7);
		observations.status(StageJobStatus::Ready, 120);
		assert_eq!(observations.snapshot(130).age_nanoseconds, 30);
		observations.record_commit(11, true);
		observations.status(StageJobStatus::Retrying, 135);
		observations.record_commit(3, false);
		observations.status(StageJobStatus::Done, 150);
		observations.status(StageJobStatus::Done, 250);
		let result = observations.snapshot(300);
		assert_eq!(result.age_nanoseconds, 50);
		assert_eq!(result.prepare_calls, 2);
		assert_eq!(result.prepare_total_nanoseconds, 12);
		assert_eq!(result.prepare_max_nanoseconds, 7);
		assert_eq!(result.prepare_last_nanoseconds, 7);
		assert_eq!(result.commit_calls, 2);
		assert_eq!(result.commit_total_nanoseconds, 14);
		assert_eq!(result.commit_max_nanoseconds, 11);
		assert_eq!(result.commit_last_nanoseconds, 3);
		assert_eq!(result.publication_retries, 1);
		assert_eq!(result.completed_jobs, 1);
		observations.admit(2, 300);
		observations.status(StageJobStatus::Cancelled, 325);
		observations.status(StageJobStatus::Cancelled, 400);
		let result = observations.snapshot(500);
		assert_eq!(result.job, 2);
		assert_eq!(result.age_nanoseconds, 25);
		assert_eq!(result.completed_jobs, 1);
		assert_eq!(result.cancelled_jobs, 1);
		assert_eq!(result.prepare_calls, 2);
		assert!(std::mem::size_of::<JobObservations>() <= 160);
	}

	#[test]
	fn counters_saturate_without_losing_last_sample() {
		let mut observations = JobObservations::default();
		observations.record_prepare(u64::MAX);
		observations.record_prepare(23);
		observations.record_commit(u64::MAX, true);
		observations.record_commit(29, false);
		let result = observations.snapshot(0);
		assert_eq!(result.prepare_total_nanoseconds, u64::MAX);
		assert_eq!(result.prepare_max_nanoseconds, u64::MAX);
		assert_eq!(result.prepare_last_nanoseconds, 23);
		assert_eq!(result.commit_total_nanoseconds, u64::MAX);
		assert_eq!(result.commit_max_nanoseconds, u64::MAX);
		assert_eq!(result.commit_last_nanoseconds, 29);
		assert_eq!(result.publication_retries, 1);
	}
}
