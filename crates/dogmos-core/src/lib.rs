pub mod frontier;
pub mod metadata;
pub mod numerics;
mod paged_vec;
pub mod reactions;
mod slot_index;
pub mod stage_cursor;
pub mod stage_job;
pub mod topology;
mod transaction;
pub mod world;

pub use numerics::diffusion::MixtureHandle;

pub const MAX_GAS_SLOTS: usize = 32;
