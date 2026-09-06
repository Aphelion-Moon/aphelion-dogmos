// Reuse the stage corpus's setup; other stage helpers are unused by this probe.
#[allow(dead_code)]
#[path = "support/core_workload.rs"]
mod core_workload;

use core_workload::{build_world_with_reactions, mixture, turf, Topology};
use dogmos_core::metadata::{ReactionExecution, ReactionId, ReactionMetadata};
use dogmos_core::world::{
	LifecycleAction, LifecycleMutation, ReactionContinuationToken, StageChunkRequest,
	TurfLifecycleMutation, WorldError, WorldEvent, WorldStage,
};
use std::{error::Error, fmt::Write as _, fs, path::PathBuf, time::Instant};

#[derive(Clone, Copy)]
enum Case {
	MixtureUnregister,
	MixtureReplace,
	TurfUnregister,
	TurfReassign,
	TurfNoop,
}
const CASES: [Case; 5] = [
	Case::MixtureUnregister,
	Case::MixtureReplace,
	Case::TurfUnregister,
	Case::TurfReassign,
	Case::TurfNoop,
];
impl Case {
	fn name(self) -> &'static str {
		match self {
			Self::MixtureUnregister => "mixture_unregister",
			Self::MixtureReplace => "mixture_replace",
			Self::TurfUnregister => "turf_unregister",
			Self::TurfReassign => "turf_reassign",
			Self::TurfNoop => "turf_noop",
		}
	}
}

struct Observation {
	mutations: usize,
	pending: u32,
	hash: u64,
	elapsed_ns: u128,
}

fn run_case(
	count: usize,
	mutation_count: usize,
	case: Case,
) -> Result<Observation, Box<dyn Error>> {
	let mut world = build_world_with_reactions(
		count,
		Topology::Corridor,
		vec![ReactionMetadata {
			id: ReactionId(0),
			key: "dm_lifecycle_probe".into(),
			priority: 1.0,
			minimum_temperature: None,
			maximum_temperature: None,
			minimum_energy: None,
			minimum_fire_reagents: None,
			gas_requirements: Box::new([]),
			execution: ReactionExecution::Dm,
		}],
	)?;
	let request = StageChunkRequest {
		stage: WorldStage::React,
		stage_epoch: 1,
		frontier_epoch: 1,
		work_limit: 4096,
		seconds_per_tick: 0.5,
	};
	let mut completed = false;
	for _ in 0..8192 {
		let chunk = world.process_stage_chunk_cancellable(request, || false)?;
		assert!(chunk.work_items <= request.work_limit);
		if !chunk.pending {
			completed = true;
			break;
		}
	}
	assert!(completed);
	let mut events = Vec::new();
	assert_eq!(world.drain_events_into(u32::MAX, &mut events), count as u32);
	let tokens = events
		.iter()
		.enumerate()
		.map(|(index, event)| match *event {
			WorldEvent::RunDmReaction {
				turf: Some(actual_turf),
				mixture: actual_mixture,
				continuation,
				..
			} => {
				assert_eq!(actual_turf, turf(index));
				assert_eq!(actual_mixture, mixture(index));
				assert_eq!(
					continuation,
					ReactionContinuationToken {
						slot: index as u32,
						generation: 1
					}
				);
				continuation
			}
			other => panic!("unexpected event {other:?}"),
		})
		.collect::<Vec<_>>();
	assert_eq!(world.pending_reaction_continuations(), count as u32);
	// Reverse owner order distinguishes mutation order from arena slot order.
	let owners = (0..count)
		.step_by(2)
		.rev()
		.take(mutation_count)
		.collect::<Vec<_>>();
	let mut invalidated = vec![false; count];
	if !matches!(case, Case::TurfNoop) {
		for &owner in &owners {
			invalidated[owner] = true;
		}
	}
	let mixture_mutations = owners
		.iter()
		.map(|&slot| LifecycleMutation {
			action: if matches!(case, Case::MixtureReplace) {
				LifecycleAction::Register
			} else {
				LifecycleAction::Unregister
			},
			handle: dogmos_core::MixtureHandle {
				slot: slot as u32,
				generation: if matches!(case, Case::MixtureReplace) {
					2
				} else {
					1
				},
			},
		})
		.collect::<Vec<_>>();
	let turf_mutations = owners
		.iter()
		.map(|&slot| match case {
			Case::TurfUnregister => TurfLifecycleMutation::Unregister { handle: turf(slot) },
			_ => TurfLifecycleMutation::Register {
				handle: turf(slot),
				mixture: Some(mixture(if matches!(case, Case::TurfReassign) {
					1
				} else {
					slot
				})),
			},
		})
		.collect::<Vec<_>>();
	let start = Instant::now();
	let applied = match case {
		Case::MixtureUnregister | Case::MixtureReplace => {
			world.apply_lifecycle(&mixture_mutations)?
		}
		_ => world.apply_turf_lifecycle(&turf_mutations)?,
	};
	let elapsed_ns = start.elapsed().as_nanos();
	assert_eq!(applied as usize, owners.len());
	let pending = world.pending_reaction_continuations();
	let invalid_count = if matches!(case, Case::TurfNoop) {
		0
	} else {
		owners.len()
	};
	assert_eq!(pending as usize, count - invalid_count);
	let mut hash = 0xcbf2_9ce4_8422_2325_u64;
	let mut hash_value = |value: &str| {
		for byte in value.bytes() {
			hash ^= u64::from(byte);
			hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
		}
	};
	for (index, &token) in tokens.iter().enumerate() {
		if invalidated[index] {
			assert_eq!(
				world.cancel_reaction(token),
				Err(WorldError::UnknownReactionContinuation(token))
			);
		}
		let handle = dogmos_core::MixtureHandle {
			slot: index as u32,
			generation: if invalidated[index] && matches!(case, Case::MixtureReplace) {
				2
			} else {
				1
			},
		};
		hash_value(&format!(
			"{:?}{:?}",
			world.snapshot(handle),
			world.turf_mixture(turf(index))
		));
	}
	for &owner in owners.iter().rev().take(invalid_count) {
		world.react_mixture_with_event_limit(mixture(1), turf(1).into(), None, count as u32)?;
		assert_eq!(world.drain_events_into(u32::MAX, &mut events), 1);
		let token = match events[0] {
			WorldEvent::RunDmReaction { continuation, .. } => continuation,
			other => panic!("unexpected event {other:?}"),
		};
		assert_eq!(
			token,
			ReactionContinuationToken {
				slot: owner as u32,
				generation: 2
			}
		);
		hash_value(&format!("{:?}", events));
	}
	for (index, token) in tokens.into_iter().enumerate() {
		if !invalidated[index] {
			let result =
				world.resume_reaction_with_result_and_event_limit(token, 0, count as u32)?;
			assert!(!result.pending);
			hash_value(&format!("{result:?}"));
		}
	}
	assert_eq!(
		world.pending_reaction_continuations() as usize,
		invalid_count
	);
	Ok(Observation {
		mutations: owners.len(),
		pending,
		hash,
		elapsed_ns,
	})
}

fn main() -> Result<(), Box<dyn Error>> {
	let mut args = std::env::args_os().skip(1);
	if args.next().as_deref() != Some(std::ffi::OsStr::new("--output")) {
		return Err("usage: continuation_lifecycle --output <path>".into());
	}
	let output = PathBuf::from(args.next().ok_or("--output requires a path")?);
	if args.next().is_some() {
		return Err("unexpected trailing arguments".into());
	}
	let mut csv =
		String::from("case,continuations,mutations,pending_after,transcript_hash,elapsed_ns\n");
	for count in [1000, 10_000] {
		for mutation_count in [1, count / 2] {
			for case in CASES {
				let result = run_case(count, mutation_count, case)?;
				writeln!(
					csv,
					"{},{count},{},{},{},{}",
					case.name(),
					result.mutations,
					result.pending,
					result.hash,
					result.elapsed_ns
				)?;
			}
		}
	}
	if let Some(parent) = output.parent().filter(|p| !p.as_os_str().is_empty()) {
		fs::create_dir_all(parent)?;
	}
	fs::write(output, csv)?;
	Ok(())
}

#[cfg(test)]
mod tests {
	use super::*;
	#[test]
	fn workload_exercises_invalidation_and_preserving_noops() {
		for (mutations, expected) in [(1, [3, 3, 3, 3, 4]), (2, [2, 2, 2, 2, 4])] {
			for (case, pending) in CASES.into_iter().zip(expected) {
				let result = run_case(4, mutations, case).unwrap();
				assert_eq!(result.mutations, mutations);
				assert_eq!(result.pending, pending);
			}
		}
	}
}
