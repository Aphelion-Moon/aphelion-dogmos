use dogmos_core::{
	metadata::{
		GasFireRole, GasId, GasMetadata, GasRequirement, NativeReactionKind, ReactionExecution,
		ReactionId, ReactionMetadata, TurfHandle,
	},
	stage_job::{JobProgress, StageJobSpec},
	world::{
		Command, DogmosWorld, LifecycleAction, LifecycleMutation, MixtureStateMutation,
		StageChunkRequest, TurfAdjacencyMutation, TurfHeatAdjacencyMutation, TurfHeatMutation,
		TurfHeatState, TurfLifecycleMutation, WorldError, WorldEvent, WorldStage,
	},
	MixtureHandle, MAX_GAS_SLOTS,
};

fn diffusion_fixture() -> (DogmosWorld, [MixtureHandle; 3], StageJobSpec) {
	diffusion_fixture_with_event_capacity(4096)
}

fn diffusion_fixture_with_event_capacity(
	max_events: u32,
) -> (DogmosWorld, [MixtureHandle; 3], StageJobSpec) {
	gas_fixture(max_events, max_events, &["o2"], vec![])
}

fn gas_fixture(
	max_events: u32,
	max_continuations: u32,
	gas_keys: &[&str],
	reactions: Vec<ReactionMetadata>,
) -> (DogmosWorld, [MixtureHandle; 3], StageJobSpec) {
	let mut world = DogmosWorld::new_with_capacities(1024 * 1024, max_events, max_continuations);
	world
		.install_gases(
			gas_keys
				.iter()
				.enumerate()
				.map(|(id, key)| GasMetadata {
					id: GasId(id as u16),
					key: (*key).into(),
					name: (*key).into(),
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
	world.install_reactions(reactions).unwrap();
	let mixtures = [0, 1, 2].map(|slot| MixtureHandle {
		slot,
		generation: 1,
	});
	world
		.apply_lifecycle(&mixtures.map(|handle| LifecycleMutation {
			action: LifecycleAction::Register,
			handle,
		}))
		.unwrap();
	for (handle, moles) in mixtures.into_iter().zip([10.0, 0.0, 3.0]) {
		let mut gases = [0.0; MAX_GAS_SLOTS];
		gases[0] = moles;
		world
			.apply_mixture_state(&[MixtureStateMutation {
				handle,
				expected_revision: 0,
				temperature: 300.0,
				volume: 2500.0,
				gases,
			}])
			.unwrap();
	}
	let turfs = [0, 1].map(|slot| TurfHandle {
		slot,
		generation: 1,
	});
	world
		.apply_turf_lifecycle(&[0, 1].map(|index| TurfLifecycleMutation::Register {
			handle: turfs[index],
			mixture: Some(mixtures[index]),
		}))
		.unwrap();
	world
		.apply_turf_adjacency(&[TurfAdjacencyMutation {
			left: turfs[0],
			right: turfs[1],
			connected: true,
		}])
		.unwrap();
	world.add_frontier(1, &turfs).unwrap();
	let spec = StageJobSpec {
		stage: WorldStage::ProcessTurfs,
		frontier_epoch: 1,
		stage_epoch: 1,
		seconds_per_tick: 0.5,
	};
	(world, mixtures, spec)
}

fn reaction_fixture(
	max_events: u32,
	max_continuations: u32,
) -> (DogmosWorld, [MixtureHandle; 3], StageJobSpec) {
	let (mut world, mixtures, mut spec) = gas_fixture(
		max_events,
		max_continuations,
		&["o2", "hydrogen", "water_vapor"],
		vec![
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
		],
	);
	spec.stage = WorldStage::React;
	for handle in mixtures.into_iter().take(2) {
		let mut gases = [0.0; MAX_GAS_SLOTS];
		gases[0] = 10.0;
		gases[1] = 1.0;
		world
			.apply_mixture_state(&[MixtureStateMutation {
				handle,
				expected_revision: world.snapshot(handle).unwrap().revision,
				temperature: 500.0,
				volume: 2500.0,
				gases,
			}])
			.unwrap();
	}
	(world, mixtures, spec)
}

#[test]
fn reaction_gas_callbacks_and_continuations_publish_only_at_commit() {
	let (mut world, mixtures, spec) = reaction_fixture(4096, 4096);
	let (mut oracle, oracle_mixtures, _) = reaction_fixture(4096, 4096);
	let original = mixtures.map(|handle| world.snapshot(handle).unwrap());
	let unit = prepare_until_ready(&mut world, spec);
	assert_eq!(
		mixtures.map(|handle| world.snapshot(handle).unwrap()),
		original
	);
	assert!(world.pending_events(32).is_empty());
	assert_eq!(world.pending_reaction_continuations(), 0);
	let receipt = world.commit_job_unit(unit).unwrap();
	assert!(!receipt.pending);
	complete_synchronously(&mut oracle, spec);
	assert_eq!(
		mixtures.map(|handle| world.snapshot(handle).unwrap()),
		oracle_mixtures.map(|handle| oracle.snapshot(handle).unwrap())
	);
	assert_ne!(world.snapshot(mixtures[0]).unwrap(), original[0]);
	let expected_events = oracle.pending_events(32).to_vec();
	assert!(expected_events
		.iter()
		.any(|event| matches!(event, WorldEvent::RunDmReaction { .. })));
	assert_eq!(world.pending_events(32), expected_events);
	assert_eq!(world.pending_reaction_continuations(), 2);
	assert_eq!(world.commit_job_unit(unit).unwrap(), receipt);
	assert_eq!(world.pending_events(32), expected_events);
	assert_eq!(world.pending_reaction_continuations(), 2);
}

#[test]
fn rejected_reaction_admission_rolls_back_all_continuations_and_gas() {
	for (events, continuations) in [(0, 4096), (4096, 1)] {
		let (mut world, mixtures, spec) = reaction_fixture(events, continuations);
		let original = mixtures.map(|handle| world.snapshot(handle).unwrap());
		let unit = prepare_until_ready(&mut world, spec);
		assert!(world.commit_job_unit(unit).is_err());
		assert_eq!(
			mixtures.map(|handle| world.snapshot(handle).unwrap()),
			original
		);
		assert!(world.pending_events(32).is_empty());
		assert_eq!(world.pending_reaction_continuations(), 0);
	}
}

#[test]
fn conflicting_reaction_write_preserves_gameplay_and_does_not_leak_callbacks() {
	let (mut world, mixtures, spec) = reaction_fixture(4096, 4096);
	let (mut oracle, oracle_mixtures, _) = reaction_fixture(4096, 4096);
	let unit = prepare_until_ready(&mut world, spec);
	for (candidate, handle) in [(&mut world, mixtures[0]), (&mut oracle, oracle_mixtures[0])] {
		candidate
			.apply_command(Command::SetMoles {
				handle,
				gas: GasId(0),
				amount: 20.0,
			})
			.unwrap();
	}
	let after_write = mixtures.map(|handle| world.snapshot(handle).unwrap());
	assert!(world.commit_job_unit(unit).unwrap().pending);
	assert_eq!(
		mixtures.map(|handle| world.snapshot(handle).unwrap()),
		after_write
	);
	assert!(world.pending_events(32).is_empty());
	assert_eq!(world.pending_reaction_continuations(), 0);
	let next_unit = prepare_until_ready(&mut world, spec);
	assert_ne!(unit, next_unit);
	assert!(!world.commit_job_unit(next_unit).unwrap().pending);
	complete_synchronously(&mut oracle, spec);
	assert_eq!(
		mixtures.map(|handle| world.snapshot(handle).unwrap()),
		oracle_mixtures.map(|handle| oracle.snapshot(handle).unwrap())
	);
	// Cancelled tentative reservations may advance token generations, but the callback
	// order and every gameplay field must still match the synchronous transcript.
	let normalize = |events: &[WorldEvent]| {
		events
			.iter()
			.copied()
			.map(|mut event| {
				if let WorldEvent::RunDmReaction {
					ref mut continuation,
					..
				} = event
				{
					*continuation = Default::default();
				}
				event
			})
			.collect::<Vec<_>>()
	};
	assert_eq!(
		normalize(world.pending_events(32)),
		normalize(oracle.pending_events(32))
	);
	assert_eq!(world.pending_reaction_continuations(), 2);
}

#[test]
fn reaction_read_only_inputs_invalidate_obsolete_dm_callbacks() {
	let (mut world, mixtures, spec) = reaction_fixture(4096, 4096);
	for handle in mixtures.into_iter().take(2) {
		world
			.apply_command(Command::SetMoles {
				handle,
				gas: GasId(1),
				amount: 0.0,
			})
			.unwrap();
	}
	let unit = prepare_until_ready(&mut world, spec);
	world
		.apply_command(Command::SetMoles {
			handle: mixtures[0],
			gas: GasId(0),
			amount: 0.0,
		})
		.unwrap();
	let after_write = mixtures.map(|handle| world.snapshot(handle).unwrap());
	assert!(
		world.commit_job_unit(unit).unwrap().pending,
		"a read-only gas input changed after DM fallback eligibility was evaluated"
	);
	assert!(world.pending_events(32).is_empty());
	assert_eq!(world.pending_reaction_continuations(), 0);
	let retry = prepare_until_ready(&mut world, spec);
	assert!(!world.commit_job_unit(retry).unwrap().pending);
	assert_eq!(
		mixtures.map(|handle| world.snapshot(handle).unwrap()),
		after_write
	);
	assert!(
		matches!(world.pending_events(32), [WorldEvent::RunDmReaction { mixture, .. }] if *mixture == mixtures[1])
	);
	assert_eq!(world.pending_reaction_continuations(), 1);
}

#[test]
fn immediate_dm_reaction_invalidates_a_prepared_fallback_for_the_same_owner() {
	let (mut world, mixtures, spec) = reaction_fixture(4096, 4096);
	for handle in mixtures.into_iter().take(2) {
		world
			.apply_command(Command::SetMoles {
				handle,
				gas: GasId(1),
				amount: 0.0,
			})
			.unwrap();
	}
	let unit = prepare_until_ready(&mut world, spec);
	let progress = world
		.react_mixture_with_event_limit(
			mixtures[0],
			TurfHandle {
				slot: 0,
				generation: 1,
			}
			.into(),
			None,
			4096,
		)
		.unwrap();
	assert!(progress.pending);
	let immediate_events = world.pending_events(32).to_vec();
	assert_eq!(world.pending_reaction_continuations(), 1);
	assert!(
		world.commit_job_unit(unit).unwrap().pending,
		"must not publish a second suspended fallback for an owner changed during preparation"
	);
	assert_eq!(world.pending_events(32), immediate_events);
	assert_eq!(world.pending_reaction_continuations(), 1);
	let retry = prepare_until_ready(&mut world, spec);
	assert!(!world.commit_job_unit(retry).unwrap().pending);
	assert_eq!(world.pending_reaction_continuations(), 2);
	assert_eq!(world.pending_events(32).len(), 2);
}

#[test]
fn reaction_continuation_inspection_consumes_preparation_work() {
	let (mut world, _, mut spec) = reaction_fixture(4096, 4096);
	complete_synchronously(&mut world, spec);
	assert_eq!(world.pending_reaction_continuations(), 2);
	spec.stage_epoch += 1;
	for _ in 0..2 {
		assert_eq!(
			world
				.prepare_job_chunk(spec, 1, || false, || false)
				.unwrap(),
			JobProgress::Running
		);
		let (_, _, frontier_inspected, _) = world.stage_telemetry().unwrap();
		assert_eq!(
			frontier_inspected, 0,
			"continuation inspection must finish under the same work budget before frontier work"
		);
	}
	let unit = prepare_until_ready(&mut world, spec);
	assert!(!world.commit_job_unit(unit).unwrap().pending);
	assert_eq!(world.pending_reaction_continuations(), 2);
}

fn prepare_until_ready(world: &mut DogmosWorld, spec: StageJobSpec) -> u64 {
	for _ in 0..128 {
		match world
			.prepare_job_chunk(spec, 1, || false, || false)
			.unwrap()
		{
			JobProgress::Ready { unit } => return unit,
			JobProgress::Running | JobProgress::Retrying => {}
			JobProgress::Done => panic!("preparation completed without an explicit commit"),
		}
	}
	panic!("preparation exceeded the fixture's bounded work count");
}

fn component_fixture(stage: WorldStage) -> (DogmosWorld, [MixtureHandle; 4], StageJobSpec) {
	let (mut world, first, mut spec) = diffusion_fixture();
	spec.stage = stage;
	spec.frontier_epoch = 2;
	let last = MixtureHandle {
		slot: 3,
		generation: 1,
	};
	world
		.apply_lifecycle(&[LifecycleMutation {
			action: LifecycleAction::Register,
			handle: last,
		}])
		.unwrap();
	let mixtures = [first[0], first[1], first[2], last];
	for (handle, amount) in mixtures.into_iter().zip([100.0, 0.0, 100.0, 0.0]) {
		// Keep pressure differences inside excited-group eligibility while retaining
		// a literal mole imbalance large enough to exercise equalization as well.
		let mut gases = [0.0; MAX_GAS_SLOTS];
		gases[0] = amount;
		world
			.apply_mixture_state(&[MixtureStateMutation {
				handle,
				expected_revision: world.snapshot(handle).unwrap().revision,
				temperature: 300.0,
				volume: 1_000_000.0,
				gases,
			}])
			.unwrap();
	}
	let turfs = [2, 3].map(|slot| TurfHandle {
		slot,
		generation: 1,
	});
	world
		.apply_turf_lifecycle(&[0, 1].map(|i| TurfLifecycleMutation::Register {
			handle: turfs[i],
			mixture: Some(mixtures[i + 2]),
		}))
		.unwrap();
	world
		.apply_turf_adjacency(&[TurfAdjacencyMutation {
			left: turfs[0],
			right: turfs[1],
			connected: true,
		}])
		.unwrap();
	world.add_frontier(2, &turfs).unwrap();
	(world, mixtures, spec)
}

fn finish_preparation(world: &mut DogmosWorld, spec: StageJobSpec) {
	for _ in 0..32 {
		match world
			.prepare_job_chunk(spec, 1, || false, || false)
			.unwrap()
		{
			JobProgress::Done => return,
			JobProgress::Running => {}
			other => panic!("expected completion after both component commits, got {other:?}"),
		}
	}
	panic!("component completion exceeded the fixture work bound");
}

#[test]
fn disconnected_components_publish_individually_and_keep_cumulative_receipts() {
	for stage in [WorldStage::Equalize, WorldStage::ExcitedGroups] {
		let (mut world, mixtures, spec) = component_fixture(stage);
		let (mut oracle, oracle_mixtures, _) = component_fixture(stage);
		let original = mixtures.map(|handle| world.snapshot(handle).unwrap());
		let first = prepare_until_ready(&mut world, spec);
		assert_eq!(
			mixtures.map(|handle| world.snapshot(handle).unwrap()),
			original
		);
		assert!(world.pending_events(32).is_empty());
		let first_receipt = world.commit_job_unit(first).unwrap();
		assert!(first_receipt.pending);
		assert_eq!(
			mixtures.map(|handle| world.snapshot(handle).unwrap().gases[0]),
			[50.0, 50.0, 100.0, 0.0]
		);
		let after_first = mixtures.map(|handle| world.snapshot(handle).unwrap());
		let second = prepare_until_ready(&mut world, spec);
		assert_ne!(first, second);
		assert_eq!(
			mixtures.map(|handle| world.snapshot(handle).unwrap()),
			after_first
		);
		assert_eq!(world.commit_job_unit(first).unwrap(), first_receipt);
		assert_eq!(
			mixtures.map(|handle| world.snapshot(handle).unwrap()),
			after_first
		);
		let second_receipt = world.commit_job_unit(second).unwrap();
		let seeds = |receipt: dogmos_core::world::StageChunkResult| {
			if stage == WorldStage::Equalize {
				receipt.produced_equalize_seeds
			} else {
				receipt.produced_group_seeds
			}
		};
		assert_eq!(seeds(first_receipt), 1);
		assert_eq!(seeds(second_receipt), 2);
		assert!(second_receipt.callback_events >= first_receipt.callback_events);
		finish_preparation(&mut world, spec);
		complete_synchronously(&mut oracle, spec);
		assert_eq!(
			mixtures.map(|handle| world.snapshot(handle).unwrap()),
			oracle_mixtures.map(|handle| oracle.snapshot(handle).unwrap())
		);
		let events = world.pending_events(32).to_vec();
		assert_eq!(events, oracle.pending_events(32));
		assert_eq!(world.commit_job_unit(second).unwrap(), second_receipt);
		assert!(world.commit_job_unit(first).is_err());
		assert_eq!(world.pending_events(32), events);
	}
}

#[test]
fn effect_free_components_need_one_final_accounting_receipt_not_one_commit_each() {
	for stage in [WorldStage::Equalize, WorldStage::ExcitedGroups] {
		let (mut world, original_handles, mut spec) = component_fixture(stage);
		let edges = [[0, 1], [2, 3]].map(|[left, right]| TurfAdjacencyMutation {
			left: TurfHandle {
				slot: left,
				generation: 1,
			},
			right: TurfHandle {
				slot: right,
				generation: 1,
			},
			connected: false,
		});
		world.apply_turf_adjacency(&edges).unwrap();
		let extra = (4..512)
			.map(|slot| MixtureHandle {
				slot,
				generation: 1,
			})
			.collect::<Vec<_>>();
		world
			.apply_lifecycle(
				&extra
					.iter()
					.map(|&handle| LifecycleMutation {
						action: LifecycleAction::Register,
						handle,
					})
					.collect::<Vec<_>>(),
			)
			.unwrap();
		let extra_turfs = extra
			.iter()
			.map(|handle| TurfHandle {
				slot: handle.slot,
				generation: 1,
			})
			.collect::<Vec<_>>();
		world
			.apply_turf_lifecycle(
				&extra
					.iter()
					.zip(&extra_turfs)
					.map(|(&mixture, &handle)| TurfLifecycleMutation::Register {
						handle,
						mixture: Some(mixture),
					})
					.collect::<Vec<_>>(),
			)
			.unwrap();
		spec.frontier_epoch = 3;
		world
			.add_frontier(spec.frontier_epoch, &extra_turfs)
			.unwrap();
		let originals = original_handles.map(|handle| world.snapshot(handle).unwrap());
		let unit = (0..1024)
			.find_map(|_| {
				match world
					.prepare_job_chunk(spec, 256, || false, || false)
					.unwrap()
				{
					JobProgress::Ready { unit } => Some(unit),
					JobProgress::Running | JobProgress::Retrying => None,
					JobProgress::Done => {
						panic!("component totals need an explicit accounting receipt")
					}
				}
			})
			.expect("512 isolated components must prepare within a bounded work count");
		assert_eq!(
			original_handles.map(|handle| world.snapshot(handle).unwrap()),
			originals
		);
		assert!(world.pending_events(32).is_empty());
		assert_eq!(
			world.stage_job_view().unwrap().remaining_estimate,
			0,
			"effect-free components must finish traversal before requesting accounting publication"
		);
		world
			.apply_command(Command::SetTemperature {
				handle: original_handles[0],
				temperature: 333.0,
			})
			.unwrap();
		let receipt = world.commit_job_unit(unit).unwrap();
		assert!(
			!receipt.pending,
			"512 isolated components should need only their final receipt"
		);
		assert_eq!(
			receipt.produced_equalize_seeds + receipt.produced_group_seeds,
			512
		);
		assert_eq!(receipt.callback_events, 0);
		assert_eq!(
			world.snapshot(original_handles[0]).unwrap().temperature,
			333.0
		);
		assert_eq!(world.commit_job_unit(unit).unwrap(), receipt);
		assert!(world.pending_events(32).is_empty());
	}
}

#[test]
fn mixed_components_acknowledge_effect_free_work_without_publishing_real_work_early() {
	for stage in [WorldStage::Equalize, WorldStage::ExcitedGroups] {
		for isolated_pair in [0, 2] {
			let (mut world, mixtures, spec) = component_fixture(stage);
			let (mut oracle, _, _) = component_fixture(stage);
			let disconnect = [TurfAdjacencyMutation {
				left: TurfHandle {
					slot: isolated_pair,
					generation: 1,
				},
				right: TurfHandle {
					slot: isolated_pair + 1,
					generation: 1,
				},
				connected: false,
			}];
			world.apply_turf_adjacency(&disconnect).unwrap();
			oracle.apply_turf_adjacency(&disconnect).unwrap();
			let original = mixtures.map(|handle| world.snapshot(handle).unwrap());
			let unit = prepare_until_ready(&mut world, spec);
			assert_eq!(
				mixtures.map(|handle| world.snapshot(handle).unwrap()),
				original
			);
			assert!(world.pending_events(32).is_empty());
			assert!(world.stage_job_view().unwrap().last_committed.is_none());
			let receipt = world.commit_job_unit(unit).unwrap();
			assert_eq!(
				receipt.produced_equalize_seeds + receipt.produced_group_seeds,
				if isolated_pair == 0 { 3 } else { 1 }
			);
			let committed = mixtures.map(|handle| world.snapshot(handle).unwrap());
			assert_eq!(
				committed.each_ref().map(|snapshot| snapshot.gases[0]),
				if isolated_pair == 0 {
					[100.0, 0.0, 50.0, 50.0]
				} else {
					[50.0, 50.0, 100.0, 0.0]
				}
			);
			if isolated_pair == 2 {
				let accounting_unit = prepare_until_ready(&mut world, spec);
				assert_eq!(world.stage_job_view().unwrap().remaining_estimate, 0);
				assert_eq!(world.commit_job_unit(unit).unwrap(), receipt);
				assert_eq!(
					mixtures.map(|handle| world.snapshot(handle).unwrap()),
					committed
				);
				let final_receipt = world.commit_job_unit(accounting_unit).unwrap();
				assert!(!final_receipt.pending);
				assert_eq!(
					final_receipt.produced_equalize_seeds + final_receipt.produced_group_seeds,
					3
				);
				assert_eq!(final_receipt.callback_events, receipt.callback_events);
				assert_eq!(
					world.commit_job_unit(accounting_unit).unwrap(),
					final_receipt
				);
			} else {
				finish_preparation(&mut world, spec);
				assert_eq!(world.commit_job_unit(unit).unwrap(), receipt);
			}
			complete_synchronously(&mut oracle, spec);
			assert_eq!(
				mixtures.map(|handle| world.snapshot(handle).unwrap()),
				mixtures.map(|handle| oracle.snapshot(handle).unwrap())
			);
			assert_eq!(world.pending_events(32), oracle.pending_events(32));
		}
	}
}

#[test]
fn effect_free_preparation_can_be_cancelled_at_every_yield_without_a_receipt() {
	for stage in [WorldStage::Equalize, WorldStage::ExcitedGroups] {
		let mut reached_accounting = false;
		for cutoff in 1..512 {
			let (mut world, mixtures, spec) = component_fixture(stage);
			world
				.apply_turf_adjacency(&[[0, 1], [2, 3]].map(|[left, right]| {
					TurfAdjacencyMutation {
						left: TurfHandle {
							slot: left,
							generation: 1,
						},
						right: TurfHandle {
							slot: right,
							generation: 1,
						},
						connected: false,
					}
				}))
				.unwrap();
			let original = mixtures.map(|handle| world.snapshot(handle).unwrap());
			for _ in 0..cutoff {
				let progress = world
					.prepare_job_chunk(spec, 1, || false, || false)
					.unwrap();
				assert_eq!(
					mixtures.map(|handle| world.snapshot(handle).unwrap()),
					original
				);
				assert!(world.pending_events(32).is_empty());
				assert!(world.stage_job_view().unwrap().last_committed.is_none());
				if matches!(progress, JobProgress::Ready { .. }) {
					reached_accounting = true;
					break;
				}
				assert_eq!(progress, JobProgress::Running);
			}
			world
				.apply_command(Command::SetTemperature {
					handle: mixtures[0],
					temperature: 333.0,
				})
				.unwrap();
			let before_cancel = mixtures.map(|handle| world.snapshot(handle).unwrap());
			world.cancel_job_unpublished();
			assert_eq!(
				mixtures.map(|handle| world.snapshot(handle).unwrap()),
				before_cancel
			);
			assert!(world.pending_events(32).is_empty());
			assert!(world.stage_job_view().is_none());
			assert!(world.pending_stage_epoch().is_none());
			if reached_accounting {
				break;
			}
		}
		assert!(
			reached_accounting,
			"must cover cancellation at the final accounting barrier"
		);
	}
}

#[test]
fn component_cancellation_preserves_only_previously_committed_units() {
	for stage in [WorldStage::Equalize, WorldStage::ExcitedGroups] {
		let (mut world, mixtures, spec) = component_fixture(stage);
		let first = prepare_until_ready(&mut world, spec);
		world.commit_job_unit(first).unwrap();
		let committed = mixtures.map(|handle| world.snapshot(handle).unwrap());
		let events = world.pending_events(32).to_vec();
		let second = prepare_until_ready(&mut world, spec);
		world.cancel_job_unpublished();
		assert_eq!(
			mixtures.map(|handle| world.snapshot(handle).unwrap()),
			committed
		);
		assert_eq!(world.pending_events(32), events);
		assert!(world.commit_job_unit(second).is_err());
		assert_eq!(world.pending_stage_epoch(), None);
	}
}

#[test]
fn component_cancellation_retains_captured_storage_at_every_yield() {
	for stage in [WorldStage::Equalize, WorldStage::ExcitedGroups] {
		for cutoff in 1..200 {
			let (mut world, _, spec) = component_fixture(stage);
			let mut high_water = world.reusable_workset_bytes();
			let mut ready = false;
			for _ in 0..cutoff {
				let progress = world
					.prepare_job_chunk(spec, 1, || false, || false)
					.unwrap();
				high_water = high_water.max(world.reusable_workset_bytes());
				if matches!(progress, JobProgress::Ready { .. }) {
					ready = true;
					break;
				}
			}
			world.cancel_job_unpublished();
			assert!(
				world.reusable_workset_bytes() >= high_water,
				"{stage:?} discarded captured storage when cancelled after {cutoff} yields"
			);
			if ready {
				break;
			}
		}
	}
}

#[test]
fn component_conflict_retries_only_the_unpublished_component() {
	for stage in [WorldStage::Equalize, WorldStage::ExcitedGroups] {
		let (mut world, mixtures, spec) = component_fixture(stage);
		let first = prepare_until_ready(&mut world, spec);
		let first_receipt = world.commit_job_unit(first).unwrap();
		let committed = [0, 1].map(|i| world.snapshot(mixtures[i]).unwrap());
		let events = world.pending_events(32).to_vec();
		let second = prepare_until_ready(&mut world, spec);
		world
			.apply_command(Command::SetMoles {
				handle: mixtures[2],
				gas: GasId(0),
				amount: 200.0,
			})
			.unwrap();
		assert!(world.commit_job_unit(second).unwrap().pending);
		assert_eq!(world.pending_events(32), events);
		assert_eq!(
			[0, 1].map(|i| world.snapshot(mixtures[i]).unwrap()),
			committed
		);
		assert_eq!(world.commit_job_unit(first).unwrap(), first_receipt);
		let retry = prepare_until_ready(&mut world, spec);
		assert_ne!(retry, second);
		let receipt = world.commit_job_unit(retry).unwrap();
		assert_eq!(
			mixtures.map(|handle| world.snapshot(handle).unwrap().gases[0]),
			[50.0, 50.0, 100.0, 100.0]
		);
		assert_eq!(
			receipt.produced_equalize_seeds + receipt.produced_group_seeds,
			2
		);
		finish_preparation(&mut world, spec);
	}
}

fn heat_fixture(
	max_events: u32,
) -> (
	DogmosWorld,
	[MixtureHandle; 3],
	[TurfHandle; 2],
	StageJobSpec,
) {
	let (mut world, mixtures, mut spec) = diffusion_fixture_with_event_capacity(max_events);
	spec.stage = WorldStage::TurfHeat;
	let turfs = [0, 1].map(|slot| TurfHandle {
		slot,
		generation: 1,
	});
	world
		.apply_turf_heat(&[0, 1].map(|index| TurfHeatMutation {
			handle: turfs[index],
			state: Some(TurfHeatState {
				temperature: [1200.0, 300.0][index],
				thermal_conductivity: 0.1,
				heat_capacity: 100.0,
				adjacent_to_space: false,
			}),
		}))
		.unwrap();
	world
		.apply_turf_heat_adjacency(&[TurfHeatAdjacencyMutation {
			left: turfs[0],
			right: turfs[1],
			connected: true,
		}])
		.unwrap();
	(world, mixtures, turfs, spec)
}

#[test]
fn heat_and_destruction_events_remain_invisible_until_explicit_commit() {
	let (mut world, mixtures, turfs, spec) = heat_fixture(4096);
	let (mut oracle, oracle_mixtures, oracle_turfs, _) = heat_fixture(4096);
	let original_gas = mixtures.map(|handle| world.snapshot(handle).unwrap());
	let original_heat = turfs.map(|handle| world.turf_heat(handle).unwrap());
	let unit = prepare_until_ready(&mut world, spec);
	assert_eq!(
		mixtures.map(|handle| world.snapshot(handle).unwrap()),
		original_gas
	);
	assert_eq!(
		turfs.map(|handle| world.turf_heat(handle).unwrap()),
		original_heat
	);
	assert!(world.pending_events(32).is_empty());
	let receipt = world.commit_job_unit(unit).unwrap();
	assert!(!receipt.pending);
	complete_synchronously(&mut oracle, spec);
	assert_eq!(
		mixtures.map(|handle| world.snapshot(handle).unwrap()),
		oracle_mixtures.map(|handle| oracle.snapshot(handle).unwrap())
	);
	assert_eq!(
		turfs.map(|handle| world.turf_heat(handle).unwrap()),
		oracle_turfs.map(|handle| oracle.turf_heat(handle).unwrap())
	);
	let expected_events = oracle.pending_events(32).to_vec();
	assert!(
		!expected_events.is_empty(),
		"fixture must exercise heat event admission"
	);
	assert_eq!(world.pending_events(32), expected_events);
	assert_eq!(world.commit_job_unit(unit).unwrap(), receipt);
	assert_eq!(world.pending_events(32), expected_events);
}

#[test]
fn heat_commit_reuses_the_already_prepared_active_set() {
	let (mut world, _, spec) = component_fixture(WorldStage::TurfHeat);
	// Keep this allocation check independent of outbox growth for destruction events.
	let heat = [0, 1, 2, 3].map(|slot| TurfHeatMutation {
		handle: TurfHandle {
			slot,
			generation: 1,
		},
		state: Some(TurfHeatState {
			temperature: 1200.0,
			thermal_conductivity: 0.05,
			heat_capacity: 20_000.0,
			adjacent_to_space: false,
		}),
	});
	world.apply_turf_heat(&heat).unwrap();
	let unit = prepare_until_ready(&mut world, spec);
	let prepared_capacity = world.reusable_workset_bytes();
	assert!(!world.commit_job_unit(unit).unwrap().pending);
	assert!(world.pending_events(32).is_empty());
	assert_eq!(
		world.reusable_workset_bytes(),
		prepared_capacity,
		"publication should swap the complete prepared active set without allocating another copy"
	);
}

#[test]
fn rejected_heat_event_admission_publishes_neither_gas_nor_turf_state() {
	let (mut world, mixtures, turfs, spec) = heat_fixture(0);
	let original_gas = mixtures.map(|handle| world.snapshot(handle).unwrap());
	let original_heat = turfs.map(|handle| world.turf_heat(handle).unwrap());
	let unit = prepare_until_ready(&mut world, spec);
	assert!(matches!(
		world.commit_job_unit(unit),
		Err(WorldError::EventCapacityExceeded { .. })
	));
	assert_eq!(
		mixtures.map(|handle| world.snapshot(handle).unwrap()),
		original_gas
	);
	assert_eq!(
		turfs.map(|handle| world.turf_heat(handle).unwrap()),
		original_heat
	);
	assert!(world.pending_events(32).is_empty());
}

#[test]
fn a_linked_gas_write_retries_the_whole_unpublished_heat_unit() {
	let (mut world, mixtures, turfs, spec) = heat_fixture(4096);
	let (mut oracle, oracle_mixtures, oracle_turfs, _) = heat_fixture(4096);
	let original_heat = turfs.map(|handle| world.turf_heat(handle).unwrap());
	let old_unit = prepare_until_ready(&mut world, spec);
	for (candidate, handle) in [(&mut world, mixtures[0]), (&mut oracle, oracle_mixtures[0])] {
		candidate
			.apply_command(Command::SetMoles {
				handle,
				gas: GasId(0),
				amount: 20.0,
			})
			.unwrap();
	}
	let after_write = mixtures.map(|handle| world.snapshot(handle).unwrap());
	assert!(world.commit_job_unit(old_unit).unwrap().pending);
	assert_eq!(
		mixtures.map(|handle| world.snapshot(handle).unwrap()),
		after_write
	);
	assert_eq!(
		turfs.map(|handle| world.turf_heat(handle).unwrap()),
		original_heat
	);
	assert!(world.pending_events(32).is_empty());
	let unit = prepare_until_ready(&mut world, spec);
	assert_ne!(unit, old_unit);
	assert!(!world.commit_job_unit(unit).unwrap().pending);
	complete_synchronously(&mut oracle, spec);
	assert_eq!(
		mixtures.map(|handle| world.snapshot(handle).unwrap()),
		oracle_mixtures.map(|handle| oracle.snapshot(handle).unwrap())
	);
	assert_eq!(
		turfs.map(|handle| world.turf_heat(handle).unwrap()),
		oracle_turfs.map(|handle| oracle.turf_heat(handle).unwrap())
	);
	assert_eq!(world.pending_events(32), oracle.pending_events(32));
}

fn complete_synchronously(world: &mut DogmosWorld, spec: StageJobSpec) {
	let request = StageChunkRequest {
		stage: spec.stage,
		frontier_epoch: spec.frontier_epoch,
		stage_epoch: spec.stage_epoch,
		seconds_per_tick: spec.seconds_per_tick,
		work_limit: 1,
	};
	for _ in 0..128 {
		if !world
			.process_stage_chunk_cancellable(request, || false)
			.unwrap()
			.pending
		{
			return;
		}
	}
	panic!("synchronous oracle exceeded its work bound");
}

#[test]
fn ready_preparation_is_invisible_and_commit_replay_matches_synchronous_results() {
	let (mut world, mixtures, spec) = diffusion_fixture();
	let (mut oracle, oracle_mixtures, _) = diffusion_fixture();
	let original = mixtures.map(|handle| world.snapshot(handle).unwrap());
	let unit = prepare_until_ready(&mut world, spec);
	assert_eq!(
		mixtures.map(|handle| world.snapshot(handle).unwrap()),
		original
	);
	assert!(world.pending_events(32).is_empty());

	// A write outside the captured input set must not invalidate the prepared unit.
	for (candidate, handle) in [(&mut world, mixtures[2]), (&mut oracle, oracle_mixtures[2])] {
		candidate
			.apply_command(Command::SetMoles {
				handle,
				gas: GasId(0),
				amount: 17.0,
			})
			.unwrap();
	}
	let receipt = world.commit_job_unit(unit).unwrap();
	assert!(!receipt.pending);
	complete_synchronously(&mut oracle, spec);
	let expected = oracle_mixtures.map(|handle| oracle.snapshot(handle).unwrap());
	assert_eq!(
		mixtures.map(|handle| world.snapshot(handle).unwrap()),
		expected
	);
	let events = world.pending_events(32).to_vec();
	assert_eq!(world.commit_job_unit(unit).unwrap(), receipt);
	assert_eq!(
		mixtures.map(|handle| world.snapshot(handle).unwrap()),
		expected
	);
	assert_eq!(world.pending_events(32), events);
}

#[test]
fn a_live_input_write_invalidates_ready_work_and_survives_retry() {
	let (mut world, mixtures, spec) = diffusion_fixture();
	let (mut oracle, oracle_mixtures, _) = diffusion_fixture();
	let stale_unit = prepare_until_ready(&mut world, spec);
	for (candidate, handle) in [(&mut world, mixtures[0]), (&mut oracle, oracle_mixtures[0])] {
		candidate
			.apply_command(Command::SetMoles {
				handle,
				gas: GasId(0),
				amount: 20.0,
			})
			.unwrap();
	}
	let after_write = mixtures.map(|handle| world.snapshot(handle).unwrap());
	assert!(world.commit_job_unit(stale_unit).unwrap().pending);
	assert_eq!(
		mixtures.map(|handle| world.snapshot(handle).unwrap()),
		after_write
	);
	assert!(world.pending_events(32).is_empty());
	let replacement_unit = prepare_until_ready(&mut world, spec);
	assert_ne!(replacement_unit, stale_unit);
	assert!(!world.commit_job_unit(replacement_unit).unwrap().pending);
	complete_synchronously(&mut oracle, spec);
	assert_eq!(
		mixtures.map(|handle| world.snapshot(handle).unwrap()),
		oracle_mixtures.map(|handle| oracle.snapshot(handle).unwrap())
	);
}

#[test]
fn invalid_new_admission_preserves_the_previous_commit_receipt() {
	let (mut world, _, spec) = diffusion_fixture();
	let unit = prepare_until_ready(&mut world, spec);
	let receipt = world.commit_job_unit(unit).unwrap();
	let invalid = StageJobSpec {
		frontier_epoch: 2,
		stage_epoch: 2,
		..spec
	};
	assert!(world
		.prepare_job_chunk(invalid, 1, || false, || false)
		.is_err());
	assert_eq!(world.commit_job_unit(unit).unwrap(), receipt);
}

#[test]
fn rejected_legacy_admission_preserves_the_previous_job_receipt() {
	let (mut world, _, spec) = diffusion_fixture();
	let unit = prepare_until_ready(&mut world, spec);
	let receipt = world.commit_job_unit(unit).unwrap();
	assert_eq!(
		world.process_stage_chunk_cancellable(
			StageChunkRequest {
				stage: spec.stage,
				frontier_epoch: spec.frontier_epoch,
				stage_epoch: spec.stage_epoch + 1,
				seconds_per_tick: 0.5,
				work_limit: 0,
			},
			|| false
		),
		Err(WorldError::InvalidStageWorkLimit(0))
	);
	assert_eq!(world.commit_job_unit(unit).unwrap(), receipt);
}

#[test]
fn cancelling_without_a_job_does_not_abort_a_legacy_stage() {
	let (mut world, _, spec) = diffusion_fixture();
	let request = StageChunkRequest {
		stage: spec.stage,
		frontier_epoch: spec.frontier_epoch,
		stage_epoch: spec.stage_epoch,
		seconds_per_tick: 0.5,
		work_limit: 1,
	};
	assert!(
		world
			.process_stage_chunk_cancellable(request, || false)
			.unwrap()
			.pending
	);
	world.cancel_job_unpublished();
	assert_eq!(world.pending_stage_epoch(), Some(spec.stage_epoch));
	complete_synchronously(&mut world, spec);
}

#[test]
fn admitted_work_fences_frontier_changes_before_its_first_quantum() {
	let (mut world, mixtures, spec) = diffusion_fixture();
	let original = mixtures.map(|handle| world.snapshot(handle).unwrap());
	assert_eq!(
		world.prepare_job_chunk(spec, 1, || true, || false).unwrap(),
		JobProgress::Running
	);
	assert!(world.begin_frontier(2, 0).is_err());
	assert!(world.add_frontier(2, &[]).is_err());
	assert!(world.remove_frontier(2, &[]).is_err());
	assert_eq!(world.pending_stage_epoch(), Some(spec.stage_epoch));
	assert!(world
		.process_stage_chunk_cancellable(
			StageChunkRequest {
				stage: spec.stage,
				frontier_epoch: spec.frontier_epoch,
				stage_epoch: spec.stage_epoch,
				seconds_per_tick: spec.seconds_per_tick,
				work_limit: 1,
			},
			|| false
		)
		.is_err());
	let unit = prepare_until_ready(&mut world, spec);
	assert_eq!(
		mixtures.map(|handle| world.snapshot(handle).unwrap()),
		original
	);
	assert!(!world.commit_job_unit(unit).unwrap().pending);
}

#[test]
fn scheduling_yield_preserves_unpublished_progress() {
	let (mut world, mixtures, spec) = diffusion_fixture();
	let original = mixtures.map(|handle| world.snapshot(handle).unwrap());
	assert_eq!(
		world
			.prepare_job_chunk(spec, 32, || true, || false)
			.unwrap(),
		JobProgress::Running
	);
	assert_eq!(
		mixtures.map(|handle| world.snapshot(handle).unwrap()),
		original
	);
	let unit = prepare_until_ready(&mut world, spec);
	assert_eq!(
		mixtures.map(|handle| world.snapshot(handle).unwrap()),
		original
	);
	assert!(!world.commit_job_unit(unit).unwrap().pending);
}

#[test]
fn job_status_reads_report_progress_without_advancing_or_publishing() {
	let (mut world, mixtures, spec) = diffusion_fixture();
	assert!(world.stage_job_view().is_none());
	let before = mixtures.map(|handle| world.snapshot(handle).unwrap());
	assert_eq!(
		world
			.prepare_job_chunk(spec, 256, || true, || false)
			.unwrap(),
		JobProgress::Running
	);
	let admitted = world.stage_job_view().unwrap();
	assert_eq!(admitted.work_items, 0);
	assert_eq!(world.stage_job_view(), Some(admitted));
	world
		.prepare_job_chunk(spec, 1, || false, || false)
		.unwrap();
	let progress = world.stage_job_view().unwrap();
	assert_eq!(progress.work_items, 1);
	assert_eq!(progress.last_committed, None);
	assert_eq!(world.stage_job_view(), Some(progress));
	assert_eq!(
		mixtures.map(|handle| world.snapshot(handle).unwrap()),
		before
	);
	let unit = prepare_until_ready(&mut world, spec);
	let receipt = world.commit_job_unit(unit).unwrap();
	let done = world.stage_job_view().unwrap();
	assert_eq!(done.progress, JobProgress::Done);
	assert_eq!(done.last_committed, Some((unit, receipt)));
	assert_eq!(done.work_items, receipt.work_items);
}

#[test]
fn service_event_allowance_is_checked_before_job_publication() {
	let (mut world, mixtures, spec) = reaction_fixture(4096, 4096);
	let before = mixtures.map(|handle| world.snapshot(handle).unwrap());
	let unit = prepare_until_ready(&mut world, spec);
	assert!(matches!(
		world.commit_job_unit_with_event_limit(unit, 0),
		Err(WorldError::EventCapacityExceeded { .. })
	));
	assert_eq!(
		mixtures.map(|handle| world.snapshot(handle).unwrap()),
		before
	);
	assert!(world.pending_events(4096).is_empty());
	assert_eq!(world.pending_reaction_continuations(), 0);
}

const STAGES: [WorldStage; 5] = [
	WorldStage::ProcessTurfs,
	WorldStage::TurfHeat,
	WorldStage::React,
	WorldStage::Equalize,
	WorldStage::ExcitedGroups,
];

fn stage_fixture(stage: WorldStage) -> (DogmosWorld, Vec<MixtureHandle>, StageJobSpec) {
	match stage {
		WorldStage::ProcessTurfs => {
			let (world, mixtures, spec) = diffusion_fixture();
			(world, mixtures.to_vec(), spec)
		}
		WorldStage::TurfHeat => {
			let (world, mixtures, _, spec) = heat_fixture(4096);
			(world, mixtures.to_vec(), spec)
		}
		WorldStage::React => {
			let (world, mixtures, spec) = reaction_fixture(4096, 4096);
			(world, mixtures.to_vec(), spec)
		}
		WorldStage::Equalize | WorldStage::ExcitedGroups => {
			let (world, mixtures, spec) = component_fixture(stage);
			(world, mixtures.to_vec(), spec)
		}
	}
}

#[test]
fn fake_clock_scheduling_preserves_every_stage_transcript() {
	for stage in STAGES {
		for quantum in 1..=7 {
			let (mut world, mixtures, spec) = stage_fixture(stage);
			let (mut oracle, oracle_mixtures, _) = stage_fixture(stage);
			let heat_handles = [0, 1].map(|slot| TurfHandle {
				slot,
				generation: 1,
			});
			let mut committed = mixtures
				.iter()
				.map(|&handle| world.snapshot(handle).unwrap())
				.collect::<Vec<_>>();
			let mut committed_heat = heat_handles.map(|handle| world.turf_heat(handle).unwrap());
			let mut committed_events = Vec::new();
			let mut committed_continuations = 0;
			let mut completed = false;
			for _ in 0..512 {
				let mut elapsed = 0;
				let progress = world
					.prepare_job_chunk(
						spec,
						256,
						|| {
							let due = elapsed >= quantum;
							elapsed += 1;
							due
						},
						|| false,
					)
					.unwrap();
				assert!(elapsed <= quantum + 1);
				assert_eq!(
					mixtures
						.iter()
						.map(|&handle| world.snapshot(handle).unwrap())
						.collect::<Vec<_>>(),
					committed
				);
				assert_eq!(
					heat_handles.map(|handle| world.turf_heat(handle).unwrap()),
					committed_heat
				);
				assert_eq!(world.pending_events(64), committed_events);
				assert_eq!(
					world.pending_reaction_continuations(),
					committed_continuations
				);
				match progress {
					JobProgress::Ready { unit } => {
						let receipt = world.commit_job_unit(unit).unwrap();
						committed = mixtures
							.iter()
							.map(|&handle| world.snapshot(handle).unwrap())
							.collect();
						committed_heat =
							heat_handles.map(|handle| world.turf_heat(handle).unwrap());
						committed_events = world.pending_events(64).to_vec();
						committed_continuations = world.pending_reaction_continuations();
						assert_eq!(world.commit_job_unit(unit).unwrap(), receipt);
					}
					JobProgress::Done => {
						completed = true;
						break;
					}
					JobProgress::Running => {}
					JobProgress::Retrying => panic!("no writer exists in the scheduling fixture"),
				}
			}
			assert!(completed, "{stage:?} quantum {quantum}");
			complete_synchronously(&mut oracle, spec);
			assert_eq!(
				committed,
				oracle_mixtures
					.iter()
					.map(|&handle| oracle.snapshot(handle).unwrap())
					.collect::<Vec<_>>()
			);
			assert_eq!(
				committed_heat,
				heat_handles.map(|handle| oracle.turf_heat(handle).unwrap())
			);
			assert_eq!(committed_events, oracle.pending_events(64));
			assert_eq!(
				committed_continuations,
				oracle.pending_reaction_continuations()
			);
		}
	}
}

#[test]
fn every_unpublished_work_position_can_be_cancelled_and_restarted() {
	for stage in STAGES {
		let mut reached_ready = false;
		for cutoff in 0..256 {
			let (mut world, mixtures, spec) = stage_fixture(stage);
			let original = mixtures
				.iter()
				.map(|&handle| world.snapshot(handle).unwrap())
				.collect::<Vec<_>>();
			let heat_handles = [0, 1].map(|slot| TurfHandle {
				slot,
				generation: 1,
			});
			let original_heat = heat_handles.map(|handle| world.turf_heat(handle).unwrap());
			let mut stale_unit = None;
			for _ in 0..cutoff {
				match world
					.prepare_job_chunk(spec, 1, || false, || false)
					.unwrap()
				{
					JobProgress::Ready { unit } => {
						stale_unit = Some(unit);
						reached_ready = true;
						break;
					}
					JobProgress::Running => {}
					other => panic!("unexpected progress before first commit: {other:?}"),
				}
			}
			assert_eq!(
				world.prepare_job_chunk(spec, 1, || false, || true),
				Err(WorldError::Cancelled)
			);
			assert_eq!(world.pending_stage_epoch(), None);
			assert_eq!(
				mixtures
					.iter()
					.map(|&handle| world.snapshot(handle).unwrap())
					.collect::<Vec<_>>(),
				original
			);
			assert_eq!(
				heat_handles.map(|handle| world.turf_heat(handle).unwrap()),
				original_heat
			);
			assert!(world.pending_events(64).is_empty());
			assert_eq!(world.pending_reaction_continuations(), 0);
			let retry = StageJobSpec {
				stage_epoch: spec.stage_epoch + 1,
				..spec
			};
			let unit = prepare_until_ready(&mut world, retry);
			if let Some(stale) = stale_unit {
				assert_ne!(unit, stale);
				assert!(world.commit_job_unit(stale).is_err());
			}
			world.commit_job_unit(unit).unwrap();
			if reached_ready {
				break;
			}
		}
		assert!(reached_ready, "{stage:?} exceeded fixture work bound");
	}
}
