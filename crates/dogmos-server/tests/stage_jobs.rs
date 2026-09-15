use dogmos_core::{
	metadata::{GasFireRole, GasId, GasMetadata, TurfHandle},
	world::{
		DogmosWorld, LifecycleAction, LifecycleMutation, MixtureStateMutation,
		TurfLifecycleMutation,
	},
	MixtureHandle, MAX_GAS_SLOTS,
};
use dogmos_protocol::{
	ScalarValue, SimulationStage, StageJobCommit, StageJobStatus, StageJobSubmit,
};
use dogmos_server::jobs::{JobError, StageJobController};

fn fixture() -> (DogmosWorld, StageJobSubmit) {
	fixture_with_gases(false)
}

fn fixture_with_gases(install_gases: bool) -> (DogmosWorld, StageJobSubmit) {
	let mut world = DogmosWorld::new_with_capacities(1024 * 1024, 64, 64);
	if install_gases {
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
	}
	for slot in 0..8 {
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
		world
			.apply_mixture_state(&[MixtureStateMutation {
				handle,
				expected_revision: 0,
				temperature: 300.0,
				volume: 2500.0,
				gases: [0.0; MAX_GAS_SLOTS],
			}])
			.unwrap();
		world
			.apply_turf_lifecycle(&[TurfLifecycleMutation::Register {
				handle: TurfHandle {
					slot,
					generation: 1,
				},
				mixture: Some(handle),
			}])
			.unwrap();
	}
	world
		.add_frontier(
			1,
			&(0..8)
				.map(|slot| TurfHandle {
					slot,
					generation: 1,
				})
				.collect::<Vec<_>>(),
		)
		.unwrap();
	let request = StageJobSubmit {
		stage: SimulationStage::ProcessTurfs,
		work_limit: 1,
		frontier_epoch: 1,
		stage_epoch: 1,
		seconds_per_tick: ScalarValue(0.5),
		quantum_us: 1000,
	};
	(world, request)
}

#[test]
fn admission_polling_busy_and_quantum_are_distinct() {
	let (mut world, request) = fixture();
	let mut jobs = StageJobController::default();
	let accepted = jobs.submit(&mut world, request).unwrap();
	assert_eq!(accepted.status, StageJobStatus::Accepted);
	assert_eq!(accepted.work_items, 0);
	assert!(jobs.runnable());
	assert_eq!(jobs.poll(accepted.job).unwrap(), accepted);
	assert!(matches!(
		jobs.submit(
			&mut world,
			StageJobSubmit {
				stage_epoch: 2,
				..request
			}
		),
		Err(JobError::Busy)
	));
	let yielded = jobs.prepare(&mut world, || true, || false).unwrap();
	assert_eq!(yielded.work_items, 0);
	let progressed = jobs.prepare(&mut world, || false, || false).unwrap();
	assert_eq!(progressed.work_items, 1);
	assert_eq!(progressed.status, StageJobStatus::Running);
	assert_eq!(jobs.poll(accepted.job).unwrap(), progressed);
}

#[test]
fn effect_free_component_totals_advance_only_with_one_final_commit() {
	for stage in [
		SimulationStage::ProcessTurfEqualize,
		SimulationStage::ProcessExcitedGroups,
	] {
		let (mut world, mut request) = fixture_with_gases(true);
		request.stage = stage;
		let mut jobs = StageJobController::default();
		let accepted = jobs.submit(&mut world, request).unwrap();
		let ready = (0..1024)
			.find_map(|_| {
				let response = jobs.prepare(&mut world, || false, || false).unwrap();
				assert_eq!(response.committed_units, 0);
				assert_eq!(
					response.produced_equalize_seeds + response.produced_group_seeds,
					0
				);
				assert_eq!(response.callback_events, 0);
				assert_eq!(jobs.poll(accepted.job).unwrap(), response);
				assert!(world.pending_events(64).is_empty());
				match response.status {
					StageJobStatus::Ready => Some(response),
					StageJobStatus::Running => None,
					status => panic!("unexpected preparation status: {status:?}"),
				}
			})
			.expect(
				"eight isolated components should finish preparation within a bounded work count",
			);
		assert_eq!(ready.remaining_estimate, 0);
		let commit = StageJobCommit {
			job: ready.job,
			unit: ready.unit,
		};
		let receipt = jobs.commit(&mut world, commit, 0).unwrap();
		assert_eq!(receipt.status, StageJobStatus::Done);
		assert_eq!(receipt.committed_units, 1);
		assert_eq!(
			receipt.produced_equalize_seeds + receipt.produced_group_seeds,
			8
		);
		assert_eq!(receipt.callback_events, 0);
		assert_eq!(jobs.poll(accepted.job).unwrap(), receipt);
		assert_eq!(jobs.commit(&mut world, commit, 0).unwrap(), receipt);
		assert_eq!(jobs.cancel(&mut world, accepted.job).unwrap(), receipt);
		assert!(!jobs.active());
	}
}

#[test]
fn receipt_replay_and_new_job_identity_survive_terminal_transitions() {
	let (mut world, request) = fixture();
	let mut jobs = StageJobController::default();
	let accepted = jobs.submit(&mut world, request).unwrap();
	let ready = loop {
		let response = jobs.prepare(&mut world, || false, || false).unwrap();
		if response.status == StageJobStatus::Ready {
			break response;
		}
		assert!(response.work_items < 100);
	};
	assert!(!jobs.runnable());
	let commit = StageJobCommit {
		job: ready.job,
		unit: ready.unit,
	};
	let receipt = jobs.commit(&mut world, commit, 64).unwrap();
	assert_eq!(receipt.status, StageJobStatus::Done);
	assert_eq!(receipt.committed_units, 1);
	assert_eq!(jobs.commit(&mut world, commit, 0).unwrap(), receipt);
	assert_eq!(jobs.cancel(&mut world, ready.job).unwrap(), receipt);
	assert!(matches!(
		jobs.submit(&mut world, request),
		Err(JobError::StaleStageEpoch)
	));
	assert_eq!(jobs.poll(accepted.job).unwrap(), receipt);
	let next = jobs
		.submit(
			&mut world,
			StageJobSubmit {
				stage_epoch: 2,
				..request
			},
		)
		.unwrap();
	assert!(next.job > accepted.job);
	assert!(jobs.poll(accepted.job).is_err());
	assert!(jobs.commit(&mut world, commit, 64).is_err());
	let cancelled = jobs.cancel(&mut world, next.job).unwrap();
	assert_eq!(cancelled.status, StageJobStatus::Cancelled);
	assert_eq!(jobs.cancel(&mut world, next.job).unwrap(), cancelled);
	assert!(world.pending_stage_epoch().is_none());
}

#[test]
fn invalid_admission_and_wrong_control_identity_preserve_the_live_job() {
	let (mut world, request) = fixture();
	let mut jobs = StageJobController::default();
	assert!(jobs
		.submit(
			&mut world,
			StageJobSubmit {
				quantum_us: 1001,
				..request
			}
		)
		.is_err());
	assert!(world.pending_stage_epoch().is_none());
	let accepted = jobs.submit(&mut world, request).unwrap();
	assert_eq!(accepted.job, 1);
	assert!(jobs.cancel(&mut world, accepted.job + 1).is_err());
	assert!(jobs
		.commit(
			&mut world,
			StageJobCommit {
				job: accepted.job,
				unit: 1
			},
			64
		)
		.is_err());
	assert_eq!(jobs.poll(accepted.job).unwrap(), accepted);
	assert!(world.pending_stage_epoch().is_some());
	jobs.cancel(&mut world, accepted.job).unwrap();
	assert!(matches!(
		jobs.submit(&mut world, request),
		Err(JobError::StaleStageEpoch)
	));
}

#[test]
fn fatal_cancel_releases_prepared_world_state_and_burns_the_admitted_epoch() {
	let (mut world, request) = fixture();
	let mut jobs = StageJobController::default();
	let accepted = jobs.submit(&mut world, request).unwrap();
	jobs.prepare(&mut world, || false, || false).unwrap();
	assert!(jobs.prepare(&mut world, || false, || true).is_err());
	assert!(!jobs.runnable());
	assert!(world.pending_stage_epoch().is_none());
	assert_eq!(
		jobs.poll(accepted.job).unwrap().status,
		StageJobStatus::Cancelled
	);
	assert!(matches!(
		jobs.submit(&mut world, request),
		Err(JobError::StaleStageEpoch)
	));
}

#[test]
fn live_write_invalidates_ready_work_without_hiding_the_write() {
	let (mut world, request) = fixture();
	let mut jobs = StageJobController::default();
	let accepted = jobs.submit(&mut world, request).unwrap();
	let ready = prepare_ready(&mut jobs, &mut world);
	let handle = MixtureHandle {
		slot: 0,
		generation: 1,
	};
	world
		.apply_command(dogmos_core::world::Command::SetTemperature {
			handle,
			temperature: 350.0,
		})
		.unwrap();
	let written = world.snapshot(handle).unwrap();
	let retry = jobs
		.commit(
			&mut world,
			StageJobCommit {
				job: accepted.job,
				unit: ready.unit,
			},
			64,
		)
		.unwrap();
	assert_eq!(retry.status, StageJobStatus::Retrying);
	assert_eq!(retry.committed_units, 0);
	assert_eq!(retry.unit, 0);
	assert_eq!(world.snapshot(handle).unwrap(), written);
	let next = prepare_ready(&mut jobs, &mut world);
	assert!(next.unit > ready.unit);
	assert!(jobs
		.commit(
			&mut world,
			StageJobCommit {
				job: accepted.job,
				unit: ready.unit
			},
			64
		)
		.is_err());
	let done = jobs
		.commit(
			&mut world,
			StageJobCommit {
				job: accepted.job,
				unit: next.unit,
			},
			64,
		)
		.unwrap();
	assert_eq!(done.status, StageJobStatus::Done);
	assert_eq!(done.committed_units, 1);
}

fn prepare_ready(
	jobs: &mut StageJobController,
	world: &mut DogmosWorld,
) -> dogmos_protocol::StageJobResponse {
	for _ in 0..1000 {
		let response = jobs.prepare(world, || false, || false).unwrap();
		if response.status == StageJobStatus::Ready {
			return response;
		}
	}
	panic!("fixture did not become ready within its work bound");
}

#[test]
fn sustained_conflicts_do_not_claim_progress_or_grow_retry_storage() {
	let (mut world, request) = fixture();
	let (mut control, _) = fixture();
	let mut jobs = StageJobController::default();
	let accepted = jobs.submit(&mut world, request).unwrap();
	let handle = MixtureHandle {
		slot: 0,
		generation: 1,
	};
	let mut previous_unit = 0;
	let mut retained_bytes = None;
	for conflict in 1_u16..=128 {
		let ready = prepare_ready(&mut jobs, &mut world);
		assert!(ready.unit > previous_unit);
		previous_unit = ready.unit;
		let command = dogmos_core::world::Command::SetTemperature {
			handle,
			temperature: 300.0 + f32::from(conflict),
		};
		world.apply_command(command.clone()).unwrap();
		control.apply_command(command).unwrap();
		let written = world.snapshot(handle).unwrap();
		let retry = jobs
			.commit(
				&mut world,
				StageJobCommit {
					job: accepted.job,
					unit: ready.unit,
				},
				64,
			)
			.unwrap();
		assert_eq!(retry.status, StageJobStatus::Retrying);
		assert_eq!(retry.committed_units, 0);
		assert_eq!(retry.callback_events, 0);
		assert_eq!(retry.unit, 0);
		assert_eq!(world.snapshot(handle).unwrap(), written);
		assert!(world.pending_events(64).is_empty());
		// Polling cannot clear the conflict or manufacture completed simulation work.
		for _ in 0..8 {
			assert_eq!(jobs.poll(accepted.job).unwrap(), retry);
		}
		let bytes = world.reusable_workset_bytes();
		assert_eq!(*retained_bytes.get_or_insert(bytes), bytes);
	}
	// Once writes stop, the same admitted job completes and matches the legacy path.
	let ready = prepare_ready(&mut jobs, &mut world);
	let done = jobs
		.commit(
			&mut world,
			StageJobCommit {
				job: accepted.job,
				unit: ready.unit,
			},
			64,
		)
		.unwrap();
	assert_eq!(done.status, StageJobStatus::Done);
	assert_eq!(done.committed_units, 1);
	let control_result = control
		.process_stage_chunk_cancellable(
			dogmos_core::world::StageChunkRequest {
				stage: dogmos_core::world::WorldStage::ProcessTurfs,
				frontier_epoch: 1,
				stage_epoch: 1,
				work_limit: 4096,
				seconds_per_tick: 0.5,
			},
			|| false,
		)
		.unwrap();
	assert!(!control_result.pending);
	for slot in 0..8 {
		let handle = MixtureHandle {
			slot,
			generation: 1,
		};
		assert_eq!(
			world.snapshot(handle).unwrap(),
			control.snapshot(handle).unwrap()
		);
	}
	assert_eq!(world.pending_events(64), control.pending_events(64));
}
