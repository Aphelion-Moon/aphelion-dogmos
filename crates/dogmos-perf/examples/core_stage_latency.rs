#[path = "support/core_workload.rs"]
mod core_workload;

#[path = "support/thread_cycles.rs"]
mod thread_cycles;

use core_workload::*;
use dogmos_core::world::{DogmosWorld, StageChunkRequest, WorldStage};
use std::{error::Error, fmt::Write as _, fs, path::PathBuf, time::Instant};

const MAX_CHUNKS: usize = 8192;

#[derive(Debug, PartialEq, Eq)]
struct SampleSummary {
	count: usize,
	total: u128,
	p50: u128,
	p95: u128,
	p99: u128,
	max: u128,
}

impl SampleSummary {
	fn summarize(samples: &mut [u128]) -> Option<Self> {
		if samples.is_empty() {
			return None;
		}
		samples.sort_unstable();
		let percentile = |percent: usize| samples[(samples.len() * percent).div_ceil(100) - 1];
		Some(Self {
			count: samples.len(),
			total: samples.iter().sum(),
			p50: percentile(50),
			p95: percentile(95),
			p99: percentile(99),
			max: *samples.last().unwrap(),
		})
	}
}

fn main() -> Result<(), Box<dyn Error>> {
	let mut args = std::env::args_os().skip(1);
	if args.next().as_deref() != Some(std::ffi::OsStr::new("--output")) {
		return Err("usage: core_stage_latency --output <path> [--thread-cycles]".into());
	}
	let output = PathBuf::from(args.next().ok_or("--output requires a path")?);
	let measure_cycles = match args.next() {
		None => false,
		Some(flag) if flag == "--thread-cycles" => true,
		_ => return Err("unexpected trailing arguments".into()),
	};
	if args.next().is_some() {
		return Err("unexpected trailing arguments".into());
	}
	if measure_cycles {
		thread_cycles::current()?;
	}
	let mut csv = String::from("stage,topology,turf_count,round,work_items,transcript_hash,chunks,stage_ns,p50_chunk_ns,p95_chunk_ns,p99_chunk_ns,max_chunk_ns,stage_thread_cycles,p50_chunk_thread_cycles,p95_chunk_thread_cycles,p99_chunk_thread_cycles,max_chunk_thread_cycles\n");
	let mut samples = Vec::with_capacity(MAX_CHUNKS);
	let mut cycle_samples = Vec::with_capacity(if measure_cycles { MAX_CHUNKS } else { 0 });
	let mut chunk_csv = measure_cycles
		.then(|| String::from("stage,topology,turf_count,round,chunk,elapsed_ns,thread_cycles\n"));
	for count in TURF_COUNTS {
		for topology in TOPOLOGIES {
			for stage in STAGES {
				let mut world = build_world(count, topology)?;
				for round in 1..=3 {
					samples.clear();
					cycle_samples.clear();
					let work = run_stage(
						&mut world,
						stage,
						round,
						&mut samples,
						measure_cycles.then_some(&mut cycle_samples),
					)?;
					if let Some(output) = &mut chunk_csv {
						for (index, (wall, cycles)) in
							samples.iter().zip(&cycle_samples).enumerate()
						{
							writeln!(
								output,
								"{},{},{count},{round},{index},{wall},{cycles}",
								stage_name(stage),
								topology.name()
							)?;
						}
					}
					let timings = SampleSummary::summarize(&mut samples)
						.ok_or("stage produced no samples")?;
					let hash = transcript_hash(&mut world, stage, topology, count, None, true)?;
					write!(
						csv,
						"{},{},{count},{round},{work},{hash},{},{},{},{},{},{}",
						stage_name(stage),
						topology.name(),
						timings.count,
						timings.total,
						timings.p50,
						timings.p95,
						timings.p99,
						timings.max
					)?;
					if let Some(cycles) = SampleSummary::summarize(&mut cycle_samples) {
						writeln!(
							csv,
							",{},{},{},{},{}",
							cycles.total, cycles.p50, cycles.p95, cycles.p99, cycles.max
						)?;
					} else {
						writeln!(csv, ",,,,,")?;
					}
				}
			}
		}
	}
	if let Some(parent) = output.parent().filter(|p| !p.as_os_str().is_empty()) {
		fs::create_dir_all(parent)?;
	}
	if let Some(chunks) = chunk_csv {
		fs::write(output.with_extension("chunks.csv"), chunks)?;
	}
	fs::write(output, csv)?;
	Ok(())
}

fn run_stage(
	world: &mut DogmosWorld,
	stage: WorldStage,
	epoch: u64,
	samples: &mut Vec<u128>,
	mut cycle_samples: Option<&mut Vec<u128>>,
) -> Result<u64, Box<dyn Error>> {
	let request = StageChunkRequest {
		stage,
		stage_epoch: epoch,
		frontier_epoch: world.committed_frontier_epoch().ok_or("missing frontier")?,
		work_limit: STAGE_WORK_LIMIT,
		seconds_per_tick: 0.5,
	};
	let mut work = 0;
	for _ in 0..MAX_CHUNKS {
		let cycles_before = if cycle_samples.is_some() {
			Some(thread_cycles::current()?)
		} else {
			None
		};
		let start = Instant::now();
		let chunk = world.process_stage_chunk_cancellable(request, || false)?;
		let elapsed = start.elapsed().as_nanos();
		if let (Some(before), Some(output)) = (cycles_before, cycle_samples.as_mut()) {
			output.push(u128::from(thread_cycles::elapsed(
				before,
				thread_cycles::current()?,
			)?));
		}
		samples.push(elapsed);
		if chunk.work_items > request.work_limit {
			return Err("stage exceeded chunk work limit".into());
		}
		work += u64::from(chunk.work_items);
		if !chunk.pending {
			return Ok(work);
		}
	}
	Err("stage exceeded benchmark chunk capacity".into())
}

#[cfg(test)]
mod tests {
	use super::*;

	#[cfg(windows)]
	#[test]
	fn cycle_diagnostics_record_every_timed_chunk() {
		// More turfs than the chunk work limit forces the driver to resume.
		let mut world = build_world(4097, Topology::Corridor).unwrap();
		let mut wall = Vec::with_capacity(MAX_CHUNKS);
		let mut cycles = Vec::with_capacity(MAX_CHUNKS);
		run_stage(
			&mut world,
			WorldStage::React,
			1,
			&mut wall,
			Some(&mut cycles),
		)
		.unwrap();
		assert!(wall.len() > 1);
		assert_eq!(wall.len(), cycles.len());
		assert!(cycles.iter().any(|&value| value > 0));
		// The fixture's empty reaction inventory leaves both ends unchanged.
		assert_eq!(world.snapshot(mixture(0)).unwrap().total_moles, 5.0);
		assert_eq!(world.snapshot(mixture(4096)).unwrap().total_moles, 21.0);
	}

	#[test]
	fn timed_driver_executes_a_conservative_diffusion_step() {
		let mut world = build_world(2, Topology::Corridor).unwrap();
		let mut samples = Vec::with_capacity(MAX_CHUNKS);
		let work = run_stage(&mut world, WorldStage::ProcessTurfs, 1, &mut samples, None).unwrap();
		assert!(work > 0);
		assert!(!samples.is_empty());
		assert!(samples.len() <= MAX_CHUNKS);
		let left = world.snapshot(mixture(0)).unwrap();
		let right = world.snapshot(mixture(1)).unwrap();
		assert_eq!((left.total_moles, right.total_moles), (5.125, 5.875));
		assert_eq!((left.revision, right.revision), (2, 2));
		assert_eq!(world.pending_stage_epoch(), None);
	}

	#[test]
	fn percentiles_use_nearest_rank_and_preserve_total() {
		let mut samples: Vec<_> = (1..=100).rev().collect();
		assert_eq!(
			SampleSummary::summarize(&mut samples),
			Some(SampleSummary {
				count: 100,
				total: 5050,
				p50: 50,
				p95: 95,
				p99: 99,
				max: 100,
			})
		);
	}

	#[test]
	fn short_samples_do_not_interpolate_or_invent_data() {
		assert_eq!(SampleSummary::summarize(&mut []), None);
		let summary = SampleSummary::summarize(&mut [1000, 1, 1]).unwrap();
		assert_eq!(summary.count, 3);
		assert_eq!(summary.total, 1002);
		assert_eq!(summary.p50, 1);
		assert_eq!(summary.p95, 1000);
		assert_eq!(summary.p99, 1000);
		assert_eq!(summary.max, 1000);
		let singleton = SampleSummary::summarize(&mut [7]).unwrap();
		assert_eq!(singleton.total, 7);
		assert_eq!(
			(singleton.p50, singleton.p95, singleton.p99, singleton.max),
			(7, 7, 7, 7)
		);
	}
}
