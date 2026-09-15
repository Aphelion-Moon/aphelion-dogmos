//! Main-thread process/service observation bindings; process roles remain separate.

use crate::bindings::production_request_with_response;
use crate::bindings::values::production_number_list;
use crate::metrics::{decode_production_service_telemetry, encode_production_process_metrics};
use byondapi::prelude::ByondValue;
use dogmos_process_metrics::sample_current_process;
use dogmos_protocol::{OperationKind, SERVICE_TELEMETRY_LEN};

#[auxmacros::bind("/proc/dogmos_service_telemetry")]
fn dogmos_service_telemetry() -> eyre::Result<ByondValue> {
	let fields = production_request_with_response(
		OperationKind::ServiceTelemetry,
		&[],
		SERVICE_TELEMETRY_LEN,
		decode_production_service_telemetry,
	)?;
	production_number_list(&fields)
}

#[auxmacros::bind("/proc/dogmos_process_metrics")]
fn dogmos_process_metrics() -> eyre::Result<ByondValue> {
	let metrics = sample_current_process();
	let fields = production_request_with_response(
		OperationKind::ServiceTelemetry,
		&[],
		SERVICE_TELEMETRY_LEN,
		|response| encode_production_process_metrics(metrics, response),
	)?;
	production_number_list(&fields)
}
