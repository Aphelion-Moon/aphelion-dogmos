use dogmos_core::{
	world::{DogmosWorld, LifecycleAction, LifecycleMutation, WorldError},
	MixtureHandle,
};
use std::{
	alloc::{GlobalAlloc, Layout, System},
	cell::Cell,
};

struct FailingAllocator;

thread_local! {
	static REJECT_ALLOCATIONS: Cell<bool> = const { Cell::new(false) };
}

#[global_allocator]
static ALLOCATOR: FailingAllocator = FailingAllocator;

unsafe impl GlobalAlloc for FailingAllocator {
	unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
		if REJECT_ALLOCATIONS.get() {
			std::ptr::null_mut()
		} else {
			System.alloc(layout)
		}
	}
	unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
		if REJECT_ALLOCATIONS.get() {
			std::ptr::null_mut()
		} else {
			System.alloc_zeroed(layout)
		}
	}
	unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, size: usize) -> *mut u8 {
		if REJECT_ALLOCATIONS.get() {
			std::ptr::null_mut()
		} else {
			System.realloc(ptr, layout, size)
		}
	}
	unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
		System.dealloc(ptr, layout);
	}
}

fn without_allocations<T>(operation: impl FnOnce() -> T) -> T {
	struct Reset;
	impl Drop for Reset {
		fn drop(&mut self) {
			REJECT_ALLOCATIONS.set(false);
		}
	}
	REJECT_ALLOCATIONS.set(true);
	let _reset = Reset;
	operation()
}

fn handle(slot: u32, generation: u32) -> MixtureHandle {
	MixtureHandle { slot, generation }
}

#[test]
fn failed_arena_reservation_leaves_identity_and_length_unchanged_for_retry() {
	let mut world = DogmosWorld::new(1024 * 1024);
	let source = handle(0, 1);
	world
		.apply_lifecycle(&[LifecycleMutation {
			action: LifecycleAction::Register,
			handle: source,
		}])
		.unwrap();
	let destination = handle(1024, 1);
	let error =
		without_allocations(|| world.create_mixture_from_source(destination, source, 125.0));
	assert!(matches!(error, Err(WorldError::AllocationFailed(_))));
	assert_eq!(world.slot_count(), 1);
	assert!(matches!(
		world.create_mixture_from_source(handle(1, 1), destination, 2500.0),
		Err(WorldError::UnknownHandle(_))
	));
	world
		.create_mixture_from_source(destination, source, 125.0)
		.unwrap();
	assert_eq!(world.slot_count(), 1025);
}

#[test]
fn recycled_creation_requires_no_allocation() {
	let mut world = DogmosWorld::new(1024 * 1024);
	for source in [handle(0, 1), handle(1, 1)] {
		world
			.apply_lifecycle(&[LifecycleMutation {
				action: LifecycleAction::Register,
				handle: source,
			}])
			.unwrap();
	}
	world
		.apply_lifecycle(&[LifecycleMutation {
			action: LifecycleAction::Unregister,
			handle: handle(1, 1),
		}])
		.unwrap();
	without_allocations(|| world.create_mixture_from_source(handle(1, 2), handle(0, 1), 125.0))
		.unwrap();
	assert_eq!(world.slot_count(), 2);
}
