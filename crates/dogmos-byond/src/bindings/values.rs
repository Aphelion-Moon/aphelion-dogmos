//! Bounded BYOND list conversion and typed response presentation on the calling thread.

use crate::dm_codec::checked_declared_length;
use byondapi::prelude::ByondValue;
use dogmos_protocol::MixtureCommandResponse;

pub(crate) fn production_number_list(fields: &[f32]) -> eyre::Result<ByondValue> {
	thread_local! { static VALUES: std::cell::RefCell<Vec<ByondValue>> = const { std::cell::RefCell::new(Vec::new()) }; }
	VALUES.with(|storage| {
		let mut values = storage
			.try_borrow_mut()
			.map_err(|_| eyre::eyre!("reentrant numeric list conversion"))?;
		values.clear();
		values.extend(fields.iter().copied().map(ByondValue::from));
		let result = ByondValue::new_list().and_then(|output| {
			output.write_list(&values)?;
			Ok(output)
		});
		values.clear();
		result.map_err(Into::into)
	})
}

pub(crate) fn bounded_number_list(
	value: ByondValue,
	field: &str,
	maximum_values: usize,
) -> eyre::Result<Vec<f32>> {
	if !value.is_list() {
		return Err(eyre::eyre!("{field} must be a BYOND list"));
	}
	let declared_length = checked_declared_length(value.builtin_length()?.get_number()?, field)?;
	if declared_length > maximum_values {
		return Err(eyre::eyre!(
			"{field} contains {declared_length} values, maximum {maximum_values}"
		));
	}
	let values = value
		.values()?
		.map(|entry| entry.get_number().map_err(Into::into))
		.collect::<eyre::Result<Vec<_>>>()?;
	if values.len() != declared_length {
		return Err(eyre::eyre!("{field} changed length while being decoded"));
	}
	Ok(values)
}

pub(crate) fn bounded_string_list(
	value: ByondValue,
	field: &str,
	maximum_values: usize,
) -> eyre::Result<Vec<String>> {
	if !value.is_list() {
		return Err(eyre::eyre!("{field} must be a BYOND list"));
	}
	let declared_length = checked_declared_length(value.builtin_length()?.get_number()?, field)?;
	if declared_length > maximum_values {
		return Err(eyre::eyre!(
			"{field} contains {declared_length} values, maximum {maximum_values}"
		));
	}
	let values = value
		.values()?
		.map(|entry| entry.get_string().map_err(Into::into))
		.collect::<eyre::Result<Vec<_>>>()?;
	if values.len() != declared_length {
		return Err(eyre::eyre!("{field} changed length while being decoded"));
	}
	Ok(values)
}

pub(crate) fn mixture_command_response_value(
	response: MixtureCommandResponse,
) -> eyre::Result<ByondValue> {
	let (kind, first, second, third, transaction_id) = match response {
		MixtureCommandResponse::Applied { updated } => (1.0, updated as f32, 0.0, 0.0, None),
		MixtureCommandResponse::Scalar(value) => (2.0, value.0 as f32, 0.0, 0.0, None),
		MixtureCommandResponse::Scalars(values) => {
			(3.0, values[0].0 as f32, values[1].0 as f32, 0.0, None)
		}
		MixtureCommandResponse::Boolean(value) => (4.0, f32::from(value), 0.0, 0.0, None),
		MixtureCommandResponse::ReactionProgress {
			flags,
			work_items,
			pending,
			transaction_id,
		} => (
			5.0,
			flags as f32,
			work_items as f32,
			f32::from(pending),
			Some(transaction_id),
		),
	};
	use crate::adapter_layout::mixtures::{
		mixture_response as ordinary, reaction_response as reaction,
	};
	let mut fields = [0.0; reaction::LEN];
	let length = if let Some(transaction_id) = transaction_id {
		fields[reaction::KIND.offset] = kind;
		fields[reaction::FLAGS.offset] = first;
		fields[reaction::WORK_ITEMS.offset] = second;
		fields[reaction::PENDING.offset] = third;
		reaction::TRANSACTION.write_u64(&mut fields, transaction_id);
		reaction::LEN
	} else {
		fields[ordinary::KIND.offset] = kind;
		fields[ordinary::FIRST.offset] = first;
		fields[ordinary::SECOND.offset] = second;
		fields[ordinary::THIRD.offset] = third;
		ordinary::LEN
	};
	let mut output = ByondValue::new_list()?;
	for field in &fields[..length] {
		output.push_list((*field).into())?;
	}
	Ok(output)
}
