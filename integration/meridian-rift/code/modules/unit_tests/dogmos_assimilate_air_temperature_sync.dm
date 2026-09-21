/** Verifies that ChangeTurf assimilation synchronizes Dogmos' gas and heat temperatures. */
/datum/unit_test/dogmos_assimilate_air_temperature_sync

/datum/unit_test/dogmos_assimilate_air_temperature_sync/Run()
	var/list/pair = allocate_turf_pair()
	var/turf/open/turf_a = pair[1]
	var/turf/open/turf_b = pair[2]

	turf_a.heat_capacity = 20000
	turf_a.air.set_temperature(1000)

	var/turf_a_temp_immediately_after_seeding = turf_a.air.return_temperature()

	var/turf_b_type = turf_b.type
	var/turf/open/new_turf_b = turf_b.ChangeTurf(turf_b_type, null, CHANGETURF_RECALC_ADJACENT)
	TEST_ASSERT(istype(new_turf_b), \
		"ChangeTurf to [turf_b_type] did not produce an open turf - test setup is broken, not the thing under test.")
	TEST_ASSERT(turf_a_temp_immediately_after_seeding > 999, \
		"turf_a's gas mixture temperature right after air.set_temperature(1000) and BEFORE any ChangeTurf call was already [turf_a_temp_immediately_after_seeding]K, not ~1000K - test setup is broken before the thing under test even starts.")

	var/gas_temp = new_turf_b.air.return_temperature()
	var/heat_graph_temp = new_turf_b.return_temperature()

	TEST_ASSERT(gas_temp > T20C + 1, \
		"The reset turf's gas mixture temperature ([gas_temp]K) never picked up any heat from its 1000K neighbor (adjacent_count=[LAZYLEN(new_turf_b.atmos_adjacent_turfs)], turf_a_in_list=[(turf_a in new_turf_b.atmos_adjacent_turfs)], turf_a_air_temp=[turf_a.air.return_temperature()]) - test setup is broken (Assimilate_Air() isn't running or isn't finding turf_a as a neighbor), not the thing under test.")
	TEST_ASSERT(abs(gas_temp - heat_graph_temp) < 1, \
		"The reset turf's gas mixture temperature ([gas_temp]K) and its own heat-graph temperature ([heat_graph_temp]K) disagree by more than 1K after Assimilate_Air() - the turf-level heat-graph copy isn't being synced to match the assimilated gas temperature.")

/datum/unit_test/dogmos_assimilate_air_temperature_sync/Destroy()
	var/turf/open/turf_a = run_loc_floor_bottom_left
	if(istype(turf_a))
		turf_a.heat_capacity = initial(turf_a.heat_capacity)
		turf_a.air.set_temperature(T20C)
		turf_a.set_temperature(T20C)
	restore_atmos()
	return ..()
