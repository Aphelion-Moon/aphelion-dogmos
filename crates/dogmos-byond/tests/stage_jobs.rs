use dogmos_byond::stage_jobs::{
	decode_response, decode_response_to, encode_cancel, encode_commit, encode_poll, encode_submit,
};
use dogmos_protocol::{
	SimulationStage, StageJobCancel, StageJobCommit, StageJobPoll, StageJobResponse,
	StageJobStatus, StageJobSubmit,
};

#[test]
fn job_bindings_preserve_exact_high_words_and_fixed_field_counts() {
	let submit = encode_submit([
		4.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 256.0, 0.0, 0.5, 1000.0,
	])
	.unwrap();
	let request = StageJobSubmit::decode(&submit).unwrap();
	assert_eq!(request.stage, SimulationStage::ProcessTurfs);
	assert_eq!(request.frontier_epoch, 0x0004_0003_0002_0001);
	assert_eq!(request.stage_epoch, 0x0008_0007_0006_0005);
	assert_eq!(request.work_limit, 256);
	assert_eq!(request.quantum_us, 1000);
	let words = [1.0, 2.0, 3.0, 65535.0];
	assert_eq!(
		StageJobPoll::decode(&encode_poll(words).unwrap())
			.unwrap()
			.job,
		0xffff_0003_0002_0001
	);
	assert_eq!(
		StageJobCancel::decode(&encode_cancel(words).unwrap())
			.unwrap()
			.job,
		0xffff_0003_0002_0001
	);
	let request = StageJobCommit::decode(
		&encode_commit([1.0, 2.0, 3.0, 65535.0, 4.0, 5.0, 6.0, 7.0]).unwrap(),
	)
	.unwrap();
	assert_eq!(request.job, 0xffff_0003_0002_0001);
	assert_eq!(request.unit, 0x0007_0006_0005_0004);
}

#[test]
fn job_receipt_must_match_its_control_request() {
	use dogmos_protocol::OperationKind;
	let done = receipt();
	let poll = StageJobPoll { job: done.job }.encode();
	assert!(
		decode_response_to(OperationKind::StageJobPoll, &poll, &done.encode().unwrap()).is_ok()
	);
	assert!(decode_response_to(
		OperationKind::StageJobPoll,
		&StageJobPoll { job: done.job + 1 }.encode(),
		&done.encode().unwrap()
	)
	.is_err());
	let commit = StageJobCommit {
		job: done.job,
		unit: done.unit,
	}
	.encode();
	assert!(decode_response_to(
		OperationKind::StageJobCommit,
		&commit,
		&done.encode().unwrap()
	)
	.is_ok());
	assert!(decode_response_to(
		OperationKind::StageJobCommit,
		&StageJobCommit {
			job: done.job,
			unit: done.unit + 1
		}
		.encode(),
		&done.encode().unwrap()
	)
	.is_err());
	assert!(decode_response_to(
		OperationKind::StageJobCancel,
		&StageJobCancel { job: done.job }.encode(),
		&StageJobResponse {
			status: StageJobStatus::Running,
			..done
		}
		.encode()
		.unwrap()
	)
	.is_err());
}

#[test]
fn job_bindings_reject_lossy_words_and_invalid_control_fields() {
	for invalid in [-1.0, 0.5, 65536.0, f32::NAN, f32::INFINITY] {
		assert!(encode_poll([1.0, 2.0, invalid, 0.0]).is_err());
		assert!(encode_cancel([1.0, 2.0, invalid, 0.0]).is_err());
		assert!(encode_commit([1.0, 2.0, 0.0, 0.0, 1.0, 2.0, invalid, 0.0]).is_err());
	}
	assert!(encode_poll([0.0; 4]).is_err());
	assert!(encode_cancel([0.0; 4]).is_err());
	assert!(encode_commit([0.0; 8]).is_err());
	for quantum in [0.0, 1001.0, f32::NAN] {
		assert!(encode_submit([
			4.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 256.0, 0.0, 0.5, quantum
		])
		.is_err());
	}
}

fn receipt() -> StageJobResponse {
	StageJobResponse {
		job: 0x0004_0003_0002_0001,
		status: StageJobStatus::Done,
		stage: SimulationStage::ProcessTurfs,
		unit: 0x0008_0007_0006_0005,
		work_items: 0x000a_0009,
		remaining_estimate: 0,
		committed_units: 0x000e_000d_000c_000b,
		produced_equalize_seeds: 0x0010_000f,
		produced_group_seeds: 0x0012_0011,
		produced_heat_seeds: 0x0014_0013,
		callback_events: 0x0016_0015,
	}
}

#[test]
fn receipt_fields_preserve_cumulative_counts_without_float_rounding() {
	let fields = decode_response(&receipt().encode().unwrap()).unwrap();
	assert_eq!(
		fields,
		[
			1.0, 2.0, 3.0, 4.0, 5.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0, 0.0, 0.0, 11.0, 12.0,
			13.0, 14.0, 15.0, 16.0, 17.0, 18.0, 19.0, 20.0, 21.0, 22.0
		]
	);
	assert!(decode_response(&[0; 63]).is_err());
}

#[test]
fn receipt_decoder_rejects_publication_counts_without_a_committed_unit() {
	for response in [
		StageJobResponse {
			unit: 0,
			..receipt()
		},
		StageJobResponse {
			committed_units: 0,
			..receipt()
		},
		StageJobResponse {
			status: StageJobStatus::Accepted,
			..receipt()
		},
	] {
		assert!(decode_response(&response.encode().unwrap()).is_err());
	}
}
