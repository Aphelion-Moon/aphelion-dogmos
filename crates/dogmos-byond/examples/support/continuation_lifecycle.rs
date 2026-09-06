use dogmos_byond::{BoundedDogmosClient, ClientError};
use dogmos_protocol::{
	encode_lifecycle_batch, encode_turf_lifecycle_batch, CallbackBatchHeader, CallbackBatchRequest,
	CallbackEvent, CallbackEventKind, CallbackScope, ContinuationCommandRequest,
	ContinuationResumeRequest, FrontierAppendRequest, FrontierAppendResponse, FrontierBeginRequest,
	FrontierBeginResponse, FrontierCommitRequest, FrontierCommitResponse, LifecycleAction,
	LifecycleMutation, MixtureCommandRequest, MixtureCommandResponse, MixtureSnapshot,
	MixtureSnapshotRequest, OperationKind, ScalarValue, ServiceErrorCode, ServiceTelemetry,
	SimulationStage, SimulationStageRequest, SimulationStageResponse, TurfLifecycleMutation,
	WireHandle, CALLBACK_BATCH_HEADER_LEN, CALLBACK_EVENT_LEN, MIXTURE_COMMAND_RESPONSE_LEN,
	MIXTURE_SNAPSHOT_LEN, SERVICE_TELEMETRY_LEN, SIMULATION_STAGE_RESPONSE_LEN,
};
use std::{error::Error, time::Duration};

const REQUEST_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Clone, Copy, Debug)]
enum Change {
	MixtureGeneration,
	TurfGeneration,
	TurfMixture,
	TurfDetach,
	TurfRestore,
}

pub(super) fn verify(client: &mut BoundedDogmosClient) -> Result<(), Box<dyn Error>> {
	// Exceed the negotiated 1,024-continuation capacity cumulatively while reusing two owners.
	// Each iteration must reclaim its invalidated token and finish its surviving reaction.
	for cycle in 0..1030 {
		let change = [
			Change::MixtureGeneration,
			Change::TurfGeneration,
			Change::TurfMixture,
			Change::TurfDetach,
			Change::TurfRestore,
		][cycle as usize % 5];
		let delivered = (cycle / 5) % 2 == 1;
		verify_cycle(client, cycle, change, delivered).map_err(|error| {
			format!("lifecycle cycle {cycle}, {change:?}, delivered={delivered}: {error}")
		})?;
	}
	println!("continuation lifecycle: 1030 cycles, five replacement modes, queued/delivered targets, no pending work");
	Ok(())
}

fn verify_cycle(
	client: &mut BoundedDogmosClient,
	cycle: u32,
	change: Change,
	delivered: bool,
) -> Result<(), Box<dyn Error>> {
	let generation = cycle * 2 + 1;
	let mut mixtures = [200, 201].map(|slot| WireHandle { slot, generation });
	let mut turfs = [300, 301].map(|slot| WireHandle { slot, generation });
	apply_mixtures(
		client,
		&mixtures.map(|handle| LifecycleMutation {
			action: LifecycleAction::Register,
			handle,
		}),
	)?;
	for (handle, amount) in mixtures.into_iter().zip([2.0, 3.0]) {
		assert_eq!(
			mixture_command(
				client,
				MixtureCommandRequest::SetMoles {
					handle,
					gas_id: 0,
					amount: ScalarValue(amount),
				}
			)?,
			MixtureCommandResponse::Applied { updated: 1 }
		);
	}
	let registrations = [0, 1].map(|index| TurfLifecycleMutation {
		action: LifecycleAction::Register,
		turf: turfs[index],
		mixture: Some(mixtures[index]),
	});
	apply_turfs(client, &registrations)?;
	let epoch = u64::from(cycle) + 2;
	let begin = request::<8>(
		client,
		OperationKind::FrontierBegin,
		&FrontierBeginRequest {
			epoch,
			expected_count: 2,
		}
		.encode(),
	)?;
	let append = request::<4>(
		client,
		OperationKind::FrontierAppend,
		&FrontierAppendRequest {
			epoch,
			offset: 0,
			handles: turfs.to_vec(),
		}
		.encode()?,
	)?;
	let commit = request::<16>(
		client,
		OperationKind::FrontierCommit,
		&FrontierCommitRequest { epoch }.encode(),
	)?;
	assert_eq!(
		FrontierBeginResponse::decode(&begin)?,
		FrontierBeginResponse { epoch }
	);
	assert_eq!(
		FrontierAppendResponse::decode(&append)?,
		FrontierAppendResponse { accepted_count: 2 }
	);
	assert_eq!(
		FrontierCommitResponse::decode(&commit)?,
		FrontierCommitResponse { epoch, count: 2 }
	);
	let stage = request::<SIMULATION_STAGE_RESPONSE_LEN>(
		client,
		OperationKind::SimulationStage,
		&SimulationStageRequest {
			stage: SimulationStage::ProcessReactions,
			frontier_epoch: epoch,
			stage_epoch: epoch + 1,
			work_limit: 4096,
			seconds_per_tick: ScalarValue(0.5),
		}
		.encode()?,
	)?;
	let stage = SimulationStageResponse::decode(&stage)?;
	assert!(!stage.pending);
	assert_eq!(stage.callback_events, 2);
	assert_depths(client, 2, 2)?;
	let invalidated = if delivered {
		Some(
			drain_one(client, mixtures[0], turfs[0], 1)?
				.continuation
				.unwrap(),
		)
	} else {
		None
	};
	match change {
		Change::MixtureGeneration => {
			mixtures[0].generation += 1;
			apply_mixtures(
				client,
				&[LifecycleMutation {
					action: LifecycleAction::Register,
					handle: mixtures[0],
				}],
			)?;
		}
		_ => {
			let mut replacement = registrations[0];
			match change {
				Change::TurfGeneration => {
					turfs[0].generation += 1;
					replacement.turf = turfs[0];
				}
				Change::TurfDetach => replacement.mixture = None,
				_ => replacement.mixture = Some(mixtures[1]),
			}
			let mut changes = vec![replacement];
			if matches!(change, Change::TurfRestore) {
				changes.push(registrations[0]);
			}
			apply_turfs(client, &changes)?;
		}
	}
	assert_depths(client, 1, 1)?;
	let before = mixture_snapshot(client, mixtures[1])?;
	assert_eq!(before.gases[0], ScalarValue(3.0));
	// Exercise each typed rejection once; repeated stale requests would flood service diagnostics.
	if let Some(token) = invalidated.filter(|_| cycle < 10) {
		let result = client.round_trip(
			OperationKind::ContinuationCommand,
			&ContinuationCommandRequest {
				token,
				command: MixtureCommandRequest::SetMoles {
					handle: mixtures[1],
					gas_id: 0,
					amount: ScalarValue(9.0),
				},
			}
			.encode()?,
			MIXTURE_COMMAND_RESPONSE_LEN,
			REQUEST_TIMEOUT,
		);
		assert!(
			matches!(
				result,
				Err(ClientError::Server(ServiceErrorCode::UnknownContinuation))
			),
			"invalidated continuation returned {result:?}"
		);
		assert_eq!(mixture_snapshot(client, mixtures[1])?, before);
	}
	let survivor = drain_one(client, mixtures[1], turfs[1], 0)?
		.continuation
		.unwrap();
	assert_depths(client, 1, 0)?;
	let response = request::<MIXTURE_COMMAND_RESPONSE_LEN>(
		client,
		OperationKind::ContinuationResume,
		&ContinuationResumeRequest {
			token: survivor,
			reaction_result: 0,
		}
		.encode()?,
	)?;
	assert_eq!(
		MixtureCommandResponse::decode(&response)?,
		MixtureCommandResponse::ReactionProgress {
			flags: 0,
			work_items: 0,
			pending: false,
			transaction_id: 0,
		}
	);
	assert_eq!(mixture_snapshot(client, mixtures[1])?, before);
	assert_depths(client, 0, 0)?;
	apply_turfs(
		client,
		&turfs.map(|turf| TurfLifecycleMutation {
			action: LifecycleAction::Unregister,
			turf,
			mixture: None,
		}),
	)?;
	apply_mixtures(
		client,
		&mixtures.map(|handle| LifecycleMutation {
			action: LifecycleAction::Unregister,
			handle,
		}),
	)?;
	Ok(())
}

fn request<const N: usize>(
	client: &mut BoundedDogmosClient,
	operation: OperationKind,
	payload: &[u8],
) -> Result<[u8; N], Box<dyn Error>> {
	let response = client.round_trip(operation, payload, N, REQUEST_TIMEOUT)?;
	assert_eq!(response.len(), N, "{operation:?} response length changed");
	Ok(response.try_into().unwrap())
}

fn apply_mixtures(
	client: &mut BoundedDogmosClient,
	changes: &[LifecycleMutation],
) -> Result<(), Box<dyn Error>> {
	let mut payload = Vec::new();
	encode_lifecycle_batch(changes, &mut payload)?;
	let response = request::<4>(client, OperationKind::MixtureLifecycleBatch, &payload)?;
	assert_eq!(u32::from_le_bytes(response), changes.len() as u32);
	Ok(())
}

fn apply_turfs(
	client: &mut BoundedDogmosClient,
	changes: &[TurfLifecycleMutation],
) -> Result<(), Box<dyn Error>> {
	let mut payload = Vec::new();
	encode_turf_lifecycle_batch(changes, &mut payload)?;
	let response = request::<4>(client, OperationKind::TurfLifecycleBatch, &payload)?;
	assert_eq!(u32::from_le_bytes(response), changes.len() as u32);
	Ok(())
}

fn drain_one(
	client: &mut BoundedDogmosClient,
	subject: WireHandle,
	target: WireHandle,
	remaining: u32,
) -> Result<CallbackEvent, Box<dyn Error>> {
	let response = request::<{ CALLBACK_BATCH_HEADER_LEN + CALLBACK_EVENT_LEN }>(
		client,
		OperationKind::CallbackBatch,
		&CallbackBatchRequest {
			max_events: 1,
			scope: CallbackScope::General,
			transaction_id: 0,
		}
		.encode()?,
	)?;
	let header = CallbackBatchHeader::decode(&response[..CALLBACK_BATCH_HEADER_LEN])?;
	let event = CallbackEvent::decode(&response[CALLBACK_BATCH_HEADER_LEN..])?;
	assert_eq!(header.returned, 1);
	assert_eq!(header.remaining, remaining);
	assert_eq!(event.kind, CallbackEventKind::RunDmReaction);
	assert_eq!(event.subject, subject);
	assert_eq!(event.target, target);
	assert_eq!(event.scope, CallbackScope::General);
	assert_eq!(event.transaction_id, 0);
	assert!(event.continuation.is_some());
	Ok(event)
}

fn assert_depths(
	client: &mut BoundedDogmosClient,
	continuations: u32,
	callbacks: u32,
) -> Result<(), Box<dyn Error>> {
	let response = request::<SERVICE_TELEMETRY_LEN>(client, OperationKind::ServiceTelemetry, &[])?;
	let telemetry = ServiceTelemetry::decode(&response)?;
	assert_eq!(telemetry.continuation_depth, continuations);
	assert_eq!(telemetry.callback_depth, callbacks);
	Ok(())
}

fn mixture_command(
	client: &mut BoundedDogmosClient,
	command: MixtureCommandRequest,
) -> Result<MixtureCommandResponse, Box<dyn Error>> {
	let response = request::<MIXTURE_COMMAND_RESPONSE_LEN>(
		client,
		OperationKind::MixtureCommand,
		&command.encode()?,
	)?;
	Ok(MixtureCommandResponse::decode(&response)?)
}

fn mixture_snapshot(
	client: &mut BoundedDogmosClient,
	handle: WireHandle,
) -> Result<MixtureSnapshot, Box<dyn Error>> {
	let response = request::<MIXTURE_SNAPSHOT_LEN>(
		client,
		OperationKind::MixtureSnapshot,
		&MixtureSnapshotRequest { handle }.encode(),
	)?;
	Ok(MixtureSnapshot::decode(&response)?)
}
