/** Verifies a fresh turf registration reaches Rust and preserves the seeded temperature. */
/datum/unit_test/dogmos_turf_registration

/datum/unit_test/dogmos_turf_registration/proc/force_fresh_registration(turf/target, test_temperature)
	var/original_thermal_conductivity = target.thermal_conductivity
	var/original_heat_capacity = target.heat_capacity

	target.thermal_conductivity = 0
	target.heat_capacity = 0
	target.register_dogmos_air() // supercond_update_ref sees therm_cond/heat_cap <= 0 and removes the turf.

	target.thermal_conductivity = original_thermal_conductivity
	target.heat_capacity = original_heat_capacity
	target.temperature = test_temperature
	target.initial_temperature = null
	target.register_dogmos_air() // Now a genuine fresh insert, seeded from the temperature just set.

/datum/unit_test/dogmos_turf_registration/Run()
	var/turf/open/floor = run_loc_floor_bottom_left
	TEST_ASSERT(istype(floor), "The unit test run location is not an open turf - this test needs one.")

	var/original_temperature = floor.temperature
	var/original_initial_temperature = floor.initial_temperature
	var/original_blocks_air = floor.blocks_air

	// Open-turf case.
	force_fresh_registration(floor, 350)

	TEST_ASSERT_EQUAL(floor.initial_temperature, 350, \
		"register_dogmos_air() did not seed initial_temperature from temperature on first registration.")
	TEST_ASSERT_EQUAL(round(floor.return_temperature()), 350, \
		"return_temperature() is [floor.return_temperature()]K, not the 350K just registered - the turf did not actually reach Rust's TurfHeat arena (hook_register_turf/supercond_update_ref).")

	// Closed/blocks_air case: hook_register_turf calls supercond_update_ref() unconditionally
	// regardless of blocks_air, so a solid turf should still land in TurfHeat - though in practice
	// ordinary walls never do (thermal_conductivity 0 excludes them, see the SSAIR_SUPERCONDUCTIVITY
	// cutover's plan notes), which is why solid/solid conduction was never really a distinct code path
	// worth preserving a DM fallback for.
	floor.blocks_air = TRUE
	force_fresh_registration(floor, 500)

	TEST_ASSERT_EQUAL(floor.initial_temperature, 500, \
		"register_dogmos_air() did not seed initial_temperature on a blocks_air turf's first registration.")
	TEST_ASSERT_EQUAL(round(floor.return_temperature()), 500, \
		"return_temperature() is [floor.return_temperature()]K, not the 500K just registered - a blocks_air turf did not register into TurfHeat. Solid/solid superconduction depends on this.")

	floor.blocks_air = original_blocks_air
	force_fresh_registration(floor, original_temperature)
	floor.initial_temperature = original_initial_temperature

/datum/unit_test/dogmos_turf_registration/Destroy()
	// Unconditional, not just on assertion failure: Run() only restores the shared test turf at its
	// very end, so any TEST_ASSERT abort above skips that restore and leaves temperature/blocks_air
	// dirty for every test that runs after this one.
	var/turf/open/floor = run_loc_floor_bottom_left
	if(istype(floor))
		floor.blocks_air = FALSE
		force_fresh_registration(floor, T20C)
		floor.initial_temperature = null
	return ..()
