#[path = "support/core_workload.rs"]
mod core_workload;

use core_workload::*;
use dogmos_core::world::{
	DogmosWorld, LifecycleAction, LifecycleMutation, StageChunkRequest, WorldStage,
};
use std::{
	alloc::{GlobalAlloc, Layout, System},
	error::Error,
	fmt::Write as _,
	fs,
	path::PathBuf,
	sync::atomic::{AtomicU64, Ordering},
};

struct CountingAllocator;

static LIVE_BYTES: AtomicU64 = AtomicU64::new(0);
static PEAK_LIVE_BYTES: AtomicU64 = AtomicU64::new(0);

static ALLOCATIONS: AtomicU64 = AtomicU64::new(0);
static DEALLOCATIONS: AtomicU64 = AtomicU64::new(0);
static ALLOCATED_BYTES: AtomicU64 = AtomicU64::new(0);
static DEALLOCATED_BYTES: AtomicU64 = AtomicU64::new(0);

#[global_allocator]
static GLOBAL_ALLOCATOR: CountingAllocator = CountingAllocator;

unsafe impl GlobalAlloc for CountingAllocator {
	unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
		let pointer = unsafe { System.alloc(layout) };
		if !pointer.is_null() {
			ALLOCATIONS.fetch_add(1, Ordering::Relaxed);
			ALLOCATED_BYTES.fetch_add(layout.size() as u64, Ordering::Relaxed);
			let live = LIVE_BYTES.fetch_add(layout.size() as u64, Ordering::Relaxed)
				+ layout.size() as u64;
			PEAK_LIVE_BYTES.fetch_max(live, Ordering::Relaxed);
		}
		pointer
	}

	unsafe fn dealloc(&self, pointer: *mut u8, layout: Layout) {
		DEALLOCATIONS.fetch_add(1, Ordering::Relaxed);
		DEALLOCATED_BYTES.fetch_add(layout.size() as u64, Ordering::Relaxed);
		LIVE_BYTES.fetch_sub(layout.size() as u64, Ordering::Relaxed);
		unsafe { System.dealloc(pointer, layout) }
	}

	unsafe fn realloc(&self, pointer: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
		let result = unsafe { System.realloc(pointer, layout, new_size) };
		if result.is_null() {
			return result;
		}
		DEALLOCATIONS.fetch_add(1, Ordering::Relaxed);
		DEALLOCATED_BYTES.fetch_add(layout.size() as u64, Ordering::Relaxed);
		ALLOCATIONS.fetch_add(1, Ordering::Relaxed);
		ALLOCATED_BYTES.fetch_add(new_size as u64, Ordering::Relaxed);
		LIVE_BYTES.fetch_sub(layout.size() as u64, Ordering::Relaxed);
		let live = LIVE_BYTES.fetch_add(new_size as u64, Ordering::Relaxed) + new_size as u64;
		PEAK_LIVE_BYTES.fetch_max(live, Ordering::Relaxed);
		result
	}
}

#[derive(Clone, Copy)]
struct AllocationSnapshot {
	allocations: u64,
	deallocations: u64,
	allocated_bytes: u64,
	deallocated_bytes: u64,
}

struct AllocationRecord {
	round: u64,
	peak_live_bytes: u64,
	max_chunk_ns: u128,
	stage: &'static str,
	topology: &'static str,
	turf_count: usize,
	allocation: AllocationSnapshot,
	work_items: u64,
	transcript_hash: u64,
	baseline_transcript_hash: u64,
	peak_active_vec_capacity_bytes_lower_bound: u64,
	post_stage_retained_vec_capacity_bytes_lower_bound: u64,
}

fn main() -> Result<(), Box<dyn Error>> {
	let (output_path, baseline) = output_path()?;
	let baseline = baseline.map(fs::read_to_string).transpose()?;
	let mut records = Vec::new();
	for turf_count in TURF_COUNTS {
		for topology in TOPOLOGIES {
			for stage in STAGES {
				let mut world = build_world(turf_count, topology)?;
				for round in 1..=3 {
					reset_allocation_counters();
					let (work_items, peak_active_vec_capacity_bytes_lower_bound, max_chunk_ns) =
						run_stage(&mut world, stage, round)?;
					let allocation = allocation_snapshot();
					let post_stage_retained_vec_capacity_bytes_lower_bound =
						world.reusable_workset_bytes();
					let peak_live_bytes = PEAK_LIVE_BYTES.load(Ordering::Relaxed);
					let baseline_work = baseline.as_ref().and_then(|csv| {
						csv.lines().skip(1).find_map(|line| {
							let fields: Vec<_> = line.split(',').collect();
							(fields.len() >= 9
								&& fields[0] == stage_name(stage)
								&& fields[1] == topology.name()
								&& fields[2].parse::<usize>().ok() == Some(turf_count))
							.then(|| fields[7].parse::<u64>().ok())
							.flatten()
						})
					});
					let baseline_transcript_hash = transcript_hash(
						&mut world,
						stage,
						topology,
						turf_count,
						baseline_work,
						false,
					)?;
					let transcript_hash =
						transcript_hash(&mut world, stage, topology, turf_count, None, true)?;
					records.push(AllocationRecord {
						round,
						max_chunk_ns,
						peak_live_bytes,
						baseline_transcript_hash,
						stage: stage_name(stage),
						topology: topology.name(),
						turf_count,
						allocation,
						work_items,
						transcript_hash,
						peak_active_vec_capacity_bytes_lower_bound,
						post_stage_retained_vec_capacity_bytes_lower_bound,
					});
				}
			}
		}
	}
	write_sparse_updates(output_path.with_extension("updates.csv"))?;
	write_records(output_path, &records)?;
	Ok(())
}

fn output_path() -> Result<(PathBuf, Option<PathBuf>), Box<dyn Error>> {
	let mut arguments = std::env::args_os().skip(1);
	if arguments.next().as_deref() != Some(std::ffi::OsStr::new("--output")) {
		return Err("usage: core_stage_allocations --output <path>".into());
	}
	let path = arguments.next().ok_or("--output requires a path")?;
	let baseline = match arguments.next() {
		None => None,
		Some(flag) if flag == "--baseline" => {
			Some(arguments.next().ok_or("--baseline requires a CSV")?.into())
		}
		_ => return Err("unexpected trailing arguments".into()),
	};
	if arguments.next().is_some() {
		return Err("unexpected trailing arguments".into());
	}
	Ok((path.into(), baseline))
}

fn reset_allocation_counters() {
	PEAK_LIVE_BYTES.store(LIVE_BYTES.load(Ordering::Relaxed), Ordering::Relaxed);
	ALLOCATIONS.store(0, Ordering::Relaxed);
	DEALLOCATIONS.store(0, Ordering::Relaxed);
	ALLOCATED_BYTES.store(0, Ordering::Relaxed);
	DEALLOCATED_BYTES.store(0, Ordering::Relaxed);
}

fn allocation_snapshot() -> AllocationSnapshot {
	AllocationSnapshot {
		allocations: ALLOCATIONS.load(Ordering::Relaxed),
		deallocations: DEALLOCATIONS.load(Ordering::Relaxed),
		allocated_bytes: ALLOCATED_BYTES.load(Ordering::Relaxed),
		deallocated_bytes: DEALLOCATED_BYTES.load(Ordering::Relaxed),
	}
}

fn run_stage(
	world: &mut DogmosWorld,
	stage: WorldStage,
	epoch: u64,
) -> Result<(u64, u64, u128), Box<dyn Error>> {
	let mut max_chunk_ns = 0;
	let request = StageChunkRequest {
		stage,
		frontier_epoch: world.committed_frontier_epoch().ok_or("missing frontier")?,
		stage_epoch: epoch,
		work_limit: STAGE_WORK_LIMIT,
		seconds_per_tick: 0.5,
	};
	let mut work_items = 0_u64;
	let mut peak_active_vec_capacity_bytes_lower_bound = world.reusable_workset_bytes();
	loop {
		let started = std::time::Instant::now();
		let result = world.process_stage_chunk_cancellable(request, || false)?;
		max_chunk_ns = max_chunk_ns.max(started.elapsed().as_nanos());
		work_items += u64::from(result.work_items);
		peak_active_vec_capacity_bytes_lower_bound =
			peak_active_vec_capacity_bytes_lower_bound.max(world.reusable_workset_bytes());
		if !result.pending {
			return Ok((
				work_items,
				peak_active_vec_capacity_bytes_lower_bound,
				max_chunk_ns,
			));
		}
	}
}

fn write_records(path: PathBuf, records: &[AllocationRecord]) -> Result<(), Box<dyn Error>> {
	if let Some(parent) = path.parent() {
		fs::create_dir_all(parent)?;
	}
	let mut output = String::from(
		"stage,topology,turf_count,allocations,deallocations,allocated_bytes,deallocated_bytes,work_items,transcript_hash,peak_active_vec_capacity_bytes_lower_bound,post_stage_retained_vec_capacity_bytes_lower_bound,round,peak_live_bytes,max_chunk_ns,baseline_transcript_hash\n",
	);
	for record in records {
		writeln!(
			output,
			"{},{},{},{},{},{},{},{},{:016x},{},{},{},{},{},{:016x}",
			record.stage,
			record.topology,
			record.turf_count,
			record.allocation.allocations,
			record.allocation.deallocations,
			record.allocation.allocated_bytes,
			record.allocation.deallocated_bytes,
			record.work_items,
			record.transcript_hash,
			record.peak_active_vec_capacity_bytes_lower_bound,
			record.post_stage_retained_vec_capacity_bytes_lower_bound,
			record.round,
			record.peak_live_bytes,
			record.max_chunk_ns,
			record.baseline_transcript_hash,
		)?;
	}
	fs::write(path, output)?;
	Ok(())
}

fn write_sparse_updates(path: PathBuf) -> Result<(), Box<dyn Error>> {
	let mut output = String::from(
		"operation,turf_count,allocations,allocated_bytes,peak_live_bytes,elapsed_ns\n",
	);
	for count in TURF_COUNTS {
		let mut world = build_world(count, Topology::Corridor)?;
		let removed: Vec<_> = (count / 2..count / 2 + 16).map(turf).collect();
		let untouched = world.snapshot(mixture(count - 1))?;
		reset_allocation_counters();
		let started = std::time::Instant::now();
		world.remove_frontier(2, &removed)?;
		let elapsed = started.elapsed().as_nanos();
		let allocations = allocation_snapshot();
		let peak = PEAK_LIVE_BYTES.load(Ordering::Relaxed);
		writeln!(
			output,
			"frontier_remove,{count},{},{},{peak},{elapsed}",
			allocations.allocations, allocations.allocated_bytes
		)?;
		assert_eq!(world.committed_frontier().len(), count - removed.len());
		let mutations: Vec<_> = removed
			.iter()
			.map(|handle| LifecycleMutation {
				action: LifecycleAction::Unregister,
				handle: mixture(handle.slot as usize),
			})
			.collect();
		reset_allocation_counters();
		let started = std::time::Instant::now();
		world.apply_lifecycle(&mutations)?;
		let elapsed = started.elapsed().as_nanos();
		let allocations = allocation_snapshot();
		let peak = PEAK_LIVE_BYTES.load(Ordering::Relaxed);
		writeln!(
			output,
			"mixture_unregister,{count},{},{},{peak},{elapsed}",
			allocations.allocations, allocations.allocated_bytes
		)?;
		for mutation in mutations {
			assert!(world.snapshot(mutation.handle).is_err());
		}
		assert_eq!(world.snapshot(mixture(count - 1))?, untouched);
	}
	if let Some(parent) = path.parent() {
		fs::create_dir_all(parent)?;
	}
	fs::write(path, output)?;
	Ok(())
}
