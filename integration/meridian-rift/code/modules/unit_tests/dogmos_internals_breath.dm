/** Verifies that a populated internals tank supplies a breathable breath. */
/datum/unit_test/dogmos_internals_breath

/datum/unit_test/dogmos_internals_breath/Run()
	var/mob/living/carbon/human/consistent/lab_rat = allocate(/mob/living/carbon/human/consistent)
	var/obj/item/tank/internals/emergency_oxygen/tank = allocate(/obj/item/tank/internals/emergency_oxygen)
	var/obj/item/clothing/mask/gas/mask = allocate(/obj/item/clothing/mask/gas)

	TEST_ASSERT(tank.air_contents.total_moles() > 0, \
		"A stock emergency oxygen tank has 0 moles right out of populate_gas() - test setup is broken, not the thing under test.")

	// Matches what actually happens when a player equips + toggles internals: invalid_internals()
	// requires both a breathing apparatus (can_breathe_internals()) AND the tank physically on the mob
	// (internal.loc == src) - a bare `lab_rat.internal = tank` var assignment (an earlier version of
	// this test) satisfies neither, so get_breath_from_internal() short-circuits via
	// cutoff_internals() before ever reaching remove_air_volume() - that's a test setup gap, not
	// evidence of a Dogmos bug on its own.
	lab_rat.equip_to_slot_if_possible(mask, ITEM_SLOT_MASK)
	tank.forceMove(lab_rat)
	lab_rat.open_internals(tank)
	TEST_ASSERT(!lab_rat.invalid_internals(), \
		"Test setup still leaves invalid_internals() true after equipping a MASKINTERNALS mask and moving the tank onto the mob - test setup is broken, not the thing under test.")

	var/datum/gas_mixture/breath = lab_rat.get_breath_from_internal(BREATH_VOLUME)
	TEST_ASSERT(breath, \
		"get_breath_from_internal() returned null/false from a tank with [tank.air_contents.total_moles()] moles at [tank.air_contents.return_pressure()] kPa - remove_air_volume()'s moles_needed calculation or the underlying remove() call is producing nothing.")

	var/o2_moles = breath.get_moles(/datum/gas/oxygen)
	var/o2_pp = breath.get_breath_partial_pressure(o2_moles)
	TEST_ASSERT(o2_moles > 0, \
		"A breath pulled from a full emergency oxygen tank contains 0 moles of oxygen.")
	TEST_ASSERT(o2_pp >= 16, \
		"A breath pulled from a full emergency oxygen tank at its default release pressure has an oxygen partial pressure of only [o2_pp] kPa - below the 16 kPa safe_oxygen_min threshold, which would suffocate the mob despite a full tank at default settings.")
