//! Pure validated DM adapters for metadata.

use crate::dm_codec::{
	exact_bool, exact_u16, exact_u32, fixed_batch_capacity, indexed, join_u32_words,
	validate_fixed_records, PRODUCTION_GAS_METADATA_FIELDS, PRODUCTION_GAS_PRODUCT_FIELDS,
	PRODUCTION_MAX_REACTION_METADATA, PRODUCTION_REACTION_METADATA_FIELDS,
	PRODUCTION_REACTION_REQUIREMENT_FIELDS,
};
use dogmos_protocol::{
	encode_gas_metadata_batch, encode_reaction_metadata_batch, GasMetadataRegistration,
	ReactionMetadataRegistration, ScalarValue, WireFireProducts, WireGasFireRole, WireGasProduct,
	WireGasRequirement, WireReactionExecution, GAS_METADATA_RECORD_LEN, MAX_GAS_SLOTS,
	REACTION_METADATA_RECORD_LEN,
};

/// Encodes validated DM numeric fields as protocol bytes for gas metadata.
///
/// Preserves field order and little-endian word identity; invalid lengths, tags or
/// numeric values return a caller-legible error. This adapter performs no BYOND call.
pub fn encode_production_gas_metadata(
	numeric_records: &[f32],
	keys: &[String],
	names: &[String],
	product_records: &[f32],
) -> eyre::Result<Vec<u8>> {
	validate_fixed_records(
		numeric_records,
		PRODUCTION_GAS_METADATA_FIELDS,
		MAX_GAS_SLOTS,
		"gas metadata numeric records",
	)?;
	let record_count = numeric_records.len() / PRODUCTION_GAS_METADATA_FIELDS;
	if keys.len() != record_count || names.len() != record_count {
		return Err(eyre::eyre!(
			"gas metadata numeric, key, and name record counts must match"
		));
	}
	validate_fixed_records(
		product_records,
		PRODUCTION_GAS_PRODUCT_FIELDS,
		record_count.saturating_mul(MAX_GAS_SLOTS),
		"gas metadata product records",
	)?;
	let mut products = vec![Vec::new(); record_count];
	for (index, entry) in product_records
		.as_chunks::<PRODUCTION_GAS_PRODUCT_FIELDS>()
		.0
		.iter()
		.enumerate()
	{
		let owner = indexed(exact_u32(entry[0], "owner index"), "gas product", index)? as usize;
		let owner_products = products
			.get_mut(owner)
			.ok_or_else(|| eyre::eyre!("gas product entry {index} owner index is out of range"))?;
		if owner_products.len() == MAX_GAS_SLOTS {
			return Err(eyre::eyre!(
				"gas metadata record {owner} exceeds {MAX_GAS_SLOTS} products"
			));
		}
		owner_products.push(WireGasProduct {
			gas_id: indexed(exact_u16(entry[1], "gas id"), "gas product", index)?,
			ratio: ScalarValue(f64::from(entry[2])),
		});
	}
	let entries = numeric_records
		.as_chunks::<PRODUCTION_GAS_METADATA_FIELDS>()
		.0
		.iter()
		.enumerate()
		.map(|(index, fields)| {
			let moles_visible_present = indexed(
				exact_bool(fields[5], "moles-visible flag"),
				"gas metadata",
				index,
			)?;
			if !moles_visible_present && fields[6] != 0.0 {
				return Err(eyre::eyre!(
					"gas metadata entry {index} has moles-visible data while the flag is false"
				));
			}
			let fire_role = match indexed(exact_u32(fields[9], "fire role"), "gas metadata", index)?
			{
				0 if fields[10] == 0.0 && fields[11] == 0.0 => WireGasFireRole::None,
				0 => {
					return Err(eyre::eyre!(
						"gas metadata entry {index} has fire-role values for role none"
					));
				}
				1 => WireGasFireRole::Oxidizer {
					minimum_temperature: ScalarValue(f64::from(fields[10])),
					power: ScalarValue(f64::from(fields[11])),
				},
				2 => WireGasFireRole::Fuel {
					minimum_temperature: ScalarValue(f64::from(fields[10])),
					burn_rate: ScalarValue(f64::from(fields[11])),
				},
				actual => return Err(eyre::eyre!("unknown gas fire role {actual}")),
			};
			let fire_products =
				match indexed(exact_u32(fields[12], "product kind"), "gas metadata", index)? {
					0 if products[index].is_empty() => None,
					1 => Some(WireFireProducts::Generic(products[index].clone())),
					2 if products[index].is_empty() => Some(WireFireProducts::Plasma),
					actual => {
						return Err(eyre::eyre!(
						"gas metadata entry {index} has invalid product kind or unexpected product records: {actual}"
					));
					}
				};
			Ok(GasMetadataRegistration {
				id: indexed(exact_u16(fields[0], "id"), "gas metadata", index)?,
				key: keys[index].clone(),
				name: names[index].clone(),
				flags: join_u32_words(
					indexed(
						exact_u16(fields[1], "flags low word"),
						"gas metadata",
						index,
					)?,
					indexed(
						exact_u16(fields[2], "flags high word"),
						"gas metadata",
						index,
					)?,
				),
				specific_heat: ScalarValue(f64::from(fields[3])),
				fusion_power: ScalarValue(f64::from(fields[4])),
				moles_visible: moles_visible_present.then_some(ScalarValue(f64::from(fields[6]))),
				enthalpy: ScalarValue(f64::from(fields[7])),
				fire_radiation_released: ScalarValue(f64::from(fields[8])),
				fire_role,
				fire_products,
			})
		})
		.collect::<eyre::Result<Vec<_>>>()?;
	let capacity =
		fixed_batch_capacity(entries.len(), GAS_METADATA_RECORD_LEN, "gas metadata batch")?;
	let mut output = Vec::with_capacity(capacity);
	encode_gas_metadata_batch(&entries, &mut output)?;
	debug_assert_eq!(output.len(), capacity);
	Ok(output)
}

/// Encodes validated DM numeric fields as protocol bytes for reaction metadata.
///
/// Preserves field order and little-endian word identity; invalid lengths, tags or
/// numeric values return a caller-legible error. This adapter performs no BYOND call.
pub fn encode_production_reaction_metadata(
	numeric_records: &[f32],
	keys: &[String],
	requirement_records: &[f32],
) -> eyre::Result<Vec<u8>> {
	validate_fixed_records(
		numeric_records,
		PRODUCTION_REACTION_METADATA_FIELDS,
		PRODUCTION_MAX_REACTION_METADATA,
		"reaction metadata numeric records",
	)?;
	let record_count = numeric_records.len() / PRODUCTION_REACTION_METADATA_FIELDS;
	if keys.len() != record_count {
		return Err(eyre::eyre!(
			"reaction metadata numeric and key record counts must match"
		));
	}
	validate_fixed_records(
		requirement_records,
		PRODUCTION_REACTION_REQUIREMENT_FIELDS,
		record_count.saturating_mul(MAX_GAS_SLOTS),
		"reaction metadata requirement records",
	)?;
	let mut requirements = vec![Vec::new(); record_count];
	for (index, entry) in requirement_records
		.as_chunks::<PRODUCTION_REACTION_REQUIREMENT_FIELDS>()
		.0
		.iter()
		.enumerate()
	{
		let owner = indexed(
			exact_u32(entry[0], "owner index"),
			"reaction requirement",
			index,
		)? as usize;
		let owner_requirements = requirements.get_mut(owner).ok_or_else(|| {
			eyre::eyre!("reaction requirement entry {index} owner index is out of range")
		})?;
		if owner_requirements.len() == MAX_GAS_SLOTS {
			return Err(eyre::eyre!(
				"reaction metadata record {owner} exceeds {MAX_GAS_SLOTS} requirements"
			));
		}
		owner_requirements.push(WireGasRequirement {
			gas_id: indexed(exact_u16(entry[1], "gas id"), "reaction requirement", index)?,
			minimum_moles: ScalarValue(f64::from(entry[2])),
		});
	}
	let entries = numeric_records
		.as_chunks::<PRODUCTION_REACTION_METADATA_FIELDS>()
		.0
		.iter()
		.enumerate()
		.map(|(index, fields)| {
			let execution = match indexed(
				exact_u32(fields[2], "execution"),
				"reaction metadata",
				index,
			)? {
				0 => WireReactionExecution::Dm,
				1 => WireReactionExecution::NativePlasma,
				2 => WireReactionExecution::NativeHydrogen,
				3 => WireReactionExecution::NativeTritium,
				4 => WireReactionExecution::NativeFreon,
				actual => return Err(eyre::eyre!("unknown reaction execution {actual}")),
			};
			let option = |present: f32, value: f32, label: &str| -> eyre::Result<_> {
				let present = exact_bool(present, label)?;
				if !present && value != 0.0 {
					return Err(eyre::eyre!("{label} has data while the flag is false"));
				}
				Ok(present.then_some(ScalarValue(f64::from(value))))
			};
			Ok(ReactionMetadataRegistration {
				id: join_u32_words(
					indexed(
						exact_u16(fields[0], "id low word"),
						"reaction metadata",
						index,
					)?,
					indexed(
						exact_u16(fields[1], "id high word"),
						"reaction metadata",
						index,
					)?,
				),
				key: keys[index].clone(),
				priority: ScalarValue(f64::from(fields[3])),
				minimum_temperature: indexed(
					option(fields[4], fields[5], "minimum-temperature"),
					"reaction metadata",
					index,
				)?,
				maximum_temperature: indexed(
					option(fields[6], fields[7], "maximum-temperature"),
					"reaction metadata",
					index,
				)?,
				minimum_energy: indexed(
					option(fields[8], fields[9], "minimum-energy"),
					"reaction metadata",
					index,
				)?,
				minimum_fire_reagents: indexed(
					option(fields[10], fields[11], "minimum-fire-reagents"),
					"reaction metadata",
					index,
				)?,
				gas_requirements: requirements[index].clone(),
				execution,
			})
		})
		.collect::<eyre::Result<Vec<_>>>()?;
	let capacity = fixed_batch_capacity(
		entries.len(),
		REACTION_METADATA_RECORD_LEN,
		"reaction metadata batch",
	)?;
	let mut output = Vec::with_capacity(capacity);
	encode_reaction_metadata_batch(&entries, &mut output)?;
	debug_assert_eq!(output.len(), capacity);
	Ok(output)
}
