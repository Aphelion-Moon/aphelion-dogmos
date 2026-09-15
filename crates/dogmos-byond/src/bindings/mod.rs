//! Main-thread BYOND entry points and the single production session admission boundary.

mod callbacks;
mod lifecycle;
mod metadata;
mod mixtures;
mod observations;
mod stages;
mod topology;
mod values;

use crate::dm_codec::decode_counted_response;
use crate::session::ServiceSession;
use byondapi::prelude::ByondValue;
use dogmos_protocol::OperationKind;
use std::sync::Mutex;

pub(crate) static SERVICE_SESSION: Mutex<Option<ServiceSession>> = Mutex::new(None);

pub(crate) fn production_counted_request(
	operation: OperationKind,
	payload: &[u8],
	label: &str,
) -> eyre::Result<ByondValue> {
	let count = production_request_with_response(operation, payload, 4, |response| {
		decode_counted_response(response, label)
	})?;
	Ok((count as f32).into())
}

pub(crate) fn production_request_with_response<T>(
	operation: OperationKind,
	payload: &[u8],
	response_capacity: usize,
	decode: impl FnOnce(&[u8]) -> eyre::Result<T>,
) -> eyre::Result<T> {
	let mut session = SERVICE_SESSION
		.lock()
		.map_err(|_| eyre::eyre!("Dogmos production service session lock is poisoned"))?;
	let session = session
		.as_mut()
		.ok_or_else(|| eyre::eyre!("Dogmos production service session is not running"))?;
	session.request_with_response(operation, payload, response_capacity, decode)
}
