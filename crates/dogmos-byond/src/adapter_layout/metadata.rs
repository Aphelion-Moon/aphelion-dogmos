//! Maintained metadata adapter field order, encoding and units.

record_layout! { gas_metadata, "GAS_METADATA";
	(ID, 1, "exact u16", "gas id", "id"),
	(FLAGS, 2, "exact u16 words, 0..65535 each", "flags", "flags"),
	(SPECIFIC_HEAT, 1, "finite scalar, protocol domain validated", "joules/(mole kelvin)", "specific heat"),
	(FUSION_POWER, 1, "finite scalar, protocol domain validated", "existing fusion units", "fusion power"),
	(MOLES_VISIBLE_PRESENT, 1, "boolean, 0 or 1", "flag", "moles visible present"),
	(MOLES_VISIBLE, 1, "finite scalar, protocol domain validated", "moles", "Zero when absent"),
	(ENTHALPY, 1, "finite scalar, protocol domain validated", "existing energy units", "enthalpy"),
	(FIRE_RADIATION, 1, "finite scalar, protocol domain validated", "existing radiation units", "fire radiation"),
	(FIRE_ROLE, 1, "enum/tag, existing protocol values", "kind", "fire role"),
	(FIRE_MINIMUM_TEMPERATURE, 1, "finite scalar, protocol domain validated", "kelvin", "fire minimum temperature"),
	(FIRE_POWER_OR_RATE, 1, "finite scalar, protocol domain validated", "role-dependent", "fire power or rate"),
	(PRODUCT_KIND, 1, "enum/tag, existing protocol values", "kind", "product kind"),
}

record_layout! { gas_product, "GAS_PRODUCT";
	(OWNER, 1, "exact unsigned integer, 0..16777216", "zero-based metadata record index", "owner"),
	(GAS_ID, 1, "exact u16", "gas id", "gas id"),
	(RATIO, 1, "finite scalar, protocol domain validated", "ratio", "ratio"),
}

record_layout! { reaction_metadata, "REACTION_METADATA";
	(ID, 2, "exact u16 words, 0..65535 each", "identity", "id"),
	(EXECUTION, 1, "enum/tag, existing protocol values", "kind", "execution"),
	(PRIORITY, 1, "finite scalar, protocol domain validated", "ordering", "priority"),
	(MINIMUM_TEMPERATURE_PRESENT, 1, "boolean, 0 or 1", "flag", "minimum temperature present"),
	(MINIMUM_TEMPERATURE, 1, "finite scalar, protocol domain validated", "kelvin", "Zero when absent"),
	(MAXIMUM_TEMPERATURE_PRESENT, 1, "boolean, 0 or 1", "flag", "maximum temperature present"),
	(MAXIMUM_TEMPERATURE, 1, "finite scalar, protocol domain validated", "kelvin", "Zero when absent"),
	(MINIMUM_ENERGY_PRESENT, 1, "boolean, 0 or 1", "flag", "minimum energy present"),
	(MINIMUM_ENERGY, 1, "finite scalar, protocol domain validated", "joules", "Zero when absent"),
	(MINIMUM_FIRE_REAGENTS_PRESENT, 1, "boolean, 0 or 1", "flag", "minimum fire reagents present"),
	(MINIMUM_FIRE_REAGENTS, 1, "finite scalar, protocol domain validated", "moles", "Zero when absent"),
}

record_layout! { reaction_requirement, "REACTION_REQUIREMENT";
	(OWNER, 1, "exact unsigned integer, 0..16777216", "zero-based metadata record index", "owner"),
	(GAS_ID, 1, "exact u16", "gas id", "gas id"),
	(MINIMUM_MOLES, 1, "finite scalar, protocol domain validated", "moles", "minimum moles"),
}

pub(crate) const LAYOUTS: &[&crate::adapter_layout::Layout] = &[
	&gas_metadata::LAYOUT,
	&gas_product::LAYOUT,
	&reaction_metadata::LAYOUT,
	&reaction_requirement::LAYOUT,
];
