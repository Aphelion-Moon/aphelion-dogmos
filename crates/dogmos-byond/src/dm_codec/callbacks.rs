//! Pure validated DM adapters for callbacks.

use crate::dm_codec::mixtures::{
	encode_production_mixture_adjust_multiple, encode_production_mixture_command,
};
use crate::dm_codec::{
	exact_u16, exact_u32, finite_indexed_byond_scalar, join_u32_words, join_u64_words,
	PRODUCTION_CALLBACK_EVENT_FIELDS, PRODUCTION_CALLBACK_HEADER_FIELDS,
	PRODUCTION_CONTINUATION_TOKEN_FIELDS,
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
	use crate::adapter_layout::callbacks::{
		callback_event as event_layout, callback_header as header_layout,
	};
	let mut header_fields = [0.0; header_layout::LEN];
	header_layout::RETURNED.write_u32(&mut header_fields, header.returned);
	header_layout::REMAINING.write_u32(&mut header_fields, header.remaining);
	header_layout::CAPACITY.write_u32(&mut header_fields, header.capacity);
	header_layout::HIGH_WATER.write_u32(&mut header_fields, header.high_water);
	header_layout::REJECTED.write_u64(&mut header_fields, header.rejected);
	fields.extend(header_fields);
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
		let mut record = [0.0; event_layout::LEN];
		event_layout::SEQUENCE.write_u64(&mut record, event.scope_sequence);
		event_layout::TRANSACTION.write_u64(&mut record, event.transaction_id);
		record[event_layout::SCOPE.offset] = event.scope as u16 as f32;
		record[event_layout::KIND.offset] = event.kind as u16 as f32;
		record[event_layout::FLAGS.offset] = f32::from(event.flags);
		event_layout::SUBJECT_SLOT.write_u32(&mut record, event.subject.slot);
		event_layout::SUBJECT_GENERATION.write_u32(&mut record, event.subject.generation);
		event_layout::TARGET_SLOT.write_u32(&mut record, event.target.slot);
		event_layout::TARGET_GENERATION.write_u32(&mut record, event.target.generation);
		for (index, value) in event.values.into_iter().enumerate() {
			record[event_layout::VALUES.offset + index] =
				finite_indexed_byond_scalar(value.0, "callback value", index)?;
		}
		event_layout::AUX.write_u32(&mut record, event.aux);
		record[event_layout::TOKEN_PRESENT.offset] = f32::from(event.continuation.is_some());
		record[event_layout::TOKEN.range()]
			.copy_from_slice(&continuation_token_fields(event.continuation));
		fields.extend(record);
	}
	Ok(fields)
}

/// Encodes validated DM numeric fields as protocol bytes for continuation command.
///
/// Preserves field order and little-endian word identity; invalid lengths, tags or
/// numeric values return a caller-legible error. This adapter performs no BYOND call.
pub fn encode_production_continuation_command(fields: &[f32]) -> eyre::Result<Vec<u8>> {
	use crate::adapter_layout::callbacks::continuation_command as layout;
	if fields.len() != layout::LEN {
		return Err(eyre::eyre!(
			"continuation command requires a 10-field token and 11 command fields"
		));
	}
	let token = decode_production_continuation_token(&fields[layout::TOKEN.range()])?;
	let command = MixtureCommandRequest::decode(&encode_production_mixture_command(
		fields[layout::COMMAND.range()].try_into().unwrap(),
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
	if fields.len()
		< PRODUCTION_CONTINUATION_TOKEN_FIELDS + crate::adapter_layout::mixtures::handle::LEN
	{
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
	use crate::adapter_layout::callbacks::continuation_resume as layout;
	if fields.len() != layout::LEN {
		return Err(eyre::eyre!(
			"continuation resume requires a 10-field token and reaction result"
		));
	}
	let token = decode_production_continuation_token(&fields[layout::TOKEN.range()])?;
	let reaction_result = exact_u32(
		fields[layout::REACTION_RESULT.offset],
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
	use crate::adapter_layout::callbacks::continuation_token as words_layout;

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
		world_generation: join_u32_words(
			words[words_layout::WORLD_GENERATION.offset],
			words[words_layout::WORLD_GENERATION.offset + 1],
		),
		id: join_u64_words(words[words_layout::ID.range()].try_into().unwrap()),
		deadline_ticks: join_u64_words(words[words_layout::DEADLINE.range()].try_into().unwrap()),
	};
	token.encode()?;
	Ok(token)
}

fn continuation_token_fields(
	token: Option<ContinuationToken>,
) -> [f32; crate::adapter_layout::callbacks::continuation_token::LEN] {
	use crate::adapter_layout::callbacks::continuation_token as layout;
	let token = token.unwrap_or(ContinuationToken {
		world_generation: 0,
		id: 0,
		deadline_ticks: 0,
	});
	let mut fields = [0.0; layout::LEN];
	layout::WORLD_GENERATION.write_u32(&mut fields, token.world_generation);
	layout::ID.write_u64(&mut fields, token.id);
	layout::DEADLINE.write_u64(&mut fields, token.deadline_ticks);
	fields
}
