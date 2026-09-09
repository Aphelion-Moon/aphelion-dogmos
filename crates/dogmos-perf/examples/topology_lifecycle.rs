//! Matched service-core allocation and latency probe for single-layer turf updates.
use dogmos_core::{
	metadata::TurfHandle,
	world::{
		DogmosWorld, LifecycleAction, LifecycleMutation, TurfAdjacencyMutation,
		TurfHeatAdjacencyMutation, TurfHeatMutation, TurfHeatState, TurfLifecycleMutation,
	},
	MixtureHandle,
};
use std::{
	alloc::{GlobalAlloc, Layout, System},
	error::Error,
	fmt::Write as _,
	sync::atomic::{AtomicU64, Ordering},
	time::Instant,
};

struct Counter;
static ALLOCATIONS: AtomicU64 = AtomicU64::new(0);
static BYTES: AtomicU64 = AtomicU64::new(0);
#[global_allocator]
static ALLOCATOR: Counter = Counter;
unsafe impl GlobalAlloc for Counter {
	unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
		let pointer = unsafe { System.alloc(layout) };
		if !pointer.is_null() {
			ALLOCATIONS.fetch_add(1, Ordering::Relaxed);
			BYTES.fetch_add(layout.size() as u64, Ordering::Relaxed);
		}
		pointer
	}
	unsafe fn dealloc(&self, pointer: *mut u8, layout: Layout) {
		unsafe { System.dealloc(pointer, layout) }
	}
	unsafe fn realloc(&self, pointer: *mut u8, layout: Layout, size: usize) -> *mut u8 {
		let result = unsafe { System.realloc(pointer, layout, size) };
		if !result.is_null() {
			ALLOCATIONS.fetch_add(1, Ordering::Relaxed);
			BYTES.fetch_add(size as u64, Ordering::Relaxed);
		}
		result
	}
}

fn turf(slot: u32) -> TurfHandle {
	TurfHandle {
		slot,
		generation: 1,
	}
}
fn mixture(slot: u32) -> MixtureHandle {
	MixtureHandle {
		slot,
		generation: 1,
	}
}

fn main() -> Result<(), Box<dyn Error>> {
	let mut args = std::env::args_os().skip(1);
	if args.next().as_deref() != Some(std::ffi::OsStr::new("--output")) {
		return Err("usage: topology_lifecycle --output <csv>".into());
	}
	let output = args.next().ok_or("missing output path")?;
	if args.next().is_some() {
		return Err("unexpected argument".into());
	}
	let mut csv = String::from(
		"case,turfs,round,allocations,allocated_bytes,elapsed_ns,revision_delta,state_hash\n",
	);
	for count in [1_000, 10_000, 100_000] {
		for case in ["heat_reregister", "gas_reregister", "gas_clear_absent_heat"] {
			for round in 1..=3 {
				let gas = case != "heat_reregister";
				let mut world = DogmosWorld::new(512 * 1024 * 1024);
				if gas {
					world.apply_lifecycle(
						&(0..count)
							.map(|slot| LifecycleMutation {
								action: LifecycleAction::Register,
								handle: mixture(slot),
							})
							.collect::<Vec<_>>(),
					)?;
				}
				let registrations = (0..count)
					.map(|slot| TurfLifecycleMutation::Register {
						handle: turf(slot),
						mixture: gas.then_some(mixture(slot)),
					})
					.collect::<Vec<_>>();
				world.apply_turf_lifecycle(&registrations)?;
				let heat = (0..count)
					.map(|slot| TurfHeatMutation {
						handle: turf(slot),
						state: (!gas).then_some(TurfHeatState {
							temperature: 300.0,
							thermal_conductivity: 0.05,
							heat_capacity: 20_000.0,
							adjacent_to_space: false,
						}),
					})
					.collect::<Vec<_>>();
				world.apply_turf_heat(&heat)?;
				if gas {
					world.apply_turf_adjacency(
						&(1..count)
							.map(|slot| TurfAdjacencyMutation {
								left: turf(slot - 1),
								right: turf(slot),
								connected: true,
							})
							.collect::<Vec<_>>(),
					)?;
				} else {
					world.apply_turf_heat_adjacency(
						&(1..count)
							.map(|slot| TurfHeatAdjacencyMutation {
								left: turf(slot - 1),
								right: turf(slot),
								connected: true,
							})
							.collect::<Vec<_>>(),
					)?;
				}
				let revision = world.topology_revision();
				ALLOCATIONS.store(0, Ordering::Relaxed);
				BYTES.store(0, Ordering::Relaxed);
				let start = Instant::now();
				if case == "gas_clear_absent_heat" {
					world.apply_turf_heat(&heat)?;
				} else {
					world.apply_turf_lifecycle(&registrations)?;
				}
				let elapsed = start.elapsed().as_nanos();
				let allocations = ALLOCATIONS.load(Ordering::Relaxed);
				let bytes = BYTES.load(Ordering::Relaxed);
				let delta = world.topology_revision().wrapping_sub(revision);
				// Hash authoritative mixture/heat/ownership state; topology behavior has unit tests.
				let mut hash = 0xcbf2_9ce4_8422_2325_u64;
				for slot in 0..count {
					let state = format!(
						"{:?}|{:?}|{:?}",
						world.turf_mixture(turf(slot))?,
						world.turf_heat(turf(slot))?,
						if gas {
							Some(world.snapshot(mixture(slot))?)
						} else {
							None
						}
					);
					for byte in state.bytes() {
						hash ^= u64::from(byte);
						hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
					}
				}
				writeln!(
					csv,
					"{case},{count},{round},{allocations},{bytes},{elapsed},{delta},{hash}"
				)?;
			}
		}
	}
	std::fs::write(output, csv)?;
	Ok(())
}
