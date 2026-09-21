/** Verifies that initialization completes without runtime errors. */
/datum/unit_test/no_runtimes_during_init

/datum/unit_test/no_runtimes_during_init/Run()
	TEST_ASSERT_EQUAL(GLOB.runtimes_at_init_complete, 0, \
		"[GLOB.runtimes_at_init_complete] runtime error(s) were logged during initialisation. See data\\logs\\ci\\runtime.log - the first one is usually the real cause and the rest are consequences.")

/**
 * A plain station floor must actually hold a standard atmosphere.
 *
 * This is the end-to-end catch for an init-order regression, and it survives being run well after
 * init specifically because of how the damage is cached, not despite it:
 * SSair.parse_gas_string() (code\controllers\subsystem\air.dm) inserts the newly-constructed
 * canonical mixture into SSair.strings_to_mix BEFORE populating it with gas. If the gas registry
 * wasn't live yet when the first turf was built, every set_moles() call on that mixture is silently
 * rejected by Dogmos, and the now-permanently-empty canonical mix is what every later turf (and every
 * restore_atmos() call) copies for the rest of the round - registration completing afterwards does
 * not repair the cache. Temperature is set separately and is unaffected, so the failure signature is
 * specifically "room temperature, zero moles, zero pressure", not a cold vacuum.
 */
/datum/unit_test/station_turf_has_air

/datum/unit_test/station_turf_has_air/Run()
	var/turf/open/floor = run_loc_floor_bottom_left
	TEST_ASSERT(istype(floor), "The unit test run location is not an open turf - this test needs one.")

	var/datum/gas_mixture/env = floor.return_air()
	TEST_ASSERT_NOTNULL(env, "A standard station floor has no gas mixture at all.")

	TEST_ASSERT(env.total_moles() > 0, \
		"A standard station floor holds zero moles. The gas registry was almost certainly handed to Dogmos after the turfs were built - check SSdogmos's init_stage and dependents, and note that SSair.strings_to_mix will have cached the empty mixture permanently.")
	TEST_ASSERT_EQUAL(round(env.total_moles(), 0.1), round(MOLES_CELLSTANDARD, 0.1), \
		"A standard station floor holds [env.total_moles()] moles, expected MOLES_CELLSTANDARD ([MOLES_CELLSTANDARD]).")

	TEST_ASSERT(env.get_moles(/datum/gas/oxygen) > 0, "A standard station floor has no oxygen.")
	TEST_ASSERT(env.get_moles(/datum/gas/nitrogen) > 0, "A standard station floor has no nitrogen.")
	TEST_ASSERT_EQUAL(round(env.return_temperature()), round(T20C), "A standard station floor is at [env.return_temperature()]K, expected T20C.")
	TEST_ASSERT(env.return_pressure() > WARNING_LOW_PRESSURE, \
		"A standard station floor is at [env.return_pressure()] kPa, at or below WARNING_LOW_PRESSURE.")
