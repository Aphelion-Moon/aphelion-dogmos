use dogmos_core::{
	metadata::{
		GasFireRole, GasId, GasMetadata, GasRequirement, NativeReactionKind, ReactionExecution,
		ReactionId, ReactionMetadata, TurfHandle,
	},
	world::{
		DogmosWorld, LifecycleAction, LifecycleMutation, MixtureStateMutation, StageChunkRequest,
		StageChunkResult, TurfLifecycleMutation, WorldError, WorldEvent, WorldStage,
	},
	MixtureHandle, MAX_GAS_SLOTS,
};

fn fixture(
	work_limit: u32,
	event_capacity: u32,
	continuation_capacity: u32,
	native_first: bool,
) -> (DogmosWorld, StageChunkRequest) {
	let mut world =
		DogmosWorld::new_with_capacities(1024 * 1024, event_capacity, continuation_capacity);
	world
		.install_gases(
			["o2", "hydrogen", "water_vapor"]
				.into_iter()
				.enumerate()
				.map(|(id, key)| GasMetadata {
					id: GasId(id as u16),
					key: key.into(),
					name: key.into(),
					flags: 0,
					specific_heat: 20.0,
					fusion_power: 0.0,
					moles_visible: None,
					enthalpy: 0.0,
					fire_radiation_released: 0.0,
					fire_role: GasFireRole::None,
					fire_products: None,
				})
				.collect(),
		)
		.unwrap();
	let mut reactions = Vec::new();
	if native_first {
		reactions.push(ReactionMetadata {
			id: ReactionId(0),
			key: "h2fire".into(),
			priority: 2.0,
			minimum_temperature: None,
			maximum_temperature: None,
			minimum_energy: None,
			minimum_fire_reagents: None,
			gas_requirements: vec![GasRequirement {
				gas: GasId(1),
				minimum_moles: 0.01,
			}]
			.into_boxed_slice(),
			execution: ReactionExecution::Native(NativeReactionKind::Hydrogen),
		});
	}
	reactions.push(ReactionMetadata {
		id: ReactionId(u32::from(native_first)),
		key: "dm_probe".into(),
		priority: 1.0,
		minimum_temperature: None,
		maximum_temperature: None,
		minimum_energy: None,
		minimum_fire_reagents: None,
		gas_requirements: vec![GasRequirement {
			gas: GasId(0),
			minimum_moles: 1.0,
		}]
		.into_boxed_slice(),
		execution: ReactionExecution::Dm,
	});
	world.install_reactions(reactions).unwrap();
	let turfs = [0, 1, 2].map(|slot| TurfHandle {
		slot,
		generation: 1,
	});
	for turf in turfs {
		let mixture = MixtureHandle {
			slot: turf.slot,
			generation: 1,
		};
		world
			.apply_lifecycle(&[LifecycleMutation {
				action: LifecycleAction::Register,
				handle: mixture,
			}])
			.unwrap();
		let mut gases = [0.0; MAX_GAS_SLOTS];
		gases[0] = 10.0;
		gases[1] = 1.0;
		world
			.apply_mixture_state(&[MixtureStateMutation {
				handle: mixture,
				expected_revision: 0,
				temperature: 500.0,
				volume: 2500.0,
				gases,
			}])
			.unwrap();
		world
			.apply_turf_lifecycle(&[TurfLifecycleMutation::Register {
				handle: turf,
				mixture: Some(mixture),
			}])
			.unwrap();
	}
	world.begin_frontier(1, 3).unwrap();
	world.append_frontier(1, 0, &turfs).unwrap();
	world.commit_frontier(1).unwrap();
	let request = StageChunkRequest {
		stage: WorldStage::React,
		frontier_epoch: 1,
		stage_epoch: 1,
		work_limit,
		seconds_per_tick: 0.5,
	};
	(world, request)
}

fn finish(
	world: &mut DogmosWorld,
	request: StageChunkRequest,
) -> Result<StageChunkResult, WorldError> {
	for _ in 0..32 {
		let result = world.process_stage_chunk_cancellable(request, || false)?;
		assert!(result.work_items <= request.work_limit);
		if !result.pending {
			return Ok(result);
		}
	}
	panic!("bounded three-target stage failed to finish");
}

fn snapshots(world: &DogmosWorld) -> Vec<dogmos_core::world::MixtureSnapshot> {
	(0..3)
		.map(|slot| {
			world
				.snapshot(MixtureHandle {
					slot,
					generation: 1,
				})
				.unwrap()
		})
		.collect()
}

fn check_frontier_coverage(work_limit: u32) {
	let (mut world, request) = fixture(work_limit, 64, 64, false);
	let mut visited = Vec::new();
	let mut completed = false;
	for _ in 0..32 {
		let result = world
			.process_stage_chunk_cancellable(request, || false)
			.unwrap();
		let mut events = Vec::new();
		while world.drain_events_into(64, &mut events) != 0 {
			for event in &events {
				if let WorldEvent::RunDmReaction {
					turf: Some(turf),
					continuation,
					..
				} = event
				{
					visited.push(turf.slot);
					world
						.resume_reaction_with_result_and_event_limit(*continuation, 0, 64)
						.unwrap();
				}
			}
		}
		if !result.pending {
			completed = true;
			break;
		}
	}
	assert!(
		completed,
		"reaction stage did not finish with work limit {work_limit}"
	);
	assert_eq!(
		visited,
		vec![0, 1, 2],
		"eligible turf callbacks with work limit {work_limit}"
	);
}

#[test]
fn reaction_frontier_visits_all_turfs_with_small_chunks() {
	check_frontier_coverage(1);
}

#[test]
fn reaction_frontier_visits_all_turfs_with_large_chunks() {
	check_frontier_coverage(4096);
}

#[test]
fn native_and_dm_events_preserve_target_order() {
	for work_limit in [1, 4096] {
		let (mut world, request) = fixture(work_limit, 8, 8, true);
		assert_eq!(finish(&mut world, request).unwrap().callback_events, 6);
		let mut events = Vec::new();
		assert_eq!(world.drain_events_into(8, &mut events), 6);
		let order: Vec<_> = events
			.iter()
			.map(|event| match event {
				WorldEvent::ReactionFinished {
					mixture,
					kind: NativeReactionKind::Hydrogen,
					..
				} => (mixture.slot, "native"),
				WorldEvent::RunDmReaction {
					mixture,
					reaction: ReactionId(1),
					..
				} => (mixture.slot, "dm"),
				other => panic!("unexpected event: {other:?}"),
			})
			.collect();
		assert_eq!(
			order,
			[
				(0, "native"),
				(0, "dm"),
				(1, "native"),
				(1, "dm"),
				(2, "native"),
				(2, "dm")
			]
		);
		for event in events {
			if let WorldEvent::RunDmReaction { continuation, .. } = event {
				world
					.resume_reaction_with_result_and_event_limit(continuation, 0, 8)
					.unwrap();
			}
		}
		assert_eq!(world.pending_reaction_continuations(), 0);
		for mixture in snapshots(&world) {
			assert!(mixture.gases[0] < 10.0 && mixture.gases[1] < 1.0);
			assert!(mixture.temperature.is_finite() && mixture.temperature > 500.0);
		}
	}
}

#[test]
fn event_capacity_rejection_preserves_all_targets_and_retry() {
	let (mut world, request) = fixture(1, 5, 8, true);
	let before = snapshots(&world);
	assert_eq!(
		finish(&mut world, request),
		Err(WorldError::EventCapacityExceeded {
			requested: 6,
			capacity: 5
		})
	);
	assert_eq!(snapshots(&world), before);
	assert_eq!(world.pending_reaction_continuations(), 0);
	assert!(world.pending_events(8).is_empty());
	assert_eq!(world.pending_stage_epoch(), None);
	world.begin_frontier(2, 1).unwrap();
	world
		.append_frontier(
			2,
			0,
			&[TurfHandle {
				slot: 0,
				generation: 1,
			}],
		)
		.unwrap();
	world.commit_frontier(2).unwrap();
	assert_eq!(
		finish(
			&mut world,
			StageChunkRequest {
				frontier_epoch: 2,
				stage_epoch: 2,
				..request
			}
		)
		.unwrap()
		.callback_events,
		2
	);
}

#[test]
fn continuation_capacity_rejection_releases_prepared_tokens() {
	let (mut world, request) = fixture(4096, 8, 2, true);
	let before = snapshots(&world);
	assert_eq!(
		finish(&mut world, request),
		Err(WorldError::ReactionContinuationCapacityExceeded)
	);
	assert_eq!(snapshots(&world), before);
	assert_eq!(world.pending_reaction_continuations(), 0);
	assert!(world.pending_events(8).is_empty());
	world.begin_frontier(2, 2).unwrap();
	world
		.append_frontier(
			2,
			0,
			&[
				TurfHandle {
					slot: 0,
					generation: 1,
				},
				TurfHandle {
					slot: 1,
					generation: 1,
				},
			],
		)
		.unwrap();
	world.commit_frontier(2).unwrap();
	assert_eq!(
		finish(
			&mut world,
			StageChunkRequest {
				frontier_epoch: 2,
				stage_epoch: 2,
				..request
			}
		)
		.unwrap()
		.callback_events,
		4
	);
	assert_eq!(world.pending_reaction_continuations(), 2);
}

#[test]
fn cancellation_at_every_prepublication_boundary_is_atomic_and_retryable() {
	let mut cancelled_cases = 0;
	let mut completed_cases = 0;
	for cutoff in 0..32 {
		let (mut world, request) = fixture(1, 8, 8, true);
		let before = snapshots(&world);
		let mut checks = 0;
		for _ in 0..32 {
			let result = world.process_stage_chunk_cancellable(request, || {
				let cancel = checks == cutoff;
				checks += 1;
				cancel
			});
			match result {
				Err(WorldError::Cancelled) => {
					cancelled_cases += 1;
					assert_eq!(snapshots(&world), before);
					assert!(world.pending_events(8).is_empty());
					assert_eq!(world.pending_reaction_continuations(), 0);
					assert_eq!(finish(&mut world, request).unwrap().callback_events, 6);
					break;
				}
				Ok(result) if result.pending => {
					assert_eq!(snapshots(&world), before);
					assert!(world.pending_events(8).is_empty());
					assert_eq!(world.pending_reaction_continuations(), 0);
				}
				Ok(result) => {
					assert_eq!(result.callback_events, 6);
					completed_cases += 1;
					break;
				}
				Err(error) => panic!("unexpected failure: {error:?}"),
			}
		}
	}
	assert!(cancelled_cases > 0 && completed_cases > 0);
	assert_eq!(cancelled_cases + completed_cases, 32);
}
