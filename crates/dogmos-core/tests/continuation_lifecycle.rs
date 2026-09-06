use dogmos_core::{
	metadata::{
		GasFireRole, GasId, GasMetadata, ReactionExecution, ReactionId, ReactionMetadata,
		TurfHandle,
	},
	world::{
		DogmosWorld, LifecycleAction, LifecycleMutation, ReactionContinuationToken,
		StageChunkRequest, TurfLifecycleMutation, WorldError, WorldEvent, WorldStage,
	},
	MixtureHandle,
};

fn mixture(slot: u32, generation: u32) -> MixtureHandle {
	MixtureHandle { slot, generation }
}

fn turf(slot: u32, generation: u32) -> TurfHandle {
	TurfHandle { slot, generation }
}

fn fixture() -> (DogmosWorld, Vec<ReactionContinuationToken>) {
	let mut world = DogmosWorld::new_with_capacities(1024 * 1024, 16, 16);
	world
		.install_gases(vec![GasMetadata {
			id: GasId(0),
			key: "test".into(),
			name: "Test".into(),
			flags: 0,
			specific_heat: 20.0,
			fusion_power: 0.0,
			moles_visible: None,
			enthalpy: 0.0,
			fire_radiation_released: 0.0,
			fire_role: GasFireRole::None,
			fire_products: None,
		}])
		.unwrap();
	world
		.install_reactions(vec![ReactionMetadata {
			id: ReactionId(0),
			key: "dm".into(),
			priority: 1.0,
			minimum_temperature: None,
			maximum_temperature: None,
			minimum_energy: None,
			minimum_fire_reagents: None,
			gas_requirements: Box::new([]),
			execution: ReactionExecution::Dm,
		}])
		.unwrap();
	world
		.apply_lifecycle(
			&(0..5)
				.map(|slot| LifecycleMutation {
					action: LifecycleAction::Register,
					handle: mixture(slot, 1),
				})
				.collect::<Vec<_>>(),
		)
		.unwrap();
	let turfs = [8, 3, 5, 2, 0].map(|slot| turf(slot, 1));
	world
		.apply_turf_lifecycle(
			&turfs
				.iter()
				.enumerate()
				.map(|(index, &handle)| TurfLifecycleMutation::Register {
					handle,
					mixture: Some(mixture(index as u32, 1)),
				})
				.collect::<Vec<_>>(),
		)
		.unwrap();
	world.begin_frontier(1, 5).unwrap();
	world.append_frontier(1, 0, &turfs).unwrap();
	world.commit_frontier(1).unwrap();
	let request = StageChunkRequest {
		stage: WorldStage::React,
		stage_epoch: 1,
		frontier_epoch: 1,
		work_limit: 4096,
		seconds_per_tick: 0.5,
	};
	assert!(
		!world
			.process_stage_chunk_cancellable(request, || false)
			.unwrap()
			.pending
	);
	let mut events = Vec::new();
	assert_eq!(world.drain_events_into(16, &mut events), 5);
	let mut tokens = events
		.into_iter()
		.enumerate()
		.map(|(index, event)| match event {
			WorldEvent::RunDmReaction {
				turf: Some(actual_turf),
				mixture: actual_mixture,
				continuation,
				..
			} => {
				assert_eq!(actual_turf, turfs[index]);
				assert_eq!(actual_mixture, mixture(index as u32, 1));
				continuation
			}
			other => panic!("unexpected event {other:?}"),
		})
		.collect::<Vec<_>>();
	// A second token owned by mixture 1 has no turf owner.
	tokens.push(start_direct(&mut world, 1));
	assert_eq!(
		tokens.iter().map(|token| token.slot).collect::<Vec<_>>(),
		[0, 1, 2, 3, 4, 5]
	);
	(world, tokens)
}

fn start_direct(world: &mut DogmosWorld, slot: u32) -> ReactionContinuationToken {
	world
		.react_mixture_with_event_limit(mixture(slot, 1), turf(99, 1).into(), None, 16)
		.unwrap();
	let mut events = Vec::new();
	assert_eq!(world.drain_events_into(16, &mut events), 1);
	match events[0] {
		WorldEvent::RunDmReaction {
			turf: None,
			continuation,
			..
		} => continuation,
		other => panic!("unexpected event {other:?}"),
	}
}

fn check_tokens(
	mut world: DogmosWorld,
	tokens: &[ReactionContinuationToken],
	invalid: &[usize],
	reuse: &[u32],
) {
	assert_eq!(
		world.pending_reaction_continuations(),
		(6 - invalid.len()) as u32
	);
	for &index in invalid {
		assert!(!world.is_reaction_continuation_pending(tokens[index]));
		assert_eq!(
			world.cancel_reaction(tokens[index]),
			Err(WorldError::UnknownReactionContinuation(tokens[index]))
		);
	}
	for &slot in reuse {
		assert_eq!(
			start_direct(&mut world, 0),
			ReactionContinuationToken {
				slot,
				generation: 2
			}
		);
	}
	for (index, &token) in tokens.iter().enumerate() {
		assert_eq!(
			world.is_reaction_continuation_pending(token),
			!invalid.contains(&index)
		);
		if invalid.contains(&index) {
			assert_eq!(
				world.cancel_reaction(token),
				Err(WorldError::StaleReactionContinuation {
					requested: token,
					current: 2
				})
			);
		} else {
			world
				.resume_reaction_with_result_and_event_limit(token, 0, 16)
				.unwrap();
			assert!(!world.is_reaction_continuation_pending(token));
		}
	}
	assert_eq!(world.pending_reaction_continuations(), reuse.len() as u32);
}

#[test]
fn single_owner_invalidation_preserves_all_its_tokens_in_arena_order() {
	for already_free in [false, true] {
		let (mut world, tokens) = fixture();
		if already_free {
			world.cancel_reaction(tokens[1]).unwrap();
		}
		world
			.apply_lifecycle(&[LifecycleMutation {
				action: LifecycleAction::Unregister,
				handle: mixture(1, 1),
			}])
			.unwrap();
		check_tokens(world, &tokens, &[1, 5], &[5, 1]);
	}

	let (mut world, tokens) = fixture();
	world
		.apply_turf_lifecycle(&[TurfLifecycleMutation::Unregister { handle: turf(3, 1) }])
		.unwrap();
	check_tokens(world, &tokens, &[1], &[1]);
}

#[test]
fn mixture_batches_preserve_all_owner_tokens_and_free_slot_order() {
	for replace in [false, true] {
		let (mut world, tokens) = fixture();
		let mut mutations = [3, 1]
			.map(|slot| LifecycleMutation {
				action: if replace {
					LifecycleAction::Register
				} else {
					LifecycleAction::Unregister
				},
				handle: mixture(slot, if replace { 2 } else { 1 }),
			})
			.to_vec();
		if replace {
			// The first invalidation of an owner determines its place in the free list.
			mutations.push(LifecycleMutation {
				action: LifecycleAction::Register,
				handle: mixture(3, 3),
			});
		}
		world.apply_lifecycle(&mutations).unwrap();
		check_tokens(world, &tokens, &[3, 1, 5], &[5, 1, 3]);
	}
}

#[test]
fn turf_batches_keep_direct_tokens_and_preserve_first_invalidation_order() {
	for mode in 0..4 {
		let (mut world, tokens) = fixture();
		let mut mutations = [2, 3]
			.map(|slot| match mode {
				0 => TurfLifecycleMutation::Unregister {
					handle: turf(slot, 1),
				},
				1 => TurfLifecycleMutation::Register {
					handle: turf(slot, 2),
					mixture: Some(mixture(if slot == 2 { 3 } else { 1 }, 1)),
				},
				3 => TurfLifecycleMutation::Register {
					handle: turf(slot, 1),
					mixture: None,
				},
				_ => TurfLifecycleMutation::Register {
					handle: turf(slot, 1),
					mixture: Some(mixture(0, 1)),
				},
			})
			.to_vec();
		if mode == 2 {
			mutations.push(TurfLifecycleMutation::Register {
				handle: turf(2, 1),
				mixture: Some(mixture(3, 1)),
			});
		}
		world.apply_turf_lifecycle(&mutations).unwrap();
		check_tokens(world, &tokens, &[3, 1], &[1, 3]);
	}
}

#[test]
fn earlier_owner_noop_does_not_determine_invalidation_order() {
	let (mut world, tokens) = fixture();
	world
		.apply_lifecycle(
			&[(3, 1), (1, 2), (3, 2)].map(|(slot, generation)| LifecycleMutation {
				action: LifecycleAction::Register,
				handle: mixture(slot, generation),
			}),
		)
		.unwrap();
	check_tokens(world, &tokens, &[3, 1, 5], &[3, 5, 1]);

	let (mut world, tokens) = fixture();
	world
		.apply_turf_lifecycle(&[
			TurfLifecycleMutation::Register {
				handle: turf(2, 1),
				mixture: Some(mixture(3, 1)),
			},
			TurfLifecycleMutation::Unregister { handle: turf(3, 1) },
			TurfLifecycleMutation::Register {
				handle: turf(2, 1),
				mixture: None,
			},
		])
		.unwrap();
	check_tokens(world, &tokens, &[3, 1], &[3, 1]);
}

#[test]
fn batch_invalidation_appends_after_already_free_tokens() {
	let (mut world, tokens) = fixture();
	world.cancel_reaction(tokens[2]).unwrap();
	world
		.apply_lifecycle(&[3, 1].map(|slot| LifecycleMutation {
			action: LifecycleAction::Unregister,
			handle: mixture(slot, 1),
		}))
		.unwrap();
	check_tokens(world, &tokens, &[2, 3, 1, 5], &[5, 1, 3, 2]);
}

#[test]
fn no_op_and_invalid_batches_preserve_pending_continuations() {
	let (mut world, tokens) = fixture();
	world
		.apply_lifecycle(&[LifecycleMutation {
			action: LifecycleAction::Register,
			handle: mixture(1, 1),
		}])
		.unwrap();
	world
		.apply_turf_lifecycle(&[TurfLifecycleMutation::Register {
			handle: turf(3, 1),
			mixture: Some(mixture(1, 1)),
		}])
		.unwrap();
	assert!(world
		.apply_lifecycle(&[
			LifecycleMutation {
				action: LifecycleAction::Unregister,
				handle: mixture(3, 1)
			},
			LifecycleMutation {
				action: LifecycleAction::Unregister,
				handle: mixture(1, 2)
			},
		])
		.is_err());
	assert!(world
		.apply_turf_lifecycle(&[
			TurfLifecycleMutation::Unregister { handle: turf(2, 1) },
			TurfLifecycleMutation::Unregister { handle: turf(3, 2) },
		])
		.is_err());
	assert_eq!(world.turf_mixture(turf(2, 1)).unwrap(), Some(mixture(3, 1)));
	assert!(world.snapshot(mixture(3, 1)).is_ok());
	check_tokens(world, &tokens, &[], &[]);
}
