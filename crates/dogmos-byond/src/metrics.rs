//! Pure service telemetry and process-metrics adapters. No BYOND calls or session ownership.

use crate::dm_codec::{append_u32_words, append_u64_words};
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
	let mut fields = Vec::with_capacity(236);
	for value in [
		telemetry.callback_depth,
		telemetry.callback_capacity,
		telemetry.callback_high_water,
		telemetry.continuation_depth,
		telemetry.continuation_capacity,
		telemetry.continuation_high_water,
	] {
		append_u32_words(&mut fields, value);
	}
	for value in [
		telemetry.oldest_callback_age_ticks,
		telemetry.callback_enqueued,
		telemetry.callback_drained,
		telemetry.callback_rejected,
		telemetry.continuation_timeouts,
		telemetry.request_timeouts,
		telemetry.protocol_errors,
	] {
		append_u64_words(&mut fields, value);
	}
	for counters in [
		telemetry.callback_enqueued_by_kind,
		telemetry.callback_drained_by_kind,
		telemetry.callback_rejected_by_kind,
	] {
		for counter in counters {
			append_u64_words(&mut fields, counter);
		}
	}
	append_u32_words(&mut fields, telemetry.service_process_available_flags);
	append_u64_words(&mut fields, telemetry.service_rss_bytes);
	append_u64_words(&mut fields, telemetry.service_cpu_total_milliseconds);
	for value in [
		telemetry.general_callback_depth,
		telemetry.reaction_callback_depth,
		telemetry.reaction_transaction_depth,
		telemetry.reaction_transaction_high_water,
		telemetry.frontier_count,
		telemetry.stage_kind,
	] {
		append_u32_words(&mut fields, value);
	}
	append_u64_words(&mut fields, telemetry.frontier_upload_bytes);
	append_u64_words(&mut fields, telemetry.stage_epoch);
	append_u32_words(&mut fields, telemetry.stage_cursor);
	append_u32_words(&mut fields, telemetry.stage_remaining);
	append_u64_words(&mut fields, telemetry.topology_revision);
	append_u64_words(&mut fields, telemetry.reusable_workset_bytes);
	append_u64_words(&mut fields, telemetry.packed_topology_bytes);
	append_u64_words(&mut fields, telemetry.stage_jobs.job);
	append_u32_words(&mut fields, u32::from(telemetry.stage_jobs.status));
	for counter in telemetry.stage_jobs.counters() {
		append_u64_words(&mut fields, counter);
	}
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
