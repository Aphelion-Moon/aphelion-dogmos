//! Pure validated DM adapters for callbacks.

use crate::dm_codec::mixtures::{
	encode_production_mixture_adjust_multiple, encode_production_mixture_command,
};
use crate::dm_codec::{
	append_u32_words, append_u64_words, exact_u16, exact_u32, finite_indexed_byond_scalar,
	join_u32_words, join_u64_words, PRODUCTION_CALLBACK_EVENT_FIELDS,
	PRODUCTION_CALLBACK_HEADER_FIELDS, PRODUCTION_CONTINUATION_TOKEN_FIELDS,
};
use dogmos_protocol::{
	decode_adjust_multiple_request, encode_continuation_adjust_multiple_request,
	CallbackBatchHeader, CallbackEvent, CallbackScope, ContinuationCommandRequest,
	ContinuationResumeRequest, ContinuationToken, MixtureCommandRequest, CALLBACK_BATCH_HEADER_LEN,
	CALLBACK_EVENT_LEN,
};

/// Decodes protocol bytes into exact DM numeric fields for callback batch.
///
/// Preserves field order and little-endian word identity; invalid lengths, tags or
/// numeric values return a caller-legible error. This adapter performs no BYOND call.
pub fn decode_production_callback_batch(
	response: &[u8],
	requested_max: u32,
	requested_scope: CallbackScope,
	requested_transaction_id: u64,
) -> eyre::Result<Vec<f32>> {
	if response.len() < CALLBACK_BATCH_HEADER_LEN {
		return Err(eyre::eyre!(
			"Dogmos callback response was {} bytes, shorter than its header",
			response.len()
		));
	}
	let header = CallbackBatchHeader::decode(&response[..CALLBACK_BATCH_HEADER_LEN])?;
	if header.returned > requested_max {
		return Err(eyre::eyre!(
			"Dogmos callback response returned {} events after {} were requested",
			header.returned,
			requested_max
		));
	}
	let expected_len = CALLBACK_BATCH_HEADER_LEN + header.returned as usize * CALLBACK_EVENT_LEN;
	if response.len() != expected_len {
		return Err(eyre::eyre!(
			"Dogmos callback response was {} bytes, expected {expected_len}",
			response.len()
		));
	}
	let mut fields = Vec::with_capacity(
		PRODUCTION_CALLBACK_HEADER_FIELDS
			+ header.returned as usize * PRODUCTION_CALLBACK_EVENT_FIELDS,
	);
	for value in [
		header.returned,
		header.remaining,
		header.capacity,
		header.high_water,
	] {
		append_u32_words(&mut fields, value);
	}
	append_u64_words(&mut fields, header.rejected);
	let mut last_sequence: Option<u64> = None;
	for event_bytes in response[CALLBACK_BATCH_HEADER_LEN..]
		.as_chunks::<CALLBACK_EVENT_LEN>()
		.0
	{
		let event = CallbackEvent::decode(event_bytes)?;
		if event.scope != requested_scope || event.transaction_id != requested_transaction_id {
			return Err(eyre::eyre!(
				"Dogmos callback response returned the wrong scope or transaction"
			));
		}
		if let Some(sequence) = last_sequence {
			let expected = sequence.checked_add(1).ok_or_else(|| {
				eyre::eyre!("Dogmos callback sequence overflowed after {sequence}")
			})?;
			if event.scope_sequence != expected {
				return Err(eyre::eyre!(
					"Dogmos callback sequence is not contiguous at {}",
					event.scope_sequence
				));
			}
		}
		last_sequence = Some(event.scope_sequence);
		append_u64_words(&mut fields, event.scope_sequence);
		append_u64_words(&mut fields, event.transaction_id);
		fields.push(event.scope as u16 as f32);
		fields.push(event.kind as u16 as f32);
		fields.push(f32::from(event.flags));
		append_u32_words(&mut fields, event.subject.slot);
		append_u32_words(&mut fields, event.subject.generation);
		append_u32_words(&mut fields, event.target.slot);
		append_u32_words(&mut fields, event.target.generation);
		for (index, value) in event.values.into_iter().enumerate() {
			fields.push(finite_indexed_byond_scalar(
				value.0,
				"callback value",
				index,
			)?);
		}
		append_u32_words(&mut fields, event.aux);
		fields.push(f32::from(event.continuation.is_some()));
		append_continuation_token_fields(&mut fields, event.continuation);
	}
	Ok(fields)
}

/// Encodes validated DM numeric fields as protocol bytes for continuation command.
///
/// Preserves field order and little-endian word identity; invalid lengths, tags or
/// numeric values return a caller-legible error. This adapter performs no BYOND call.
pub fn encode_production_continuation_command(fields: &[f32]) -> eyre::Result<Vec<u8>> {
	if fields.len() != PRODUCTION_CONTINUATION_TOKEN_FIELDS + 11 {
		return Err(eyre::eyre!(
			"continuation command requires a 10-field token and 11 command fields"
		));
	}
	let token =
		decode_production_continuation_token(&fields[..PRODUCTION_CONTINUATION_TOKEN_FIELDS])?;
	let command = MixtureCommandRequest::decode(&encode_production_mixture_command(
		fields[PRODUCTION_CONTINUATION_TOKEN_FIELDS..]
			.try_into()
			.unwrap(),
	)?)?;
	Ok(ContinuationCommandRequest { token, command }
		.encode()?
		.to_vec())
}

/// Encodes validated DM numeric fields as protocol bytes for continuation adjust multiple.
///
/// Preserves field order and little-endian word identity; invalid lengths, tags or
/// numeric values return a caller-legible error. This adapter performs no BYOND call.
pub fn encode_production_continuation_adjust_multiple(fields: &[f32]) -> eyre::Result<Vec<u8>> {
	if fields.len() < PRODUCTION_CONTINUATION_TOKEN_FIELDS + 2 {
		return Err(eyre::eyre!(
			"continuation multi-adjust requires a 10-field token and mixture adjustments"
		));
	}
	let token =
		decode_production_continuation_token(&fields[..PRODUCTION_CONTINUATION_TOKEN_FIELDS])?;
	let nested =
		encode_production_mixture_adjust_multiple(&fields[PRODUCTION_CONTINUATION_TOKEN_FIELDS..])?;
	let (handle, adjustments) = decode_adjust_multiple_request(&nested)?;
	let mut output = Vec::new();
	encode_continuation_adjust_multiple_request(token, handle, &adjustments, &mut output)?;
	Ok(output)
}

/// Encodes validated DM numeric fields as protocol bytes for continuation resume.
///
/// Preserves field order and little-endian word identity; invalid lengths, tags or
/// numeric values return a caller-legible error. This adapter performs no BYOND call.
pub fn encode_production_continuation_resume(fields: &[f32]) -> eyre::Result<Vec<u8>> {
	if fields.len() != PRODUCTION_CONTINUATION_TOKEN_FIELDS + 1 {
		return Err(eyre::eyre!(
			"continuation resume requires a 10-field token and reaction result"
		));
	}
	let token =
		decode_production_continuation_token(&fields[..PRODUCTION_CONTINUATION_TOKEN_FIELDS])?;
	let reaction_result = exact_u32(
		fields[PRODUCTION_CONTINUATION_TOKEN_FIELDS],
		"continuation reaction result",
	)?;
	Ok(ContinuationResumeRequest {
		token,
		reaction_result,
	}
	.encode()?
	.to_vec())
}

/// Validates ten DM token fields and returns the exact typed continuation identity for continuation token.
///
/// Preserves field order and little-endian word identity; invalid lengths, tags or
/// numeric values return a caller-legible error. This adapter performs no BYOND call.
pub fn decode_production_continuation_token(fields: &[f32]) -> eyre::Result<ContinuationToken> {
	if fields.len() != PRODUCTION_CONTINUATION_TOKEN_FIELDS {
		return Err(eyre::eyre!(
			"continuation token requires exactly {PRODUCTION_CONTINUATION_TOKEN_FIELDS} fields"
		));
	}
	let labels = [
		"word 0", "word 1", "word 2", "word 3", "word 4", "word 5", "word 6", "word 7", "word 8",
		"word 9",
	];
	let mut words = [0_u16; PRODUCTION_CONTINUATION_TOKEN_FIELDS];
	for (index, value) in fields.iter().enumerate() {
		words[index] = exact_u16(*value, labels[index])
			.map_err(|error| eyre::eyre!("continuation token {error}"))?;
	}
	let token = ContinuationToken {
		world_generation: join_u32_words(words[0], words[1]),
		id: join_u64_words(words[2..6].try_into().unwrap()),
		deadline_ticks: join_u64_words(words[6..10].try_into().unwrap()),
	};
	token.encode()?;
	Ok(token)
}

pub(crate) fn append_continuation_token_fields(
	output: &mut Vec<f32>,
	token: Option<ContinuationToken>,
) {
	let token = token.unwrap_or(ContinuationToken {
		world_generation: 0,
		id: 0,
		deadline_ticks: 0,
	});
	append_u32_words(output, token.world_generation);
	append_u64_words(output, token.id);
	append_u64_words(output, token.deadline_ticks);
}
