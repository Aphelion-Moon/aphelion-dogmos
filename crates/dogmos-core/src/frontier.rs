use crate::metadata::TurfHandle;
use std::{
	collections::TryReserveError,
	collections::{HashMap, HashSet},
	sync::OnceLock,
};

fn reserve(operation: impl FnOnce() -> Result<(), TryReserveError>) -> Result<(), FrontierError> {
	#[cfg(test)]
	if FAIL_RESERVATION.with(|remaining| match remaining.get() {
		Some(0) => {
			remaining.set(None);
			true
		}
		Some(count) => {
			remaining.set(Some(count - 1));
			false
		}
		None => false,
	}) {
		return Err(FrontierError::AllocationFailed);
	}
	operation().map_err(|_| FrontierError::AllocationFailed)
}

fn reserve_vec_to<T>(buffer: &mut Vec<T>, target: usize) -> Result<(), FrontierError> {
	reserve(|| buffer.try_reserve(target.saturating_sub(buffer.len())))
}

#[cfg(test)]
thread_local! {
	static FAIL_RESERVATION: std::cell::Cell<Option<usize>> = const { std::cell::Cell::new(None) };
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum FrontierError {
	InvalidEpoch(u64),
	EpochConflict {
		committed: Option<u64>,
		uploading: Option<u64>,
		requested: u64,
	},
	CountExceeded {
		actual: u32,
		maximum: u32,
	},
	RangeOutOfBounds {
		offset: u32,
		count: u32,
		expected: u32,
	},
	RangeAlreadyReceived {
		offset: u32,
		count: u32,
	},
	Incomplete {
		epoch: u64,
		expected: u32,
		received: u32,
	},
	DuplicateHandle(TurfHandle),
	AllocationFailed,
}

#[derive(Default)]
pub(crate) struct FrontierState {
	committed_epoch: Option<u64>,
	committed: Vec<TurfHandle>,
	// Mirrors `committed`'s membership so add()'s duplicate check and remove()'s filter are O(1)
	// per handle instead of rebuilding a HashSet from the whole committed vec on every call -
	// the steady-state incremental path exists specifically to avoid full-frontier-sized work.
	committed_set: HashMap<TurfHandle, usize>,
	committed_view: OnceLock<Vec<TurfHandle>>,
	upload_epoch: Option<u64>,
	upload_expected: u32,
	upload_received: u32,
	staging: Vec<TurfHandle>,
	received_bits: Vec<u64>,
	upload_seen: HashSet<TurfHandle>,
}

impl FrontierState {
	pub(crate) fn begin(
		&mut self,
		epoch: u64,
		expected: u32,
		maximum: u32,
	) -> Result<(), FrontierError> {
		if epoch == 0 {
			return Err(FrontierError::InvalidEpoch(epoch));
		}
		if expected > maximum {
			return Err(FrontierError::CountExceeded {
				actual: expected,
				maximum,
			});
		}
		if self
			.committed_epoch
			.is_some_and(|committed| epoch <= committed)
			|| self
				.upload_epoch
				.is_some_and(|uploading| epoch <= uploading)
		{
			return Err(FrontierError::EpochConflict {
				committed: self.committed_epoch,
				uploading: self.upload_epoch,
				requested: epoch,
			});
		}

		let expected_usize = expected as usize;
		let word_count = expected_usize.div_ceil(u64::BITS as usize);
		// Reserve every buffer before changing a previous upload. Capacity growth is harmless
		// on failure; changing its ranges or membership would make the old epoch inconsistent.
		reserve_vec_to(&mut self.staging, expected_usize)?;
		reserve_vec_to(&mut self.received_bits, word_count)?;
		reserve(|| {
			self.upload_seen
				.try_reserve(expected_usize.saturating_sub(self.upload_seen.len()))
		})?;
		self.staging.resize(
			expected_usize,
			TurfHandle {
				slot: 0,
				generation: 0,
			},
		);
		self.received_bits.resize(word_count, 0);
		self.received_bits.fill(0);
		self.upload_seen.clear();
		self.upload_epoch = Some(epoch);
		self.upload_expected = expected;
		self.upload_received = 0;
		Ok(())
	}

	pub(crate) fn append(
		&mut self,
		epoch: u64,
		offset: u32,
		handles: &[TurfHandle],
	) -> Result<u32, FrontierError> {
		if self.upload_epoch != Some(epoch) {
			return Err(FrontierError::EpochConflict {
				committed: self.committed_epoch,
				uploading: self.upload_epoch,
				requested: epoch,
			});
		}
		let count = u32::try_from(handles.len()).map_err(|_| FrontierError::RangeOutOfBounds {
			offset,
			count: u32::MAX,
			expected: self.upload_expected,
		})?;
		let Some(end) = offset.checked_add(count) else {
			return Err(FrontierError::RangeOutOfBounds {
				offset,
				count,
				expected: self.upload_expected,
			});
		};
		if end > self.upload_expected {
			return Err(FrontierError::RangeOutOfBounds {
				offset,
				count,
				expected: self.upload_expected,
			});
		}
		if (offset..end).any(|index| self.is_received(index)) {
			return Err(FrontierError::RangeAlreadyReceived { offset, count });
		}
		let mut incoming = HashSet::new();
		reserve(|| incoming.try_reserve(handles.len()))?;
		for handle in handles {
			if self.upload_seen.contains(handle) || !incoming.insert(*handle) {
				return Err(FrontierError::DuplicateHandle(*handle));
			}
		}
		for (relative_index, handle) in handles.iter().enumerate() {
			let index = offset as usize + relative_index;
			self.staging[index] = *handle;
			self.received_bits[index / u64::BITS as usize] |= 1 << (index % u64::BITS as usize);
		}
		self.upload_seen.extend(handles.iter().copied());
		self.upload_received += count;
		Ok(count)
	}

	pub(crate) fn pending(&self, epoch: u64) -> Result<&[TurfHandle], FrontierError> {
		if self.upload_epoch != Some(epoch) {
			return Err(FrontierError::EpochConflict {
				committed: self.committed_epoch,
				uploading: self.upload_epoch,
				requested: epoch,
			});
		}
		if self.upload_received != self.upload_expected {
			return Err(FrontierError::Incomplete {
				epoch,
				expected: self.upload_expected,
				received: self.upload_received,
			});
		}
		Ok(&self.staging)
	}

	/// Commits an upload after World::commit_frontier validates completeness and live turfs.
	/// Reserve the replacement membership before publishing either vector or epoch.
	pub(crate) fn commit_validated(&mut self, epoch: u64) -> Result<u32, FrontierError> {
		reserve(|| {
			self.committed_set
				.try_reserve(self.staging.len().saturating_sub(self.committed_set.len()))
		})?;
		std::mem::swap(&mut self.committed, &mut self.staging);
		self.staging.clear();
		self.committed_epoch = Some(epoch);
		self.upload_epoch = None;
		self.upload_expected = 0;
		self.upload_received = 0;
		self.upload_seen.clear();
		self.committed_set.clear();
		self.committed_set.extend(
			self.committed
				.iter()
				.copied()
				.enumerate()
				.map(|(index, handle)| (handle, index)),
		);
		self.committed_view.take();
		Ok(self.committed.len() as u32)
	}

	/// Adds handles directly to the committed frontier without a begin/append/commit round trip.
	/// Used for the steady-state incremental sync path: DM diffs its local active-turf set
	/// against what it last successfully committed and sends only the delta, instead of
	/// re-uploading the whole frontier every tick. The two-phase begin/append/commit path above
	/// remains available for the initial bootstrap sync and any full resync DM chooses to force.
	pub(crate) fn add(
		&mut self,
		epoch: u64,
		handles: &[TurfHandle],
		maximum: u32,
	) -> Result<u32, FrontierError> {
		if self
			.committed_epoch
			.is_some_and(|committed| epoch <= committed)
		{
			return Err(FrontierError::EpochConflict {
				committed: self.committed_epoch,
				uploading: self.upload_epoch,
				requested: epoch,
			});
		}
		let projected = self.committed_set.len().saturating_add(handles.len());
		if projected > maximum as usize {
			return Err(FrontierError::CountExceeded {
				actual: u32::try_from(projected).unwrap_or(u32::MAX),
				maximum,
			});
		}
		if handles.is_empty() {
			self.committed_epoch = Some(epoch);
			return Ok(0);
		}
		let mut incoming = HashSet::new();
		reserve(|| incoming.try_reserve(handles.len()))?;
		for handle in handles {
			if self.committed_set.contains_key(handle) || !incoming.insert(*handle) {
				return Err(FrontierError::DuplicateHandle(*handle));
			}
		}
		reserve(|| self.committed.try_reserve(handles.len()))?;
		reserve(|| self.committed_set.try_reserve(handles.len()))?;
		self.compact();
		let start = self.committed.len();
		self.committed.extend_from_slice(handles);
		self.committed_set.extend(
			handles
				.iter()
				.copied()
				.enumerate()
				.map(|(index, handle)| (handle, start + index)),
		);
		self.committed_view.take();
		self.committed_epoch = Some(epoch);
		Ok(u32::try_from(handles.len()).unwrap_or(u32::MAX))
	}

	/// Removes handles directly from the committed frontier. See `add` for the incremental-sync
	/// rationale. A handle that isn't currently committed is silently ignored rather than
	/// rejected, since DM's diff is computed against its own last-known-committed snapshot and a
	/// handle can legitimately have already left the frontier through an earlier partial sync.
	pub(crate) fn remove(
		&mut self,
		epoch: u64,
		handles: &[TurfHandle],
	) -> Result<u32, FrontierError> {
		if self
			.committed_epoch
			.is_some_and(|committed| epoch <= committed)
		{
			return Err(FrontierError::EpochConflict {
				committed: self.committed_epoch,
				uploading: self.upload_epoch,
				requested: epoch,
			});
		}
		let before = self.committed_set.len();
		for handle in handles {
			self.committed_set.remove(handle);
		}
		if before != self.committed_set.len() {
			self.committed_view.take();
			self.compact();
		}
		self.committed_epoch = Some(epoch);
		Ok((before - self.committed_set.len()) as u32)
	}

	fn compact(&mut self) {
		if self.committed.len() <= self.committed_set.len().saturating_mul(2) {
			return;
		}
		let mut index = 0;
		self.committed.retain(|handle| {
			let keep = self.committed_set.get(handle) == Some(&index);
			index += 1;
			keep
		});
		for (index, handle) in self.committed.iter().enumerate() {
			*self.committed_set.get_mut(handle).unwrap() = index;
		}
	}

	pub(crate) fn committed_epoch(&self) -> Option<u64> {
		self.committed_epoch
	}

	pub(crate) fn committed(&self) -> &[TurfHandle] {
		self.committed_view.get_or_init(|| {
			self.committed
				.iter()
				.copied()
				.enumerate()
				.filter_map(|(index, handle)| {
					(self.committed_set.get(&handle) == Some(&index)).then_some(handle)
				})
				.collect()
		})
	}

	pub(crate) fn upload_bytes(&self) -> u64 {
		(self.staging.capacity() * std::mem::size_of::<TurfHandle>()
			+ self.received_bits.capacity() * std::mem::size_of::<u64>()
			+ self.upload_seen.capacity() * std::mem::size_of::<TurfHandle>()) as u64
	}

	pub(crate) fn committed_storage_bytes_lower_bound(&self) -> u64 {
		(self.committed.capacity() * std::mem::size_of::<TurfHandle>()
			+ self.committed_set.capacity() * std::mem::size_of::<(TurfHandle, usize)>()
			+ self.committed_view.get().map_or(0, |view| {
				view.capacity() * std::mem::size_of::<TurfHandle>()
			})) as u64
	}

	pub(crate) fn committed_capacities(&self) -> (usize, usize) {
		(
			self.committed.capacity() + self.committed_view.get().map_or(0, Vec::capacity),
			self.committed_set.capacity(),
		)
	}

	fn is_received(&self, index: u32) -> bool {
		let index = index as usize;
		self.received_bits[index / u64::BITS as usize] & (1 << (index % u64::BITS as usize)) != 0
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	fn handle(slot: u32) -> TurfHandle {
		TurfHandle {
			slot,
			generation: 1,
		}
	}

	fn fail_at<T>(index: usize, operation: impl FnOnce() -> T) -> T {
		struct Reset;
		impl Drop for Reset {
			fn drop(&mut self) {
				FAIL_RESERVATION.with(|failure| failure.set(None));
			}
		}
		FAIL_RESERVATION.with(|failure| failure.set(Some(index)));
		let _reset = Reset;
		operation()
	}

	#[test]
	fn rejected_begin_preserves_previous_partial_upload() {
		for failure in 0..3 {
			let mut frontier = FrontierState::default();
			frontier.begin(1, 2, 1024).unwrap();
			frontier.append(1, 0, &[handle(7)]).unwrap();
			assert_eq!(
				fail_at(failure, || frontier.begin(2, 513, 1024)),
				Err(FrontierError::AllocationFailed)
			);
			assert_eq!(
				frontier.append(1, 0, &[handle(9)]),
				Err(FrontierError::RangeAlreadyReceived {
					offset: 0,
					count: 1
				})
			);
			assert_eq!(
				frontier.append(1, 1, &[handle(7)]),
				Err(FrontierError::DuplicateHandle(handle(7)))
			);
			frontier.append(1, 1, &[handle(9)]).unwrap();
			assert_eq!(frontier.pending(1).unwrap(), &[handle(7), handle(9)]);
		}
	}

	#[test]
	fn cleared_upload_buffers_reserve_the_full_new_length() {
		let mut buffer = Vec::<TurfHandle>::with_capacity(100);
		buffer.resize(50, handle(7));
		buffer.clear();
		let target = buffer.capacity() + 50;
		reserve_vec_to(&mut buffer, target).unwrap();
		assert!(buffer.capacity() >= target);
		assert!(buffer.is_empty());
		let mut frontier = FrontierState::default();
		for (epoch, expected) in [(1, 100), (2, 50), (3, 150), (4, 513)] {
			frontier.begin(epoch, expected, 1024).unwrap();
			assert!(frontier.staging.capacity() >= expected as usize);
			assert!(frontier.received_bits.capacity() >= (expected as usize).div_ceil(64));
			assert!(frontier.upload_seen.capacity() >= expected as usize);
		}
	}

	#[test]
	fn rejected_add_and_commit_preserve_both_frontiers() {
		for failure in 0..3 {
			let mut frontier = FrontierState::default();
			frontier.add(1, &[handle(3), handle(7)], 1024).unwrap();
			frontier.begin(2, 1, 1024).unwrap();
			frontier.append(2, 0, &[handle(9)]).unwrap();
			assert_eq!(frontier.committed(), &[handle(3), handle(7)]);
			assert_eq!(
				fail_at(failure, || frontier.add(3, &[handle(5)], 1024)),
				Err(FrontierError::AllocationFailed)
			);
			assert_eq!(frontier.committed_epoch(), Some(1));
			assert_eq!(frontier.committed(), &[handle(3), handle(7)]);
			assert_eq!(frontier.pending(2).unwrap(), &[handle(9)]);
			assert_eq!(
				fail_at(0, || frontier.commit_validated(2)),
				Err(FrontierError::AllocationFailed)
			);
			assert_eq!(frontier.committed_epoch(), Some(1));
			assert_eq!(frontier.committed(), &[handle(3), handle(7)]);
			assert_eq!(frontier.pending(2).unwrap(), &[handle(9)]);
			frontier.commit_validated(2).unwrap();
			assert_eq!(frontier.committed(), &[handle(9)]);
		}
	}

	#[test]
	fn no_op_deltas_preserve_materialized_view_and_readds_keep_order() {
		let mut frontier = FrontierState::default();
		frontier
			.add(1, &[handle(3), handle(7), handle(9)], 1024)
			.unwrap();
		assert_eq!(frontier.committed(), &[handle(3), handle(7), handle(9)]);
		frontier.add(2, &[], 1024).unwrap();
		assert!(frontier.committed_view.get().is_some());
		frontier.remove(3, &[handle(999)]).unwrap();
		assert!(frontier.committed_view.get().is_some());
		frontier.remove(4, &[handle(7), handle(7)]).unwrap();
		frontier.add(5, &[handle(7)], 1024).unwrap();
		assert_eq!(frontier.committed(), &[handle(3), handle(9), handle(7)]);
	}
}
