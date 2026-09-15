//! Pure service telemetry and process-metrics adapters. No BYOND calls or session ownership.

use crate::process_metrics_layout;
use dogmos_process_metrics::{
	CurrentProcessMetrics, PROCESS_ALL_AVAILABLE, PROCESS_CPU_AVAILABLE,
	PROCESS_PRIVATE_BYTES_AVAILABLE, PROCESS_VIRTUAL_BYTES_AVAILABLE,
	PROCESS_WORKING_SET_AVAILABLE,
};
use dogmos_protocol::ServiceTelemetry;

/// Decodes protocol bytes into exact DM numeric fields for service telemetry.
///
/// Preserves field order and little-endian word identity; invalid lengths, tags or
/// numeric values return a caller-legible error. This adapter performs no BYOND call.
pub fn decode_production_service_telemetry(response: &[u8]) -> eyre::Result<Vec<f32>> {
	let telemetry = ServiceTelemetry::decode(response)?;
	use crate::adapter_layout::telemetry::service_telemetry as layout;
	let mut fields = vec![0.0; layout::LEN];
	layout::CALLBACK_DEPTH.write_u32(&mut fields, telemetry.callback_depth);
	layout::CALLBACK_CAPACITY.write_u32(&mut fields, telemetry.callback_capacity);
	layout::CALLBACK_HIGH_WATER.write_u32(&mut fields, telemetry.callback_high_water);
	layout::CONTINUATION_DEPTH.write_u32(&mut fields, telemetry.continuation_depth);
	layout::CONTINUATION_CAPACITY.write_u32(&mut fields, telemetry.continuation_capacity);
	layout::CONTINUATION_HIGH_WATER.write_u32(&mut fields, telemetry.continuation_high_water);
	layout::OLDEST_CALLBACK_AGE.write_u64(&mut fields, telemetry.oldest_callback_age_ticks);
	layout::CALLBACK_ENQUEUED.write_u64(&mut fields, telemetry.callback_enqueued);
	layout::CALLBACK_DRAINED.write_u64(&mut fields, telemetry.callback_drained);
	layout::CALLBACK_REJECTED.write_u64(&mut fields, telemetry.callback_rejected);
	layout::CONTINUATION_TIMEOUTS.write_u64(&mut fields, telemetry.continuation_timeouts);
	layout::REQUEST_TIMEOUTS.write_u64(&mut fields, telemetry.request_timeouts);
	layout::PROTOCOL_ERRORS.write_u64(&mut fields, telemetry.protocol_errors);
	for (words, counter) in fields[layout::ENQUEUED_BY_KIND.range()]
		.as_chunks_mut::<4>()
		.0
		.iter_mut()
		.zip(telemetry.callback_enqueued_by_kind)
	{
		words.copy_from_slice(&crate::dm_codec::split_u64_words(counter).map(f32::from));
	}
	for (words, counter) in fields[layout::DRAINED_BY_KIND.range()]
		.as_chunks_mut::<4>()
		.0
		.iter_mut()
		.zip(telemetry.callback_drained_by_kind)
	{
		words.copy_from_slice(&crate::dm_codec::split_u64_words(counter).map(f32::from));
	}
	for (words, counter) in fields[layout::REJECTED_BY_KIND.range()]
		.as_chunks_mut::<4>()
		.0
		.iter_mut()
		.zip(telemetry.callback_rejected_by_kind)
	{
		words.copy_from_slice(&crate::dm_codec::split_u64_words(counter).map(f32::from));
	}
	layout::PROCESS_FLAGS.write_u32(&mut fields, telemetry.service_process_available_flags);
	layout::RSS.write_u64(&mut fields, telemetry.service_rss_bytes);
	layout::CPU.write_u64(&mut fields, telemetry.service_cpu_total_milliseconds);
	layout::GENERAL_CALLBACK_DEPTH.write_u32(&mut fields, telemetry.general_callback_depth);
	layout::REACTION_CALLBACK_DEPTH.write_u32(&mut fields, telemetry.reaction_callback_depth);
	layout::REACTION_TRANSACTION_DEPTH.write_u32(&mut fields, telemetry.reaction_transaction_depth);
	layout::REACTION_TRANSACTION_HIGH_WATER
		.write_u32(&mut fields, telemetry.reaction_transaction_high_water);
	layout::FRONTIER_COUNT.write_u32(&mut fields, telemetry.frontier_count);
	layout::STAGE_KIND.write_u32(&mut fields, telemetry.stage_kind);
	layout::FRONTIER_UPLOAD_BYTES.write_u64(&mut fields, telemetry.frontier_upload_bytes);
	layout::STAGE_EPOCH.write_u64(&mut fields, telemetry.stage_epoch);
	layout::STAGE_CURSOR.write_u32(&mut fields, telemetry.stage_cursor);
	layout::STAGE_REMAINING.write_u32(&mut fields, telemetry.stage_remaining);
	layout::TOPOLOGY_REVISION.write_u64(&mut fields, telemetry.topology_revision);
	layout::REUSABLE_WORKSET_BYTES.write_u64(&mut fields, telemetry.reusable_workset_bytes);
	layout::PACKED_TOPOLOGY_BYTES.write_u64(&mut fields, telemetry.packed_topology_bytes);
	layout::JOB.write_u64(&mut fields, telemetry.stage_jobs.job);
	layout::JOB_STATUS.write_u32(&mut fields, u32::from(telemetry.stage_jobs.status));
	layout::JOB_AGE.write_u64(&mut fields, telemetry.stage_jobs.age_nanoseconds);
	layout::PREPARE_CALLS.write_u64(&mut fields, telemetry.stage_jobs.prepare_calls);
	layout::PREPARE_TOTAL_NS.write_u64(&mut fields, telemetry.stage_jobs.prepare_total_nanoseconds);
	layout::PREPARE_MAX_NS.write_u64(&mut fields, telemetry.stage_jobs.prepare_max_nanoseconds);
	layout::PREPARE_LAST_NS.write_u64(&mut fields, telemetry.stage_jobs.prepare_last_nanoseconds);
	layout::COMMIT_CALLS.write_u64(&mut fields, telemetry.stage_jobs.commit_calls);
	layout::COMMIT_TOTAL_NS.write_u64(&mut fields, telemetry.stage_jobs.commit_total_nanoseconds);
	layout::COMMIT_MAX_NS.write_u64(&mut fields, telemetry.stage_jobs.commit_max_nanoseconds);
	layout::COMMIT_LAST_NS.write_u64(&mut fields, telemetry.stage_jobs.commit_last_nanoseconds);
	layout::PUBLICATION_RETRIES.write_u64(&mut fields, telemetry.stage_jobs.publication_retries);
	layout::COMPLETED_JOBS.write_u64(&mut fields, telemetry.stage_jobs.completed_jobs);
	layout::CANCELLED_JOBS.write_u64(&mut fields, telemetry.stage_jobs.cancelled_jobs);
	Ok(fields)
}

/// Packs validated host and service observations into 28 exact u16 words for process metrics.
///
/// Preserves field order and little-endian word identity; invalid lengths, tags or
/// numeric values return a caller-legible error. This adapter performs no BYOND call.
pub fn encode_production_process_metrics(
	host: CurrentProcessMetrics,
	service_response: &[u8],
) -> eyre::Result<Vec<f32>> {
	validate_current_process_metrics(host)?;
	let service = ServiceTelemetry::decode(service_response)?;
	Ok(process_metrics_layout::encode(host, &service))
}

pub(crate) fn validate_current_process_metrics(metrics: CurrentProcessMetrics) -> eyre::Result<()> {
	let unknown_flags = metrics.available_flags & !PROCESS_ALL_AVAILABLE;
	if unknown_flags != 0 {
		return Err(eyre::eyre!(
			"DreamDaemon process metrics contained unknown availability flags {unknown_flags:#x}"
		));
	}
	for (flag, value, name) in [
		(
			PROCESS_PRIVATE_BYTES_AVAILABLE,
			metrics.private_bytes,
			"private bytes",
		),
		(
			PROCESS_VIRTUAL_BYTES_AVAILABLE,
			metrics.virtual_bytes,
			"virtual bytes",
		),
		(
			PROCESS_WORKING_SET_AVAILABLE,
			metrics.working_set_bytes,
			"working-set bytes",
		),
		(
			PROCESS_CPU_AVAILABLE,
			metrics.cpu_total_milliseconds,
			"total CPU milliseconds",
		),
	] {
		if metrics.available_flags & flag == 0 && value != 0 {
			return Err(eyre::eyre!(
				"DreamDaemon process metrics reported nonzero {name} without its availability flag"
			));
		}
	}
	Ok(())
}
