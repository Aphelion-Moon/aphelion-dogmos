/** Verifies that the turf temperature wrapper updates Rust's heat graph. */
/datum/unit_test/dogmos_turf_temperature_setter

/datum/unit_test/dogmos_turf_temperature_setter/Run()
	var/turf/open/floor = run_loc_floor_bottom_left
	TEST_ASSERT(istype(floor), "The unit test run location is not an open turf - this test needs one.")

	var/original_temperature = floor.temperature
	var/original_initial_temperature = floor.initial_temperature

	// Make sure it's actually registered before testing the setter against it.
	floor.register_dogmos_air()

	floor.set_temperature(400)
	TEST_ASSERT_EQUAL(floor.temperature, 400, \
		"set_temperature() did not update the turf's own temperature var.")
	TEST_ASSERT_EQUAL(round(floor.return_temperature()), 400, \
		"return_temperature() is [floor.return_temperature()]K after set_temperature(400) - the write did not reach Rust's TurfHeat arena.")

	floor.set_temperature(150)
	TEST_ASSERT_EQUAL(floor.temperature, 150, \
		"set_temperature() did not update the turf's own temperature var on a second write.")
	TEST_ASSERT_EQUAL(round(floor.return_temperature()), 150, \
		"return_temperature() is [floor.return_temperature()]K after set_temperature(150) - a second write did not reach Rust.")

	floor.set_temperature(original_temperature)
	floor.initial_temperature = original_initial_temperature

/datum/unit_test/dogmos_turf_temperature_setter/Destroy()
	// Unconditional, matching dogmos_turf_registration.dm's convention: a TEST_ASSERT abort above
	// skips Run()'s own restore, and this is a shared test-room turf every later test depends on.
	var/turf/open/floor = run_loc_floor_bottom_left
	if(istype(floor))
		floor.set_temperature(T20C)
		floor.initial_temperature = null
	return ..()
