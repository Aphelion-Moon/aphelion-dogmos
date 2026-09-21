/** Verifies graph cleanup when an open turf becomes closed. */
/datum/unit_test/dogmos_turf_lifecycle
	/// Original turf type restored during teardown.
	var/original_type

/datum/unit_test/dogmos_turf_lifecycle/Run()
	var/turf/test_turf = run_loc_floor_bottom_left
	TEST_ASSERT(istype(test_turf, /turf/open), "The unit test run location is not an open turf - this test needs one.")

	original_type = test_turf.type
	test_turf.set_temperature(700)
	var/turf/closed/wall = test_turf.ChangeTurf(/turf/closed/wall)
	TEST_ASSERT(istype(wall), "Changing the test turf to a wall did not produce a closed turf.")
	TEST_ASSERT(isnull(wall.dogmos_heat_temperature()), \
		"The replaced closed turf still has a Dogmos heat-graph node. Open-to-closed replacement must remove the old node from both Dogmos graphs.")

	var/turf/open/restored = wall.ChangeTurf(original_type, flags = CHANGETURF_RECALC_ADJACENT)
	TEST_ASSERT(istype(restored), "Restoring the test turf to its original open type failed.")
	TEST_ASSERT(!isnull(restored.dogmos_heat_temperature()), \
		"Restoring an open turf did not register a new Dogmos heat-graph node after the old node was removed.")

/datum/unit_test/dogmos_turf_lifecycle/Destroy()
	var/turf/test_turf = run_loc_floor_bottom_left
	if(original_type && test_turf.type != original_type)
		test_turf.ChangeTurf(original_type, flags = CHANGETURF_RECALC_ADJACENT)
	restore_atmos()
	return ..()
