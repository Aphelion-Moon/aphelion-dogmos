//! Opt-in diagnostic bindings and benchmark fixtures; never enabled by production generation.

use crate::client::ClientError;
use crate::dm_codec::diagnostics::{
	callback_count_from_number, diagnostic_bytes_from_number, scalar_response_value,
};
use crate::session::{start_service_session, ServiceSession};
use crate::session_limits::SESSION_CONTROL_PAYLOAD_BYTES;
use byondapi::prelude::ByondValue;
use dogmos_protocol::{
	encode_adjacency_batch, encode_lifecycle_batch, encode_mixture_state_batch, AdjacencyMutation,
	CallbackBatchHeader, CallbackBatchRequest, CallbackEvent, CallbackScope, LifecycleAction,
	LifecycleMutation, MixtureSnapshot, MixtureSnapshotRequest, MixtureStateMutation,
	OperationKind, ScalarValue, ServiceErrorCode, SimulationStage, SimulationStageRequest,
	SimulationStageResponse, WireHandle, CALLBACK_BATCH_HEADER_LEN, CALLBACK_EVENT_LEN,
	MAX_GAS_SLOTS, MIXTURE_SNAPSHOT_LEN, SIMULATION_STAGE_RESPONSE_LEN,
};
use std::sync::{Mutex, OnceLock};
use std::time::Instant;

#[cfg(feature = "diagnostic-bindings")]
pub(crate) static BENCHMARK_ADJACENCY_BATCH: OnceLock<Vec<u8>> = OnceLock::new();

#[cfg(feature = "diagnostic-bindings")]
pub(crate) static BENCHMARK_STATE_BATCH: OnceLock<Vec<u8>> = OnceLock::new();

#[cfg(feature = "diagnostic-bindings")]
pub(crate) static BENCHMARK_LIFECYCLE_BATCH: OnceLock<Vec<u8>> = OnceLock::new();

#[cfg(feature = "diagnostic-bindings")]
pub(crate) static BENCHMARK_CLOCK: OnceLock<Instant> = OnceLock::new();

#[cfg(feature = "diagnostic-bindings")]
pub(crate) static BENCHMARK_SESSION: Mutex<Option<ServiceSession>> = Mutex::new(None);

#[cfg(feature = "diagnostic-bindings")]
#[auxmacros::bind("/proc/dogmos_ipc_benchmark_start")]
fn dogmos_ipc_benchmark_start(service_path: ByondValue) -> eyre::Result<ByondValue> {
	let service_path = service_path.get_string()?;
	let mut session = BENCHMARK_SESSION
		.lock()
		.map_err(|_| eyre::eyre!("Dogmos IPC benchmark session lock is poisoned"))?;
	if session.is_some() {
		return Err(eyre::eyre!(
			"Dogmos IPC benchmark session is already running"
		));
	}
	*session = Some(start_service_session(&service_path)?);
	Ok(true.into())
}

#[cfg(feature = "diagnostic-bindings")]
#[auxmacros::bind("/proc/dogmos_ipc_benchmark_scalar_get")]
fn dogmos_ipc_benchmark_scalar_get() -> eyre::Result<ByondValue> {
	let mut session = BENCHMARK_SESSION
		.lock()
		.map_err(|_| eyre::eyre!("Dogmos IPC benchmark session lock is poisoned"))?;
	let session = session
		.as_mut()
		.ok_or_else(|| eyre::eyre!("Dogmos IPC benchmark session is not running"))?;
	session.request_with_response(OperationKind::ScalarGet, &[0; 8], 8, |response| {
		Ok(scalar_response_value(response, response.len())?.into())
	})
}

#[cfg(feature = "diagnostic-bindings")]
#[auxmacros::bind("/proc/dogmos_ipc_benchmark_snapshot")]
fn dogmos_ipc_benchmark_snapshot() -> eyre::Result<ByondValue> {
	let mut session = BENCHMARK_SESSION
		.lock()
		.map_err(|_| eyre::eyre!("Dogmos IPC benchmark session lock is poisoned"))?;
	let session = session
		.as_mut()
		.ok_or_else(|| eyre::eyre!("Dogmos IPC benchmark session is not running"))?;
	let request = MixtureSnapshotRequest {
		handle: WireHandle {
			slot: 1,
			generation: 1,
		},
	}
	.encode();
	session.request_with_response(
		OperationKind::MixtureSnapshot,
		&request,
		MIXTURE_SNAPSHOT_LEN,
		|response| {
			if response.len() != MIXTURE_SNAPSHOT_LEN {
				return Err(eyre::eyre!(
					"Dogmos snapshot response was {} bytes, expected {MIXTURE_SNAPSHOT_LEN}",
					response.len(),
				));
			}
			Ok((MixtureSnapshot::decode(response)?.gas_count as f32).into())
		},
	)
}

#[cfg(feature = "diagnostic-bindings")]
#[auxmacros::bind("/proc/dogmos_ipc_benchmark_lifecycle_batch")]
fn dogmos_ipc_benchmark_lifecycle_batch() -> eyre::Result<ByondValue> {
	let request = BENCHMARK_LIFECYCLE_BATCH.get_or_init(make_benchmark_lifecycle_batch);
	benchmark_counted_command(OperationKind::MixtureLifecycleBatch, request)
}

#[cfg(feature = "diagnostic-bindings")]
#[auxmacros::bind("/proc/dogmos_ipc_benchmark_state_batch")]
fn dogmos_ipc_benchmark_state_batch() -> eyre::Result<ByondValue> {
	let request = BENCHMARK_STATE_BATCH.get_or_init(make_benchmark_state_batch);
	benchmark_counted_command(OperationKind::MixtureStateBatch, request)
}

#[cfg(feature = "diagnostic-bindings")]
#[auxmacros::bind("/proc/dogmos_ipc_benchmark_adjacency_batch")]
fn dogmos_ipc_benchmark_adjacency_batch() -> eyre::Result<ByondValue> {
	let request = BENCHMARK_ADJACENCY_BATCH.get_or_init(make_benchmark_adjacency_batch);
	benchmark_counted_command(OperationKind::AdjacencyBatch, request)
}

#[cfg(feature = "diagnostic-bindings")]
#[auxmacros::bind("/proc/dogmos_ipc_benchmark_simulation_stage")]
fn dogmos_ipc_benchmark_simulation_stage() -> eyre::Result<ByondValue> {
	let request = SimulationStageRequest {
		stage: SimulationStage::ProcessTurfs,
		frontier_epoch: 1,
		stage_epoch: 1,
		work_limit: 1,
		seconds_per_tick: ScalarValue(0.5),
	}
	.encode()?;
	let mut session = BENCHMARK_SESSION
		.lock()
		.map_err(|_| eyre::eyre!("Dogmos IPC benchmark session lock is poisoned"))?;
	let session = session
		.as_mut()
		.ok_or_else(|| eyre::eyre!("Dogmos IPC benchmark session is not running"))?;
	session.request_with_response(
		OperationKind::SimulationStage,
		&request,
		SIMULATION_STAGE_RESPONSE_LEN,
		|response| {
			if response.len() != SIMULATION_STAGE_RESPONSE_LEN {
				return Err(eyre::eyre!(
					"Dogmos stage response was {} bytes, expected {SIMULATION_STAGE_RESPONSE_LEN}",
					response.len(),
				));
			}
			Ok((SimulationStageResponse::decode(response)?.work_items as f32).into())
		},
	)
}

#[cfg(feature = "diagnostic-bindings")]
#[auxmacros::bind("/proc/dogmos_ipc_benchmark_callback_enqueue")]
fn dogmos_ipc_benchmark_callback_enqueue(count: ByondValue) -> eyre::Result<ByondValue> {
	let request = CallbackBatchRequest {
		max_events: callback_count_from_number(count.get_number()?)?,
		scope: CallbackScope::General,
		transaction_id: 0,
	}
	.encode()?;
	let mut session = BENCHMARK_SESSION
		.lock()
		.map_err(|_| eyre::eyre!("Dogmos IPC benchmark session lock is poisoned"))?;
	let session = session
		.as_mut()
		.ok_or_else(|| eyre::eyre!("Dogmos IPC benchmark session is not running"))?;
	match session.request_with_response(
		OperationKind::DiagnosticCallbackEnqueue,
		&request,
		4,
		|response| {
			Ok::<_, ClientError>(if response.len() == 4 {
				Ok((u32::from_le_bytes(response.try_into().unwrap()) as f32).into())
			} else {
				Err(eyre::eyre!(
					"Dogmos callback enqueue response was {} bytes, expected 4",
					response.len(),
				))
			})
		},
	) {
		Ok(result) => result,
		Err(ClientError::Server(ServiceErrorCode::CallbackBackpressure)) => Ok((-1.0_f32).into()),
		Err(error) => Err(error.into()),
	}
}

#[cfg(feature = "diagnostic-bindings")]
#[auxmacros::bind("/proc/dogmos_ipc_benchmark_callback_drain")]
fn dogmos_ipc_benchmark_callback_drain(max_events: ByondValue) -> eyre::Result<ByondValue> {
	let request = CallbackBatchRequest {
		max_events: callback_count_from_number(max_events.get_number()?)?,
		scope: CallbackScope::General,
		transaction_id: 0,
	}
	.encode()?;
	let mut session = BENCHMARK_SESSION
		.lock()
		.map_err(|_| eyre::eyre!("Dogmos IPC benchmark session lock is poisoned"))?;
	let session = session
		.as_mut()
		.ok_or_else(|| eyre::eyre!("Dogmos IPC benchmark session is not running"))?;
	session.request_with_response(
		OperationKind::CallbackBatch,
		&request,
		SESSION_CONTROL_PAYLOAD_BYTES,
		decode_benchmark_callback_drain,
	)
}

#[cfg(feature = "diagnostic-bindings")]
pub(crate) fn decode_benchmark_callback_drain(response: &[u8]) -> eyre::Result<ByondValue> {
	let response_len = response.len();
	if response_len < CALLBACK_BATCH_HEADER_LEN {
		return Err(eyre::eyre!(
			"Dogmos callback drain response was {response_len} bytes, shorter than its header"
		));
	}
	let header = CallbackBatchHeader::decode(&response[..CALLBACK_BATCH_HEADER_LEN])?;
	let expected_len = CALLBACK_BATCH_HEADER_LEN
		+ usize::try_from(header.returned)?
			.checked_mul(CALLBACK_EVENT_LEN)
			.ok_or_else(|| eyre::eyre!("Dogmos callback response length overflow"))?;
	if response_len != expected_len {
		return Err(eyre::eyre!(
			"Dogmos callback drain response was {response_len} bytes, expected {expected_len}"
		));
	}
	let mut first_sequence = 0;
	let mut last_sequence: u64 = 0;
	for (index, event_bytes) in response[CALLBACK_BATCH_HEADER_LEN..response_len]
		.as_chunks::<CALLBACK_EVENT_LEN>()
		.0
		.iter()
		.enumerate()
	{
		let event = CallbackEvent::decode(event_bytes)?;
		if index == 0 {
			first_sequence = event.scope_sequence;
		} else {
			let expected = last_sequence.checked_add(1).ok_or_else(|| {
				eyre::eyre!("Dogmos callback sequence overflowed after {last_sequence}")
			})?;
			if event.scope_sequence != expected {
				return Err(eyre::eyre!(
					"Dogmos callback sequence skipped from {last_sequence} to {}",
					event.scope_sequence
				));
			}
		}
		last_sequence = event.scope_sequence;
	}
	let summary: ByondValue = format!(
		"{},{},{},{},{},{},{}",
		header.returned,
		header.remaining,
		header.capacity,
		header.high_water,
		header.rejected,
		first_sequence,
		last_sequence
	)
	.try_into()?;
	Ok(summary)
}

#[cfg(feature = "diagnostic-bindings")]
pub(crate) fn benchmark_counted_command(
	operation: OperationKind,
	request: &[u8],
) -> eyre::Result<ByondValue> {
	let mut session = BENCHMARK_SESSION
		.lock()
		.map_err(|_| eyre::eyre!("Dogmos IPC benchmark session lock is poisoned"))?;
	let session = session
		.as_mut()
		.ok_or_else(|| eyre::eyre!("Dogmos IPC benchmark session is not running"))?;
	session.request_with_response(operation, request, 4, |response| {
		if response.len() != 4 {
			return Err(eyre::eyre!(
				"Dogmos counted response was {} bytes, expected 4",
				response.len(),
			));
		}
		Ok((u32::from_le_bytes(response.try_into().unwrap()) as f32).into())
	})
}

#[cfg(feature = "diagnostic-bindings")]
pub(crate) fn make_benchmark_lifecycle_batch() -> Vec<u8> {
	let entries = (0..64)
		.map(|slot| LifecycleMutation {
			action: LifecycleAction::Register,
			handle: WireHandle {
				slot,
				generation: 1,
			},
		})
		.collect::<Vec<_>>();
	let mut output = Vec::new();
	encode_lifecycle_batch(&entries, &mut output)
		.expect("the fixed benchmark lifecycle batch is valid");
	output
}

#[cfg(feature = "diagnostic-bindings")]
pub(crate) fn make_benchmark_state_batch() -> Vec<u8> {
	let entries = (0..64)
		.map(|slot| {
			let mut gases = [ScalarValue(0.0); MAX_GAS_SLOTS];
			gases[0] = ScalarValue(if slot % 2 == 0 { 20.0 } else { 5.0 });
			MixtureStateMutation {
				handle: WireHandle {
					slot,
					generation: 1,
				},
				expected_revision: 0,
				temperature: ScalarValue(293.15),
				volume: ScalarValue(2500.0),
				gases,
			}
		})
		.collect::<Vec<_>>();
	let mut output = Vec::new();
	encode_mixture_state_batch(&entries, &mut output)
		.expect("the fixed benchmark mixture-state batch is valid");
	output
}

#[cfg(feature = "diagnostic-bindings")]
pub(crate) fn make_benchmark_adjacency_batch() -> Vec<u8> {
	let entries = (0..64)
		.map(|slot| AdjacencyMutation {
			left: WireHandle {
				slot,
				generation: 1,
			},
			right: WireHandle {
				slot: (slot + 1) % 64,
				generation: 1,
			},
			conductivity: ScalarValue(0.75),
		})
		.collect::<Vec<_>>();
	let mut output = Vec::new();
	encode_adjacency_batch(&entries, &mut output)
		.expect("the fixed benchmark adjacency batch is valid");
	output
}

#[cfg(feature = "diagnostic-bindings")]
#[auxmacros::bind("/proc/dogmos_ipc_benchmark_service_pid")]
fn dogmos_ipc_benchmark_service_pid() -> eyre::Result<ByondValue> {
	let session = BENCHMARK_SESSION
		.lock()
		.map_err(|_| eyre::eyre!("Dogmos IPC benchmark session lock is poisoned"))?;
	let session = session
		.as_ref()
		.ok_or_else(|| eyre::eyre!("Dogmos IPC benchmark session is not running"))?;
	Ok((session.client.peer().process_id as f32).into())
}

#[cfg(feature = "diagnostic-bindings")]
#[auxmacros::bind("/proc/dogmos_ipc_benchmark_clock_microseconds")]
fn dogmos_ipc_benchmark_clock_microseconds() -> eyre::Result<ByondValue> {
	let origin = BENCHMARK_CLOCK.get_or_init(Instant::now);
	Ok((origin.elapsed().as_secs_f32() * 1_000_000.0).into())
}

#[cfg(feature = "diagnostic-bindings")]
#[auxmacros::bind("/proc/dogmos_ipc_benchmark_allocate")]
fn dogmos_ipc_benchmark_allocate(bytes: ByondValue) -> eyre::Result<ByondValue> {
	let bytes = diagnostic_bytes_from_number(bytes.get_number()?)?;
	let mut session = BENCHMARK_SESSION
		.lock()
		.map_err(|_| eyre::eyre!("Dogmos IPC benchmark session lock is poisoned"))?;
	let session = session
		.as_mut()
		.ok_or_else(|| eyre::eyre!("Dogmos IPC benchmark session is not running"))?;
	session.request_with_response(
		OperationKind::AllocateDiagnostic,
		&bytes.to_le_bytes(),
		8,
		|response| {
			let response: [u8; 8] = response.try_into().map_err(|_| {
				eyre::eyre!(
					"Dogmos allocation response was {} bytes, expected 8",
					response.len(),
				)
			})?;
			Ok((u64::from_le_bytes(response) as f32).into())
		},
	)
}

#[cfg(feature = "diagnostic-bindings")]
#[auxmacros::bind("/proc/dogmos_ipc_benchmark_stop")]
fn dogmos_ipc_benchmark_stop() -> eyre::Result<ByondValue> {
	let mut session = BENCHMARK_SESSION
		.lock()
		.map_err(|_| eyre::eyre!("Dogmos IPC benchmark session lock is poisoned"))?;
	let mut active = session
		.take()
		.ok_or_else(|| eyre::eyre!("Dogmos IPC benchmark session is not running"))?;
	active.request_with_response(
		OperationKind::AllocateDiagnostic,
		&0_u64.to_le_bytes(),
		8,
		|_| Ok::<(), eyre::Report>(()),
	)?;
	active.shutdown()?;
	Ok(true.into())
}
