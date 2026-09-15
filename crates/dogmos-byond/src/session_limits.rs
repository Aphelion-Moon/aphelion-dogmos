//! Shim session policy shared by production and diagnostic sessions.
//!
//! These limits bound the negotiated session and its requests; they are not wire
//! layout constants or the protocol codec's theoretical maximum capacities.

use std::time::Duration;

/// Entries allowed in each of the callback, pending-continuation and reaction-
/// transaction capacities. Each capacity is independent and intentionally equal.
pub(crate) const SESSION_PENDING_CAPACITY: u32 = 65_536;
/// Maximum control payload bytes negotiated by the shim, excluding frame headers.
pub(crate) const SESSION_CONTROL_PAYLOAD_BYTES: usize = 64 * 1024;
/// Request-worker timeout and total deadline for one chunked mixture-state upload.
pub(crate) const SESSION_REQUEST_TIMEOUT: Duration = Duration::from_secs(5);
