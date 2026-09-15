//! Maintained mixtures adapter field order, encoding and units.

record_layout! { handle, "HANDLE";
	(SLOT, 1, "exact unsigned integer, 0..16777216", "identity", "slot"),
	(GENERATION, 1, "exact unsigned integer, 0..16777216", "identity", "generation"),
}

record_layout! { word_handle, "WORD_HANDLE";
	(SLOT, 2, "exact u16 words, 0..65535 each", "identity", "slot"),
	(GENERATION, 2, "exact u16 words, 0..65535 each", "identity", "generation"),
}

record_layout! { mixture_command, "MIXTURE_COMMAND";
	(KIND, 1, "enum/tag, existing protocol values", "kind", "kind"),
	(FLAGS, 1, "exact u16 bit flags", "flags", "flags"),
	(PRIMARY_SLOT, 1, "exact unsigned integer, 0..16777216", "identity", "primary slot"),
	(PRIMARY_GENERATION, 1, "exact unsigned integer, 0..16777216", "identity", "primary generation"),
	(SECONDARY_SLOT, 1, "exact unsigned integer, 0..16777216", "identity", "secondary slot"),
	(SECONDARY_GENERATION, 1, "exact unsigned integer, 0..16777216", "identity", "secondary generation"),
	(SCALARS, 3, "finite scalar, protocol domain validated", "operation-dependent", "Three existing operation operands; no coefficient changes"),
	(GAS_ID, 1, "exact u16", "gas id", "gas id"),
	(AUX, 1, "exact unsigned integer, 0..16777216", "operation-dependent", "aux"),
}

record_layout! { mixture_response, "MIXTURE_RESPONSE";
	(KIND, 1, "enum/tag, existing protocol values", "kind", "kind"),
	(FIRST, 1, "finite scalar, protocol domain validated", "operation-dependent", "first"),
	(SECOND, 1, "finite scalar, protocol domain validated", "operation-dependent", "second"),
	(THIRD, 1, "finite scalar, protocol domain validated", "operation-dependent", "third"),
}

record_layout! { reaction_response, "REACTION_RESPONSE";
	(KIND, 1, "enum/tag, existing protocol values", "kind", "kind"),
	(FLAGS, 1, "exact unsigned integer, 0..16777216", "count", "flags"),
	(WORK_ITEMS, 1, "exact unsigned integer, 0..16777216", "count", "work items"),
	(PENDING, 1, "boolean, 0 or 1", "flag", "pending"),
	(TRANSACTION, 4, "exact u16 words, 0..65535 each", "identity", "transaction"),
}

record_layout! { adjustment, "ADJUSTMENT";
	(GAS_ID, 1, "exact u16", "gas id", "gas id"),
	(DELTA, 1, "finite scalar, protocol domain validated", "moles", "delta"),
}

record_layout! { mixture_lifecycle, "MIXTURE_LIFECYCLE";
	(ACTION, 1, "enum/tag, existing protocol values", "kind", "action"),
	(SLOT, 1, "exact unsigned integer, 0..16777216", "identity", "slot"),
	(GENERATION, 1, "exact unsigned integer, 0..16777216", "identity", "generation"),
}

record_layout! { mixture_state, "MIXTURE_STATE";
	(SLOT, 1, "exact unsigned integer, 0..16777216", "identity", "slot"),
	(GENERATION, 1, "exact unsigned integer, 0..16777216", "identity", "generation"),
	(REVISION, 2, "exact u16 words, 0..65535 each", "identity", "revision"),
	(TEMPERATURE, 1, "finite scalar, protocol domain validated", "kelvin", "temperature"),
	(VOLUME, 1, "finite scalar, protocol domain validated", "liters", "volume"),
	(GASES, dogmos_protocol::MAX_GAS_SLOTS, "finite scalar, protocol domain validated", "moles", "gases"),
}

record_layout! { mixture_snapshot, "MIXTURE_SNAPSHOT";
	(REVISION, 2, "exact u16 words, 0..65535 each", "identity", "revision"),
	(GAS_COUNT, 1, "exact unsigned integer, 0..16777216", "count", "gas count"),
	(TEMPERATURE, 1, "finite scalar, protocol domain validated", "kelvin", "temperature"),
	(VOLUME, 1, "finite scalar, protocol domain validated", "liters", "volume"),
	(MINIMUM_HEAT_CAPACITY, 1, "finite scalar, protocol domain validated", "joules/kelvin", "minimum heat capacity"),
	(TOTAL_MOLES, 1, "finite scalar, protocol domain validated", "moles", "total moles"),
	(PRESSURE, 1, "finite scalar, protocol domain validated", "kilopascals", "pressure"),
	(HEAT_CAPACITY, 1, "finite scalar, protocol domain validated", "joules/kelvin", "heat capacity"),
	(IMMUTABLE, 1, "boolean, 0 or 1", "flag", "immutable"),
	(GASES, dogmos_protocol::MAX_GAS_SLOTS, "finite scalar, protocol domain validated", "moles", "Fixed gas-id-indexed slots; unused slots retain protocol zeros"),
}

record_layout! { pipenet_record, "PIPENET_RECORD";
	(SLOT, 1, "exact unsigned integer, 0..16777216", "identity", "slot"),
	(GENERATION, 1, "exact unsigned integer, 0..16777216", "identity", "generation"),
	(SNAPSHOT, super::mixture_snapshot::LEN, "mixture_snapshot record", "record", "Same snapshot layout follows handle"),
}

pub(crate) const LAYOUTS: &[&crate::adapter_layout::Layout] = &[
	&handle::LAYOUT,
	&word_handle::LAYOUT,
	&mixture_command::LAYOUT,
	&mixture_response::LAYOUT,
	&reaction_response::LAYOUT,
	&adjustment::LAYOUT,
	&mixture_lifecycle::LAYOUT,
	&mixture_state::LAYOUT,
	&mixture_snapshot::LAYOUT,
	&pipenet_record::LAYOUT,
];
