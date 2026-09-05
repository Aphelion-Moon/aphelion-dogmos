use crate::{metadata::TurfHandle, MixtureHandle};

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
pub(crate) struct SlotIndex<K, V> {
	slots: Vec<usize>,
	values: Vec<(K, V)>,
}

impl<K: SlotKey, V> SlotIndex<K, V> {
	pub(crate) fn new() -> Self {
		Self {
			slots: Vec::new(),
			values: Vec::new(),
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
		let slot = key.slot();
		if let Some(index) = self.entry_index(slot) {
			let (old, previous) = std::mem::replace(&mut self.values[index], (key, value));
			return (old == key).then_some(previous);
		}
		if slot >= self.slots.len() {
			self.slots.resize(slot + 1, usize::MAX);
		}
		self.slots[slot] = self.values.len();
		self.values.push((key, value));
		None
	}
	pub(crate) fn get(&self, key: &K) -> Option<&V> {
		let (stored, value) = &self.values[self.entry_index(key.slot())?];
		(stored == key).then_some(value)
	}
	pub(crate) fn contains_key(&self, key: &K) -> bool {
		self.get(key).is_some()
	}
	pub(crate) fn capacity_bytes(&self) -> usize {
		self.slots.capacity() * std::mem::size_of::<usize>()
			+ self.values.capacity() * std::mem::size_of::<(K, V)>()
	}
}

impl<K: SlotKey, V> std::ops::Index<&K> for SlotIndex<K, V> {
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
