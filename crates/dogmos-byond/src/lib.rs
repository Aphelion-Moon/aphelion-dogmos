#![deny(unsafe_op_in_unsafe_fn)]

//! Thin BYOND boundary: bindings own main-thread/session access; codecs own validation.

mod binding_generation;
mod bindings;
mod client;
#[cfg(feature = "diagnostic-bindings")]
mod diagnostics;
mod dm_codec;
mod ffi;
mod metrics;
mod process_metrics_layout;
mod session;
mod session_limits;
/// Fixed-size stage-job adapters retained as a public Rust compatibility API.
pub mod stage_jobs;

pub use binding_generation::generate_bindings_file;
pub use client::{BoundedDogmosClient, ClientError, DogmosClient};
pub use dm_codec::callbacks::{
	decode_production_callback_batch, decode_production_continuation_token,
	encode_production_continuation_adjust_multiple, encode_production_continuation_command,
	encode_production_continuation_resume,
};
pub use dm_codec::metadata::{encode_production_gas_metadata, encode_production_reaction_metadata};
pub use dm_codec::mixtures::{
	decode_production_mixture_snapshot, decode_production_mixture_snapshot_batch,
	decode_production_pipenet_reconcile, encode_production_mixture_adjust_multiple,
	encode_production_mixture_command, encode_production_mixture_lifecycle_batch,
	encode_production_mixture_snapshot_batch, encode_production_mixture_state_batch,
	encode_production_pipenet_reconcile,
};
pub use dm_codec::stages::{
	decode_production_simulation_stage, encode_production_frontier_append,
	encode_production_frontier_begin, encode_production_frontier_mutate,
	encode_production_simulation_stage,
};
pub use dm_codec::topology::{
	decode_production_turf_heat_snapshot, encode_production_turf_adjacency_batch,
	encode_production_turf_heat_adjacency_batch, encode_production_turf_heat_batch,
	encode_production_turf_lifecycle_batch,
};
pub use metrics::{decode_production_service_telemetry, encode_production_process_metrics};

#[cfg(test)]
mod tests;
