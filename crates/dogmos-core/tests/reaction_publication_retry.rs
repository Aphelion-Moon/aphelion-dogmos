use dogmos_core::{
	metadata::{
		GameplayHandle, GasFireRole, GasId, GasMetadata, GasRequirement, NativeReactionKind,
		ReactionExecution, ReactionId, ReactionMetadata, TurfHandle,
	},
	world::{
		Command, DogmosWorld, LifecycleAction, LifecycleMutation, MixtureSnapshot,
		MixtureStateMutation, ReactionContinuationToken, ReactionProgress, StageChunkRequest,
		TurfLifecycleMutation, WorldError, WorldEvent, WorldStage,
	},
	MixtureHandle, MAX_GAS_SLOTS,
};

#[derive(Debug, PartialEq)]
enum NormalizedReactionEvent {
	Finished {
		mixture: MixtureHandle,
		target: GameplayHandle,
		reaction: ReactionId,
		kind: NativeReactionKind,
		values: [f32; 4],
	},
	Dm {
		turf: Option<TurfHandle>,
		mixture: MixtureHandle,
		target: GameplayHandle,
		reaction: ReactionId,
	},
}

fn snapshots(world: &DogmosWorld, mixtures: &[MixtureHandle; 3]) -> Vec<MixtureSnapshot> {
	mixtures
		.iter()
		.map(|mixture| world.snapshot(*mixture).unwrap())
		.collect()
}

fn complete_stage(world: &mut DogmosWorld, request: StageChunkRequest) {
	let mut completed = false;
	for _ in 0..64 {
		let chunk = world
			.process_stage_chunk_cancellable(request, || false)
			.expect("quiet reaction inputs must eventually publish");
		assert!(chunk.work_items <= request.work_limit);
		if !chunk.pending {
			completed = true;
			break;
		}
	}
	assert!(
		completed,
		"reaction stage did not finish within its bounded retries"
	);
}

fn drain_and_resume_reactions(
	world: &mut DogmosWorld,
) -> (Vec<NormalizedReactionEvent>, Vec<ReactionProgress>) {
	let mut events = Vec::new();
	assert_eq!(world.drain_events_into(16, &mut events), 6);
	let mut normalized = Vec::with_capacity(events.len());
	let mut resume_progress = Vec::new();
	for event in events {
		match event {
			WorldEvent::ReactionFinished {
				mixture,
				target,
				reaction,
				kind,
				values,
			} => normalized.push(NormalizedReactionEvent::Finished {
				mixture,
				target,
				reaction,
				kind,
				values,
			}),
			WorldEvent::RunDmReaction {
				turf,
				mixture,
				target,
				reaction,
				continuation,
			} => {
				normalized.push(NormalizedReactionEvent::Dm {
					turf,
					mixture,
					target,
					reaction,
				});
				assert_ne!(continuation, ReactionContinuationToken::default());
				resume_progress.push(
					world
						.resume_reaction_with_result_and_event_limit(continuation, 0, 16)
						.unwrap(),
				);
				assert_eq!(
					world.resume_reaction_with_result_and_event_limit(continuation, 0, 16),
					Err(WorldError::UnknownReactionContinuation(continuation))
				);
			}
			other => panic!("unexpected reaction event: {other:?}"),
		}
	}
	assert_eq!(world.pending_reaction_continuations(), 0);
	assert!(world.pending_events(16).is_empty());
	(normalized, resume_progress)
}

fn fixture() -> (DogmosWorld, StageChunkRequest, [MixtureHandle; 3]) {
	let mut world = DogmosWorld::new_with_capacities(1024 * 1024, 16, 16);
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
	world
		.install_reactions(vec![
			ReactionMetadata {
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
			},
			ReactionMetadata {
				id: ReactionId(1),
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
			},
		])
		.unwrap();

	let turfs = [0, 1, 2].map(|slot| TurfHandle {
		slot,
		generation: 1,
	});
	let mixtures = turfs.map(|turf| MixtureHandle {
		slot: turf.slot,
		generation: 1,
	});
	world
		.apply_lifecycle(&mixtures.map(|handle| LifecycleMutation {
			action: LifecycleAction::Register,
			handle,
		}))
		.unwrap();
	for mixture in mixtures {
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
	}
	world
		.apply_turf_lifecycle(&turfs.map(|turf| TurfLifecycleMutation::Register {
			handle: turf,
			mixture: Some(mixtures[turf.slot as usize]),
		}))
		.unwrap();
	world.begin_frontier(1, turfs.len() as u32).unwrap();
	world.append_frontier(1, 0, &turfs).unwrap();
	world.commit_frontier(1).unwrap();
	(
		world,
		StageChunkRequest {
			stage: WorldStage::React,
			frontier_epoch: 1,
			stage_epoch: 1,
			work_limit: 1,
			seconds_per_tick: 0.5,
		},
		mixtures,
	)
}

#[test]
fn accepted_write_retries_mixed_native_and_dm_reaction_publication() {
	let (mut world, request, mixtures) = fixture();
	for _ in 0..4 {
		assert!(
			world
				.process_stage_chunk_cancellable(request, || false)
				.unwrap()
				.pending
		);
	}

	assert_eq!(
		world
			.apply_command(Command::SetMoles {
				handle: mixtures[0],
				gas: GasId(0),
				amount: 20.0,
			})
			.unwrap(),
		dogmos_core::world::CommandResult::Applied { updated: 1 }
	);
	assert_eq!(world.snapshot(mixtures[0]).unwrap().gases[0], 20.0);

	let retry = world
		.process_stage_chunk_cancellable(request, || false)
		.expect("an accepted write must make reaction publication retryable");
	assert!(retry.pending);
	assert_eq!(world.pending_stage_epoch(), Some(request.stage_epoch));
	assert_eq!(world.pending_reaction_continuations(), 0);
	assert!(world.pending_events(16).is_empty());
	assert_eq!(
		mixtures.map(|mixture| world.snapshot(mixture).unwrap().gases[0]),
		[20.0, 10.0, 10.0]
	);
	let conflict_retry = world
		.process_stage_chunk_cancellable(request, || false)
		.expect("publication conflict must become a bounded retry");
	assert!(conflict_retry.pending);
	assert_eq!(world.pending_stage_epoch(), Some(request.stage_epoch));
	assert_eq!(world.pending_reaction_continuations(), 0);
	assert!(world.pending_events(16).is_empty());
	assert_eq!(
		mixtures.map(|mixture| world.snapshot(mixture).unwrap().gases[0]),
		[20.0, 10.0, 10.0]
	);
	assert_eq!(
		world.process_stage_chunk_cancellable(request, || true),
		Err(WorldError::Cancelled)
	);
	assert_eq!(world.pending_stage_epoch(), None);
	assert_eq!(world.pending_reaction_continuations(), 0);
	assert!(world.pending_events(16).is_empty());
	assert_eq!(world.snapshot(mixtures[0]).unwrap().gases[0], 20.0);

	let mut completed = false;
	for _ in 0..32 {
		let chunk = world
			.process_stage_chunk_cancellable(request, || false)
			.expect("quiet reaction inputs must eventually publish");
		assert!(chunk.work_items <= request.work_limit);
		if !chunk.pending {
			completed = true;
			break;
		}
	}
	assert!(completed);

	let mut events = Vec::new();
	assert_eq!(world.drain_events_into(16, &mut events), 6);
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
	assert_eq!(world.pending_reaction_continuations(), 3);
	for event in events {
		if let WorldEvent::RunDmReaction { continuation, .. } = event {
			assert_ne!(continuation, ReactionContinuationToken::default());
			world
				.resume_reaction_with_event_limit(continuation, 16)
				.unwrap();
			assert_eq!(
				world.resume_reaction_with_event_limit(continuation, 16),
				Err(WorldError::UnknownReactionContinuation(continuation))
			);
		}
	}
	assert_eq!(world.pending_reaction_continuations(), 0);
	assert_eq!(world.snapshot(mixtures[0]).unwrap().gases[0], 19.75);
}

#[test]
fn repeated_accepted_writes_retry_without_duplicate_events() {
	let (mut world, request, mixtures) = fixture();
	for (mixture, amount) in [(mixtures[0], 20.0), (mixtures[0], 30.0)] {
		for _ in 0..4 {
			assert!(
				world
					.process_stage_chunk_cancellable(request, || false)
					.unwrap()
					.pending
			);
		}
		assert_eq!(
			world
				.apply_command(Command::SetMoles {
					handle: mixture,
					gas: GasId(0),
					amount,
				})
				.unwrap(),
			dogmos_core::world::CommandResult::Applied { updated: 1 }
		);
		assert!(
			world
				.process_stage_chunk_cancellable(request, || false)
				.unwrap()
				.pending
		);
		assert!(
			world
				.process_stage_chunk_cancellable(request, || false)
				.unwrap()
				.pending
		);
		assert_eq!(world.pending_reaction_continuations(), 0);
		assert!(world.pending_events(16).is_empty());
		assert_eq!(world.snapshot(mixture).unwrap().gases[0], amount);
	}

	let mut completed = false;
	for _ in 0..64 {
		let chunk = world
			.process_stage_chunk_cancellable(request, || false)
			.expect("reaction stage did not finish after repeated writes");
		if !chunk.pending {
			completed = true;
			break;
		}
	}
	assert!(completed);
	let mut events = Vec::new();
	assert_eq!(world.drain_events_into(16, &mut events), 6);
	assert_eq!(world.pending_reaction_continuations(), 3);
	for event in events {
		if let WorldEvent::RunDmReaction { continuation, .. } = event {
			world
				.resume_reaction_with_event_limit(continuation, 16)
				.unwrap();
			assert_eq!(
				world.resume_reaction_with_event_limit(continuation, 16),
				Err(WorldError::UnknownReactionContinuation(continuation))
			);
		}
	}
	assert_eq!(world.pending_reaction_continuations(), 0);
	assert_eq!(world.snapshot(mixtures[0]).unwrap().gases[0], 29.75);
	assert_eq!(world.snapshot(mixtures[2]).unwrap().gases[0], 9.75);
}

#[test]
fn accepted_write_retry_matches_reference_started_after_write() {
	let (mut retrying, request, mixtures) = fixture();
	for _ in 0..4 {
		assert!(
			retrying
				.process_stage_chunk_cancellable(request, || false)
				.unwrap()
				.pending
		);
	}
	retrying
		.apply_command(Command::SetMoles {
			handle: mixtures[0],
			gas: GasId(0),
			amount: 20.0,
		})
		.unwrap();
	assert!(
		retrying
			.process_stage_chunk_cancellable(request, || false)
			.unwrap()
			.pending
	);
	let conflict_retry = retrying
		.process_stage_chunk_cancellable(request, || false)
		.expect("accepted write must retry publication without exposing a partial result");
	assert!(conflict_retry.pending);
	assert_eq!(retrying.pending_reaction_continuations(), 0);
	assert!(retrying.pending_events(16).is_empty());
	complete_stage(&mut retrying, request);
	let retrying_snapshots = snapshots(&retrying, &mixtures);
	let (retrying_events, retrying_resume_progress) = drain_and_resume_reactions(&mut retrying);

	let (mut reference, reference_request, reference_mixtures) = fixture();
	reference
		.apply_command(Command::SetMoles {
			handle: reference_mixtures[0],
			gas: GasId(0),
			amount: 20.0,
		})
		.unwrap();
	complete_stage(&mut reference, reference_request);
	let reference_snapshots = snapshots(&reference, &reference_mixtures);
	let (reference_events, reference_resume_progress) = drain_and_resume_reactions(&mut reference);

	assert_eq!(retrying_snapshots, reference_snapshots);
	assert_eq!(retrying_events, reference_events);
	assert_eq!(retrying_resume_progress, reference_resume_progress);
}

#[test]
fn retry_preserves_existing_continuation_exclusion_and_single_use_tokens() {
	let (mut world, request, mixtures) = fixture();
	let holder = GameplayHandle::from(TurfHandle {
		slot: 0,
		generation: 1,
	});
	assert!(
		world
			.react_mixture_with_event_limit(mixtures[0], holder, None, 16)
			.unwrap()
			.pending
	);
	let mut prior_events = Vec::new();
	assert_eq!(world.drain_events_into(16, &mut prior_events), 2);
	let prior_token = match prior_events.as_slice() {
		[WorldEvent::ReactionFinished { .. }, WorldEvent::RunDmReaction { continuation, .. }] => {
			*continuation
		}
		other => panic!("unexpected prior reaction events: {other:?}"),
	};
	assert_eq!(world.pending_reaction_continuations(), 1);

	for _ in 0..5 {
		assert!(
			world
				.process_stage_chunk_cancellable(request, || false)
				.unwrap()
				.pending
		);
	}
	world
		.apply_command(Command::SetMoles {
			handle: mixtures[1],
			gas: GasId(0),
			amount: 20.0,
		})
		.unwrap();
	assert!(
		world
			.process_stage_chunk_cancellable(request, || false)
			.unwrap()
			.pending
	);
	assert_eq!(world.pending_reaction_continuations(), 1);
	assert!(world.pending_events(16).is_empty());

	let mut completed = false;
	for _ in 0..64 {
		let chunk = world
			.process_stage_chunk_cancellable(request, || false)
			.expect("quiet retry with an active continuation must finish");
		if !chunk.pending {
			completed = true;
			break;
		}
	}
	assert!(completed);
	let mut events = Vec::new();
	assert_eq!(world.drain_events_into(16, &mut events), 4);
	assert!(events.iter().all(|event| match event {
		WorldEvent::ReactionFinished { mixture, .. }
		| WorldEvent::RunDmReaction { mixture, .. } => mixture.slot != mixtures[0].slot,
		_ => true,
	}));
	assert_eq!(world.pending_reaction_continuations(), 3);
	for event in events {
		if let WorldEvent::RunDmReaction { continuation, .. } = event {
			world
				.resume_reaction_with_event_limit(continuation, 16)
				.unwrap();
			assert_eq!(
				world.resume_reaction_with_event_limit(continuation, 16),
				Err(WorldError::UnknownReactionContinuation(continuation))
			);
		}
	}
	assert!(world.is_reaction_continuation_pending(prior_token));
	world
		.resume_reaction_with_event_limit(prior_token, 16)
		.unwrap();
	assert_eq!(
		world.resume_reaction_with_event_limit(prior_token, 16),
		Err(WorldError::UnknownReactionContinuation(prior_token))
	);
	assert_eq!(world.pending_reaction_continuations(), 0);
}
