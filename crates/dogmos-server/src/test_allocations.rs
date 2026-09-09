//! Thread-local allocation measurements for synchronous service operations.
use std::{
	alloc::{GlobalAlloc, Layout, System},
	cell::Cell,
};

#[derive(Clone, Copy, Debug, Default)]
pub(crate) struct Allocations {
	pub calls: u64,
	pub bytes: u64,
}

thread_local! {
	static ACTIVE: Cell<Option<Allocations>> = const { Cell::new(None) };
}

struct CountingAllocator;
#[global_allocator]
static ALLOCATOR: CountingAllocator = CountingAllocator;

fn record(bytes: usize) {
	let _ = ACTIVE.try_with(|active| {
		if let Some(mut count) = active.get() {
			count.calls += 1;
			count.bytes += bytes as u64;
			active.set(Some(count));
		}
	});
}

unsafe impl GlobalAlloc for CountingAllocator {
	unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
		let result = unsafe { System.alloc(layout) };
		if !result.is_null() {
			record(layout.size());
		}
		result
	}
	unsafe fn dealloc(&self, pointer: *mut u8, layout: Layout) {
		unsafe { System.dealloc(pointer, layout) }
	}
	unsafe fn realloc(&self, pointer: *mut u8, layout: Layout, size: usize) -> *mut u8 {
		let result = unsafe { System.realloc(pointer, layout, size) };
		if !result.is_null() {
			record(size);
		}
		result
	}
}

pub(crate) fn measure<T>(operation: impl FnOnce() -> T) -> (T, Allocations) {
	struct Reset;
	impl Drop for Reset {
		fn drop(&mut self) {
			ACTIVE.with(|active| active.set(None));
		}
	}
	ACTIVE.with(|active| {
		assert!(active.get().is_none(), "nested allocation measurement");
		active.set(Some(Allocations::default()));
	});
	let _reset = Reset;
	let result = operation();
	let counts = ACTIVE.with(|active| active.get().unwrap());
	(result, counts)
}
