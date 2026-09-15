//! Reusable storage whose payload pages stay in place as the workset grows.

use std::{
	collections::TryReserveError,
	ops::{Index, IndexMut},
};

const PAGE_LEN: usize = 256;

pub(crate) struct PagedVec<T> {
	pages: Vec<Box<[T]>>,
	len: usize,
}

impl<T: Clone> PagedVec<T> {
	pub(crate) fn new() -> Self {
		Self {
			pages: Vec::new(),
			len: 0,
		}
	}
	pub(crate) fn len(&self) -> usize {
		self.len
	}
	pub(crate) fn capacity(&self) -> usize {
		self.pages.len() * PAGE_LEN
	}
	pub(crate) fn clear(&mut self) {
		// Pages retain initialized records. World scratch uses records without owned
		// heap payloads, so clearing and overwriting do not defer hidden destructor work.
		self.len = 0;
	}
	pub(crate) fn get(&self, index: usize) -> Option<&T> {
		(index < self.len).then(|| &self.pages[index / PAGE_LEN][index % PAGE_LEN])
	}
	pub(crate) fn try_push(&mut self, value: T) -> Result<(), TryReserveError> {
		let page = self.len / PAGE_LEN;
		let offset = self.len % PAGE_LEN;
		if page == self.pages.len() {
			// Only the small directory may move. Never relocate an accumulated gas
			// column; allocate and initialize at most one fixed-size payload page.
			self.pages.try_reserve(1)?;
			let mut values = Vec::new();
			values.try_reserve_exact(PAGE_LEN)?;
			values.resize(PAGE_LEN, value);
			self.pages.push(values.into_boxed_slice());
		} else {
			self.pages[page][offset] = value;
		}
		self.len += 1;
		Ok(())
	}
	#[cfg(test)]
	fn iter(&self) -> impl Iterator<Item = &T> {
		self.pages
			.iter()
			.flat_map(|page| page.iter())
			.take(self.len)
	}
}

impl<T> Index<usize> for PagedVec<T> {
	type Output = T;
	fn index(&self, index: usize) -> &T {
		assert!(index < self.len, "paged workset index out of bounds");
		&self.pages[index / PAGE_LEN][index % PAGE_LEN]
	}
}
impl<T> IndexMut<usize> for PagedVec<T> {
	fn index_mut(&mut self, index: usize) -> &mut T {
		assert!(index < self.len, "paged workset index out of bounds");
		&mut self.pages[index / PAGE_LEN][index % PAGE_LEN]
	}
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn growth_keeps_existing_rows_in_place_and_preserves_index_order() {
		let mut rows = PagedVec::new();
		rows.try_push([7_u8; 128]).unwrap();
		let first = std::ptr::from_ref(&rows[0]);
		for index in 1..(PAGE_LEN * 5 + 17) {
			rows.try_push([index as u8; 128]).unwrap();
			assert_eq!(std::ptr::from_ref(&rows[0]), first);
		}
		for index in 1..rows.len() {
			assert_eq!(rows[index], [index as u8; 128]);
		}
		assert_eq!(rows.iter().count(), rows.len());
		assert!(rows.capacity() - rows.len() < PAGE_LEN);
	}

	#[test]
	fn clear_reuses_pages_without_exposing_previous_rows() {
		let mut rows = PagedVec::new();
		for index in 0..(PAGE_LEN * 3) {
			rows.try_push(index).unwrap();
		}
		let capacity = rows.capacity();
		let first = std::ptr::from_ref(&rows[0]);
		rows.clear();
		assert_eq!(rows.len(), 0);
		assert_eq!(rows.iter().count(), 0);
		rows.try_push(99).unwrap();
		assert_eq!(rows.iter().copied().collect::<Vec<_>>(), [99]);
		assert_eq!(rows.capacity(), capacity);
		assert_eq!(std::ptr::from_ref(&rows[0]), first);
		rows[0] = 123;
		assert_eq!(rows[0], 123);
	}
}
