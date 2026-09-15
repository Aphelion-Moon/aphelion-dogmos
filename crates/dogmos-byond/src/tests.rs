//! Independent literal contract fixtures and allocation checks, unchanged by module movement.

#[cfg(test)]
struct TestCountingAllocator;

#[cfg(test)]
thread_local! {
	static COUNT_TEST_ALLOCATIONS: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
	static TEST_ALLOCATION_COUNT: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
}

#[cfg(test)]
unsafe impl std::alloc::GlobalAlloc for TestCountingAllocator {
	unsafe fn alloc(&self, layout: std::alloc::Layout) -> *mut u8 {
		let allocation = unsafe { std::alloc::System.alloc(layout) };
		COUNT_TEST_ALLOCATIONS.with(|enabled| {
			if enabled.get() && !allocation.is_null() {
				TEST_ALLOCATION_COUNT.with(|count| count.set(count.get().saturating_add(1)));
			}
		});
		allocation
	}

	unsafe fn dealloc(&self, pointer: *mut u8, layout: std::alloc::Layout) {
		unsafe { std::alloc::System.dealloc(pointer, layout) };
	}
}

#[cfg(test)]
#[global_allocator]
static TEST_GLOBAL_ALLOCATOR: TestCountingAllocator = TestCountingAllocator;

use crate::dm_codec::callbacks::{
	decode_production_callback_batch, decode_production_continuation_token,
	encode_production_continuation_adjust_multiple, encode_production_continuation_command,
	encode_production_continuation_resume,
};
use crate::dm_codec::diagnostics::{
	callback_count_from_number, diagnostic_bytes_from_number, scalar_response_value,
};
use crate::dm_codec::metadata::{
	encode_production_gas_metadata, encode_production_reaction_metadata,
};
use crate::dm_codec::mixtures::{
	decode_production_mixture_snapshot, decode_production_pipenet_reconcile,
	encode_dm_mixture_command, encode_production_mixture_adjust_multiple,
	encode_production_mixture_lifecycle_batch, encode_production_mixture_state_batch,
	encode_production_pipenet_reconcile, DmMixtureCommandFields,
};
use crate::dm_codec::stages::{
	decode_production_simulation_stage, encode_production_frontier_append,
	encode_production_frontier_begin, encode_production_simulation_stage,
};
use crate::dm_codec::topology::{
	decode_production_turf_heat_snapshot, encode_production_turf_adjacency_batch,
	encode_production_turf_heat_adjacency_batch, encode_production_turf_heat_batch,
	encode_production_turf_lifecycle_batch,
};
use crate::dm_codec::{
	exact_u16, exact_u32, hex_lower, PRODUCTION_CALLBACK_HEADER_FIELDS,
	PRODUCTION_MAX_CALLBACK_EVENTS,
};
use crate::metrics::{decode_production_service_telemetry, encode_production_process_metrics};

use dogmos_process_metrics::{
	CurrentProcessMetrics, PROCESS_ALL_AVAILABLE, PROCESS_PRIVATE_BYTES_AVAILABLE,
};
use dogmos_protocol::{
	decode_adjust_multiple_request, decode_continuation_adjust_multiple_request,
	decode_gas_metadata_batch, decode_lifecycle_batch, decode_mixture_state_batch,
	decode_pipenet_reconcile_request, decode_reaction_metadata_batch, decode_turf_adjacency_batch,
	decode_turf_heat_adjacency_batch, decode_turf_heat_batch, decode_turf_lifecycle_batch,
	encode_pipenet_reconcile_response, CallbackBatchHeader, CallbackEvent, CallbackEventKind,
	CallbackScope, ContinuationCommandRequest, ContinuationResumeRequest, ContinuationToken,
	FrontierBeginRequest, GasMetadataRegistration, LifecycleAction, LifecycleMutation,
	MixtureAdjustment, MixtureCommandRequest, MixtureSnapshot, PipenetReconcileSnapshot,
	ReactionMetadataRegistration, ScalarValue, ServiceTelemetry, SimulationStage,
	SimulationStageRequest, SimulationStageResponse, TurfAdjacencyMutation,
	TurfHeatAdjacencyMutation, TurfHeatMutation, TurfHeatSnapshot, TurfHeatState,
	TurfLifecycleMutation, WireFireProducts, WireGasFireRole, WireGasProduct, WireGasRequirement,
	WireHandle, WireReactionExecution, MAX_GAS_SLOTS, SERVICE_PROCESS_ALL_AVAILABLE,
};

fn handle(slot: u32, generation: u32) -> WireHandle {
	WireHandle { slot, generation }
}

fn error_text<T>(result: eyre::Result<T>) -> String {
	match result {
		Ok(_) => panic!("expected an error"),
		Err(error) => error.to_string(),
	}
}

fn count_allocations<T>(operation: impl FnOnce() -> T) -> (T, usize) {
	struct CountingGuard;

	impl Drop for CountingGuard {
		fn drop(&mut self) {
			COUNT_TEST_ALLOCATIONS.with(|enabled| enabled.set(false));
		}
	}

	TEST_ALLOCATION_COUNT.with(|count| count.set(0));
	COUNT_TEST_ALLOCATIONS.with(|enabled| enabled.set(true));
	let guard = CountingGuard;
	let output = operation();
	drop(guard);
	let allocations = TEST_ALLOCATION_COUNT.with(std::cell::Cell::get);
	(output, allocations)
}

#[test]
fn indexed_decoder_errors_preserve_complete_context() {
	let mut continuation = [0.0; 10];
	continuation[3] = 65_536.0;
	assert_eq!(
		error_text(decode_production_continuation_token(&continuation)),
		"continuation token word 3 exceeds the u16 wire range"
	);
	assert_eq!(
		error_text(encode_production_mixture_lifecycle_batch(&[
			1.0,
			0.0,
			f32::NAN,
		])),
		"mixture lifecycle entry 0 generation must be an exact non-negative BYOND integer"
	);

	let mut mixture_state = vec![0.0; 6 + MAX_GAS_SLOTS];
	mixture_state[1] = f32::NAN;
	assert_eq!(
		error_text(encode_production_mixture_state_batch(&mixture_state)),
		"mixture state entry 0 generation must be an exact non-negative BYOND integer"
	);

	let mut gas = [0.0; 13];
	gas[0] = 65_536.0;
	assert_eq!(
		error_text(encode_production_gas_metadata(
			&gas,
			&["gas".to_owned()],
			&["Gas".to_owned()],
			&[],
		)),
		"gas metadata entry 0 id exceeds the u16 wire range"
	);

	let mut reaction = [0.0; 12];
	reaction[0] = 65_536.0;
	assert_eq!(
		error_text(encode_production_reaction_metadata(
			&reaction,
			&["reaction".to_owned()],
			&[],
		)),
		"reaction metadata entry 0 id low word exceeds the u16 wire range"
	);

	assert_eq!(
		error_text(encode_production_turf_lifecycle_batch(&[
			1.0,
			0.0,
			f32::NAN,
			0.0,
			0.0,
			0.0,
		])),
		"turf lifecycle entry 0 generation must be an exact non-negative BYOND integer"
	);
	assert_eq!(
		error_text(encode_production_turf_adjacency_batch(&[
			0.0,
			0.0,
			1.0,
			f32::NAN,
			0.0,
			0.0,
		])),
		"turf adjacency entry 0 right generation must be an exact non-negative BYOND integer"
	);
	assert_eq!(
		error_text(encode_production_turf_heat_batch(&[
			0.0,
			f32::NAN,
			0.0,
			0.0,
			0.0,
			0.0,
			0.0,
		])),
		"turf heat entry 0 generation must be an exact non-negative BYOND integer"
	);
	assert_eq!(
		error_text(encode_production_turf_heat_adjacency_batch(&[
			0.0,
			0.0,
			1.0,
			f32::NAN,
			0.0,
		])),
		"turf heat adjacency entry 0 right generation must be an exact non-negative BYOND integer"
	);

	let mut frontier = vec![0.0; 10];
	frontier[9] = 65_536.0;
	assert_eq!(
		error_text(encode_production_frontier_append(&frontier)),
		"frontier handle 0 generation word 1 exceeds the u16 wire range"
	);

	let event = CallbackEvent {
		scope_sequence: 1,
		transaction_id: 0,
		scope: CallbackScope::General,
		kind: CallbackEventKind::Diagnostic,
		flags: 0,
		subject: handle(0, 1),
		target: handle(0, 1),
		values: [
			ScalarValue(f64::MAX),
			ScalarValue(0.0),
			ScalarValue(0.0),
			ScalarValue(0.0),
		],
		aux: 0,
		continuation: None,
	};
	let mut callback = CallbackBatchHeader {
		returned: 1,
		remaining: 0,
		capacity: 1,
		high_water: 1,
		rejected: 0,
	}
	.encode()
	.to_vec();
	callback.extend(event.encode().unwrap());
	assert_eq!(
		error_text(decode_production_callback_batch(
			&callback,
			1,
			CallbackScope::General,
			0,
		)),
		"callback value 0 is outside the finite BYOND number range"
	);
}

#[test]
fn callback_value_overflow_preserves_the_exact_index() {
	let event = CallbackEvent {
		scope_sequence: 1,
		transaction_id: 0,
		scope: CallbackScope::General,
		kind: CallbackEventKind::Diagnostic,
		flags: 0,
		subject: handle(0, 1),
		target: handle(0, 1),
		values: [
			ScalarValue(0.0),
			ScalarValue(0.0),
			ScalarValue(0.0),
			ScalarValue(f64::from(f32::MAX) * 2.0),
		],
		aux: 0,
		continuation: None,
	};
	let mut response = CallbackBatchHeader {
		returned: 1,
		remaining: 0,
		capacity: 1,
		high_water: 1,
		rejected: 0,
	}
	.encode()
	.to_vec();
	response.extend(event.encode().unwrap());

	assert_eq!(
		error_text(decode_production_callback_batch(
			&response,
			1,
			CallbackScope::General,
			0,
		)),
		"callback value 3 is outside the finite BYOND number range"
	);
}

#[test]
fn callback_value_success_path_does_not_allocate_index_labels() {
	let mut response = CallbackBatchHeader {
		returned: PRODUCTION_MAX_CALLBACK_EVENTS,
		remaining: 0,
		capacity: PRODUCTION_MAX_CALLBACK_EVENTS,
		high_water: PRODUCTION_MAX_CALLBACK_EVENTS,
		rejected: 0,
	}
	.encode()
	.to_vec();
	for sequence in 1..=u64::from(PRODUCTION_MAX_CALLBACK_EVENTS) {
		response.extend(
			CallbackEvent {
				scope_sequence: sequence,
				transaction_id: 0,
				scope: CallbackScope::General,
				kind: CallbackEventKind::Diagnostic,
				flags: 0,
				subject: handle(0, 1),
				target: handle(0, 1),
				values: [ScalarValue(1.0); 4],
				aux: 0,
				continuation: None,
			}
			.encode()
			.unwrap(),
		);
	}

	let (fields, allocations) = count_allocations(|| {
		decode_production_callback_batch(
			&response,
			PRODUCTION_MAX_CALLBACK_EVENTS,
			CallbackScope::General,
			0,
		)
		.unwrap()
	});
	assert_eq!(
		fields.len(),
		PRODUCTION_CALLBACK_HEADER_FIELDS + PRODUCTION_MAX_CALLBACK_EVENTS as usize * 36
	);
	assert_eq!(
		allocations, 1,
		"only the returned field vector should allocate"
	);
}

#[test]
fn production_mixture_fields_encode_only_canonical_commands() {
	let request = encode_dm_mixture_command(DmMixtureCommandFields {
		kind: 1,
		flags: 0,
		primary: handle(7, 2),
		secondary: handle(0, 0),
		scalars: [12.5, 0.0, 0.0],
		gas_id: 3,
		aux: 0,
	})
	.unwrap();
	assert_eq!(
		MixtureCommandRequest::decode(&request),
		Ok(MixtureCommandRequest::SetMoles {
			handle: handle(7, 2),
			gas_id: 3,
			amount: ScalarValue(12.5),
		})
	);

	let error = encode_dm_mixture_command(DmMixtureCommandFields {
		kind: 5,
		flags: 0,
		primary: handle(7, 2),
		secondary: handle(0, 0),
		scalars: [1.0, 0.0, 0.0],
		gas_id: 0,
		aux: 0,
	});
	assert!(error.is_err(), "unused scalar must fail closed");

	let direct_reaction = encode_dm_mixture_command(DmMixtureCommandFields {
		kind: 36,
		flags: 0,
		primary: handle(7, 2),
		secondary: handle(41, 9),
		scalars: [0.0; 3],
		gas_id: 0,
		aux: 0,
	})
	.unwrap();
	assert_eq!(
		MixtureCommandRequest::decode(&direct_reaction),
		Ok(MixtureCommandRequest::React {
			handle: handle(7, 2),
			target: handle(41, 9),
			reaction_profile_threshold_ms: None,
		})
	);

	let profiled_reaction = encode_dm_mixture_command(DmMixtureCommandFields {
		kind: 36,
		flags: 1,
		primary: handle(7, 2),
		secondary: handle(41, 9),
		scalars: [0.5, 0.0, 0.0],
		gas_id: 0,
		aux: 0,
	})
	.unwrap();
	assert_eq!(
		MixtureCommandRequest::decode(&profiled_reaction),
		Ok(MixtureCommandRequest::React {
			handle: handle(7, 2),
			target: handle(41, 9),
			reaction_profile_threshold_ms: Some(ScalarValue(0.5)),
		})
	);

	let create_from_source = encode_dm_mixture_command(DmMixtureCommandFields {
		kind: 37,
		flags: 0,
		primary: handle(7, 2),
		secondary: handle(41, 9),
		scalars: [125.5, 0.0, 0.0],
		gas_id: 0,
		aux: 0,
	})
	.unwrap();
	assert_eq!(
		MixtureCommandRequest::decode(&create_from_source),
		Ok(MixtureCommandRequest::CreateFromSource {
			destination: handle(7, 2),
			source: handle(41, 9),
			volume: ScalarValue(125.5),
		})
	);

	assert!(encode_dm_mixture_command(DmMixtureCommandFields {
		kind: 37,
		flags: 0,
		primary: handle(7, 2),
		secondary: handle(41, 9),
		scalars: [f32::INFINITY, 0.0, 0.0],
		gas_id: 0,
		aux: 0,
	})
	.is_err());
}

#[test]
fn production_mixture_integer_fields_reject_hostile_numbers() {
	for number in [f32::NAN, f32::INFINITY, -1.0, 1.5, 16_777_218.0] {
		assert!(exact_u32(number, "test field").is_err());
	}
	assert_eq!(exact_u32(16_777_216.0, "test field").unwrap(), 16_777_216);
	assert!(exact_u16(65_536.0, "test field").is_err());
}

#[test]
fn production_lifecycle_batches_are_bounded_exact_triples() {
	let request =
		encode_production_mixture_lifecycle_batch(&[1.0, 7.0, 2.0, 2.0, 7.0, 2.0]).unwrap();
	assert_eq!(
		decode_lifecycle_batch(&request, 2),
		Ok(vec![
			LifecycleMutation {
				action: LifecycleAction::Register,
				handle: handle(7, 2),
			},
			LifecycleMutation {
				action: LifecycleAction::Unregister,
				handle: handle(7, 2),
			},
		])
	);
	assert!(encode_production_mixture_lifecycle_batch(&[1.0, 7.0]).is_err());
	assert!(encode_production_mixture_lifecycle_batch(&[3.0, 7.0, 2.0]).is_err());
	assert!(encode_production_mixture_lifecycle_batch(&[1.0, 7.5, 2.0]).is_err());
}

#[test]
fn production_multi_adjust_is_bounded_and_validated() {
	let request =
		encode_production_mixture_adjust_multiple(&[7.0, 2.0, 1.0, -0.5, 3.0, 2.0]).unwrap();
	assert_eq!(
		decode_adjust_multiple_request(&request),
		Ok((
			handle(7, 2),
			vec![
				MixtureAdjustment {
					gas_id: 1,
					delta: ScalarValue(-0.5),
				},
				MixtureAdjustment {
					gas_id: 3,
					delta: ScalarValue(2.0),
				},
			],
		))
	);
	assert!(encode_production_mixture_adjust_multiple(&[7.0]).is_err());
	assert!(encode_production_mixture_adjust_multiple(&[7.0, 2.0, 1.0]).is_err());
	assert!(encode_production_mixture_adjust_multiple(&[7.0, 2.0, 1.5, 1.0]).is_err());
	assert!(encode_production_mixture_adjust_multiple(&[7.0, 2.0, 1.0, f32::NAN]).is_err());
}

#[test]
fn production_snapshot_preserves_revision_and_fixed_gas_layout() {
	let mut gases = [ScalarValue(0.0); MAX_GAS_SLOTS];
	gases[0] = ScalarValue(1.25);
	gases[31] = ScalarValue(9.5);
	let response = MixtureSnapshot {
		revision: 0xfedc_ba98,
		gas_count: 2,
		temperature: ScalarValue(293.15),
		volume: ScalarValue(2_500.0),
		minimum_heat_capacity: ScalarValue(0.5),
		total_moles: ScalarValue(10.75),
		pressure: ScalarValue(10.5),
		heat_capacity: ScalarValue(215.0),
		immutable: true,
		gases,
	}
	.encode()
	.unwrap();
	let fields = decode_production_mixture_snapshot(&response).unwrap();
	assert_eq!(fields.len(), 10 + MAX_GAS_SLOTS);
	assert_eq!(&fields[..3], &[0xba98 as f32, 0xfedc as f32, 2.0]);
	assert_eq!(
		&fields[3..10],
		&[293.15, 2_500.0, 0.5, 10.75, 10.5, 215.0, 1.0]
	);
	assert_eq!(fields[10], 1.25);
	assert_eq!(fields[10 + 31], 9.5);
}

#[test]
fn production_pipenet_reconcile_preserves_duplicate_request_handles() {
	let request = encode_production_pipenet_reconcile(&[7.0, 11.0, 13.0, 17.0, 7.0, 11.0]).unwrap();
	assert_eq!(
		decode_pipenet_reconcile_request(&request, 3).unwrap(),
		[handle(7, 11), handle(13, 17), handle(7, 11)]
	);
	assert!(encode_production_pipenet_reconcile(&[7.0]).is_err());
}

#[test]
fn production_compact_snapshot_requests_fit_the_session_response_window() {
	let pairs: Vec<_> = (1..=382).flat_map(|slot| [slot as f32, 1.0]).collect();
	assert_eq!(
		super::encode_production_mixture_snapshot_batch(&pairs[..762])
			.unwrap()
			.len(),
		3052
	);
	assert!(
		super::encode_production_mixture_snapshot_batch(&pairs).is_err(),
		"382 compact records exceed the production 65536-byte response window"
	);
}

#[test]
fn production_compact_pipenet_requests_fit_the_session_response_window() {
	let pairs: Vec<_> = (1..=382).flat_map(|slot| [slot as f32, 1.0]).collect();
	assert_eq!(
		encode_production_pipenet_reconcile(&pairs[..762])
			.unwrap()
			.len(),
		3052
	);
	assert!(
		encode_production_pipenet_reconcile(&pairs).is_err(),
		"382 compact records exceed the production 65536-byte response window"
	);
}

#[test]
fn production_pipenet_reconcile_flattens_handle_snapshot_records_for_dm() {
	let mut gases = [ScalarValue(0.0); MAX_GAS_SLOTS];
	gases[0] = ScalarValue(5.0);
	let snapshot = MixtureSnapshot {
		revision: 0x1234_5678,
		gas_count: 1,
		temperature: ScalarValue(450.0),
		volume: ScalarValue(100.0),
		minimum_heat_capacity: ScalarValue(0.0),
		total_moles: ScalarValue(5.0),
		pressure: ScalarValue(187.0),
		heat_capacity: ScalarValue(100.0),
		immutable: false,
		gases,
	};
	let mut response = Vec::new();
	encode_pipenet_reconcile_response(
		&[PipenetReconcileSnapshot {
			handle: handle(7, 11),
			snapshot,
		}],
		&mut response,
	)
	.unwrap();

	let fields = decode_production_pipenet_reconcile(&response).unwrap();
	assert_eq!(fields.len(), 2 + 10 + MAX_GAS_SLOTS);
	assert_eq!(
		&fields[0..5],
		&[7.0, 11.0, 0x5678 as f32, 0x1234 as f32, 1.0]
	);
	assert_eq!(fields[5], 450.0);
	assert_eq!(fields[12], 5.0);
}

#[test]
fn mixture_snapshot_gas_overflow_preserves_the_exact_index() {
	let mut gases = [ScalarValue(0.0); MAX_GAS_SLOTS];
	gases[17] = ScalarValue(f64::from(f32::MAX) * 2.0);
	let response = MixtureSnapshot {
		revision: 1,
		gas_count: MAX_GAS_SLOTS as u32,
		temperature: ScalarValue(293.15),
		volume: ScalarValue(2_500.0),
		minimum_heat_capacity: ScalarValue(0.5),
		total_moles: ScalarValue(10.75),
		pressure: ScalarValue(10.5),
		heat_capacity: ScalarValue(215.0),
		immutable: false,
		gases,
	}
	.encode()
	.unwrap();

	assert_eq!(
		error_text(decode_production_mixture_snapshot(&response)),
		"mixture snapshot gas 17 is outside the finite BYOND number range"
	);
}

#[test]
fn mixture_snapshot_success_path_does_not_allocate_index_labels() {
	let response = MixtureSnapshot {
		revision: 1,
		gas_count: MAX_GAS_SLOTS as u32,
		temperature: ScalarValue(293.15),
		volume: ScalarValue(2_500.0),
		minimum_heat_capacity: ScalarValue(0.5),
		total_moles: ScalarValue(10.75),
		pressure: ScalarValue(10.5),
		heat_capacity: ScalarValue(215.0),
		immutable: false,
		gases: [ScalarValue(1.0); MAX_GAS_SLOTS],
	}
	.encode()
	.unwrap();

	let (fields, allocations) =
		count_allocations(|| decode_production_mixture_snapshot(&response).unwrap());
	assert_eq!(fields.len(), 10 + MAX_GAS_SLOTS);
	assert_eq!(
		allocations, 1,
		"only the returned field vector should allocate"
	);
}

#[test]
fn production_turf_heat_snapshot_preserves_presence_and_values() {
	let response = TurfHeatSnapshot {
		state: Some(TurfHeatState {
			temperature: ScalarValue(700.0),
			thermal_conductivity: ScalarValue(0.4),
			heat_capacity: ScalarValue(2500.0),
			adjacent_to_space: true,
		}),
	}
	.encode()
	.unwrap();
	assert_eq!(
		decode_production_turf_heat_snapshot(&response).unwrap(),
		[1.0, 700.0, 0.4, 2500.0, 1.0]
	);
	let absent = TurfHeatSnapshot { state: None }.encode().unwrap();
	assert_eq!(
		decode_production_turf_heat_snapshot(&absent).unwrap(),
		[0.0; 5]
	);
}

#[test]
fn production_state_batch_uses_lossless_revision_words() {
	let mut fields = vec![7.0, 2.0, 0xba98 as f32, 0xfedc as f32, 293.15, 2_500.0];
	fields.extend((0..MAX_GAS_SLOTS).map(|index| index as f32 * 0.25));
	let request = encode_production_mixture_state_batch(&fields).unwrap();
	let mutations = decode_mixture_state_batch(&request, 1).unwrap();
	assert_eq!(mutations.len(), 1);
	assert_eq!(mutations[0].handle, handle(7, 2));
	assert_eq!(mutations[0].expected_revision, 0xfedc_ba98);
	assert_eq!(mutations[0].temperature, ScalarValue(293.15_f32.into()));
	assert_eq!(mutations[0].volume, ScalarValue(2_500.0));
	assert_eq!(mutations[0].gases[31], ScalarValue(7.75));

	assert!(encode_production_mixture_state_batch(&fields[..fields.len() - 1]).is_err());
	fields[2] = 65_536.0;
	assert!(encode_production_mixture_state_batch(&fields).is_err());
	fields[2] = 0.0;
	fields[6] = f32::NAN;
	assert!(encode_production_mixture_state_batch(&fields).is_err());
}

#[test]
fn production_turf_lifecycle_and_topology_are_fixed_records() {
	let lifecycle = encode_production_turf_lifecycle_batch(&[
		1.0, 10.0, 1.0, 1.0, 0.0, 1.0, 2.0, 11.0, 1.0, 0.0, 0.0, 0.0,
	])
	.unwrap();
	assert_eq!(
		decode_turf_lifecycle_batch(&lifecycle, 2).unwrap(),
		vec![
			TurfLifecycleMutation {
				action: LifecycleAction::Register,
				turf: handle(10, 1),
				mixture: Some(handle(0, 1)),
			},
			TurfLifecycleMutation {
				action: LifecycleAction::Unregister,
				turf: handle(11, 1),
				mixture: None,
			},
		]
	);
	assert!(encode_production_turf_lifecycle_batch(&[2.0, 11.0, 1.0, 0.0, 4.0, 1.0]).is_err());

	let adjacency =
		encode_production_turf_adjacency_batch(&[10.0, 1.0, 11.0, 1.0, 1.0, 1.0]).unwrap();
	assert_eq!(
		decode_turf_adjacency_batch(&adjacency, 1).unwrap(),
		vec![TurfAdjacencyMutation {
			left: handle(10, 1),
			right: handle(11, 1),
			connected: true,
			firelock: true,
		}]
	);
	assert!(encode_production_turf_adjacency_batch(&[10.0, 1.0, 11.0, 1.0, 0.0, 1.0]).is_err());
}

#[test]
fn production_turf_heat_state_and_topology_are_fixed_records() {
	let heat = encode_production_turf_heat_batch(&[
		10.0, 1.0, 1.0, 700.0, 0.4, 2_500.0, 1.0, 11.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0,
	])
	.unwrap();
	assert_eq!(
		decode_turf_heat_batch(&heat, 2).unwrap(),
		vec![
			TurfHeatMutation {
				turf: handle(10, 1),
				state: Some(TurfHeatState {
					temperature: ScalarValue(700.0),
					thermal_conductivity: ScalarValue(0.4_f32.into()),
					heat_capacity: ScalarValue(2_500.0),
					adjacent_to_space: true,
				}),
			},
			TurfHeatMutation {
				turf: handle(11, 1),
				state: None,
			},
		]
	);
	assert!(encode_production_turf_heat_batch(&[11.0, 1.0, 0.0, 1.0, 0.0, 0.0, 0.0]).is_err());

	let adjacency =
		encode_production_turf_heat_adjacency_batch(&[10.0, 1.0, 11.0, 1.0, 1.0]).unwrap();
	assert_eq!(
		decode_turf_heat_adjacency_batch(&adjacency, 1).unwrap(),
		vec![TurfHeatAdjacencyMutation {
			left: handle(10, 1),
			right: handle(11, 1),
			connected: true,
		}]
	);
	assert!(encode_production_turf_heat_adjacency_batch(&[10.0, 1.0, 11.0, 1.0, 2.0]).is_err());
}

#[test]
fn production_stage_request_and_response_are_typed_and_lossless() {
	let request = encode_production_simulation_stage([
		4.0,
		0x4444 as f32,
		0x3333 as f32,
		0x2222 as f32,
		0x1111 as f32,
		0x8888 as f32,
		0x7777 as f32,
		0x6666 as f32,
		0x5555 as f32,
		0x0100 as f32,
		0.0,
		0.5,
	])
	.unwrap();
	assert_eq!(
		SimulationStageRequest::decode(&request).unwrap(),
		SimulationStageRequest {
			stage: SimulationStage::ProcessTurfs,
			frontier_epoch: 0x1111_2222_3333_4444,
			stage_epoch: 0x5555_6666_7777_8888,
			work_limit: 256,
			seconds_per_tick: ScalarValue(0.5),
		}
	);
	let response = SimulationStageResponse {
		work_items: 0xfedc_ba98,
		callback_events: 0x7654_3210,
		pending: true,
		remaining_estimate: 0x1111_2222,
		produced_equalize_seeds: 0x3333_4444,
		produced_group_seeds: 0x5555_6666,
		produced_heat_seeds: 0x7777_8888,
	}
	.encode();
	assert_eq!(
		decode_production_simulation_stage(&response).unwrap(),
		[
			0xba98 as f32,
			0xfedc as f32,
			0x3210 as f32,
			0x7654 as f32,
			1.0,
			0x2222 as f32,
			0x1111 as f32,
			0x4444 as f32,
			0x3333 as f32,
			0x6666 as f32,
			0x5555 as f32,
			0x8888 as f32,
			0x7777 as f32,
		]
	);
	let mut invalid = [0.0; 12];
	invalid[0] = 6.0;
	invalid[9] = 1.0;
	invalid[11] = 0.5;
	assert!(encode_production_simulation_stage(invalid).is_err());
	invalid[0] = 4.0;
	invalid[11] = f32::NAN;
	assert!(encode_production_simulation_stage(invalid).is_err());
}

#[test]
fn production_frontier_requests_preserve_all_integer_bits_and_bounds() {
	let begin = encode_production_frontier_begin(&[
		0x4444 as f32,
		0x3333 as f32,
		0x2222 as f32,
		0x1111 as f32,
		0xba98 as f32,
		0xfedc as f32,
	])
	.unwrap();
	assert_eq!(
		FrontierBeginRequest::decode(&begin).unwrap(),
		FrontierBeginRequest {
			epoch: 0x1111_2222_3333_4444,
			expected_count: 0xfedc_ba98,
		}
	);

	let append = encode_production_frontier_append(&[
		0x4444 as f32,
		0x3333 as f32,
		0x2222 as f32,
		0x1111 as f32,
		0x3210 as f32,
		0x7654 as f32,
		0xcdef as f32,
		0x89ab as f32,
		0x4567 as f32,
		0x0123 as f32,
	])
	.unwrap();
	let mut handles = Vec::new();
	let header = dogmos_protocol::decode_frontier_append_into(&append, &mut handles).unwrap();
	assert_eq!(header.epoch, 0x1111_2222_3333_4444);
	assert_eq!(header.offset, 0x7654_3210);
	assert_eq!(
		handles,
		vec![WireHandle {
			slot: 0x89ab_cdef,
			generation: 0x0123_4567,
		}]
	);
	assert!(encode_production_frontier_append(&[0.0; 6]).is_err());
	assert!(encode_production_frontier_append(&vec![0.0; 6 + 513 * 4]).is_err());
}

#[test]
fn production_gas_metadata_uses_parallel_bounded_records() {
	let numeric = [
		7.0,
		0x4321 as f32,
		0x8765 as f32,
		20.0,
		0.0,
		1.0,
		0.25,
		0.0,
		1.5,
		2.0,
		373.15,
		0.4,
		1.0,
	];
	let request = encode_production_gas_metadata(
		&numeric,
		&["plasma".to_owned()],
		&["Plasma".to_owned()],
		&[0.0, 3.0, 0.75],
	)
	.unwrap();
	assert_eq!(
		decode_gas_metadata_batch(&request).unwrap(),
		vec![GasMetadataRegistration {
			id: 7,
			key: "plasma".to_owned(),
			name: "Plasma".to_owned(),
			flags: 0x8765_4321,
			specific_heat: ScalarValue(20.0),
			fusion_power: ScalarValue(0.0),
			moles_visible: Some(ScalarValue(0.25)),
			enthalpy: ScalarValue(0.0),
			fire_radiation_released: ScalarValue(1.5),
			fire_role: WireGasFireRole::Fuel {
				minimum_temperature: ScalarValue(373.15_f32.into()),
				burn_rate: ScalarValue(0.4_f32.into()),
			},
			fire_products: Some(WireFireProducts::Generic(vec![WireGasProduct {
				gas_id: 3,
				ratio: ScalarValue(0.75),
			}])),
		}]
	);
	let mut noncanonical = numeric;
	noncanonical[5] = 0.0;
	assert!(encode_production_gas_metadata(
		&noncanonical,
		&["plasma".to_owned()],
		&["Plasma".to_owned()],
		&[0.0, 3.0, 0.75],
	)
	.is_err());
	assert!(encode_production_gas_metadata(&numeric, &[], &["Plasma".to_owned()], &[],).is_err());
}

#[test]
fn production_reaction_metadata_uses_lossless_ids_and_option_flags() {
	let numeric = [
		0xba98 as f32,
		0xfedc as f32,
		0.0,
		10.0,
		1.0,
		373.15,
		0.0,
		0.0,
		1.0,
		5.0,
		0.0,
		0.0,
	];
	let request = encode_production_reaction_metadata(
		&numeric,
		&["combustion".to_owned()],
		&[0.0, 7.0, 0.25],
	)
	.unwrap();
	assert_eq!(
		decode_reaction_metadata_batch(&request).unwrap(),
		vec![ReactionMetadataRegistration {
			id: 0xfedc_ba98,
			key: "combustion".to_owned(),
			priority: ScalarValue(10.0),
			minimum_temperature: Some(ScalarValue(373.15_f32.into())),
			maximum_temperature: None,
			minimum_energy: Some(ScalarValue(5.0)),
			minimum_fire_reagents: None,
			gas_requirements: vec![WireGasRequirement {
				gas_id: 7,
				minimum_moles: ScalarValue(0.25),
			}],
			execution: WireReactionExecution::Dm,
		}]
	);
	let mut noncanonical = numeric;
	noncanonical[6] = 0.0;
	noncanonical[7] = 1.0;
	assert!(
		encode_production_reaction_metadata(&noncanonical, &["combustion".to_owned()], &[],)
			.is_err()
	);
	assert!(encode_production_reaction_metadata(
		&numeric,
		&["combustion".to_owned()],
		&[1.0, 7.0, 0.25],
	)
	.is_err());
}

#[test]
fn production_telemetry_preserves_all_counter_bits() {
	let telemetry = ServiceTelemetry {
		callback_depth: 0xfedc_ba98,
		callback_capacity: 2,
		callback_high_water: 3,
		continuation_depth: 4,
		continuation_capacity: 5,
		continuation_high_water: 6,
		oldest_callback_age_ticks: 0x0123_4567_89ab_cdef,
		callback_enqueued: 8,
		callback_drained: 9,
		callback_rejected: 10,
		continuation_timeouts: 11,
		request_timeouts: 12,
		protocol_errors: 13,
		callback_enqueued_by_kind: [14, 15, 16, 17, 18, 19, 20, 21],
		callback_drained_by_kind: [22, 23, 24, 25, 26, 27, 28, 29],
		callback_rejected_by_kind: [30, 31, 32, 33, 34, 35, 36, u64::MAX],
		service_process_available_flags: SERVICE_PROCESS_ALL_AVAILABLE,
		service_rss_bytes: 0x1111_2222_3333_4444,
		service_cpu_total_milliseconds: 0x5555_6666_7777_8888,
		general_callback_depth: 38,
		reaction_callback_depth: 39,
		reaction_transaction_depth: 40,
		reaction_transaction_high_water: 41,
		frontier_count: 42,
		stage_kind: 5,
		frontier_upload_bytes: 43,
		stage_epoch: 44,
		stage_cursor: 45,
		stage_remaining: 46,
		topology_revision: 47,
		reusable_workset_bytes: 48,
		packed_topology_bytes: 49,
		stage_jobs: dogmos_protocol::StageJobTelemetry {
			job: 0x0001_0002_0003_0004,
			status: 3,
			age_nanoseconds: 0x0005_0006_0007_0008,
			publication_retries: u64::MAX,
			..Default::default()
		},
	};
	let fields = decode_production_service_telemetry(&telemetry.encode()).unwrap();
	assert_eq!(fields.len(), 236);
	assert_eq!(&fields[..2], &[0xba98 as f32, 0xfedc as f32]);
	assert_eq!(
		&fields[12..16],
		&[0xcdef as f32, 0x89ab as f32, 0x4567 as f32, 0x0123 as f32]
	);
	assert_eq!(&fields[132..136], &[65_535.0; 4]);
	assert_eq!(&fields[136..138], &[3.0, 0.0]);
	assert_eq!(&fields[138..142], &[17_476.0, 13_107.0, 8_738.0, 4_369.0]);
	assert_eq!(&fields[142..146], &[34_952.0, 30_583.0, 26_214.0, 21_845.0]);
	assert_eq!(&fields[146..148], &[38.0, 0.0]);
	assert_eq!(&fields[178..182], &[49.0, 0.0, 0.0, 0.0]);
	assert_eq!(&fields[182..186], &[4.0, 3.0, 2.0, 1.0]);
	assert_eq!(&fields[186..188], &[3.0, 0.0]);
	assert_eq!(&fields[188..192], &[8.0, 7.0, 6.0, 5.0]);
	assert_eq!(&fields[224..228], &[65_535.0; 4]);
}

#[test]
fn production_process_metrics_preserve_roles_width_and_word_order() {
	let host = CurrentProcessMetrics {
		available_flags: PROCESS_ALL_AVAILABLE,
		private_bytes: 0x1111_2222_3333_4444,
		virtual_bytes: 0x5555_6666_7777_8888,
		working_set_bytes: 0x9999_aaaa_bbbb_cccc,
		cpu_total_milliseconds: 99,
	};
	let service = ServiceTelemetry {
		callback_depth: 0,
		callback_capacity: 0,
		callback_high_water: 0,
		continuation_depth: 0,
		continuation_capacity: 0,
		continuation_high_water: 0,
		oldest_callback_age_ticks: 0,
		callback_enqueued: 0,
		callback_drained: 0,
		callback_rejected: 0,
		continuation_timeouts: 0,
		request_timeouts: 0,
		protocol_errors: 0,
		callback_enqueued_by_kind: [0; 8],
		callback_drained_by_kind: [0; 8],
		callback_rejected_by_kind: [0; 8],
		service_process_available_flags: SERVICE_PROCESS_ALL_AVAILABLE,
		service_rss_bytes: 0xdddd_eeee_ffff_0001,
		service_cpu_total_milliseconds: u64::MAX,
		..Default::default()
	};

	let fields = encode_production_process_metrics(host, &service.encode()).unwrap();

	assert_eq!(fields.len(), 28);
	assert_eq!(
		fields,
		vec![
			1.0, 0.0, 7.0, 0.0, 3.0, 0.0, 0.0, 0.0, 17_476.0, 13_107.0, 8_738.0, 4_369.0, 34_952.0,
			30_583.0, 26_214.0, 21_845.0, 52_428.0, 48_059.0, 43_690.0, 39_321.0, 1.0, 65_535.0,
			61_166.0, 56_797.0, 65_535.0, 65_535.0, 65_535.0, 65_535.0,
		]
	);
}

#[test]
fn production_process_metrics_reject_noncanonical_host_samples() {
	let empty_service = ServiceTelemetry {
		callback_depth: 0,
		callback_capacity: 0,
		callback_high_water: 0,
		continuation_depth: 0,
		continuation_capacity: 0,
		continuation_high_water: 0,
		oldest_callback_age_ticks: 0,
		callback_enqueued: 0,
		callback_drained: 0,
		callback_rejected: 0,
		continuation_timeouts: 0,
		request_timeouts: 0,
		protocol_errors: 0,
		callback_enqueued_by_kind: [0; 8],
		callback_drained_by_kind: [0; 8],
		callback_rejected_by_kind: [0; 8],
		service_process_available_flags: 0,
		service_rss_bytes: 0,
		service_cpu_total_milliseconds: 0,
		..Default::default()
	}
	.encode();
	let unknown_flags = CurrentProcessMetrics {
		available_flags: 16,
		..Default::default()
	};
	let nonzero_unavailable = CurrentProcessMetrics {
		private_bytes: 1,
		..Default::default()
	};

	assert!(encode_production_process_metrics(unknown_flags, &empty_service).is_err());
	assert!(encode_production_process_metrics(nonzero_unavailable, &empty_service).is_err());
	let partial = CurrentProcessMetrics {
		available_flags: PROCESS_PRIVATE_BYTES_AVAILABLE,
		private_bytes: 1,
		..Default::default()
	};
	assert!(encode_production_process_metrics(partial, &empty_service).is_ok());
}

#[test]
fn production_callbacks_preserve_events_and_continuation_tokens() {
	let token = ContinuationToken {
		world_generation: 0x8765_4321,
		id: 0x0123_4567_89ab_cdef,
		deadline_ticks: 0xfedc_ba98_7654_3210,
	};
	let event = CallbackEvent {
		scope_sequence: 0x1111_2222_3333_4444,
		transaction_id: 0x9999_aaaa_bbbb_cccc,
		scope: CallbackScope::Reaction,
		kind: CallbackEventKind::RunDmReaction,
		flags: 0,
		subject: handle(0x1234, 2),
		target: handle(0x5678, 3),
		values: [
			ScalarValue(1.0),
			ScalarValue(2.0),
			ScalarValue(3.0),
			ScalarValue(4.0),
		],
		aux: 0xaaaa_bbbb,
		continuation: Some(token),
	};
	let mut response = CallbackBatchHeader {
		returned: 1,
		remaining: 2,
		capacity: 256,
		high_water: 10,
		rejected: 0x0123_4567_89ab_cdef,
	}
	.encode()
	.to_vec();
	response.extend(event.encode().unwrap());
	let fields = decode_production_callback_batch(
		&response,
		1,
		CallbackScope::Reaction,
		0x9999_aaaa_bbbb_cccc,
	)
	.unwrap();
	assert_eq!(fields.len(), 12 + 36);
	assert_eq!(&fields[..2], &[1.0, 0.0]);
	assert_eq!(
		&fields[12..16],
		&[0x4444 as f32, 0x3333 as f32, 0x2222 as f32, 0x1111 as f32]
	);
	assert_eq!(
		&fields[16..20],
		&[0xcccc as f32, 0xbbbb as f32, 0xaaaa as f32, 0x9999 as f32]
	);
	assert_eq!(fields[20], CallbackScope::Reaction as u16 as f32);
	assert_eq!(fields[21], CallbackEventKind::RunDmReaction as u16 as f32);
	assert_eq!(fields[37], 1.0);
	assert_eq!(
		decode_production_continuation_token(&fields[38..48]).unwrap(),
		token
	);
	assert!(decode_production_callback_batch(
		&response,
		0,
		CallbackScope::Reaction,
		0x9999_aaaa_bbbb_cccc
	)
	.is_err());
	response.pop();
	assert!(decode_production_callback_batch(
		&response,
		1,
		CallbackScope::Reaction,
		0x9999_aaaa_bbbb_cccc
	)
	.is_err());

	let mut wrapped = CallbackBatchHeader {
		returned: 2,
		remaining: 0,
		capacity: 256,
		high_water: 2,
		rejected: 0,
	}
	.encode()
	.to_vec();
	wrapped.extend(
		CallbackEvent {
			scope_sequence: u64::MAX,
			..event
		}
		.encode()
		.unwrap(),
	);
	wrapped.extend(
		CallbackEvent {
			scope_sequence: 0,
			..event
		}
		.encode()
		.unwrap(),
	);
	assert!(decode_production_callback_batch(
		&wrapped,
		2,
		CallbackScope::Reaction,
		0x9999_aaaa_bbbb_cccc
	)
	.is_err());
}

#[test]
fn production_continuation_commands_use_exact_tokens() {
	let token_fields = [
		0x4321 as f32,
		0x8765 as f32,
		0xcdef as f32,
		0x89ab as f32,
		0x4567 as f32,
		0x0123 as f32,
		0x3210 as f32,
		0x7654 as f32,
		0xba98 as f32,
		0xfedc as f32,
	];
	let token = decode_production_continuation_token(&token_fields).unwrap();
	let mut command_fields = token_fields.to_vec();
	command_fields.extend([1.0, 0.0, 7.0, 2.0, 0.0, 0.0, 5.0, 0.0, 0.0, 3.0, 0.0]);
	let command = encode_production_continuation_command(&command_fields).unwrap();
	assert_eq!(
		ContinuationCommandRequest::decode(&command).unwrap(),
		ContinuationCommandRequest {
			token,
			command: MixtureCommandRequest::SetMoles {
				handle: handle(7, 2),
				gas_id: 3,
				amount: ScalarValue(5.0),
			},
		}
	);
	let mut adjust_fields = token_fields.to_vec();
	adjust_fields.extend([7.0, 2.0, 3.0, -0.5]);
	let (actual_token, actual_handle, adjustments) = decode_continuation_adjust_multiple_request(
		&encode_production_continuation_adjust_multiple(&adjust_fields).unwrap(),
	)
	.unwrap();
	assert_eq!(actual_token, token);
	assert_eq!(actual_handle, handle(7, 2));
	assert_eq!(adjustments[0].delta, ScalarValue(-0.5));
	let mut resume_fields = token_fields.to_vec();
	resume_fields.push(5.0);
	assert_eq!(
		ContinuationResumeRequest::decode(
			&encode_production_continuation_resume(&resume_fields).unwrap()
		),
		Ok(ContinuationResumeRequest {
			token,
			reaction_result: 5,
		})
	);
	let mut invalid = token_fields;
	invalid[2] = 65_536.0;
	assert!(decode_production_continuation_token(&invalid).is_err());
}

#[test]
fn binary_identity_fields_use_exact_lowercase_hex() {
	assert_eq!(hex_lower(&[0x00, 0x09, 0x10, 0xab, 0xff]), "000910abff");
}

#[test]
fn diagnostic_allocation_rejects_non_finite_negative_and_oversized_values() {
	assert!(diagnostic_bytes_from_number(f32::NAN).is_err());
	assert!(diagnostic_bytes_from_number(-1.0).is_err());
	assert!(diagnostic_bytes_from_number(9.0 * 1024.0 * 1024.0 * 1024.0).is_err());
	assert_eq!(
		diagnostic_bytes_from_number(512.0 * 1024.0 * 1024.0).unwrap(),
		536_870_912
	);
}

#[test]
fn scalar_response_requires_the_exact_wire_width() {
	let response = 42.5_f64.to_le_bytes();
	assert_eq!(scalar_response_value(&response, 8).unwrap(), 42.5);
	assert!(scalar_response_value(&response, 0).is_err());
	assert!(scalar_response_value(&response, 7).is_err());
}

#[test]
fn callback_count_requires_a_bounded_integer() {
	assert_eq!(callback_count_from_number(65_536.0).unwrap(), 65_536);
	assert!(callback_count_from_number(65_537.0).is_err());
	assert!(callback_count_from_number(1.5).is_err());
	assert!(callback_count_from_number(-1.0).is_err());
	assert!(callback_count_from_number(f32::NAN).is_err());
}

#[cfg(not(windows))]
#[test]
fn system_auth_tokens_are_nonempty_and_fresh() {
	let first = super::session::system_auth_token().unwrap();
	let second = super::session::system_auth_token().unwrap();
	assert_ne!(first, [0; 32]);
	assert_ne!(second, [0; 32]);
	assert_ne!(first, second);
}
