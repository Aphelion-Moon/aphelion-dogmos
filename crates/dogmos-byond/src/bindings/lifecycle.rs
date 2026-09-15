//! Version/identity and service lifecycle bindings. The session owns native resources.

use crate::bindings::SERVICE_SESSION;
use crate::dm_codec::{hex_lower, split_u32_words};
use crate::session::start_service_session;
use byondapi::prelude::ByondValue;
use dogmos_protocol::{DOGMOS_ABI_VERSION, DOGMOS_PROTOCOL_VERSION};

#[auxmacros::bind("/proc/dogmos_abi_version")]
fn dogmos_abi_version() -> eyre::Result<ByondValue> {
	Ok((DOGMOS_ABI_VERSION as f32).into())
}

#[auxmacros::bind("/proc/dogmos_protocol_version")]
fn dogmos_protocol_version() -> eyre::Result<ByondValue> {
	Ok((DOGMOS_PROTOCOL_VERSION as f32).into())
}

#[auxmacros::bind("/proc/dogmos_source_revision")]
fn dogmos_source_revision() -> eyre::Result<ByondValue> {
	let metadata = dogmos_identity::BuildMetadata::from_compile_environment()?;
	Ok(hex_lower(&metadata.source_revision).try_into()?)
}

#[auxmacros::bind("/proc/dogmos_feature_fingerprint")]
fn dogmos_feature_fingerprint() -> eyre::Result<ByondValue> {
	let metadata = dogmos_identity::BuildMetadata::from_compile_environment()?;
	Ok(hex_lower(&metadata.feature_fingerprint).try_into()?)
}

#[auxmacros::bind("/proc/dogmos_service_start")]
fn dogmos_service_start(service_path: ByondValue) -> eyre::Result<ByondValue> {
	let service_path = service_path.get_string()?;
	let mut session = SERVICE_SESSION
		.lock()
		.map_err(|_| eyre::eyre!("Dogmos production service session lock is poisoned"))?;
	if session.is_some() {
		return Err(eyre::eyre!(
			"Dogmos production service session is already running"
		));
	}
	*session = Some(start_service_session(&service_path)?);
	Ok(true.into())
}

#[auxmacros::bind("/proc/dogmos_service_health")]
fn dogmos_service_health() -> eyre::Result<ByondValue> {
	let mut session = SERVICE_SESSION
		.lock()
		.map_err(|_| eyre::eyre!("Dogmos production service session lock is poisoned"))?;
	let healthy = match session.as_mut() {
		Some(session) => session.is_healthy()?,
		None => false,
	};
	Ok(healthy.into())
}

#[auxmacros::bind("/proc/dogmos_service_pid")]
fn dogmos_service_pid() -> eyre::Result<ByondValue> {
	let session = SERVICE_SESSION
		.lock()
		.map_err(|_| eyre::eyre!("Dogmos production service session lock is poisoned"))?;
	let session = session
		.as_ref()
		.ok_or_else(|| eyre::eyre!("Dogmos production service session is not running"))?;
	Ok((session.client.peer().process_id as f32).into())
}

#[auxmacros::bind("/proc/dogmos_service_world_generation")]
fn dogmos_service_world_generation() -> eyre::Result<ByondValue> {
	let session = SERVICE_SESSION
		.lock()
		.map_err(|_| eyre::eyre!("Dogmos production service session lock is poisoned"))?;
	let session = session
		.as_ref()
		.ok_or_else(|| eyre::eyre!("Dogmos production service session is not running"))?;
	let mut output = ByondValue::new_list()?;
	for word in split_u32_words(session.client.peer().world_generation) {
		output.push_list(f32::from(word).into())?;
	}
	Ok(output)
}

#[auxmacros::bind("/proc/dogmos_service_shutdown")]
fn dogmos_service_shutdown() -> eyre::Result<ByondValue> {
	let mut session = SERVICE_SESSION
		.lock()
		.map_err(|_| eyre::eyre!("Dogmos production service session lock is poisoned"))?;
	let Some(mut active) = session.take() else {
		return Ok(false.into());
	};
	active.shutdown()?;
	Ok(true.into())
}
