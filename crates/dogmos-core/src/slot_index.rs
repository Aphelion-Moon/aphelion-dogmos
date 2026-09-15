use crate::paged_vec::PagedVec;
use crate::{metadata::TurfHandle, MixtureHandle};
use std::{
	collections::TryReserveError,
	marker::PhantomData,
	ops::{Index, IndexMut},
};

/// Both layouts share exactly the same generation and dense-position rules.
/// Large captured records use fixed pages; small indices retain flat vectors.
pub(crate) trait SlotValues<T>: Index<usize, Output = T> + IndexMut<usize> {
	fn new() -> Self;
	fn len(&self) -> usize;
	fn get(&self, index: usize) -> Option<&T>;
	fn try_push(&mut self, value: T) -> Result<(), TryReserveError>;
	fn clear(&mut self);
	fn capacity(&self) -> usize;
}

impl<T> SlotValues<T> for Vec<T> {
	fn new() -> Self {
		Vec::new()
	}
	fn len(&self) -> usize {
		Vec::len(self)
	}
	fn get(&self, index: usize) -> Option<&T> {
		self.as_slice().get(index)
	}
	fn try_push(&mut self, value: T) -> Result<(), TryReserveError> {
		self.try_reserve(1)?;
		self.push(value);
		Ok(())
	}
	fn clear(&mut self) {
		Vec::clear(self);
	}
	fn capacity(&self) -> usize {
		Vec::capacity(self)
	}
}

impl<T: Clone> SlotValues<T> for PagedVec<T> {
	fn new() -> Self {
		PagedVec::new()
	}
	fn len(&self) -> usize {
		PagedVec::len(self)
	}
	fn get(&self, index: usize) -> Option<&T> {
		PagedVec::get(self, index)
	}
	fn try_push(&mut self, value: T) -> Result<(), TryReserveError> {
		PagedVec::try_push(self, value)
	}
	fn clear(&mut self) {
		PagedVec::clear(self);
	}
	fn capacity(&self) -> usize {
		PagedVec::capacity(self)
	}
}

pub(crate) type SlotIndex<K, V> = SlotIndexStorage<K, V, Vec<(K, V)>>;
pub(crate) type PagedSlotIndex<K, V> = SlotIndexStorage<K, V, PagedVec<(K, V)>>;

pub(crate) trait SlotKey: Copy + Eq {
	fn slot(self) -> usize;
}

impl SlotKey for u32 {
	fn slot(self) -> usize {
		self as usize
	}
}

impl SlotKey for TurfHandle {
	fn slot(self) -> usize {
		self.slot as usize
	}
}

impl SlotKey for MixtureHandle {
	fn slot(self) -> usize {
		self.slot as usize
	}
}

/// Reusable generation-checked lookup with records stored only for occupied slots.
pub(crate) struct SlotIndexStorage<K, V, S> {
	slots: Vec<usize>,
	values: S,
	record: PhantomData<(K, V)>,
}

impl<K: SlotKey, V, S: SlotValues<(K, V)>> SlotIndexStorage<K, V, S> {
	pub(crate) fn new() -> Self {
		Self {
			slots: Vec::new(),
			values: S::new(),
			record: PhantomData,
		}
	}
	pub(crate) fn clear(&mut self) {
		self.values.clear();
	}
	fn entry_index(&self, slot: usize) -> Option<usize> {
		let index = *self.slots.get(slot)?;
		let (stored, _) = self.values.get(index)?;
		(stored.slot() == slot).then_some(index)
	}
	pub(crate) fn insert(&mut self, key: K, value: V) -> Option<V> {
		self.try_insert(key, value)
			.expect("slot index allocation failed")
	}
	pub(crate) fn try_insert(&mut self, key: K, value: V) -> Result<Option<V>, TryReserveError> {
		let slot = key.slot();
		if let Some(index) = self.entry_index(slot) {
			let (old, previous) = std::mem::replace(&mut self.values[index], (key, value));
			return Ok((old == key).then_some(previous));
		}
		if slot >= self.slots.len() {
			self.slots.try_reserve(slot + 1 - self.slots.len())?;
			self.slots.resize(slot + 1, usize::MAX);
		}
		let position = self.values.len();
		self.values.try_push((key, value))?;
		self.slots[slot] = position;
		Ok(None)
	}
	pub(crate) fn get(&self, key: &K) -> Option<&V> {
		Some(&self.values[self.index_of(key)?].1)
	}
	/// Dense position for a live key, stable across inserts until `clear`.
	/// Replacing a slot's generation preserves its position but invalidates the old key.
	pub(crate) fn index_of(&self, key: &K) -> Option<usize> {
		let index = self.entry_index(key.slot())?;
		(self.values[index].0 == *key).then_some(index)
	}
	pub(crate) fn contains_key(&self, key: &K) -> bool {
		self.get(key).is_some()
	}
	pub(crate) fn capacity_bytes(&self) -> usize {
		self.slots.capacity() * std::mem::size_of::<usize>()
			+ self.values.capacity() * std::mem::size_of::<(K, V)>()
	}
}

impl<K: SlotKey, V, S: SlotValues<(K, V)>> std::ops::Index<&K> for SlotIndexStorage<K, V, S> {
	type Output = V;
	fn index(&self, key: &K) -> &V {
		self.get(key).expect("indexed slot must be present")
	}
}

/// Reusable membership storage retaining the full generation of each key.
pub(crate) struct SlotSet<K>(SlotIndex<K, ()>);

impl<K: SlotKey> SlotSet<K> {
	pub(crate) fn new() -> Self {
		Self(SlotIndex::new())
	}
	pub(crate) fn clear(&mut self) {
		self.0.clear();
	}
	pub(crate) fn insert(&mut self, key: K) -> bool {
		self.0.insert(key, ()).is_none()
	}
	pub(crate) fn contains(&self, key: &K) -> bool {
		self.0.contains_key(key)
	}
	pub(crate) fn capacity_bytes(&self) -> usize {
		self.0.capacity_bytes()
	}
}

impl<K: SlotKey> FromIterator<K> for SlotSet<K> {
	fn from_iter<T: IntoIterator<Item = K>>(iter: T) -> Self {
		let mut result = Self::new();
		for key in iter {
			result.insert(key);
		}
		result
	}
}

#[cfg(test)]
mod tests {
	use super::*;
	#[test]
	fn paged_records_keep_their_addresses_and_reject_stale_generations() {
		let mut index = PagedSlotIndex::new();
		let first = MixtureHandle {
			slot: 0,
			generation: 1,
		};
		index.try_insert(first, [7_u8; 512]).unwrap();
		let address = std::ptr::from_ref(index.get(&first).unwrap());
		for slot in 1..2048 {
			index
				.try_insert(
					MixtureHandle {
						slot,
						generation: 1,
					},
					[slot as u8; 512],
				)
				.unwrap();
			assert_eq!(std::ptr::from_ref(index.get(&first).unwrap()), address);
		}
		let replacement = MixtureHandle {
			generation: 2,
			..first
		};
		assert_eq!(index.try_insert(replacement, [9; 512]).unwrap(), None);
		assert_eq!(index.get(&first), None);
		assert_eq!(index.index_of(&replacement), Some(0));
		let capacity = index.capacity_bytes();
		index.clear();
		index.try_insert(first, [1; 512]).unwrap();
		assert_eq!(index.get(&replacement), None);
		assert_eq!(index.capacity_bytes(), capacity);
		assert_eq!(std::ptr::from_ref(index.get(&first).unwrap()), address);
	}
	#[test]
	fn dense_positions_reject_stale_keys_and_remain_stable_until_clear() {
		let mut index = SlotIndex::new();
		let first = TurfHandle {
			slot: 900,
			generation: 1,
		};
		let second = TurfHandle {
			slot: 7,
			generation: 1,
		};
		index.insert(first, 10);
		let first_position = index.index_of(&first).unwrap();
		index.insert(second, 20);
		assert_eq!(index.index_of(&first), Some(first_position));
		let second_position = index.index_of(&second).unwrap();
		assert_ne!(first_position, second_position);
		assert!(first_position < 2 && second_position < 2);
		let replacement = TurfHandle {
			generation: 2,
			..first
		};
		index.insert(replacement, 30);
		assert_eq!(index.index_of(&first), None);
		assert_eq!(index.index_of(&replacement), Some(first_position));
		assert_eq!(index.index_of(&second), Some(second_position));
		index.clear();
		index.insert(second, 40);
		assert_eq!(index.index_of(&replacement), None);
		assert_eq!(index.index_of(&first), None);
		assert_eq!(index.index_of(&second), Some(0));
	}
	#[test]
	fn reuse_rejects_old_generations_and_clears_only_live_entries() {
		let mut index = SlotIndex::new();
		let old = MixtureHandle {
			slot: 100,
			generation: 1,
		};
		let new = MixtureHandle {
			generation: 2,
			..old
		};
		assert_eq!(index.insert(old, 3), None);
		assert_eq!(index.insert(old, 4), Some(3));
		let mut set = SlotSet::new();
		assert!(set.insert(old));
		assert!(!set.insert(old));
		assert!(set.insert(new));
		assert!(!set.contains(&old));
		index.insert(new, 7);
		assert_eq!(index.get(&old), None);
		assert_eq!(index.get(&new), Some(&7));
		let capacity = index.capacity_bytes();
		index.clear();
		assert_eq!(index.get(&new), None);
		index.insert(old, 9);
		assert_eq!(index.capacity_bytes(), capacity);
		assert_eq!(index.get(&old), Some(&9));
	}
	#[test]
	fn clear_does_not_alias_reused_dense_positions() {
		let mut index = SlotIndex::new();
		index.insert(100_u32, 1);
		index.clear();
		index.insert(200, 2);
		assert_eq!(index.get(&100), None);
		assert_eq!(index.insert(100, 3), None);
		assert_eq!(index.get(&200), Some(&2));
		assert_eq!(index.get(&100), Some(&3));
	}

	#[test]
	fn sparse_large_records_do_not_allocate_a_record_per_slot() {
		let mut index = SlotIndex::new();
		index.insert(10_000_u32, [7_u8; 512]);
		assert_eq!(index.get(&10_000), Some(&[7; 512]));
		assert!(index.capacity_bytes() < 200_000);
	}

	#[test]
	fn operations_match_an_independent_slot_map() {
		let mut index = SlotIndex::new();
		let mut reference = std::collections::BTreeMap::new();
		for step in 0..500_u32 {
			if step % 37 == 0 {
				index.clear();
				reference.clear();
			}
			let key = MixtureHandle {
				slot: (step * 17) % 23,
				generation: step % 3,
			};
			let expected = reference
				.insert(key.slot, (key, step))
				.and_then(|(old, value)| (old == key).then_some(value));
			assert_eq!(index.insert(key, step), expected);
			for slot in 0..23 {
				for generation in 0..3 {
					let query = MixtureHandle { slot, generation };
					let expected = reference
						.get(&slot)
						.and_then(|(key, value)| (*key == query).then_some(value));
					assert_eq!(index.get(&query), expected);
				}
			}
		}
	}
}
