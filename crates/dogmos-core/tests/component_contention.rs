use dogmos_core::{
	metadata::{GasFireRole, GasId, GasMetadata, TurfHandle},
	world::{
		Command, DogmosWorld, LifecycleAction, LifecycleMutation, MixtureStateMutation,
		StageChunkRequest, TurfAdjacencyMutation, TurfLifecycleMutation, WorldStage,
	},
	MixtureHandle, MAX_GAS_SLOTS,
};

fn fixture(stage: WorldStage) -> (DogmosWorld, StageChunkRequest) {
	fixture_components(stage, 1)
}

fn fixture_components(stage: WorldStage, components: u32) -> (DogmosWorld, StageChunkRequest) {
	let mut world = DogmosWorld::new_with_event_capacity(1024 * 1024, 128);
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
	let turfs: Vec<_> = (0..components * 2)
		.map(|slot| TurfHandle {
			slot,
			generation: 1,
		})
		.collect();
	for slot in 0..components * 2 {
		let handle = MixtureHandle {
			slot,
			generation: 1,
		};
		world
			.apply_lifecycle(&[LifecycleMutation {
				action: LifecycleAction::Register,
				handle,
			}])
			.unwrap();
		let mut gases = [0.0; MAX_GAS_SLOTS];
		gases[0] = 10.0;
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
				handle: turfs[slot as usize],
				mixture: Some(handle),
			}])
			.unwrap();
	}
	for pair in turfs.as_chunks::<2>().0 {
		world
			.apply_turf_adjacency(&[TurfAdjacencyMutation {
				left: pair[0],
				right: pair[1],
				connected: true,
			}])
			.unwrap();
	}
	world.begin_frontier(1, components * 2).unwrap();
	world.append_frontier(1, 0, &turfs).unwrap();
	world.commit_frontier(1).unwrap();
	(
		world,
		StageChunkRequest {
			stage,
			frontier_epoch: 1,
			stage_epoch: 1,
			work_limit: 1,
			seconds_per_tick: 0.5,
		},
	)
}

#[test]
fn repeated_gameplay_writes_preserve_completed_components() {
	for stage in [WorldStage::ExcitedGroups, WorldStage::Equalize] {
		let (mut world, request) = fixture_components(stage, 2);
		let mut expected_energy = 240000.0;
		let mut writes = 0;
		let mut complete = false;
		for tick in 0..2048 {
			let result = world
				.process_stage_chunk_cancellable(request, || false)
				.unwrap();
			assert!(result.work_items <= 1);
			if !result.pending {
				let components = if stage == WorldStage::ExcitedGroups {
					result.produced_group_seeds
				} else {
					result.produced_equalize_seeds
				};
				assert_eq!(
					components, 2,
					"retries must not discard or recount earlier components"
				);
				complete = true;
				break;
			}
			// Continue gameplay writes through several attempts, then allow the stage to settle.
			if tick < 256 && tick % 7 == 0 {
				let handle = MixtureHandle {
					slot: 2,
					generation: 1,
				};
				let before = world.snapshot(handle).unwrap();
				world
					.apply_command(Command::SetTemperature {
						handle,
						temperature: before.temperature + 1.0,
					})
					.unwrap();
				expected_energy += before.total_moles * 20.0;
				writes += 1;
			}
		}
		assert!(complete, "{stage:?} failed to finish after writes stopped");
		assert!(writes > 5);
		let snapshots: Vec<_> = (0..4)
			.map(|slot| {
				world
					.snapshot(MixtureHandle {
						slot,
						generation: 1,
					})
					.unwrap()
			})
			.collect();
		let moles: f32 = snapshots.iter().map(|s| s.total_moles).sum();
		let energy: f32 = snapshots
			.iter()
			.map(|s| s.total_moles * s.temperature * 20.0)
			.sum();
		assert!((moles - 40.0).abs() < 0.001);
		assert!(
			(energy - expected_energy).abs() < 1.0,
			"{stage:?}: expected {expected_energy}, got {energy}"
		);
	}
}

#[test]
fn gameplay_write_at_each_component_yield_preserves_moles_and_energy() {
	for stage in [WorldStage::ExcitedGroups, WorldStage::Equalize] {
		let mut tested = 0;
		for pause in 1..256 {
			let (mut world, request) = fixture(stage);
			let mut pending = true;
			for _ in 0..pause {
				let result = world
					.process_stage_chunk_cancellable(request, || false)
					.unwrap();
				assert!(result.work_items <= 1);
				pending = result.pending;
				if !pending {
					break;
				}
			}
			if !pending {
				break;
			}
			tested += 1;
			world
				.apply_command(Command::SetTemperature {
					handle: MixtureHandle {
						slot: 0,
						generation: 1,
					},
					temperature: 302.0,
				})
				.unwrap();
			for _ in 0..512 {
				let result = world
					.process_stage_chunk_cancellable(request, || false)
					.unwrap_or_else(|error| panic!("{stage:?}, pause {pause}: {error:?}"));
				assert!(result.work_items <= 1);
				pending = result.pending;
				if !pending {
					break;
				}
			}
			assert!(!pending, "{stage:?}, pause {pause} failed to finish");
			let a = world
				.snapshot(MixtureHandle {
					slot: 0,
					generation: 1,
				})
				.unwrap();
			let b = world
				.snapshot(MixtureHandle {
					slot: 1,
					generation: 1,
				})
				.unwrap();
			assert!((a.total_moles + b.total_moles - 20.0).abs() < 0.001);
			let energy = 20.0 * (a.total_moles * a.temperature + b.total_moles * b.temperature);
			assert!(
				(energy - 120400.0).abs() < 1.0,
				"{stage:?}, pause {pause}: energy {energy}"
			);
		}
		assert!(
			tested > 10,
			"fixture must exercise capture, computation and publication"
		);
	}
}
