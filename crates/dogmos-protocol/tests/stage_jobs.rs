use dogmos_protocol::{
	OperationKind, ScalarValue, SimulationStage, StageJobCancel, StageJobCommit, StageJobPoll,
	StageJobResponse, StageJobStatus, StageJobSubmit, DOGMOS_PROTOCOL_VERSION,
};

fn submit() -> StageJobSubmit {
	StageJobSubmit {
		stage: SimulationStage::ProcessTurfs,
		work_limit: 256,
		frontier_epoch: 0x0001_0002_0003_0004,
		stage_epoch: 0x0005_0006_0007_0008,
		seconds_per_tick: ScalarValue(0.5),
		quantum_us: 1000,
	}
}

fn response() -> StageJobResponse {
	StageJobResponse {
		job: 0x0001_0002_0003_0004,
		status: StageJobStatus::Ready,
		stage: SimulationStage::ProcessTurfs,
		unit: 0x0005_0006_0007_0008,
		work_items: 9,
		remaining_estimate: 10,
		committed_units: 11,
		produced_equalize_seeds: 12,
		produced_group_seeds: 13,
		produced_heat_seeds: 14,
		callback_events: 15,
	}
}

#[test]
fn stage_job_operation_numbers_require_the_new_paired_protocol() {
	assert_eq!(DOGMOS_PROTOCOL_VERSION, 16);
	for (number, operation) in [
		(49, OperationKind::StageJobSubmit),
		(50, OperationKind::StageJobPoll),
		(51, OperationKind::StageJobCommit),
		(52, OperationKind::StageJobCancel),
	] {
		assert_eq!(OperationKind::try_from(number).unwrap(), operation);
	}
}

#[test]
fn submit_and_poll_have_literal_little_endian_bytes() {
	let expected = [
		4, 0, 0, 0, 0, 1, 0, 0, 4, 0, 3, 0, 2, 0, 1, 0, 8, 0, 7, 0, 6, 0, 5, 0, 0, 0, 0, 0, 0, 0,
		224, 63, 232, 3, 0, 0, 0, 0, 0, 0,
	];
	assert_eq!(submit().encode().unwrap(), expected);
	assert_eq!(StageJobSubmit::decode(&expected).unwrap(), submit());
	let poll = StageJobPoll {
		job: 0x0001_0002_0003_0004,
	};
	assert_eq!(poll.encode(), [4, 0, 3, 0, 2, 0, 1, 0]);
	assert_eq!(StageJobPoll::decode(&poll.encode()).unwrap(), poll);
}

#[test]
fn commit_cancel_and_receipt_have_fixed_canonical_layouts() {
	let commit = StageJobCommit {
		job: 0x0001_0002_0003_0004,
		unit: 0x0005_0006_0007_0008,
	};
	assert_eq!(
		commit.encode(),
		[4, 0, 3, 0, 2, 0, 1, 0, 8, 0, 7, 0, 6, 0, 5, 0]
	);
	assert_eq!(StageJobCommit::decode(&commit.encode()).unwrap(), commit);
	let cancel = StageJobCancel { job: commit.job };
	assert_eq!(
		cancel.encode(),
		[4, 0, 3, 0, 2, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0]
	);
	assert_eq!(StageJobCancel::decode(&cancel.encode()).unwrap(), cancel);
	let expected = [
		4, 0, 3, 0, 2, 0, 1, 0, 3, 0, 4, 0, 0, 0, 0, 0, 8, 0, 7, 0, 6, 0, 5, 0, 9, 0, 0, 0, 10, 0,
		0, 0, 11, 0, 0, 0, 0, 0, 0, 0, 12, 0, 0, 0, 13, 0, 0, 0, 14, 0, 0, 0, 15, 0, 0, 0, 0, 0, 0,
		0, 0, 0, 0, 0,
	];
	assert_eq!(response().encode().unwrap(), expected);
	assert_eq!(StageJobResponse::decode(&expected).unwrap(), response());
}

#[test]
fn every_codec_rejects_truncated_and_oversized_frames() {
	macro_rules! lengths {
		($type:ty, $bytes:expr) => {{
			let bytes = $bytes;
			for length in 0..bytes.len() {
				assert!(<$type>::decode(&bytes[..length]).is_err());
			}
			let mut longer = bytes.to_vec();
			longer.push(0);
			assert!(<$type>::decode(&longer).is_err());
		}};
	}
	lengths!(StageJobSubmit, submit().encode().unwrap());
	lengths!(StageJobPoll, StageJobPoll { job: 1 }.encode());
	lengths!(StageJobCommit, StageJobCommit { job: 1, unit: 1 }.encode());
	lengths!(StageJobCancel, StageJobCancel { job: 1 }.encode());
	lengths!(StageJobResponse, response().encode().unwrap());
}

#[test]
fn submit_rejects_invalid_budgets_seconds_epochs_and_reserved_fields() {
	for quantum_us in [0, 1001, u32::MAX] {
		assert!(StageJobSubmit {
			quantum_us,
			..submit()
		}
		.encode()
		.is_err());
		let mut bytes = submit().encode().unwrap();
		bytes[32..36].copy_from_slice(&quantum_us.to_le_bytes());
		assert!(StageJobSubmit::decode(&bytes).is_err());
	}
	for work_limit in [0, 4097, u32::MAX] {
		assert!(StageJobSubmit {
			work_limit,
			..submit()
		}
		.encode()
		.is_err());
		let mut bytes = submit().encode().unwrap();
		bytes[4..8].copy_from_slice(&work_limit.to_le_bytes());
		assert!(StageJobSubmit::decode(&bytes).is_err());
	}
	for seconds in [0.0, -0.0, -1.0, f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
		assert!(StageJobSubmit {
			seconds_per_tick: ScalarValue(seconds),
			..submit()
		}
		.encode()
		.is_err());
		let mut bytes = submit().encode().unwrap();
		bytes[24..32].copy_from_slice(&seconds.to_le_bytes());
		assert!(StageJobSubmit::decode(&bytes).is_err());
	}
	for offset in [8, 16] {
		let mut bytes = submit().encode().unwrap();
		bytes[offset..offset + 8].fill(0);
		assert!(StageJobSubmit::decode(&bytes).is_err());
	}
	for offset in [2, 3, 36, 37, 38, 39] {
		let mut bytes = submit().encode().unwrap();
		bytes[offset] = 1;
		assert!(StageJobSubmit::decode(&bytes).is_err());
	}
	let mut bytes = submit().encode().unwrap();
	bytes[0..2].copy_from_slice(&6_u16.to_le_bytes());
	assert!(StageJobSubmit::decode(&bytes).is_err());
}

#[test]
fn receipts_and_control_requests_reject_invalid_identity_and_reserved_data() {
	assert!(StageJobPoll::decode(&[0; 8]).is_err());
	assert!(StageJobCommit::decode(&StageJobCommit { job: 0, unit: 1 }.encode()).is_err());
	assert!(StageJobCommit::decode(&StageJobCommit { job: 1, unit: 0 }.encode()).is_err());
	assert!(StageJobCancel::decode(&[0; 16]).is_err());
	for offset in 8..16 {
		let mut bytes = StageJobCancel { job: 1 }.encode();
		bytes[offset] = 1;
		assert!(StageJobCancel::decode(&bytes).is_err());
	}
	for offset in [12, 13, 14, 15, 56, 57, 58, 59, 60, 61, 62, 63] {
		let mut bytes = response().encode().unwrap();
		bytes[offset] = 1;
		assert!(StageJobResponse::decode(&bytes).is_err());
	}
	for status in [0_u16, 7, u16::MAX] {
		let mut bytes = response().encode().unwrap();
		bytes[8..10].copy_from_slice(&status.to_le_bytes());
		assert!(StageJobResponse::decode(&bytes).is_err());
	}
	for offset in [0, 16] {
		let mut bytes = response().encode().unwrap();
		bytes[offset..offset + 8].fill(0);
		assert!(StageJobResponse::decode(&bytes).is_err());
	}
	assert!(StageJobResponse {
		unit: 0,
		..response()
	}
	.encode()
	.is_err());
	for status in [
		StageJobStatus::Accepted,
		StageJobStatus::Running,
		StageJobStatus::Retrying,
		StageJobStatus::Done,
		StageJobStatus::Cancelled,
	] {
		let receipt = StageJobResponse {
			status,
			unit: 0,
			..response()
		};
		assert_eq!(
			StageJobResponse::decode(&receipt.encode().unwrap()).unwrap(),
			receipt
		);
	}
}
