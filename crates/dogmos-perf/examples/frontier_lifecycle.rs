//! Matched frontier mutation plus first-consumer probe. Setup and oracle checks are untimed.
use dogmos_core::{
	metadata::TurfHandle,
	world::{DogmosWorld, StageChunkRequest, TurfLifecycleMutation, WorldStage},
};
use std::{
	alloc::{GlobalAlloc, Layout, System},
	error::Error,
	fmt::Write as _,
	hint::black_box,
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

fn measure<T>(operation: impl FnOnce() -> T) -> (T, u64, u64, u128) {
	ALLOCATIONS.store(0, Ordering::Relaxed);
	BYTES.store(0, Ordering::Relaxed);
	let start = Instant::now();
	let result = operation();
	let elapsed = start.elapsed().as_nanos();
	let allocations = ALLOCATIONS.load(Ordering::Relaxed);
	let bytes = BYTES.load(Ordering::Relaxed);
	(result, allocations, bytes, elapsed)
}

fn turf(slot: u32) -> TurfHandle {
	TurfHandle {
		slot,
		generation: 1,
	}
}

fn main() -> Result<(), Box<dyn Error>> {
	let mut args = std::env::args_os().skip(1);
	if args.next().as_deref() != Some(std::ffi::OsStr::new("--output")) {
		return Err("usage: frontier_lifecycle --output <csv>".into());
	}
	let output = args.next().ok_or("missing output path")?;
	if args.next().is_some() {
		return Err("unexpected argument".into());
	}
	let mut csv =
		String::from("case,turfs,round,phase,allocations,allocated_bytes,elapsed_ns,state_hash,consumer_work,consumer_chunks\n");
	for count in [1_000, 10_000, 100_000] {
		for case in [
			"initial_read",
			"add16",
			"remove16",
			"remove75pct",
			"remove_readd16",
			"remove_burst64",
			"first_chunk",
			"full_stage",
			"burst_first_chunk",
			"burst_full_stage",
		] {
			for round in 1..=3 {
				let mut world = DogmosWorld::new(512 * 1024 * 1024);
				world.apply_turf_lifecycle(
					&(0..count + 16)
						.map(|slot| TurfLifecycleMutation::Register {
							handle: turf(slot),
							mixture: None,
						})
						.collect::<Vec<_>>(),
				)?;
				let initial = (0..count).map(turf).collect::<Vec<_>>();
				world.begin_frontier(1, count)?;
				world.append_frontier(1, 0, &initial)?;
				world.commit_frontier(1)?;
				if case != "initial_read" {
					assert_eq!(world.committed_frontier(), initial);
				}
				let removed = match case {
					"remove75pct" => (0..count * 3 / 4).map(turf).collect::<Vec<_>>(),
					"remove_burst64" | "burst_first_chunk" | "burst_full_stage" => {
						(0..512).map(turf).collect()
					}
					_ => (count / 2..count / 2 + 16).map(turf).collect(),
				};
				let added = (count..count + 16).map(turf).collect::<Vec<_>>();
				let mut epoch = 1;
				let (result, ma, mb, mt) = measure(|| -> Result<(), Box<dyn Error>> {
					match case {
						"initial_read" => {}
						"add16" => {
							epoch += 1;
							world.add_frontier(epoch, &added)?;
						}
						"remove_burst64" | "burst_first_chunk" | "burst_full_stage" => {
							for chunk in removed.chunks(8) {
								epoch += 1;
								world.remove_frontier(epoch, chunk)?;
							}
						}
						_ => {
							epoch += 1;
							world.remove_frontier(epoch, &removed)?;
							if case == "remove_readd16" {
								epoch += 1;
								world.add_frontier(epoch, &removed)?;
							}
						}
					}
					Ok(())
				});
				result?;
				let mut consumer_work = 0_u64;
				let mut consumer_chunks = 0_u64;
				let (result, ra, rb, rt) = measure(|| -> Result<(), Box<dyn Error>> {
					if case.ends_with("chunk") || case.ends_with("stage") {
						let full_stage = case.ends_with("stage");
						loop {
							let result = world.process_stage_chunk_cancellable(
								StageChunkRequest {
									stage: WorldStage::ProcessTurfs,
									frontier_epoch: epoch,
									stage_epoch: 1,
									work_limit: if full_stage { 64 } else { 1 },
									seconds_per_tick: 0.5,
								},
								|| false,
							)?;
							consumer_work += u64::from(result.work_items);
							consumer_chunks += 1;
							if !full_stage {
								assert_eq!(result.work_items, 1);
								assert!(result.pending);
								break;
							}
							if !result.pending {
								break;
							}
							assert!(consumer_chunks < u64::from(count) * 4);
						}
					} else {
						black_box(world.committed_frontier());
					}
					Ok(())
				});
				result?;
				// Independent ordered-vector oracle, including surviving order and re-add-at-end.
				let mut expected = initial;
				match case {
					"initial_read" => {}
					"add16" => expected.extend_from_slice(&added),
					_ => {
						let removed_set = removed
							.iter()
							.copied()
							.collect::<std::collections::HashSet<_>>();
						expected.retain(|handle| !removed_set.contains(handle));
						if case == "remove_readd16" {
							expected.extend_from_slice(&removed);
						}
					}
				}
				assert_eq!(world.committed_frontier(), expected);
				let hash = expected
					.iter()
					.fold(0xcbf29ce484222325_u64, |hash, handle| {
						handle
							.slot
							.to_le_bytes()
							.into_iter()
							.chain(handle.generation.to_le_bytes())
							.fold(hash, |hash, byte| {
								(hash ^ u64::from(byte)).wrapping_mul(0x100000001b3)
							})
					});
				for (phase, allocations, bytes, elapsed) in
					[("mutation", ma, mb, mt), ("consumer", ra, rb, rt)]
				{
					writeln!(csv, "{case},{count},{round},{phase},{allocations},{bytes},{elapsed},{hash:016x},{consumer_work},{consumer_chunks}")?;
				}
			}
		}
	}
	std::fs::write(output, csv)?;
	Ok(())
}
