//! Main-thread service bindings for metadata.

use crate::bindings::production_counted_request;
use crate::bindings::values::{bounded_number_list, bounded_string_list};
use crate::dm_codec::metadata::{
	encode_production_gas_metadata, encode_production_reaction_metadata,
};
use crate::dm_codec::{
	PRODUCTION_GAS_METADATA_FIELDS, PRODUCTION_GAS_PRODUCT_FIELDS,
	PRODUCTION_MAX_REACTION_METADATA, PRODUCTION_REACTION_METADATA_FIELDS,
	PRODUCTION_REACTION_REQUIREMENT_FIELDS,
};
use byondapi::prelude::ByondValue;
use dogmos_protocol::{OperationKind, MAX_GAS_SLOTS};

#[auxmacros::bind("/proc/dogmos_gas_metadata_install")]
fn dogmos_gas_metadata_install(
	numeric_records: ByondValue,
	keys: ByondValue,
	names: ByondValue,
	product_records: ByondValue,
) -> eyre::Result<ByondValue> {
	let numeric_records = bounded_number_list(
		numeric_records,
		"gas metadata numeric records",
		MAX_GAS_SLOTS * PRODUCTION_GAS_METADATA_FIELDS,
	)?;
	let record_count = numeric_records.len() / PRODUCTION_GAS_METADATA_FIELDS;
	let keys = bounded_string_list(keys, "gas metadata keys", MAX_GAS_SLOTS)?;
	let names = bounded_string_list(names, "gas metadata names", MAX_GAS_SLOTS)?;
	let product_records = bounded_number_list(
		product_records,
		"gas metadata product records",
		MAX_GAS_SLOTS * MAX_GAS_SLOTS * PRODUCTION_GAS_PRODUCT_FIELDS,
	)?;
	if keys.len() != record_count || names.len() != record_count {
		return Err(eyre::eyre!(
			"gas metadata numeric, key, and name record counts must match"
		));
	}
	let request =
		encode_production_gas_metadata(&numeric_records, &keys, &names, &product_records)?;
	production_counted_request(OperationKind::GasMetadataInstall, &request, "gas metadata")
}

#[auxmacros::bind("/proc/dogmos_reaction_metadata_install")]
fn dogmos_reaction_metadata_install(
	numeric_records: ByondValue,
	keys: ByondValue,
	requirement_records: ByondValue,
) -> eyre::Result<ByondValue> {
	let numeric_records = bounded_number_list(
		numeric_records,
		"reaction metadata numeric records",
		PRODUCTION_MAX_REACTION_METADATA * PRODUCTION_REACTION_METADATA_FIELDS,
	)?;
	let record_count = numeric_records.len() / PRODUCTION_REACTION_METADATA_FIELDS;
	let keys = bounded_string_list(
		keys,
		"reaction metadata keys",
		PRODUCTION_MAX_REACTION_METADATA,
	)?;
	let requirement_records = bounded_number_list(
		requirement_records,
		"reaction metadata requirement records",
		PRODUCTION_MAX_REACTION_METADATA * MAX_GAS_SLOTS * PRODUCTION_REACTION_REQUIREMENT_FIELDS,
	)?;
	if keys.len() != record_count {
		return Err(eyre::eyre!(
			"reaction metadata numeric and key record counts must match"
		));
	}
	let request =
		encode_production_reaction_metadata(&numeric_records, &keys, &requirement_records)?;
	production_counted_request(
		OperationKind::ReactionMetadataInstall,
		&request,
		"reaction metadata",
	)
}
