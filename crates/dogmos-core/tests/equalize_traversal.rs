use dogmos_core::{
	metadata::{GasFireRole, GasId, GasMetadata, TurfHandle},
	world::{
		Command, DogmosWorld, LifecycleAction, LifecycleMutation, MixtureStateMutation,
		StageChunkRequest, TurfAdjacencyMutation, TurfFirelockMutation, TurfLifecycleMutation,
		WorldEvent, WorldStage,
	},
	MixtureHandle, MAX_GAS_SLOTS,
};

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

fn branched_world() -> DogmosWorld {
	branched_world_with_mixtures([100, 7, 22, 900, 3].map(mixture))
}

fn branched_world_with_mixtures(mixtures: [MixtureHandle; 5]) -> DogmosWorld {
	let mut world = DogmosWorld::new(4 * 1024 * 1024);
	world
		.install_gases(vec![GasMetadata {
			id: GasId(0),
			key: "o2".into(),
			name: "Oxygen".into(),
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
	for ((slot, moles), handle) in [(100, 0.0), (7, 30.0), (22, 0.0), (900, 60.0), (3, 10.0)]
		.into_iter()
		.zip(mixtures)
	{
		world
			.apply_lifecycle(&[LifecycleMutation {
				action: LifecycleAction::Register,
				handle,
			}])
			.unwrap();
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
		world
			.apply_turf_lifecycle(&[TurfLifecycleMutation::Register {
				handle: turf(slot),
				mixture: Some(handle),
			}])
			.unwrap();
	}
	world
		.apply_turf_adjacency(
			&[(100, 7), (100, 22), (22, 900), (100, 3)].map(|(left, right)| {
				TurfAdjacencyMutation {
					left: turf(left),
					right: turf(right),
					connected: true,
				}
			}),
		)
		.unwrap();
	world
		.add_frontier(1, &[100, 7, 22, 900, 3].map(turf))
		.unwrap();
	world
}

fn unrelated_mixture_handles() -> [MixtureHandle; 5] {
	[(71, 3), (2, 7), (400, 1), (17, 5), (77, 2)]
		.map(|(slot, generation)| MixtureHandle { slot, generation })
}

#[test]
fn equalization_resolves_mixtures_from_turf_associations() {
	let mixtures = unrelated_mixture_handles();
	for work_limit in [1, 7, 4096] {
		let mut world = branched_world_with_mixtures(mixtures);
		finish_equalize(&mut world, work_limit);
		for handle in mixtures {
			assert_eq!(world.snapshot(handle).unwrap().total_moles, 20.0);
		}
		assert_eq!(
			world.pending_events(u32::MAX),
			&[
				WorldEvent::PressureDifference {
					source: turf(900),
					target: turf(22),
					moles: 40.0
				},
				WorldEvent::PressureDifference {
					source: turf(22),
					target: turf(100),
					moles: 20.0
				},
				WorldEvent::PressureDifference {
					source: turf(7),
					target: turf(100),
					moles: 10.0
				},
				WorldEvent::PressureDifference {
					source: turf(100),
					target: turf(3),
					moles: 10.0
				},
			]
		);
	}
}

#[test]
fn decompression_preserves_order_and_loss_with_multiple_immutable_boundaries() {
	let mixtures = unrelated_mixture_handles();
	for work_limit in [1, 7, 4096] {
		let mut world = branched_world_with_mixtures(mixtures);
		for handle in [mixtures[0], mixtures[4]] {
			world
				.apply_command(Command::MarkImmutable { handle })
				.unwrap();
		}
		let immutable_before = [mixtures[0], mixtures[4]].map(|h| world.snapshot(h).unwrap());
		world
			.apply_turf_firelocks(&[(7, 100), (22, 900)].map(|(left, right)| {
				TurfFirelockMutation {
					left: turf(left),
					right: turf(right),
					firelock: true,
				}
			}))
			.unwrap();
		finish_equalize(&mut world, work_limit);
		assert_eq!(
			mixtures.map(|h| world.snapshot(h).unwrap().total_moles),
			[0.0, 15.0, 0.0, 45.0, 10.0]
		);
		assert_eq!(
			[mixtures[0], mixtures[4]].map(|h| world.snapshot(h).unwrap()),
			immutable_before
		);
		// Two immutable roots give a 1/2 frontage factor. Ninety moles over
		// three mutable turfs removes up to 15 per turf; the empty turf loses zero.
		assert_eq!(
			world.pending_events(u32::MAX),
			&[
				WorldEvent::FirelockConsideration {
					source: turf(7),
					target: turf(100)
				},
				WorldEvent::FirelockConsideration {
					source: turf(22),
					target: turf(900)
				},
				WorldEvent::PressureDifference {
					source: turf(900),
					target: turf(22),
					moles: 15.0
				},
				WorldEvent::PressureDifference {
					source: turf(22),
					target: turf(100),
					moles: 15.0
				},
				WorldEvent::PressureDifference {
					source: turf(7),
					target: turf(100),
					moles: 15.0
				},
				WorldEvent::DecompressionFloorRip {
					turf: turf(7),
					moles_lost: 15.0
				},
			]
		);
	}
}

#[test]
fn decompression_separates_local_floor_loss_from_descendant_pressure() {
	let mixtures = unrelated_mixture_handles();
	for work_limit in [1, 7, 4096] {
		let mut world = branched_world_with_mixtures(mixtures);
		// Discover from the far end: BFS order differs from sorted turf slots.
		world.begin_frontier(2, 5).unwrap();
		world
			.append_frontier(2, 0, &[900, 22, 100, 3, 7].map(turf))
			.unwrap();
		world.commit_frontier(2).unwrap();
		world
			.apply_command(Command::MarkImmutable {
				handle: mixtures[0],
			})
			.unwrap();
		world
			.apply_command(Command::SetMoles {
				handle: mixtures[2],
				gas: GasId(0),
				amount: 30.0,
			})
			.unwrap();
		finish_equalize(&mut world, work_limit);
		// 130 mutable moles / 4 mutable turfs / 4 frontage divisor = 8.125
		// removed locally. The junction at 22 also carries 900's loss to space.
		assert_eq!(
			mixtures.map(|handle| world.snapshot(handle).unwrap().total_moles),
			[0.0, 21.875, 21.875, 51.875, 1.875]
		);
		assert_eq!(
			world.pending_events(u32::MAX),
			&[
				WorldEvent::PressureDifference {
					source: turf(900),
					target: turf(22),
					moles: 8.125,
				},
				WorldEvent::PressureDifference {
					source: turf(22),
					target: turf(100),
					moles: 16.25,
				},
				WorldEvent::DecompressionFloorRip {
					turf: turf(22),
					moles_lost: 8.125,
				},
				WorldEvent::PressureDifference {
					source: turf(7),
					target: turf(100),
					moles: 8.125,
				},
				WorldEvent::DecompressionFloorRip {
					turf: turf(7),
					moles_lost: 8.125,
				},
				WorldEvent::PressureDifference {
					source: turf(3),
					target: turf(100),
					moles: 8.125,
				},
				WorldEvent::DecompressionFloorRip {
					turf: turf(3),
					moles_lost: 8.125,
				},
			]
		);
	}
}

fn finish_equalize(world: &mut DogmosWorld, work_limit: u32) {
	let request = StageChunkRequest {
		stage: WorldStage::Equalize,
		frontier_epoch: world.committed_frontier_epoch().unwrap(),
		stage_epoch: 1,
		work_limit,
		seconds_per_tick: 0.5,
	};
	for _ in 0..256 {
		let result = world
			.process_stage_chunk_cancellable(request, || false)
			.unwrap();
		assert!(result.work_items <= work_limit);
		if !result.pending {
			return;
		}
	}
	panic!("equalization must finish within the fixture's chunk bound");
}

#[test]
fn branched_equalization_preserves_parent_paths_and_transfer_order() {
	for work_limit in [1, 7, 4096] {
		let mut world = branched_world();
		let request = StageChunkRequest {
			stage: WorldStage::Equalize,
			frontier_epoch: 1,
			stage_epoch: 1,
			work_limit,
			seconds_per_tick: 0.5,
		};
		let mut complete = false;
		for _ in 0..256 {
			let result = world
				.process_stage_chunk_cancellable(request, || false)
				.unwrap();
			assert!(result.work_items <= work_limit);
			if !result.pending {
				complete = true;
				break;
			}
			let visible =
				[100, 7, 22, 900, 3].map(|slot| world.snapshot(mixture(slot)).unwrap().total_moles);
			assert!(visible == [0.0, 30.0, 0.0, 60.0, 10.0] || visible == [20.0; 5]);
			if visible[0] == 0.0 {
				assert!(world.pending_events(u32::MAX).is_empty());
			} else {
				assert_eq!(world.pending_events(u32::MAX).len(), 4);
			}
		}
		assert!(complete, "branched equalization must finish");
		for slot in [100, 7, 22, 900, 3] {
			assert_eq!(world.snapshot(mixture(slot)).unwrap().total_moles, 20.0);
		}
		assert_eq!(
			world.pending_events(u32::MAX),
			&[
				WorldEvent::PressureDifference {
					source: turf(900),
					target: turf(22),
					moles: 40.0
				},
				WorldEvent::PressureDifference {
					source: turf(22),
					target: turf(100),
					moles: 20.0
				},
				WorldEvent::PressureDifference {
					source: turf(7),
					target: turf(100),
					moles: 10.0
				},
				WorldEvent::PressureDifference {
					source: turf(100),
					target: turf(3),
					moles: 10.0
				},
			]
		);
	}
}

#[test]
fn cyclic_equalization_visits_sparse_turfs_once_across_repeated_stages() {
	for work_limit in [1, 7, 4096] {
		let mut world = branched_world();
		world
			.apply_turf_adjacency(&[TurfAdjacencyMutation {
				left: turf(7),
				right: turf(900),
				connected: true,
			}])
			.unwrap();
		for epoch in 1..=2 {
			if epoch == 2 {
				world.discard_pending_events(4).unwrap();
				for (slot, moles) in [(100, 0.0), (7, 30.0), (22, 0.0), (900, 60.0), (3, 10.0)] {
					let handle = mixture(slot);
					let mut gases = [0.0; MAX_GAS_SLOTS];
					gases[0] = moles;
					world
						.apply_mixture_state(&[MixtureStateMutation {
							handle,
							expected_revision: world.snapshot(handle).unwrap().revision,
							temperature: 300.0,
							volume: 2500.0,
							gases,
						}])
						.unwrap();
				}
			}
			let request = StageChunkRequest {
				stage: WorldStage::Equalize,
				frontier_epoch: 1,
				stage_epoch: epoch,
				work_limit,
				seconds_per_tick: 0.5,
			};
			let mut complete = false;
			for _ in 0..256 {
				let result = world
					.process_stage_chunk_cancellable(request, || false)
					.unwrap();
				assert!(result.work_items <= work_limit);
				if !result.pending {
					complete = true;
					break;
				}
			}
			assert!(complete, "cyclic equalization must finish");
			for slot in [100, 7, 22, 900, 3] {
				assert_eq!(world.snapshot(mixture(slot)).unwrap().total_moles, 20.0);
			}
			// Sorted neighbor traversal reaches 900 through 7 before 22. The extra
			// edge must not duplicate 900 or change its chosen parent on a revisit.
			assert_eq!(
				world.pending_events(u32::MAX),
				&[
					WorldEvent::PressureDifference {
						source: turf(900),
						target: turf(7),
						moles: 40.0
					},
					WorldEvent::PressureDifference {
						source: turf(7),
						target: turf(100),
						moles: 50.0
					},
					WorldEvent::PressureDifference {
						source: turf(100),
						target: turf(3),
						moles: 10.0
					},
					WorldEvent::PressureDifference {
						source: turf(100),
						target: turf(22),
						moles: 20.0
					},
				]
			);
		}
	}
}
