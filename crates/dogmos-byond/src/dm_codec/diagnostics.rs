//! Pure validated DM adapters for diagnostics.

use crate::session_limits::SESSION_PENDING_CAPACITY;

#[cfg(any(feature = "diagnostic-bindings", test))]
pub(crate) fn diagnostic_bytes_from_number(bytes: f32) -> eyre::Result<u64> {
	if !bytes.is_finite() || bytes < 0.0 || bytes > 8.0 * 1024.0 * 1024.0 * 1024.0 {
		return Err(eyre::eyre!(
			"diagnostic bytes are outside the supported range"
		));
	}
	Ok(bytes as u64)
}

#[cfg(any(feature = "diagnostic-bindings", test))]
pub(crate) fn callback_count_from_number(count: f32) -> eyre::Result<u32> {
	if !count.is_finite()
		|| count < 0.0
		|| count > SESSION_PENDING_CAPACITY as f32
		|| count.fract() != 0.0
	{
		return Err(eyre::eyre!(
			"callback count is outside the supported integer range"
		));
	}
	Ok(count as u32)
}

#[cfg(any(feature = "diagnostic-bindings", test))]
pub(crate) fn scalar_response_value(response: &[u8], response_len: usize) -> eyre::Result<f32> {
	if response_len != response.len() {
		return Err(eyre::eyre!(
			"Dogmos scalar response was {response_len} bytes, expected {}",
			response.len()
		));
	}
	Ok(f64::from_le_bytes(response.try_into().unwrap()) as f32)
}
