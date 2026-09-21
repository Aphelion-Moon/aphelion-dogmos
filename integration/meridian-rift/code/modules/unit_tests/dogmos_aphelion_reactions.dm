/** Verifies native fire reactions and their codebase-specific byproducts. */
/datum/unit_test/dogmos_aphelion_reactions

/datum/unit_test/dogmos_aphelion_reactions/Run()
	var/datum/gas_mixture/plasma_air = allocate(/datum/gas_mixture, CELL_VOLUME) // APHELION EDIT CHANGE - DOGMOS - ORIGINAL: var/datum/gas_mixture/plasma_air = new(CELL_VOLUME)
	// Stay below PLASMA_OXYGEN_FULLBURN to exercise the water-vapor branch.
	plasma_air.set_moles(/datum/gas/plasma, 50)
	plasma_air.set_moles(/datum/gas/oxygen, 200)
	plasma_air.set_temperature(PLASMA_MINIMUM_BURN_TEMPERATURE + 500)

	var/plasma_before = plasma_air.get_moles(/datum/gas/plasma)
	var/o2_before = plasma_air.get_moles(/datum/gas/oxygen)
	var/plasma_temp_before = plasma_air.return_temperature()

	var/plasma_reacted = plasma_air.react(null)
	TEST_ASSERT(plasma_reacted, \
		"plasmafire did not report a reaction despite plasma+oxygen well above ignition temperature - the aphelion_reactions Rust port isn't firing.")
	TEST_ASSERT(plasma_air.get_moles(/datum/gas/plasma) < plasma_before, \
		"Plasma moles did not decrease after plasmafire ([plasma_before] -> [plasma_air.get_moles(/datum/gas/plasma)]).")
	TEST_ASSERT(plasma_air.get_moles(/datum/gas/oxygen) < o2_before, \
		"Oxygen moles did not decrease after plasmafire ([o2_before] -> [plasma_air.get_moles(/datum/gas/oxygen)]).")
	TEST_ASSERT(plasma_air.return_temperature() > plasma_temp_before, \
		"Temperature did not increase after plasmafire ([plasma_temp_before] -> [plasma_air.return_temperature()]) - energy release is missing.")
	TEST_ASSERT(plasma_air.get_moles(/datum/gas/carbon_dioxide) > 0 && plasma_air.get_moles(/datum/gas/water_vapor) > 0, \
		"Non-supersaturated plasmafire should produce both CO2 and water_vapor - got CO2=[plasma_air.get_moles(/datum/gas/carbon_dioxide)], water_vapor=[plasma_air.get_moles(/datum/gas/water_vapor)]. Missing water_vapor is exactly the divergence citadel_reactions' formula has from this codebase's.")
	TEST_ASSERT(plasma_air.reaction_results[/datum/gas_reaction/standard/plasmafire], \
		"reaction_results wasn't populated for /datum/gas_reaction/standard/plasmafire - dogmos_aphelion_plasmafire_finish() isn't writing the typepath-keyed entry SSair.hotspot_reactions-driven fire growth (LINDA_fire.dm) depends on.")

	qdel(plasma_air)

	var/datum/gas_mixture/trit_air = allocate(/datum/gas_mixture, CELL_VOLUME) // APHELION EDIT CHANGE - DOGMOS - ORIGINAL: var/datum/gas_mixture/trit_air = new(CELL_VOLUME)
	trit_air.set_moles(/datum/gas/tritium, 20)
	trit_air.set_moles(/datum/gas/oxygen, 200)
	trit_air.set_temperature(TRITIUM_MINIMUM_BURN_TEMPERATURE + 500)

	var/trit_before = trit_air.get_moles(/datum/gas/tritium)
	var/trit_o2_before = trit_air.get_moles(/datum/gas/oxygen)
	var/trit_temp_before = trit_air.return_temperature()

	var/trit_reacted = trit_air.react(null)
	TEST_ASSERT(trit_reacted, \
		"tritfire did not report a reaction despite tritium+oxygen well above ignition temperature.")
	TEST_ASSERT(trit_air.get_moles(/datum/gas/tritium) < trit_before, \
		"Tritium moles did not decrease after tritfire ([trit_before] -> [trit_air.get_moles(/datum/gas/tritium)]).")
	TEST_ASSERT(trit_air.get_moles(/datum/gas/oxygen) < trit_o2_before, \
		"Oxygen moles did not decrease after tritfire.")
	TEST_ASSERT(trit_air.return_temperature() > trit_temp_before, \
		"Temperature did not increase after tritfire ([trit_temp_before] -> [trit_air.return_temperature()]).")
	TEST_ASSERT(trit_air.get_moles(/datum/gas/water_vapor) > 0, \
		"tritfire should produce water_vapor (this codebase's measured fuel/oxidizer model) - zero here would mean the Rust port fell back to citadel_reactions' water-less 'trit bomb' formula instead.")
	TEST_ASSERT(trit_air.reaction_results[/datum/gas_reaction/standard/tritfire], \
		"reaction_results wasn't populated for /datum/gas_reaction/standard/tritfire.")

	qdel(trit_air)

	var/datum/gas_mixture/h2_air = allocate(/datum/gas_mixture, CELL_VOLUME) // APHELION EDIT CHANGE - DOGMOS - ORIGINAL: var/datum/gas_mixture/h2_air = new(CELL_VOLUME)
	h2_air.set_moles(/datum/gas/hydrogen, 20)
	h2_air.set_moles(/datum/gas/oxygen, 200)
	h2_air.set_temperature(HYDROGEN_MINIMUM_BURN_TEMPERATURE + 500)

	var/h2_before = h2_air.get_moles(/datum/gas/hydrogen)
	var/h2_o2_before = h2_air.get_moles(/datum/gas/oxygen)
	var/h2_temp_before = h2_air.return_temperature()

	var/h2_reacted = h2_air.react(null)
	TEST_ASSERT(h2_reacted, \
		"h2fire did not report a reaction despite hydrogen+oxygen well above ignition temperature.")
	TEST_ASSERT(h2_air.get_moles(/datum/gas/hydrogen) < h2_before, \
		"Hydrogen moles did not decrease after h2fire ([h2_before] -> [h2_air.get_moles(/datum/gas/hydrogen)]).")
	TEST_ASSERT(h2_air.get_moles(/datum/gas/oxygen) < h2_o2_before, \
		"Oxygen moles did not decrease after h2fire.")
	TEST_ASSERT(h2_air.return_temperature() > h2_temp_before, \
		"Temperature did not increase after h2fire ([h2_temp_before] -> [h2_air.return_temperature()]).")
	TEST_ASSERT(h2_air.get_moles(/datum/gas/water_vapor) > 0, \
		"h2fire should produce water_vapor - got 0.")
	TEST_ASSERT(h2_air.reaction_results[/datum/gas_reaction/standard/h2fire], \
		"reaction_results wasn't populated for /datum/gas_reaction/standard/h2fire.")

	qdel(h2_air)

	var/datum/gas_mixture/freon_air = allocate(/datum/gas_mixture, CELL_VOLUME) // APHELION EDIT CHANGE - DOGMOS - ORIGINAL: var/datum/gas_mixture/freon_air = new(CELL_VOLUME)
	freon_air.set_moles(/datum/gas/freon, 50)
	freon_air.set_moles(/datum/gas/oxygen, 200)
	// Within freonfire's [FREON_TERMINAL_TEMPERATURE, FREON_MAXIMUM_BURN_TEMPERATURE] = [20, 283]
	// window - unlike the other three fire reactions, freonfire is ENDOTHERMIC (it requires already
	// being cold and gets colder), so there is no "well above ignition temperature" seed to pick here.
	freon_air.set_temperature(150)

	var/freon_before = freon_air.get_moles(/datum/gas/freon)
	var/freon_o2_before = freon_air.get_moles(/datum/gas/oxygen)
	var/freon_temp_before = freon_air.return_temperature()

	var/freon_reacted = freon_air.react(null)
	TEST_ASSERT(freon_reacted, \
		"freonfire did not report a reaction despite freon+oxygen within its burn temperature window.")
	TEST_ASSERT(freon_air.get_moles(/datum/gas/freon) < freon_before, \
		"Freon moles did not decrease after freonfire ([freon_before] -> [freon_air.get_moles(/datum/gas/freon)]).")
	TEST_ASSERT(freon_air.get_moles(/datum/gas/oxygen) < freon_o2_before, \
		"Oxygen moles did not decrease after freonfire.")
	TEST_ASSERT(freon_air.return_temperature() < freon_temp_before, \
		"Temperature did not decrease after freonfire ([freon_temp_before] -> [freon_air.return_temperature()]) - freonfire is endothermic, unlike the other three fire reactions.")
	TEST_ASSERT(freon_air.get_moles(/datum/gas/carbon_dioxide) > 0, \
		"freonfire should produce CO2 - got 0.")
	TEST_ASSERT(freon_air.reaction_results[/datum/gas_reaction/standard/freonfire], \
		"reaction_results wasn't populated for /datum/gas_reaction/standard/freonfire.")

	qdel(freon_air)
