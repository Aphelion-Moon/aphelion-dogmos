use dogmos_protocol::{
	ServiceTelemetry, StageJobTelemetry, SERVICE_TELEMETRY_LEN, STAGE_JOB_TELEMETRY_LEN,
};

#[test]
fn job_observations_have_literal_fixed_width_and_high_word_identity() {
	let jobs = StageJobTelemetry {
		job: 0x0001_0002_0003_0004,
		status: 3,
		age_nanoseconds: 11,
		prepare_calls: 12,
		prepare_total_nanoseconds: 13,
		prepare_max_nanoseconds: 14,
		prepare_last_nanoseconds: 15,
		commit_calls: 16,
		commit_total_nanoseconds: 17,
		commit_max_nanoseconds: 18,
		commit_last_nanoseconds: 19,
		publication_retries: 20,
		completed_jobs: 21,
		cancelled_jobs: 22,
	};
	assert_eq!(STAGE_JOB_TELEMETRY_LEN, 112);
	assert_eq!(SERVICE_TELEMETRY_LEN, 480);
	let bytes = jobs.encode();
	assert_eq!(
		&bytes[..16],
		&[4, 0, 3, 0, 2, 0, 1, 0, 3, 0, 0, 0, 0, 0, 0, 0]
	);
	for (field, value) in (11_u64..=22).enumerate() {
		assert_eq!(&bytes[16 + field * 8..24 + field * 8], &value.to_le_bytes());
	}
	assert_eq!(StageJobTelemetry::decode(&bytes).unwrap(), jobs);
	let service = ServiceTelemetry {
		stage_jobs: jobs,
		..Default::default()
	};
	assert_eq!(&service.encode()[368..480], &bytes);
	assert_eq!(
		ServiceTelemetry::decode(&service.encode()).unwrap(),
		service
	);
}

#[test]
fn job_observations_reject_truncation_reserved_status_and_false_identity() {
	let zero = StageJobTelemetry::default().encode();
	assert_eq!(
		StageJobTelemetry::decode(&zero).unwrap(),
		StageJobTelemetry::default()
	);
	assert!(StageJobTelemetry::decode(&zero[..111]).is_err());
	assert!(StageJobTelemetry::decode(&[0; 113]).is_err());
	for offset in 8..16 {
		let mut malformed = zero;
		malformed[offset] = 255;
		assert!(StageJobTelemetry::decode(&malformed).is_err());
	}
	let mut malformed = zero;
	malformed[0] = 1;
	assert!(StageJobTelemetry::decode(&malformed).is_err());
	malformed[8] = 3;
	assert!(StageJobTelemetry::decode(&malformed).is_ok());
	malformed[0] = 0;
	assert!(StageJobTelemetry::decode(&malformed).is_err());
	let mut aged_without_job = zero;
	aged_without_job[16] = 1;
	assert!(StageJobTelemetry::decode(&aged_without_job).is_err());
}
