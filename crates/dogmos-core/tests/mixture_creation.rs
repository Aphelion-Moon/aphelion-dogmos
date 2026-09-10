use dogmos_core::{
	metadata::{GasFireRole, GasId, GasMetadata, TurfHandle},
	world::{
		Command, DogmosWorld, LifecycleAction, LifecycleMutation, MixtureStateMutation,
		StageChunkRequest, TurfLifecycleMutation, WorldError, WorldStage,
	},
	MixtureHandle, MAX_GAS_SLOTS,
};

fn handle(slot: u32, generation: u32) -> MixtureHandle {
	MixtureHandle { slot, generation }
}

fn register(world: &mut DogmosWorld, handle: MixtureHandle) {
	world
		.apply_lifecycle(&[LifecycleMutation {
			action: LifecycleAction::Register,
			handle,
		}])
		.unwrap();
}

fn fixture() -> DogmosWorld {
	let mut world = DogmosWorld::new(1024 * 1024);
	world
		.install_gases(
			(0..MAX_GAS_SLOTS as u16)
				.map(|id| GasMetadata {
					id: GasId(id),
					key: format!("gas{id}").into(),
					name: format!("Gas {id}").into(),
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
	register(&mut world, handle(0, 1));
	world
}

fn old_copy(
	world: &mut DogmosWorld,
	destination: MixtureHandle,
	source: MixtureHandle,
	volume: f32,
) {
	register(world, destination);
	if volume != 2500.0 {
		world
			.apply_command(Command::SetVolume {
				handle: destination,
				volume,
			})
			.unwrap();
	}
	world
		.apply_command(Command::CopyFrom {
			receiver: destination,
			giver: source,
		})
		.unwrap();
}

#[test]
fn creation_matches_constructor_sequence_and_keeps_source_independent() {
	// Literal revisions: default registration starts at zero; changing volume adds
	// one, and copying different gas/temperature adds one independently.
	for (volume, temperature, moles, revision) in [
		(2500.0_f32, 2.7, 0.0, 0),
		(2500.0, 293.15, 0.0, 1),
		(2500.0, 2.7, 2.0, 1),
		(125.0, 700.0, 2.0, 2),
		(0.0, 2.7, 0.0, 1),
		(-0.0, 2.7, 0.0, 1),
	] {
		for immutable in [false, true] {
			for recycled in [false, true] {
				let source = handle(0, 1);
				let destination = handle(1, if recycled { 2 } else { 1 });
				let mut candidate = fixture();
				let mut control = fixture();
				for world in [&mut candidate, &mut control] {
					if recycled {
						register(world, handle(1, 1));
						world
							.apply_lifecycle(&[LifecycleMutation {
								action: LifecycleAction::Unregister,
								handle: handle(1, 1),
							}])
							.unwrap();
					}
					world
						.apply_command(Command::SetVolume {
							handle: source,
							volume,
						})
						.unwrap();
					world
						.apply_command(Command::SetTemperature {
							handle: source,
							temperature,
						})
						.unwrap();
					for id in 0..MAX_GAS_SLOTS as u16 {
						world
							.apply_command(Command::SetMoles {
								handle: source,
								gas: GasId(id),
								amount: moles,
							})
							.unwrap();
					}
					world
						.apply_command(Command::SetMinimumHeatCapacity {
							handle: source,
							amount: 17.0,
						})
						.unwrap();
					if immutable {
						world
							.apply_command(Command::MarkImmutable { handle: source })
							.unwrap();
					}
				}
				let source_before = candidate.snapshot(source).unwrap();
				old_copy(&mut control, destination, source, volume);
				candidate
					.create_mixture_from_source(destination, source, volume)
					.unwrap();
				let actual = candidate.snapshot(destination).unwrap();
				assert_eq!(actual, control.snapshot(destination).unwrap());
				assert_eq!(actual.revision, revision);
				assert_eq!(actual.volume.to_bits(), volume.to_bits());
				assert_eq!(actual.minimum_heat_capacity, 0.0);
				assert!(!actual.immutable);
				assert_eq!(actual.gases, [moles; MAX_GAS_SLOTS]);
				assert_eq!(candidate.snapshot(source).unwrap(), source_before);
				candidate
					.apply_command(Command::SetMoles {
						handle: destination,
						gas: GasId(0),
						amount: 99.0,
					})
					.unwrap();
				assert_eq!(candidate.snapshot(source).unwrap(), source_before);
				assert!(candidate.pending_events(u32::MAX).is_empty());
			}
		}
	}
}

#[test]
fn invalid_source_does_not_allocate_or_publish_destination() {
	for source in [handle(99, 1), handle(0, 2)] {
		let mut world = fixture();
		let before = world.snapshot(handle(0, 1)).unwrap();
		assert!(world
			.create_mixture_from_source(handle(1, 1), source, 2500.0)
			.is_err());
		assert_eq!(world.slot_count(), 1);
		assert_eq!(
			world.snapshot(handle(1, 1)),
			Err(WorldError::UnknownHandle(handle(1, 1)))
		);
		assert_eq!(world.snapshot(handle(0, 1)).unwrap(), before);
		world
			.create_mixture_from_source(handle(1, 1), handle(0, 1), 2500.0)
			.unwrap();
	}
}

#[test]
fn invalid_volume_leaves_destination_generation_available_for_retry() {
	for volume in [f32::NAN, f32::INFINITY, f32::NEG_INFINITY, -1.0] {
		let mut world = fixture();
		assert_eq!(
			world.create_mixture_from_source(handle(1, 1), handle(0, 1), volume),
			Err(WorldError::InvalidVolume)
		);
		assert_eq!(world.slot_count(), 1);
		world
			.create_mixture_from_source(handle(1, 1), handle(0, 1), 125.0)
			.unwrap();
		assert_eq!(world.snapshot(handle(1, 1)).unwrap().volume, 125.0);
	}
}

#[test]
fn occupied_or_same_slot_destination_cannot_replace_a_live_mixture() {
	for destination in [handle(0, 1), handle(0, 2), handle(1, 1), handle(1, 2)] {
		let mut world = fixture();
		register(&mut world, handle(1, 1));
		world
			.apply_command(Command::SetTemperature {
				handle: handle(1, 1),
				temperature: 700.0,
			})
			.unwrap();
		let before = [
			world.snapshot(handle(0, 1)).unwrap(),
			world.snapshot(handle(1, 1)).unwrap(),
		];
		assert!(world
			.create_mixture_from_source(destination, handle(0, 1), 2500.0)
			.is_err());
		assert_eq!(
			[
				world.snapshot(handle(0, 1)).unwrap(),
				world.snapshot(handle(1, 1)).unwrap()
			],
			before
		);
		assert_eq!(world.slot_count(), 2);
	}
}

#[test]
fn retired_generation_must_advance_before_creation() {
	let mut world = fixture();
	register(&mut world, handle(1, 7));
	world
		.apply_lifecycle(&[LifecycleMutation {
			action: LifecycleAction::Unregister,
			handle: handle(1, 7),
		}])
		.unwrap();
	for generation in [6, 7] {
		assert_eq!(
			world.create_mixture_from_source(handle(1, generation), handle(0, 1), 2500.0),
			Err(WorldError::StaleHandle {
				requested: handle(1, generation),
				current: 7
			})
		);
		assert_eq!(
			world.snapshot(handle(1, 7)),
			Err(WorldError::UnknownHandle(handle(1, 7)))
		);
	}
	world
		.create_mixture_from_source(handle(1, 8), handle(0, 1), 2500.0)
		.unwrap();
	assert_eq!(world.snapshot(handle(1, 8)).unwrap().revision, 0);
}

#[test]
fn capacity_rejection_preserves_source_and_accepts_smaller_retry() {
	let mut world = fixture();
	let source = world.snapshot(handle(0, 1)).unwrap();
	assert_eq!(
		world.create_mixture_from_source(handle(u32::MAX, 1), handle(0, 1), 2500.0),
		Err(WorldError::StateCapacityExceeded)
	);
	assert_eq!(world.slot_count(), 1);
	assert_eq!(world.snapshot(handle(0, 1)).unwrap(), source);
	world
		.create_mixture_from_source(handle(1, 1), handle(0, 1), 2500.0)
		.unwrap();
}

#[test]
fn creation_and_rejection_leave_active_stage_publishable() {
	for reject in [false, true] {
		let mut world = fixture();
		let source = handle(0, 1);
		let turf = TurfHandle {
			slot: 0,
			generation: 1,
		};
		let mut gases = [0.0; MAX_GAS_SLOTS];
		gases[0] = 10.0;
		world
			.apply_mixture_state(&[MixtureStateMutation {
				handle: source,
				expected_revision: 0,
				temperature: 300.0,
				volume: 2500.0,
				gases,
			}])
			.unwrap();
		world
			.apply_turf_lifecycle(&[TurfLifecycleMutation::Register {
				handle: turf,
				mixture: Some(source),
			}])
			.unwrap();
		world.begin_frontier(1, 1).unwrap();
		world.append_frontier(1, 0, &[turf]).unwrap();
		world.commit_frontier(1).unwrap();
		let request = StageChunkRequest {
			stage: WorldStage::ProcessTurfs,
			frontier_epoch: 1,
			stage_epoch: 1,
			work_limit: 1,
			seconds_per_tick: 0.5,
		};
		assert!(
			world
				.process_stage_chunk_cancellable(request, || false)
				.unwrap()
				.pending
		);
		let before = world.snapshot(source).unwrap();
		let telemetry = world.stage_telemetry();
		if reject {
			assert!(world
				.create_mixture_from_source(handle(1, 1), handle(0, 2), 2500.0)
				.is_err());
		} else {
			world
				.create_mixture_from_source(handle(1, 1), source, 2500.0)
				.unwrap();
			assert_eq!(world.snapshot(handle(1, 1)).unwrap().gases, before.gases);
		}
		assert_eq!(world.snapshot(source).unwrap(), before);
		assert_eq!(world.stage_telemetry(), telemetry);
		let mut finished = false;
		for _ in 0..16 {
			if !world
				.process_stage_chunk_cancellable(request, || false)
				.unwrap()
				.pending
			{
				finished = true;
				break;
			}
		}
		assert!(finished, "single-turf stage must remain publishable");
		assert_eq!(world.snapshot(source).unwrap().gases, gases);
		assert_eq!(world.snapshot(source).unwrap().revision, 2);
	}
}
