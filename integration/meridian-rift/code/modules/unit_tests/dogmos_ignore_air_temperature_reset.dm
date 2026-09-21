/** Regression coverage for resetting TurfHeat temperature on CHANGETURF_IGNORE_AIR.
 * It follows the deferred ChangeTurf/AfterChange sequence used by map-template loading.
 */
/datum/unit_test/dogmos_ignore_air_temperature_reset
	var/original_type

/datum/unit_test/dogmos_ignore_air_temperature_reset/Run()
	var/turf/open/turf_a = run_loc_floor_bottom_left
	TEST_ASSERT(istype(turf_a), "run_loc_floor_bottom_left is not an open turf - this test needs one.")

	original_type = turf_a.type
	turf_a.set_temperature(1000)
	TEST_ASSERT(abs(turf_a.return_temperature() - 1000) < 1, \
		"turf_a's heat-graph temperature right after set_temperature(1000) was [turf_a.return_temperature()]K, not ~1000K - test setup is broken before the thing under test even starts.")

	// CHANGETURF_DEFER_CHANGE: matches build_coordinate()'s own ChangeTurf call exactly - AfterChange()
	// is NOT invoked yet after this line (change_turf.dm's own early-return on this flag). Swaps to a
	// different real type (matching the other alternating-type tests in this suite) since path == type
	// is a ChangeTurf() no-op.
	var/turf/open/floor/plating/new_turf = turf_a.ChangeTurf(/turf/open/floor/plating, flags = CHANGETURF_DEFER_CHANGE)
	TEST_ASSERT(istype(new_turf), "ChangeTurf to /turf/open/floor/plating did not produce a plating turf - test setup is broken, not the thing under test.")

	// Matches reader.dm:358's later finalization call exactly - this is the real code path under test.
	new_turf.AfterChange(CHANGETURF_IGNORE_AIR, original_type)

	var/heat_graph_temp = new_turf.return_temperature()
	TEST_ASSERT(heat_graph_temp < 900, \
		"The reset turf's heat-graph temperature is still [heat_graph_temp]K after AfterChange(CHANGETURF_IGNORE_AIR) - it retained the pre-reset 1000K instead of resetting, reproducing the Thunderdome hot-spot-after-reset bug.")
	TEST_ASSERT(abs(heat_graph_temp - new_turf.temperature) < 1, \
		"The reset turf's heat-graph temperature ([heat_graph_temp]K) and its own DM-side temperature var ([new_turf.temperature]K) disagree by more than 1K - the heat graph isn't synced to this fresh turf's real temperature.")

/datum/unit_test/dogmos_ignore_air_temperature_reset/Destroy()
	var/turf/open/turf_a = run_loc_floor_bottom_left
	if(original_type && istype(turf_a) && turf_a.type != original_type)
		turf_a.ChangeTurf(original_type, flags = CHANGETURF_INHERIT_AIR | CHANGETURF_RECALC_ADJACENT)
	restore_atmos()
	return ..()
