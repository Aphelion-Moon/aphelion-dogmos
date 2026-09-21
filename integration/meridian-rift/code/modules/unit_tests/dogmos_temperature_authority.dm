/** Verifies the configured temperature authority for blocked turfs. */
/datum/unit_test/dogmos_temperature_authority

/datum/unit_test/dogmos_temperature_authority/Run()
	var/turf/open/test_turf = run_loc_floor_bottom_left
	TEST_ASSERT(istype(test_turf), "The unit test run location is not an open turf - this test needs one.")

	test_turf.blocks_air = TRUE
	resync_turf_for_dogmos(test_turf)
	test_turf.set_temperature(600)
	// Deliberately create the split this test is meant to expose: Rust stays at 600K while the
	// legacy DM-side variable is changed independently.
	test_turf.temperature = 300

	SSair.dogmos_blocked_turf_temperature_authority = DOGMOS_TEMPERATURE_AUTHORITY_DM
	TEST_ASSERT_EQUAL(test_turf.GetTemperature(), 300, \
		"DM temperature authority did not use the legacy turf temperature var.")

	SSair.dogmos_blocked_turf_temperature_authority = DOGMOS_TEMPERATURE_AUTHORITY_RUST
	TEST_ASSERT(abs(test_turf.GetTemperature() - 600) < 1, \
		"Rust temperature authority did not use the live TurfHeat value after the DM var was changed to 300K.")

	var/turf/open/space/space_turf = locate(/turf/open/space)
	if(space_turf)
		var/rust_temperature = space_turf.dogmos_heat_temperature()
		TEST_ASSERT(isnull(rust_temperature), \
			"dogmos_heat_temperature() returned [rust_temperature]K for a turf without a TurfHeat node instead of null.")

/datum/unit_test/dogmos_temperature_authority/Destroy()
	var/turf/open/test_turf = run_loc_floor_bottom_left
	if(istype(test_turf))
		test_turf.blocks_air = initial(test_turf.blocks_air)
		test_turf.temperature = initial(test_turf.temperature)
		resync_turf_for_dogmos(test_turf)
	SSair.dogmos_blocked_turf_temperature_authority = initial(SSair.dogmos_blocked_turf_temperature_authority)
	return ..()
