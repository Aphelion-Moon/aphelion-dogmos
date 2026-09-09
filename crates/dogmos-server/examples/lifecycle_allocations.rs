#[cfg(not(test))]
#[path = "../src/test_allocations.rs"]
mod allocation_measurements;
#[allow(dead_code)]
#[path = "../src/state.rs"]
mod state;
#[cfg(test)]
use state::test_allocations as allocation_measurements;

use dogmos_protocol::{
	CallbackEvent, CallbackScope, GasMetadataRegistration, LifecycleAction, LifecycleMutation,
	MixtureCommandRequest, MixtureCommandResponse, ReactionMetadataRegistration, ScalarValue,
	TurfLifecycleMutation, WireGasFireRole, WireHandle, WireReactionExecution,
	CALLBACK_BATCH_HEADER_LEN, CALLBACK_EVENT_LEN,
};
use state::ServiceState;
use std::{error::Error, fmt::Write as _, time::Instant};

fn handle(slot: u32, generation: u32) -> WireHandle {
	WireHandle { slot, generation }
}

fn fixture(count: u32) -> (ServiceState, Vec<u64>) {
	let mut state =
		ServiceState::new_for_world(16 * 1024 * 1024, count + 8, count + 8, count + 8, 1);
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
		.install_reactions(vec![ReactionMetadataRegistration {
			id: 0,
			key: "dm".into(),
			priority: ScalarValue(1.0),
			minimum_temperature: None,
			maximum_temperature: None,
			minimum_energy: None,
			minimum_fire_reagents: None,
			gas_requirements: Vec::new(),
			execution: WireReactionExecution::Dm,
		}])
		.unwrap();
	state
		.apply_lifecycle(&[0, 1].map(|slot| LifecycleMutation {
			action: LifecycleAction::Register,
			handle: handle(slot, 1),
		}))
		.unwrap();
	state
		.apply_turf_lifecycle(&[TurfLifecycleMutation {
			action: LifecycleAction::Register,
			turf: handle(0, 1),
			mixture: Some(handle(0, 1)),
		}])
		.unwrap();
	let mut transactions = Vec::new();
	for _ in 0..count {
		let response = state
			.apply_mixture_command(MixtureCommandRequest::React {
				handle: handle(0, 1),
				target: handle(41, 9),
				reaction_profile_threshold_ms: None,
			})
			.unwrap();
		let MixtureCommandResponse::ReactionProgress {
			transaction_id,
			pending: true,
			..
		} = response
		else {
			panic!("expected pending reaction");
		};
		transactions.push(transaction_id);
	}
	(state, transactions)
}

fn main() -> Result<(), Box<dyn Error>> {
	let mut arguments = std::env::args_os().skip(1);
	if arguments.next().as_deref() != Some(std::ffi::OsStr::new("--output")) {
		return Err("usage: lifecycle_allocations --output <csv>".into());
	}
	let path = arguments.next().ok_or("missing output path")?;
	if arguments.next().is_some() {
		return Err("unexpected trailing argument".into());
	}
	let mut csv = String::from(
		"case,pending,round,operations,allocations,allocated_bytes,elapsed_ns,transcript_hash\n",
	);
	for count in [64, 512, 2048] {
		for case in ["mixture_noop", "turf_noop", "unrelated_replacement"] {
			for round in 1..=3 {
				let (mut state, transactions) = fixture(count);
				let register = LifecycleMutation {
					action: LifecycleAction::Register,
					handle: handle(0, 1),
				};
				let turf_register = TurfLifecycleMutation {
					action: LifecycleAction::Register,
					turf: handle(0, 1),
					mixture: Some(handle(0, 1)),
				};
				state.apply_lifecycle(&[register])?;
				state.apply_turf_lifecycle(&[turf_register])?;
				let before = state.snapshot(handle(0, 1))?;
				let (elapsed, allocations) = allocation_measurements::measure(|| {
					let start = Instant::now();
					for generation in 2..102 {
						match case {
							"mixture_noop" => {
								state.apply_lifecycle(&[register]).unwrap();
							}
							"turf_noop" => {
								state.apply_turf_lifecycle(&[turf_register]).unwrap();
							}
							_ => {
								state
									.apply_lifecycle(&[LifecycleMutation {
										action: LifecycleAction::Register,
										handle: handle(1, generation),
									}])
									.unwrap();
							}
						}
					}
					start.elapsed().as_nanos()
				});
				assert_eq!(state.snapshot(handle(0, 1))?, before);
				assert_eq!(state.pending_continuation_count(), count);
				let mut hash = 0xcbf2_9ce4_8422_2325_u64;
				let mut output = [0; CALLBACK_BATCH_HEADER_LEN + CALLBACK_EVENT_LEN];
				for transaction in transactions {
					assert_eq!(
						state.drain_scoped_callbacks(
							CallbackScope::Reaction,
							transaction,
							1,
							&mut output
						)?,
						output.len()
					);
					let mut event = CallbackEvent::decode(&output[CALLBACK_BATCH_HEADER_LEN..])?;
					let token = event.continuation.unwrap();
					// Absolute session deadlines depend on setup time; preserve all other token/event fields.
					event.continuation.as_mut().unwrap().deadline_ticks = 1;
					for byte in event.encode()? {
						hash ^= u64::from(byte);
						hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
					}
					state.cancel_continuation_at(token, token.deadline_ticks - 1)?;
				}
				assert_eq!(state.pending_continuation_count(), 0);
				writeln!(
					csv,
					"{case},{count},{round},100,{},{},{elapsed},{hash}",
					allocations.calls, allocations.bytes
				)?;
			}
		}
	}
	std::fs::write(path, csv)?;
	Ok(())
}
