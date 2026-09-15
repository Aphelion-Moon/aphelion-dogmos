//! Maintained topology adapter field order, encoding and units.

record_layout! { turf_lifecycle, "TURF_LIFECYCLE";
	(ACTION, 1, "enum/tag, existing protocol values", "kind", "action"),
	(SLOT, 1, "exact unsigned integer, 0..16777216", "identity", "slot"),
	(GENERATION, 1, "exact unsigned integer, 0..16777216", "identity", "generation"),
	(MIXTURE_PRESENT, 1, "boolean, 0 or 1", "flag", "mixture present"),
	(MIXTURE_SLOT, 1, "exact unsigned integer, 0..16777216", "identity", "mixture slot"),
	(MIXTURE_GENERATION, 1, "exact unsigned integer, 0..16777216", "identity", "mixture generation"),
}

record_layout! { turf_adjacency, "TURF_ADJACENCY";
	(LEFT_SLOT, 1, "exact unsigned integer, 0..16777216", "identity", "left slot"),
	(LEFT_GENERATION, 1, "exact unsigned integer, 0..16777216", "identity", "left generation"),
	(RIGHT_SLOT, 1, "exact unsigned integer, 0..16777216", "identity", "right slot"),
	(RIGHT_GENERATION, 1, "exact unsigned integer, 0..16777216", "identity", "right generation"),
	(CONNECTED, 1, "boolean, 0 or 1", "flag", "connected"),
	(FIRELOCK, 1, "boolean, 0 or 1", "flag", "firelock"),
}

record_layout! { turf_heat_adjacency, "TURF_HEAT_ADJACENCY";
	(LEFT_SLOT, 1, "exact unsigned integer, 0..16777216", "identity", "left slot"),
	(LEFT_GENERATION, 1, "exact unsigned integer, 0..16777216", "identity", "left generation"),
	(RIGHT_SLOT, 1, "exact unsigned integer, 0..16777216", "identity", "right slot"),
	(RIGHT_GENERATION, 1, "exact unsigned integer, 0..16777216", "identity", "right generation"),
	(CONNECTED, 1, "boolean, 0 or 1", "flag", "connected"),
}

record_layout! { turf_heat, "TURF_HEAT";
	(SLOT, 1, "exact unsigned integer, 0..16777216", "identity", "slot"),
	(GENERATION, 1, "exact unsigned integer, 0..16777216", "identity", "generation"),
	(PRESENT, 1, "boolean, 0 or 1", "flag", "present"),
	(TEMPERATURE, 1, "finite scalar, protocol domain validated", "kelvin", "temperature"),
	(CONDUCTIVITY, 1, "finite scalar, protocol domain validated", "existing thermal conductivity units", "conductivity"),
	(HEAT_CAPACITY, 1, "finite scalar, protocol domain validated", "joules/kelvin", "heat capacity"),
	(ADJACENT_TO_SPACE, 1, "boolean, 0 or 1", "flag", "adjacent to space"),
}

record_layout! { heat_snapshot, "HEAT_SNAPSHOT";
	(PRESENT, 1, "boolean, 0 or 1", "flag", "present"),
	(TEMPERATURE, 1, "finite scalar, protocol domain validated", "kelvin", "temperature"),
	(CONDUCTIVITY, 1, "finite scalar, protocol domain validated", "existing thermal conductivity units", "conductivity"),
	(HEAT_CAPACITY, 1, "finite scalar, protocol domain validated", "joules/kelvin", "heat capacity"),
	(ADJACENT_TO_SPACE, 1, "boolean, 0 or 1", "flag", "adjacent to space"),
}

pub(crate) const LAYOUTS: &[&crate::adapter_layout::Layout] = &[
	&turf_lifecycle::LAYOUT,
	&turf_adjacency::LAYOUT,
	&turf_heat_adjacency::LAYOUT,
	&turf_heat::LAYOUT,
	&heat_snapshot::LAYOUT,
];
