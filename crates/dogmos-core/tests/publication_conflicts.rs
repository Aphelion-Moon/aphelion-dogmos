use dogmos_core::{
	metadata::{GasFireRole, GasId, GasMetadata, TurfHandle},
	world::{
		Command, CommandResult, DogmosWorld, LifecycleAction, LifecycleMutation,
		MixtureStateMutation, StageChunkRequest, TurfLifecycleMutation, WorldError, WorldStage,
	},
	MixtureHandle, MAX_GAS_SLOTS,
};

fn paused_diffusion() -> (DogmosWorld, MixtureHandle, StageChunkRequest) {
	paused_diffusion_with_immutable(false)
}

fn paused_diffusion_with_immutable(
	immutable: bool,
) -> (DogmosWorld, MixtureHandle, StageChunkRequest) {
	let mut world = DogmosWorld::new_with_event_capacity(1024 * 1024, 64);
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
	let mixture = MixtureHandle {
		slot: 0,
		generation: 1,
	};
	let turf = TurfHandle {
		slot: 0,
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
	world
		.apply_mixture_state(&[MixtureStateMutation {
			handle: mixture,
			expected_revision: 0,
			temperature: 300.0,
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
	if immutable {
		world
			.apply_command(Command::MarkImmutable { handle: mixture })
			.unwrap();
	}
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
	(world, mixture, request)
}

fn finish(world: &mut DogmosWorld, request: StageChunkRequest) -> Result<(), WorldError> {
	for _ in 0..16 {
		if !world
			.process_stage_chunk_cancellable(request, || false)?
			.pending
		{
			return Ok(());
		}
	}
	panic!("single-turf diffusion exceeded the bounded fixture");
}

#[test]
fn undisturbed_diffusion_publishes() {
	let (mut world, mixture, request) = paused_diffusion();
	finish(&mut world, request).unwrap();
	let snapshot = world.snapshot(mixture).unwrap();
	assert_eq!(
		(
			snapshot.revision,
			snapshot.temperature,
			snapshot.total_moles
		),
		(2, 300.0, 10.0)
	);
}

#[test]
fn unchanged_temperature_does_not_invalidate_diffusion() {
	let (mut world, mixture, request) = paused_diffusion();
	assert_eq!(
		world
			.apply_command(Command::SetTemperature {
				handle: mixture,
				temperature: 300.0
			})
			.unwrap(),
		CommandResult::Applied { updated: 0 }
	);
	assert_eq!(world.snapshot(mixture).unwrap().revision, 1);
	finish(&mut world, request).expect("a zero-update command must leave diffusion publishable");
	let snapshot = world.snapshot(mixture).unwrap();
	assert_eq!(
		(
			snapshot.revision,
			snapshot.temperature,
			snapshot.total_moles
		),
		(2, 300.0, 10.0)
	);
}

#[test]
fn real_write_survives_diffusion_resnapshot() {
	let (mut world, mixture, request) = paused_diffusion();
	assert_eq!(
		world
			.apply_command(Command::SetTemperature {
				handle: mixture,
				temperature: 320.0
			})
			.unwrap(),
		CommandResult::Applied { updated: 1 }
	);
	finish(&mut world, request).expect("accepted gameplay writes must restart stale diffusion");
	let snapshot = world.snapshot(mixture).unwrap();
	assert_eq!(
		(
			snapshot.revision,
			snapshot.temperature,
			snapshot.total_moles
		),
		(3, 320.0, 10.0)
	);
}

#[test]
fn repeated_writes_keep_chunks_bounded_and_publish_after_contention_stops() {
	let (mut world, mixture, request) = paused_diffusion();
	for temperature in [310.0, 320.0, 330.0] {
		world
			.apply_command(Command::SetTemperature {
				handle: mixture,
				temperature,
			})
			.unwrap();
		let retry = world
			.process_stage_chunk_cancellable(request, || false)
			.unwrap();
		assert!(retry.pending);
		assert!(retry.work_items <= request.work_limit);
		assert_eq!(world.pending_stage_epoch(), Some(request.stage_epoch));
		assert_eq!(world.snapshot(mixture).unwrap().temperature, temperature);
		// Recollect the single input, then interrupt it again before publication.
		assert!(
			world
				.process_stage_chunk_cancellable(request, || false)
				.unwrap()
				.pending
		);
	}
	finish(&mut world, request).unwrap();
	assert_eq!(world.snapshot(mixture).unwrap().temperature, 330.0);
	assert_eq!(world.snapshot(mixture).unwrap().total_moles, 10.0);
}

#[test]
fn resnapshot_retains_identity_validation_and_cancellation() {
	for cancel in [false, true] {
		let (mut world, mixture, request) = paused_diffusion();
		world
			.apply_command(Command::SetTemperature {
				handle: mixture,
				temperature: 320.0,
			})
			.unwrap();
		assert!(
			world
				.process_stage_chunk_cancellable(request, || false)
				.unwrap()
				.pending
		);
		let invalid_request = StageChunkRequest {
			stage_epoch: request.stage_epoch + 1,
			..request
		};
		let result = if cancel {
			world.process_stage_chunk_cancellable(request, || true)
		} else {
			world.process_stage_chunk_cancellable(invalid_request, || false)
		};
		if cancel {
			assert!(matches!(result, Err(WorldError::Cancelled)));
		} else {
			assert!(matches!(result, Err(WorldError::StageConflict(_))));
		}
		assert_eq!(world.pending_stage_epoch(), None);
		assert_eq!(world.snapshot(mixture).unwrap().temperature, 320.0);
		assert_eq!(world.snapshot(mixture).unwrap().revision, 2);
	}
}

#[test]
fn zero_update_commands_preserve_prepared_diffusion() {
	let handle = MixtureHandle {
		slot: 0,
		generation: 1,
	};
	for command in [
		Command::SetMoles {
			handle,
			gas: GasId(0),
			amount: 10.0,
		},
		Command::AdjustMoles {
			handle,
			gas: GasId(0),
			delta: 0.0,
		},
		Command::AdjustMultiple {
			handle,
			adjustments: vec![(GasId(0), 0.0)].into_boxed_slice(),
		},
		Command::SetVolume {
			handle,
			volume: 2500.0,
		},
		Command::SetMinimumHeatCapacity {
			handle,
			amount: 0.0,
		},
		Command::Add {
			handle,
			amount: 0.0,
		},
		Command::Multiply {
			handle,
			factor: 1.0,
		},
		Command::AdjustHeat { handle, heat: 0.0 },
	] {
		let (mut world, mixture, request) = paused_diffusion();
		assert_eq!(
			world.apply_command(command).unwrap(),
			CommandResult::Applied { updated: 0 }
		);
		assert_eq!(world.snapshot(mixture).unwrap().revision, 1);
		finish(&mut world, request).expect("zero-update command invalidated diffusion");
		let snapshot = world.snapshot(mixture).unwrap();
		assert_eq!(
			(
				snapshot.revision,
				snapshot.temperature,
				snapshot.total_moles
			),
			(2, 300.0, 10.0)
		);
	}
}

#[test]
fn zero_heat_exchange_preserves_prepared_diffusion() {
	let (mut world, mixture, request) = paused_diffusion();
	assert_eq!(
		world
			.apply_command(Command::TemperatureShareNonGas {
				handle: mixture,
				conduction_coefficient: 1.0,
				sharer_temperature: 300.0,
				sharer_heat_capacity: 100.0,
			})
			.unwrap(),
		CommandResult::Scalar(300.0)
	);
	finish(&mut world, request).unwrap();
	let snapshot = world.snapshot(mixture).unwrap();
	assert_eq!(
		(
			snapshot.revision,
			snapshot.temperature,
			snapshot.total_moles
		),
		(2, 300.0, 10.0)
	);
}

#[test]
fn immutable_commands_preserve_prepared_diffusion() {
	let handle = MixtureHandle {
		slot: 0,
		generation: 1,
	};
	for command in [
		Command::SetTemperature {
			handle,
			temperature: 320.0,
		},
		Command::SetVolume {
			handle,
			volume: 50.0,
		},
		Command::Clear { handle },
		Command::MarkImmutable { handle },
	] {
		let (mut world, mixture, request) = paused_diffusion_with_immutable(true);
		assert_eq!(
			world.apply_command(command).unwrap(),
			CommandResult::Applied { updated: 0 }
		);
		finish(&mut world, request).expect("ignored immutable command invalidated diffusion");
		let snapshot = world.snapshot(mixture).unwrap();
		assert!(snapshot.immutable);
		assert_eq!(
			(
				snapshot.revision,
				snapshot.temperature,
				snapshot.total_moles
			),
			(2, 300.0, 10.0)
		);
	}
}

#[test]
fn immutable_state_batch_preserves_prepared_diffusion() {
	let (mut world, mixture, request) = paused_diffusion_with_immutable(true);
	let mut gases = [0.0; MAX_GAS_SLOTS];
	gases[0] = 20.0;
	assert_eq!(
		world
			.apply_mixture_state(&[MixtureStateMutation {
				handle: mixture,
				expected_revision: 2,
				temperature: 600.0,
				volume: 50.0,
				gases,
			}])
			.unwrap(),
		1
	);
	finish(&mut world, request).expect("ignored immutable state batch invalidated diffusion");
	let snapshot = world.snapshot(mixture).unwrap();
	assert!(snapshot.immutable);
	assert_eq!(
		(
			snapshot.revision,
			snapshot.temperature,
			snapshot.total_moles
		),
		(2, 300.0, 10.0)
	);
}
