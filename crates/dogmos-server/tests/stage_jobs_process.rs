#![cfg(all(windows, target_arch = "x86"))]

mod common;
use dogmos_byond::{ClientError, DogmosClient};
use dogmos_protocol::*;
use std::time::{Duration, Instant};

fn handle(slot: u32) -> WireHandle {
	WireHandle {
		slot,
		generation: 1,
	}
}

fn request(client: &mut DogmosClient, kind: OperationKind, payload: &[u8]) -> Vec<u8> {
	let mut output = vec![0; MAX_CONTROL_PAYLOAD as usize];
	let len = client.round_trip_into(kind, payload, &mut output).unwrap();
	output.truncate(len);
	output
}

fn fixture() -> common::TestService {
	let mut service = common::start(64, 64, 64);
	let client = &mut service.client;
	let handles = (0..64).map(handle).collect::<Vec<_>>();
	let mut payload = Vec::new();
	encode_lifecycle_batch(
		&handles
			.iter()
			.map(|handle| LifecycleMutation {
				action: LifecycleAction::Register,
				handle: *handle,
			})
			.collect::<Vec<_>>(),
		&mut payload,
	)
	.unwrap();
	request(client, OperationKind::MixtureLifecycleBatch, &payload);
	encode_turf_lifecycle_batch(
		&handles
			.iter()
			.map(|handle| TurfLifecycleMutation {
				action: LifecycleAction::Register,
				turf: *handle,
				mixture: Some(*handle),
			})
			.collect::<Vec<_>>(),
		&mut payload,
	)
	.unwrap();
	request(client, OperationKind::TurfLifecycleBatch, &payload);
	request(
		client,
		OperationKind::FrontierBegin,
		&FrontierBeginRequest {
			epoch: 1,
			expected_count: handles.len() as u32,
		}
		.encode(),
	);
	request(
		client,
		OperationKind::FrontierAppend,
		&FrontierAppendRequest {
			epoch: 1,
			offset: 0,
			handles,
		}
		.encode()
		.unwrap(),
	);
	request(
		client,
		OperationKind::FrontierCommit,
		&FrontierCommitRequest { epoch: 1 }.encode(),
	);
	service
}

fn submit() -> StageJobSubmit {
	StageJobSubmit {
		stage: SimulationStage::ProcessTurfs,
		frontier_epoch: 1,
		stage_epoch: 1,
		work_limit: 1,
		seconds_per_tick: ScalarValue(0.5),
		quantum_us: 1000,
	}
}

fn ready(client: &mut DogmosClient, job: u64) -> StageJobResponse {
	let deadline = Instant::now() + Duration::from_secs(5);
	loop {
		let response = StageJobResponse::decode(&request(
			client,
			OperationKind::StageJobPoll,
			&StageJobPoll { job }.encode(),
		))
		.unwrap();
		if response.status == StageJobStatus::Ready {
			return response;
		}
		assert!(matches!(
			response.status,
			StageJobStatus::Accepted | StageJobStatus::Running | StageJobStatus::Retrying
		));
		assert!(Instant::now() < deadline, "job did not reach Ready");
		std::thread::yield_now();
	}
}

#[test]
fn autonomous_job_keeps_commands_available_and_replays_exact_commit_receipts() {
	let mut service = fixture();
	let client = &mut service.client;
	let snapshot_request = MixtureSnapshotRequest { handle: handle(0) }.encode();
	let original = request(client, OperationKind::MixtureSnapshot, &snapshot_request);
	let accepted = StageJobResponse::decode(&request(
		client,
		OperationKind::StageJobSubmit,
		&submit().encode().unwrap(),
	))
	.unwrap();
	assert_eq!(accepted.status, StageJobStatus::Accepted);
	assert_eq!(accepted.work_items, 0);
	assert_eq!(
		client.echo(b"control remains available").unwrap(),
		b"control remains available"
	);
	let first_ready = ready(client, accepted.job);
	assert_eq!(
		request(client, OperationKind::MixtureSnapshot, &snapshot_request),
		original
	);
	request(
		client,
		OperationKind::MixtureCommand,
		&MixtureCommandRequest::SetTemperature {
			handle: handle(0),
			temperature: ScalarValue(345.0),
		}
		.encode()
		.unwrap(),
	);
	let written = request(client, OperationKind::MixtureSnapshot, &snapshot_request);
	assert_ne!(written, original);
	let first_commit = StageJobCommit {
		job: accepted.job,
		unit: first_ready.unit,
	};
	let retry = StageJobResponse::decode(&request(
		client,
		OperationKind::StageJobCommit,
		&first_commit.encode(),
	))
	.unwrap();
	assert_eq!(retry.status, StageJobStatus::Retrying);
	assert_eq!(retry.committed_units, 0);
	assert_eq!(
		request(client, OperationKind::MixtureSnapshot, &snapshot_request),
		written
	);
	let next_ready = ready(client, accepted.job);
	assert!(next_ready.unit > first_ready.unit);
	let commit = StageJobCommit {
		job: accepted.job,
		unit: next_ready.unit,
	};
	let receipt_bytes = request(client, OperationKind::StageJobCommit, &commit.encode());
	let receipt = StageJobResponse::decode(&receipt_bytes).unwrap();
	assert_eq!(receipt.status, StageJobStatus::Done);
	assert_eq!(receipt.committed_units, 1);
	assert_eq!(
		request(client, OperationKind::StageJobCommit, &commit.encode()),
		receipt_bytes
	);
	assert_eq!(
		request(
			client,
			OperationKind::StageJobCancel,
			&StageJobCancel { job: accepted.job }.encode()
		),
		receipt_bytes
	);
	assert!(matches!(
		client.round_trip_into(
			OperationKind::StageJobSubmit,
			&submit().encode().unwrap(),
			&mut [0; STAGE_JOB_RESPONSE_LEN]
		),
		Err(ClientError::Server(ServiceErrorCode::StageConflict))
	));
	client.shutdown().unwrap();
}

#[test]
fn cancelled_job_and_malformed_commands_preserve_session_identity() {
	let mut service = fixture();
	let client = &mut service.client;
	let accepted = StageJobResponse::decode(&request(
		client,
		OperationKind::StageJobSubmit,
		&submit().encode().unwrap(),
	))
	.unwrap();
	assert!(matches!(
		client.round_trip_into(
			OperationKind::StageJobPoll,
			&[0; 7],
			&mut [0; STAGE_JOB_RESPONSE_LEN]
		),
		Err(ClientError::Server(ServiceErrorCode::InvalidRequest))
	));
	assert!(matches!(
		client.round_trip_into(
			OperationKind::StageJobSubmit,
			&StageJobSubmit {
				stage_epoch: 2,
				..submit()
			}
			.encode()
			.unwrap(),
			&mut [0; STAGE_JOB_RESPONSE_LEN]
		),
		Err(ClientError::Server(ServiceErrorCode::Busy))
	));
	let bytes = request(
		client,
		OperationKind::StageJobCancel,
		&StageJobCancel { job: accepted.job }.encode(),
	);
	assert_eq!(
		StageJobResponse::decode(&bytes).unwrap().status,
		StageJobStatus::Cancelled
	);
	assert_eq!(
		request(
			client,
			OperationKind::StageJobCancel,
			&StageJobCancel { job: accepted.job }.encode()
		),
		bytes
	);
	let next = StageJobResponse::decode(&request(
		client,
		OperationKind::StageJobSubmit,
		&StageJobSubmit {
			stage_epoch: 2,
			..submit()
		}
		.encode()
		.unwrap(),
	))
	.unwrap();
	assert!(next.job > accepted.job);
	assert!(matches!(
		client.round_trip_into(
			OperationKind::StageJobPoll,
			&StageJobPoll { job: accepted.job }.encode(),
			&mut [0; STAGE_JOB_RESPONSE_LEN]
		),
		Err(ClientError::Server(ServiceErrorCode::InvalidRequest))
	));
	assert_eq!(
		client.echo(b"still authenticated").unwrap(),
		b"still authenticated"
	);
	client.shutdown().unwrap();
}

#[test]
fn admitted_job_advances_without_poll_requests_after_submit_budget_expires() {
	let mut service = fixture();
	let client = &mut service.client;
	let mut bytes = [0; STAGE_JOB_RESPONSE_LEN];
	client
		.round_trip_into_with_deadline(
			OperationKind::StageJobSubmit,
			&submit().encode().unwrap(),
			&mut bytes,
			50_000_000,
		)
		.unwrap();
	let accepted = StageJobResponse::decode(&bytes).unwrap();
	let deadline = Instant::now() + Duration::from_secs(5);
	loop {
		let telemetry =
			ServiceTelemetry::decode(&request(client, OperationKind::ServiceTelemetry, &[]))
				.unwrap();
		if telemetry.stage_epoch == 1
			&& telemetry.stage_remaining == 0
			&& telemetry.stage_cursor == 64
		{
			break;
		}
		assert!(
			Instant::now() < deadline,
			"autonomous preparation did not traverse the frontier"
		);
	}
	// The admission frame is completed. Its budget must never become the lifetime of the job.
	std::thread::sleep(Duration::from_millis(60));
	let ready = ready(client, accepted.job);
	assert_eq!(ready.committed_units, 0);
	assert!(ready.work_items >= 64);
	client.shutdown().unwrap();
}
