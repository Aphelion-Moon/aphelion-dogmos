//! Main-thread service bindings for callbacks.

use crate::bindings::production_request_with_response;
use crate::bindings::values::{
	bounded_number_list, mixture_command_response_value, production_number_list,
};
use crate::dm_codec::callbacks::{
	decode_production_callback_batch, decode_production_continuation_token,
	encode_production_continuation_adjust_multiple, encode_production_continuation_command,
	encode_production_continuation_resume,
};
use crate::dm_codec::{
	exact_u16, join_u32_words, join_u64_words, PRODUCTION_CONTINUATION_TOKEN_FIELDS,
	PRODUCTION_MAX_CALLBACK_EVENTS, PRODUCTION_MAX_MIXTURE_ADJUSTMENTS,
};
use byondapi::prelude::ByondValue;
use dogmos_protocol::{
	CallbackBatchRequest, CallbackScope, MixtureCommandResponse, OperationKind,
	CALLBACK_BATCH_HEADER_LEN, CALLBACK_EVENT_LEN, MIXTURE_COMMAND_RESPONSE_LEN,
};

#[auxmacros::bind("/proc/dogmos_callback_drain")]
fn dogmos_callback_drain(fields: ByondValue) -> eyre::Result<ByondValue> {
	use crate::adapter_layout::callbacks::callback_request as fields_layout;

	let fields = bounded_number_list(fields, "callback drain", fields_layout::LEN)?;
	if fields.len() != fields_layout::LEN {
		return Err(eyre::eyre!(
			"callback drain requires scope, four transaction words, and two maximum-event words"
		));
	}
	let scope = CallbackScope::try_from(exact_u16(
		fields[fields_layout::SCOPE.offset],
		"callback scope",
	)?)?;
	let transaction_id = join_u64_words([
		exact_u16(
			fields[fields_layout::TRANSACTION.offset],
			"callback transaction word 0",
		)?,
		exact_u16(
			fields[fields_layout::TRANSACTION.offset + 1],
			"callback transaction word 1",
		)?,
		exact_u16(
			fields[fields_layout::TRANSACTION.offset + 2],
			"callback transaction word 2",
		)?,
		exact_u16(
			fields[fields_layout::TRANSACTION.offset + 3],
			"callback transaction word 3",
		)?,
	]);
	let max_events = join_u32_words(
		exact_u16(
			fields[fields_layout::MAX_EVENTS.offset],
			"callback maximum word 0",
		)?,
		exact_u16(
			fields[fields_layout::MAX_EVENTS.offset + 1],
			"callback maximum word 1",
		)?,
	);
	if max_events > PRODUCTION_MAX_CALLBACK_EVENTS {
		return Err(eyre::eyre!(
			"callback drain requested {max_events} events, maximum {PRODUCTION_MAX_CALLBACK_EVENTS}"
		));
	}
	let request = CallbackBatchRequest {
		max_events,
		scope,
		transaction_id,
	}
	.encode()?;
	let response_capacity = CALLBACK_BATCH_HEADER_LEN + max_events as usize * CALLBACK_EVENT_LEN;
	let fields = production_request_with_response(
		OperationKind::CallbackBatch,
		&request,
		response_capacity,
		|response| decode_production_callback_batch(response, max_events, scope, transaction_id),
	)?;
	production_number_list(&fields)
}

#[auxmacros::bind("/proc/dogmos_continuation_command")]
fn dogmos_continuation_command(fields: ByondValue) -> eyre::Result<ByondValue> {
	let fields = bounded_number_list(
		fields,
		"continuation command",
		crate::adapter_layout::callbacks::continuation_command::LEN,
	)?;
	let request = encode_production_continuation_command(&fields)?;
	let response = production_request_with_response(
		OperationKind::ContinuationCommand,
		&request,
		MIXTURE_COMMAND_RESPONSE_LEN,
		|response| Ok(MixtureCommandResponse::decode(response)?),
	)?;
	mixture_command_response_value(response)
}

#[auxmacros::bind("/proc/dogmos_continuation_adjust_multiple")]
fn dogmos_continuation_adjust_multiple(fields: ByondValue) -> eyre::Result<ByondValue> {
	let fields = bounded_number_list(
		fields,
		"continuation multi-adjust",
		PRODUCTION_CONTINUATION_TOKEN_FIELDS
			+ crate::adapter_layout::mixtures::handle::LEN
			+ PRODUCTION_MAX_MIXTURE_ADJUSTMENTS * crate::adapter_layout::mixtures::adjustment::LEN,
	)?;
	let request = encode_production_continuation_adjust_multiple(&fields)?;
	let response = production_request_with_response(
		OperationKind::ContinuationAdjustMultiple,
		&request,
		MIXTURE_COMMAND_RESPONSE_LEN,
		|response| Ok(MixtureCommandResponse::decode(response)?),
	)?;
	mixture_command_response_value(response)
}

#[auxmacros::bind("/proc/dogmos_continuation_resume")]
fn dogmos_continuation_resume(fields: ByondValue) -> eyre::Result<ByondValue> {
	let fields = bounded_number_list(
		fields,
		"continuation resume",
		crate::adapter_layout::callbacks::continuation_resume::LEN,
	)?;
	let request = encode_production_continuation_resume(&fields)?;
	let response = production_request_with_response(
		OperationKind::ContinuationResume,
		&request,
		MIXTURE_COMMAND_RESPONSE_LEN,
		|response| Ok(MixtureCommandResponse::decode(response)?),
	)?;
	mixture_command_response_value(response)
}

#[auxmacros::bind("/proc/dogmos_continuation_cancel")]
fn dogmos_continuation_cancel(fields: ByondValue) -> eyre::Result<ByondValue> {
	let fields = bounded_number_list(
		fields,
		"continuation cancel token",
		PRODUCTION_CONTINUATION_TOKEN_FIELDS,
	)?;
	let token = decode_production_continuation_token(&fields)?;
	production_request_with_response(
		OperationKind::ContinuationCancel,
		&token.encode()?,
		0,
		|response| {
			if response.is_empty() {
				Ok(())
			} else {
				Err(eyre::eyre!(
					"Dogmos continuation cancel response was not empty"
				))
			}
		},
	)?;
	Ok(true.into())
}
