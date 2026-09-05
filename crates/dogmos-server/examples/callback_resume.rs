#[allow(dead_code)]
#[path = "../src/state.rs"]
mod state;

use dogmos_protocol::{
	CallbackBatchHeader, CallbackEvent, CallbackEventKind, CallbackScope, GasMetadataRegistration,
	LifecycleAction, LifecycleMutation, MixtureCommandRequest, ReactionMetadataRegistration,
	ScalarValue, SimulationStage, TurfLifecycleMutation, WireGasFireRole, WireGasRequirement,
	WireHandle, WireReactionExecution, CALLBACK_BATCH_HEADER_LEN, CALLBACK_EVENT_LEN,
};
use state::ServiceState;
use std::time::Instant;

fn fixture(reactions: u32) -> ServiceState {
	let mut state = ServiceState::new_for_world(16 * 1024 * 1024, 32768, 16, 16, 1);
	state
		.install_gases(vec![GasMetadataRegistration {
			id: 0,
			key: "o2".into(),
			name: "Oxygen".into(),
			flags: 0,
			specific_heat: ScalarValue(20.0),
			fusion_power: ScalarValue(0.0),
			moles_visible: None,
			enthalpy: ScalarValue(0.0),
			fire_radiation_released: ScalarValue(0.0),
			fire_role: WireGasFireRole::None,
			fire_products: None,
		}])
		.unwrap();
	state
		.install_reactions(
			(0..reactions)
				.map(|id| ReactionMetadataRegistration {
					id,
					key: format!("dm_{id}"),
					priority: ScalarValue(10.0 - id as f64),
					minimum_temperature: None,
					maximum_temperature: None,
					minimum_energy: None,
					minimum_fire_reagents: None,
					gas_requirements: vec![WireGasRequirement {
						gas_id: 0,
						minimum_moles: ScalarValue(1.0),
					}],
					execution: WireReactionExecution::Dm,
				})
				.collect(),
		)
		.unwrap();
	let handle = WireHandle {
		slot: 0,
		generation: 1,
	};
	state
		.apply_lifecycle(&[LifecycleMutation {
			action: LifecycleAction::Register,
			handle,
		}])
		.unwrap();
	state
		.apply_mixture_command(MixtureCommandRequest::SetMoles {
			handle,
			gas_id: 0,
			amount: ScalarValue(10.0),
		})
		.unwrap();
	state
		.apply_turf_lifecycle(&[TurfLifecycleMutation {
			action: LifecycleAction::Register,
			turf: handle,
			mixture: Some(handle),
		}])
		.unwrap();
	state.begin_frontier(1, 1).unwrap();
	state.append_frontier(1, 0, &[handle]).unwrap();
	state.commit_frontier(1).unwrap();
	let result = state
		.process_stage_chunk_cancellable(SimulationStage::ProcessReactions, 1, 1, 16, 0.5, || false)
		.unwrap();
	assert!(!result.pending);
	state
}

fn drain_one(state: &mut ServiceState) -> (CallbackBatchHeader, CallbackEvent) {
	let mut output = [0_u8; CALLBACK_BATCH_HEADER_LEN + CALLBACK_EVENT_LEN];
	state
		.drain_scoped_callbacks(CallbackScope::General, 0, 1, &mut output)
		.unwrap();
	let header = CallbackBatchHeader::decode(&output[..CALLBACK_BATCH_HEADER_LEN]).unwrap();
	let event = CallbackEvent::decode(&output[CALLBACK_BATCH_HEADER_LEN..]).unwrap();
	(header, event)
}

fn main() {
	let mut chain = fixture(2);
	let (header, first) = drain_one(&mut chain);
	assert_eq!(first.kind, CallbackEventKind::RunDmReaction);
	assert_eq!(header.remaining, 0);
	chain
		.resume_continuation_with_result(first.continuation.unwrap(), 0)
		.unwrap();
	let (_, second) = drain_one(&mut chain);
	assert_eq!(second.kind, CallbackEventKind::RunDmReaction);
	assert_eq!(second.aux, 1);
	chain
		.resume_continuation_with_result(second.continuation.unwrap(), 0)
		.unwrap();
	println!("chain: final-batch remaining=0, resume enqueued the second DM callback");
	for trial in 1..=3 {
		for depth in [0, 1024, 16384] {
			let mut times = Vec::new();
			for _ in 0..101 {
				let mut state = fixture(1);
				let (_, event) = drain_one(&mut state);
				state.enqueue_diagnostic_callbacks(depth).unwrap();
				let started = Instant::now();
				state
					.resume_continuation_with_result(event.continuation.unwrap(), 0)
					.unwrap();
				times.push(started.elapsed().as_nanos());
				assert_eq!(state.pending_continuation_count(), 0);
				let mut output = [0_u8; CALLBACK_BATCH_HEADER_LEN + CALLBACK_EVENT_LEN];
				state
					.drain_scoped_callbacks(CallbackScope::General, 0, 1, &mut output)
					.unwrap();
				let header =
					CallbackBatchHeader::decode(&output[..CALLBACK_BATCH_HEADER_LEN]).unwrap();
				assert_eq!(header.remaining, depth.saturating_sub(1));
			}
			times.sort_unstable();
			println!(
				"trial={trial} depth={depth} samples=101 p50_ns={} p95_ns={} max_ns={}",
				times[50], times[95], times[100]
			);
		}
	}
}
