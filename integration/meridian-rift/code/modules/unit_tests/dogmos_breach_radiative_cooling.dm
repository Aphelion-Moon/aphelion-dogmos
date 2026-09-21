#define DOGMOS_BREACH_HEAT_STAGE 3

/** Verifies that a thermally balanced interior cools only after its neighbor becomes space. */
/datum/unit_test/dogmos_breach_radiative_cooling
	/// The EAST neighbor's original type, so Destroy() can restore it even if Run() aborts partway
	/// through via a TEST_ASSERT failure.
	var/original_neighbor_type

/datum/unit_test/dogmos_breach_radiative_cooling/Run()
	TEST_ASSERT(dogmos_wait_for_stage_boundary(), "The breach fixture did not reach a healthy stage boundary.")
	var/turf/open/interior = run_loc_floor_bottom_left
	TEST_ASSERT(istype(interior), "run_loc_floor_bottom_left is not an open turf - this test needs one.")
	TEST_ASSERT(!interior.should_conduct_to_space(), "The sealed control is already exposed to space.")

	// Finite heat_capacity (the stock test room's is INFINITY, same NaN hazard
	// dogmos_superconduction_golden.dm documents) and a hot seed temperature so a real blackbody delta
	// is easily distinguishable from float noise within a couple of cycles.
	interior.heat_capacity = 20000
	interior.set_temperature(2000)
	// Matching gas/turf temperatures remove ordinary gas coupling as an alternative cause
	// of cooling. No diffusion, equalization or reaction stages run in either measurement.
	interior.air.set_temperature(2000)
	resync_turf_for_dogmos(interior)

	var/before_temp = interior.return_temperature()
	TEST_ASSERT(before_temp > T0C, \
		"Seeding the interior turf at 2000K did not take ([before_temp]) - test setup is broken, not the thing under test.")
	TEST_ASSERT(dogmos_run_fixture_stage(DOGMOS_BREACH_HEAT_STAGE, list(interior)), "The sealed-control heat stage did not finish.")
	TEST_ASSERT(abs(interior.return_temperature() - before_temp) < 0.01, "The sealed control cooled without a breach, so this fixture cannot isolate radiation.")

	// CHANGETURF_RECALC_ADJACENT (inside convert_neighbor_to_space()): without it, AfterChange() queues
	// the adjacency recompute for a later SSair.fire() instead of running it immediately - this test
	// needs the edge (and, critically, the interior turf's sync_dogmos_adjacency() call) to happen
	// synchronously.
	var/list/conversion = convert_neighbor_to_space(interior)
	TEST_ASSERT_EQUAL(length(conversion), 2, "The breach fixture could not replace its neighbor with space.")
	original_neighbor_type = conversion[2]
	TEST_ASSERT(interior.should_conduct_to_space(), "The breached fixture is not exposed to space.")
	TEST_ASSERT(dogmos_run_fixture_stage(DOGMOS_BREACH_HEAT_STAGE, list(interior)), "The breached heat stage did not finish.")
	var/after_temp = interior.return_temperature()

	TEST_ASSERT(after_temp < before_temp, \
		"The interior turf's temperature ([before_temp] -> [after_temp]) did not decrease after a real heat cycle with a newly-breached space neighbor - should_conduct_to_space() is not being refreshed when a breach changes adjacency.")

	restore_neighbor_from_space(interior, original_neighbor_type)
	original_neighbor_type = null

/datum/unit_test/dogmos_breach_radiative_cooling/Destroy()
	if(dogmos_fixture_aborted)
		return ..()
	// Unconditional, not just on success: a TEST_ASSERT abort in Run() skips its own restore.
	var/turf/open/interior = run_loc_floor_bottom_left
	if(istype(interior))
		restore_neighbor_from_space(interior, original_neighbor_type)
		interior.heat_capacity = initial(interior.heat_capacity)
		interior.set_temperature(T20C)
		interior.register_dogmos_air()
	return ..()

#undef DOGMOS_BREACH_HEAT_STAGE
