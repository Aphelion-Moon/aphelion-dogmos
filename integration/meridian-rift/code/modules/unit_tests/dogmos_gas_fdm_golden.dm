#define DOGMOS_FDM_TEST_STAGE 4

/** Verifies directional flow, no overshoot and bounded conservation in one native FDM stage. */
/datum/unit_test/dogmos_gas_fdm_golden

/datum/unit_test/dogmos_gas_fdm_golden/Run()
	TEST_ASSERT(dogmos_wait_for_stage_boundary(), "Dogmos did not reach a safe boundary before diffusion.")
	var/list/pair = allocate_turf_pair()
	TEST_ASSERT_EQUAL(length(pair), 2, "The diffusion fixture needs two gas-adjacent turfs.")
	var/turf/open/turf_a = pair[1]
	var/turf/open/turf_b = pair[2]
	var/datum/gas_mixture/air_a = turf_a.air
	var/datum/gas_mixture/air_b = turf_b.air
	air_a.set_moles(/datum/gas/oxygen, air_a.get_moles(/datum/gas/oxygen) * 3)
	var/a_before = air_a.get_moles(/datum/gas/oxygen)
	var/b_before = air_b.get_moles(/datum/gas/oxygen)
	TEST_ASSERT(a_before > b_before, "The diffusion fixture did not produce asymmetric oxygen amounts.")

	var/list/room_turfs = get_area_turfs(turf_a.loc)
	var/oxygen_before = 0
	var/open_count = 0
	for(var/turf/open/room_turf in room_turfs)
		open_count++
		oxygen_before += room_turf.air.get_moles(/datum/gas/oxygen)
		for(var/turf/open/neighbor as anything in room_turf.atmos_adjacent_turfs)
			TEST_ASSERT(neighbor in room_turfs, "The conservation fixture must be closed to external gas flow.")

	// Invoke one stage directly: process_turfs_auxtools may perform several configured
	// FDM passes, and waiting for SSair could also run equalization or excited groups.
	TEST_ASSERT(dogmos_run_fixture_stage(DOGMOS_FDM_TEST_STAGE, pair), "Native diffusion did not complete and restore its frontier within the fixture bound.")
	var/a_after = air_a.get_moles(/datum/gas/oxygen)
	var/b_after = air_b.get_moles(/datum/gas/oxygen)
	TEST_ASSERT(a_after < a_before, "Diffusion did not move oxygen out of the fuller turf.")
	TEST_ASSERT(b_after > b_before, "Diffusion did not move oxygen into the emptier turf.")
	TEST_ASSERT(a_after > b_after, "One diffusion stage overshot equilibrium.")
	var/oxygen_after = 0
	for(var/turf/open/room_turf in room_turfs)
		oxygen_after += room_turf.air.get_moles(/datum/gas/oxygen)
	// The documented trace sink is less than 0.01 mole per gas per committed mixture.
	TEST_ASSERT(abs(oxygen_after - oxygen_before) < 0.01 * open_count, "Diffusion changed closed-room oxygen beyond its trace-sink bound ([oxygen_before] -> [oxygen_after]).")

/datum/unit_test/dogmos_gas_fdm_golden/Destroy()
	restore_atmos()
	return ..()

#undef DOGMOS_FDM_TEST_STAGE
