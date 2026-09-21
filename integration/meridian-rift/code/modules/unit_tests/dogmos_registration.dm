/** Verifies that gas and reaction registries reach Dogmos during SSair initialization. */
/datum/unit_test/dogmos_registration

/datum/unit_test/dogmos_registration/Run()
	var/library = __detect_dogmos()
	TEST_ASSERT(istext(library), "__detect_dogmos() returned no library name, got: [isnull(library) ? "null" : library]")

	// The Defect-1 assertion, stated directly: SSdogmos must initialise before anything that could
	// build a gas mixture. init_order is assigned by the MC in a single increasing sweep across all
	// init stages (code\controllers\master.dm), so a plain numeric comparison is meaningful here.
	TEST_ASSERT(SSdogmos.gases_registered, "SSdogmos never finished registering the gas table.")
	TEST_ASSERT(SSdogmos.init_order < SSatoms.init_order, \
		"SSdogmos initialised at order [SSdogmos.init_order], AFTER SSatoms at [SSatoms.init_order]. Every turf's air was built before Dogmos knew a single gas id.")
	TEST_ASSERT(SSdogmos.init_order < SSmapping.init_order, \
		"SSdogmos initialised after SSmapping - mapload creates gas mixtures.")

	TEST_ASSERT(length(GLOB.gas_data.datums) == GAS_TYPE_COUNT, "GLOB.gas_data holds [length(GLOB.gas_data.datums)] gas datums, expected [GAS_TYPE_COUNT]")

	for(var/gas_path in GLOB.gas_data.datums)
		var/datum/gas/gas = GLOB.gas_data.datums[gas_path]
		TEST_ASSERT(istype(gas), "GLOB.gas_data.datums\[[gas_path]\] is not a gas datum instance - Dogmos reads vars off instances, not type paths")
		TEST_ASSERT(gas.id, "[gas_path] registered with no id")
		TEST_ASSERT(isnum(gas.specific_heat), "[gas_path] registered with a non-numeric specific_heat")

	TEST_ASSERT(length(SSair.dogmos_reactions), "SSair.dogmos_reactions is empty - Dogmos would have no reactions at all")

	// Dogmos keys reactions by priority and silently drops duplicates, so a collision here means
	// reactions vanish at runtime with no error.
	var/list/seen_priorities = list()
	for(var/datum/gas_reaction/reaction as anything in SSair.dogmos_reactions)
		TEST_ASSERT(isnum(reaction.priority), "[reaction.type] has a non-numeric Dogmos priority")
		TEST_ASSERT(!seen_priorities["[reaction.priority]"], "[reaction.type] shares Dogmos priority [reaction.priority] with another reaction - one of them would be silently discarded")
		seen_priorities["[reaction.priority]"] = TRUE

	// Every requirement key must be a gas id string or a recognised sentinel, or Dogmos ignores it.
	var/list/meta_gas_id = GLOB.meta_gas_info[META_GAS_ID]
	var/list/known_gas_ids = list()
	for(var/gas_path in meta_gas_id)
		known_gas_ids[meta_gas_id[gas_path]] = TRUE

	for(var/datum/gas_reaction/reaction as anything in SSair.dogmos_reactions)
		for(var/requirement in reaction.min_requirements)
			if(requirement == "TEMP" || requirement == "MAX_TEMP" || requirement == "ENER" || requirement == "FIRE_REAGENTS")
				continue
			TEST_ASSERT(known_gas_ids[requirement], "[reaction.type] has requirement key \"[requirement]\", which is neither a gas id nor a sentinel Dogmos understands")

	// Everything above validates what DM handed Dogmos. Nothing yet has asked Dogmos whether it
	// actually accepted any of it - round-trip every gas through the FFI boundary for real.
	var/datum/gas_mixture/probe = allocate(/datum/gas_mixture)
	probe.set_volume(CELL_VOLUME)
	probe.set_temperature(T20C)

	// Upstream admin tanks use set_gas; it must replace native moles, not add to them.
	probe.set_gas(/datum/gas/oxygen, 2)
	probe.set_gas(/datum/gas/oxygen, 3)
	TEST_ASSERT_EQUAL(probe.get_moles(/datum/gas/oxygen), 3, "set_gas must replace Dogmos-owned moles.")
	probe.set_gas(/datum/gas/oxygen, 0)
	TEST_ASSERT_EQUAL(probe.get_moles(/datum/gas/oxygen), 0, "set_gas must clear Dogmos-owned moles.")

	for(var/gas_path in GLOB.gas_data.datums)
		var/datum/gas/gas = GLOB.gas_data.datums[gas_path]
		probe.set_moles(gas_path, 1)
		TEST_ASSERT_EQUAL(round(probe.get_moles(gas_path), 0.0001), 1, \
			"Dogmos did not store 1 mole of [gas.id] ([gas_path]) - it never accepted this gas at registration.")
		// partial_heat_capacity for exactly 1 mole IS the specific heat, so this proves Dogmos'
		// copy of the gas metadata actually matches DM's, not just that the gas is present.
		TEST_ASSERT_EQUAL(round(probe.partial_heat_capacity(gas_path), 0.01), round(gas.specific_heat, 0.01), \
			"Dogmos reports specific heat [probe.partial_heat_capacity(gas_path)] for [gas.id], DM says [gas.specific_heat] - the registry is stale or gas indices collided.")
		probe.set_moles(gas_path, 0)

	// Every gas simultaneously: catches index collisions that per-gas testing above cannot, since
	// a collision only shows up when two gases are present at once and one silently overwrites
	// the other.
	probe.clear()
	for(var/gas_path in GLOB.gas_data.datums)
		probe.set_moles(gas_path, 1)
	var/list/present = probe.__get_gases()
	TEST_ASSERT_EQUAL(length(present), GAS_TYPE_COUNT, \
		"Dogmos reports [length(present)] gases present after setting one mole of each of [GAS_TYPE_COUNT] - ids collided on registration and gases are overwriting each other.")

	// The reaction table crossed the boundary too, not just the gas table.
	TEST_ASSERT_EQUAL(dogmos_reaction_count(), length(SSair.dogmos_reactions), \
		"Dogmos holds [dogmos_reaction_count()] reactions, DM handed it [length(SSair.dogmos_reactions)] - reactions were dropped at init.")
