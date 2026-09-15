// This is a core diagnostic, not a DreamDaemon or main-server performance gate.
#[allow(dead_code)]
#[path = "support/core_workload.rs"]
mod core_workload;

use core_workload::*;
use dogmos_core::{
	metadata::{ReactionExecution, ReactionId, ReactionMetadata},
	stage_job::{JobProgress, StageJobSpec},
	world::{DogmosWorld, StageChunkRequest, TurfHeatMutation, TurfHeatState, WorldStage},
};
use std::{error::Error, fmt::Write as _, fs, path::PathBuf, time::Instant};

const MAX_STEPS: usize = 2_097_152;

struct Sample {
	phase: &'static str,
	elapsed_ns: u128,
	workset_bytes: u64,
}

struct Probe {
	samples: Vec<Sample>,
	hash: u64,
	synchronous_hash: u64,
}

fn spec(world: &DogmosWorld, stage: WorldStage) -> Result<StageJobSpec, Box<dyn Error>> {
	Ok(StageJobSpec {
		stage,
		stage_epoch: 1,
		frontier_epoch: world.committed_frontier_epoch().ok_or("missing frontier")?,
		seconds_per_tick: 0.5,
	})
}

fn fixture(
	count: usize,
	topology: Topology,
	stage: WorldStage,
) -> Result<DogmosWorld, Box<dyn Error>> {
	let reactions = if stage == WorldStage::React {
		vec![ReactionMetadata {
			id: ReactionId(0),
			key: "job_publication_probe".into(),
			priority: 1.0,
			minimum_temperature: None,
			maximum_temperature: None,
			minimum_energy: None,
			minimum_fire_reagents: None,
			gas_requirements: Box::new([]),
			execution: ReactionExecution::Dm,
		}]
	} else {
		vec![]
	};
	let mut world = build_world_with_reactions(count, topology, reactions)?;
	if stage == WorldStage::TurfHeat {
		// Exercise linked-gas candidates, including their unpublished cleanup. Ambient
		// temperatures from the shared corpus never enter that branch.
		world.apply_turf_heat(
			&(0..count)
				.map(|slot| TurfHeatMutation {
					handle: turf(slot),
					state: Some(TurfHeatState {
						temperature: 1200.0,
						thermal_conductivity: 0.05,
						heat_capacity: 20_000.0,
						adjacent_to_space: slot % 97 == 0,
					}),
				})
				.collect::<Vec<_>>(),
		)?;
	}
	Ok(world)
}

fn measure_job(
	world: &mut DogmosWorld,
	spec: StageJobSpec,
	samples: &mut Vec<Sample>,
	maximum: usize,
) -> Result<(), Box<dyn Error>> {
	for _ in 0..maximum {
		let start = Instant::now();
		// One core work item exposes unaccounted setup/teardown inside that call too.
		let progress = world.prepare_job_chunk(spec, 1, || false, || false)?;
		let elapsed_ns = start.elapsed().as_nanos();
		samples.push(Sample {
			phase: "prepare",
			elapsed_ns,
			workset_bytes: world.reusable_workset_bytes(),
		});
		match progress {
			JobProgress::Ready { unit } => {
				let start = Instant::now();
				world.commit_job_unit(unit)?;
				let elapsed_ns = start.elapsed().as_nanos();
				samples.push(Sample {
					phase: "commit",
					elapsed_ns,
					workset_bytes: world.reusable_workset_bytes(),
				});
			}
			JobProgress::Done => return Ok(()),
			JobProgress::Running => {}
			JobProgress::Retrying => {
				return Err("unexpected retry without an external writer".into())
			}
		}
	}
	Err("stage job exceeded diagnostic sample limit".into())
}

fn run_probe(count: usize, topology: Topology, stage: WorldStage) -> Result<Probe, Box<dyn Error>> {
	let mut world = fixture(count, topology, stage)?;
	let mut oracle = fixture(count, topology, stage)?;
	let spec = spec(&world, stage)?;
	let mut samples = Vec::new();
	measure_job(&mut world, spec, &mut samples, MAX_STEPS)?;
	let hash = transcript_hash(&mut world, stage, topology, count, None, false)?;
	let request = StageChunkRequest {
		stage,
		stage_epoch: 1,
		frontier_epoch: spec.frontier_epoch,
		seconds_per_tick: 0.5,
		work_limit: STAGE_WORK_LIMIT,
	};
	let mut finished = false;
	for _ in 0..MAX_STEPS {
		if !oracle
			.process_stage_chunk_cancellable(request, || false)?
			.pending
		{
			finished = true;
			break;
		}
	}
	if !finished {
		return Err("synchronous oracle exceeded diagnostic limit".into());
	}
	let synchronous_hash = transcript_hash(&mut oracle, stage, topology, count, None, false)?;
	if hash != synchronous_hash
		|| world.pending_reaction_continuations() != oracle.pending_reaction_continuations()
	{
		return Err("job transcript differs from synchronous execution".into());
	}
	drop(world);
	drop(oracle);
	let prepare_calls = samples
		.iter()
		.filter(|sample| sample.phase == "prepare")
		.count();
	// Inspect cancellation during discovery/computation and at the publication boundary.
	for cutoff in [
		Some(0),
		Some(1),
		Some(64),
		Some(256),
		Some(1024),
		Some(prepare_calls / 2),
		Some(prepare_calls * 3 / 4),
		None,
	] {
		let mut cancelled = fixture(count, topology, stage)?;
		let original = transcript_hash(&mut cancelled, stage, topology, count, None, false)?;
		let mut ready = false;
		for _ in 0..cutoff.unwrap_or(MAX_STEPS) {
			match cancelled.prepare_job_chunk(spec, 1, || false, || false)? {
				JobProgress::Ready { .. } => {
					ready = true;
					break;
				}
				JobProgress::Running => {}
				_ => return Err("cancellation fixture bypassed its first publication".into()),
			}
		}
		if cutoff.is_none() && !ready {
			return Err("cancellation preparation exceeded diagnostic limit".into());
		}
		let start = Instant::now();
		cancelled.cancel_job_unpublished();
		let elapsed_ns = start.elapsed().as_nanos();
		samples.push(Sample {
			phase: "cancel",
			elapsed_ns,
			workset_bytes: cancelled.reusable_workset_bytes(),
		});
		if cancelled.pending_stage_epoch().is_some()
			|| cancelled.pending_reaction_continuations() != 0
			|| original != transcript_hash(&mut cancelled, stage, topology, count, None, false)?
		{
			return Err("cancellation changed authoritative state".into());
		}
	}
	Ok(Probe {
		samples,
		hash,
		synchronous_hash,
	})
}

fn main() -> Result<(), Box<dyn Error>> {
	use std::io::Write as _;
	let mut args = std::env::args_os().skip(1);
	if args.next().as_deref() != Some(std::ffi::OsStr::new("--output")) {
		return Err("usage: stage_job_latency --output <path> [--turfs 2..100000] [--stage name] [--topology name] [--rounds 1..3]".into());
	}
	let output = PathBuf::from(args.next().ok_or("--output requires a path")?);
	let mut count = 1000;
	let mut rounds = 3;
	let mut selected_stage = None;
	let mut selected_topology = None;
	while let Some(flag) = args.next() {
		let value = args
			.next()
			.ok_or("option requires a value")?
			.into_string()
			.map_err(|_| "invalid argument encoding")?;
		match flag.to_str() {
			Some("--turfs") => count = value.parse::<usize>()?,
			Some("--rounds") => rounds = value.parse::<usize>()?,
			Some("--stage") => {
				selected_stage = Some(
					STAGES
						.into_iter()
						.find(|&stage| stage_name(stage) == value)
						.ok_or("unknown stage")?,
				)
			}
			Some("--topology") => {
				selected_topology = Some(
					TOPOLOGIES
						.into_iter()
						.find(|&topology| topology.name() == value)
						.ok_or("unknown topology")?,
				)
			}
			_ => return Err("unexpected argument".into()),
		}
	}
	if !(2..=100_000).contains(&count) || !(1..=3).contains(&rounds) {
		return Err("invalid diagnostic arguments".into());
	}
	if count > 4096 && selected_stage.is_none_or(|stage| stage == WorldStage::React) {
		return Err("the reaction fixture has 4096 continuation slots; select a non-reaction stage for larger worlds".into());
	}
	if let Some(parent) = output.parent().filter(|p| !p.as_os_str().is_empty()) {
		fs::create_dir_all(parent)?;
	}
	if output.exists() {
		return Err("diagnostic summary already exists; choose a fresh output path".into());
	}
	let mut raw = std::io::BufWriter::new(
		fs::OpenOptions::new()
			.write(true)
			.create_new(true)
			.open(output.with_extension("samples.csv"))?,
	);
	writeln!(
		raw,
		"stage,topology,turfs,round,index,phase,elapsed_ns,retained_workset_bytes_lower_bound,scenario"
	)?;
	let mut summary = String::from("stage,topology,turfs,round,phase,samples,total_ns,max_ns,hash,synchronous_hash,performance_accepted,scenario\n");
	for topology in TOPOLOGIES {
		if selected_topology.is_some_and(|selected| selected.name() != topology.name()) {
			continue;
		}
		for stage in STAGES {
			if selected_stage.is_some_and(|selected| selected != stage) {
				continue;
			}
			for round in 1..=rounds {
				let scenario = if stage == WorldStage::TurfHeat {
					"linked_heat_1200k"
				} else {
					"standard"
				};
				let probe = run_probe(count, topology, stage)?;
				for (index, sample) in probe.samples.iter().enumerate() {
					writeln!(
						raw,
						"{},{},{count},{round},{index},{},{},{},{scenario}",
						stage_name(stage),
						topology.name(),
						sample.phase,
						sample.elapsed_ns,
						sample.workset_bytes
					)?;
				}
				for phase in ["prepare", "commit", "cancel"] {
					let mut total = 0;
					let mut maximum = 0;
					let mut count_samples = 0;
					for sample in probe.samples.iter().filter(|sample| sample.phase == phase) {
						count_samples += 1;
						total += sample.elapsed_ns;
						maximum = maximum.max(sample.elapsed_ns);
					}
					writeln!(summary, "{},{},{count},{round},{phase},{count_samples},{total},{maximum},{},{},false,{scenario}", stage_name(stage), topology.name(), probe.hash, probe.synchronous_hash)?;
				}
			}
		}
	}
	raw.flush()?;
	// A summary exists only after every bounded run and transcript check succeeds.
	fs::write(output, summary)?;
	Ok(())
}

#[cfg(test)]
mod tests {
	use super::*;

	#[test]
	fn probe_compares_published_state_and_measures_each_phase_separately() {
		for stage in STAGES {
			let result = run_probe(8, Topology::Corridor, stage).unwrap();
			assert_eq!(result.hash, result.synchronous_hash);
			assert!(result.samples.iter().any(|s| s.phase == "prepare"));
			assert!(result.samples.iter().any(|s| s.phase == "commit"));
			assert_eq!(
				result
					.samples
					.iter()
					.filter(|s| s.phase == "cancel")
					.count(),
				8
			);
			assert!(result.samples.iter().any(|s| s.workset_bytes > 0));
		}
	}

	#[test]
	fn a_sample_limit_fails_without_claiming_completion() {
		let mut world = build_world(8, Topology::Corridor).unwrap();
		let spec = spec(&world, WorldStage::ProcessTurfs).unwrap();
		assert!(measure_job(&mut world, spec, &mut Vec::new(), 1).is_err());
		assert_eq!(world.snapshot(mixture(0)).unwrap().total_moles, 5.0);
		assert!(world.pending_events(8).is_empty());
	}
}
