/** Verifies fixed reservoir temperatures for BYOND's infinite heat-capacity sentinel. */
/datum/unit_test/dogmos_infinite_heat_capacity_conduction

/datum/unit_test/dogmos_infinite_heat_capacity_conduction/Run()
	TEST_ASSERT(dogmos_wait_for_stage_boundary(), "The infinite-capacity fixture did not reach a healthy stage boundary.")
	var/list/pair = allocate_turf_pair()
	TEST_ASSERT_EQUAL(length(pair), 2, "The infinite-capacity fixture needs two adjacent turfs.")
	var/turf/open/turf_a = pair[1]
	var/turf/open/turf_b = pair[2]

	// BYOND's INFINITY is a finite sentinel, so compare it directly rather than with isinf().
	TEST_ASSERT(turf_a.heat_capacity == INFINITY && turf_b.heat_capacity == INFINITY, \
		"The test room's turfs no longer default to infinite heat_capacity ([turf_a.heat_capacity], [turf_b.heat_capacity]) - test setup is broken, not the thing under test (this test specifically needs the infinite-capacity condition to reproduce the bug).")

	// A non-gas-adjacent neighbor creates the heat edge.
	turf_b.blocks_air = TRUE
	resync_turf_for_dogmos(turf_a)
	resync_turf_for_dogmos(turf_b)

	TEST_ASSERT(!(turf_b in turf_a.atmos_adjacent_turfs), \
		"turf_b is still gas-adjacent to turf_a after being marked blocks_air - the heat edge this test depends on only exists for NON-gas-adjacent neighbors, so the setup did not take.")
	TEST_ASSERT(!(turf_a.conductivity_blocked_directions & EAST) && !(turf_b.conductivity_blocked_directions & WEST), "The infinite-capacity fixture needs a reciprocal heat edge.")

	// First prove this exact edge conducts. An unchanged infinite pair alone also
	// passes when its heat edge is missing or the stage does no work.
	turf_a.heat_capacity = 20000
	turf_b.heat_capacity = 20000
	resync_turf_for_dogmos(turf_a)
	resync_turf_for_dogmos(turf_b)
	turf_a.set_temperature(1500)
	// Other heat neighbors remain at room temperature; do not let them cool the
	// control's cold turf and hide the transfer from A.
	turf_b.set_temperature(T20C)
	turf_a.air.set_temperature(1500)
	turf_b.air.set_temperature(T20C)
	TEST_ASSERT(dogmos_run_fixture_stage(3, pair), "The finite-capacity control did not finish.")
	TEST_ASSERT(turf_a.dogmos_heat_temperature() < 1500 && turf_b.dogmos_heat_temperature() > T20C, "The finite-capacity control did not transfer heat across the fixture edge.")

	// Infinite capacities are fixed reservoirs in the native contract. They must
	// retain both temperatures, not conduct via the old overflowing inf/inf path.
	turf_a.heat_capacity = INFINITY
	turf_b.heat_capacity = INFINITY
	resync_turf_for_dogmos(turf_a)
	resync_turf_for_dogmos(turf_b)
	turf_a.set_temperature(1500)
	turf_b.set_temperature(1000)
	// Equal gas/turf temperatures exclude ordinary gas coupling from the fixture.
	turf_a.air.set_temperature(1500)
	turf_b.air.set_temperature(1000)

	// Finish each native stage before another stage or teardown can mutate the same turfs.
	for(var/attempt in 1 to 10)
		TEST_ASSERT(dogmos_run_fixture_stage(3, pair), "The infinite-capacity heat stage did not finish within the fixture bound.")
		var/step_a = turf_a.dogmos_heat_temperature()
		var/step_b = turf_b.dogmos_heat_temperature()
		TEST_ASSERT(!isnull(step_a) && !isnan(step_a) && abs(step_a - 1500) < 0.01, "The hot infinite reservoir changed temperature or became invalid at step [attempt]: [step_a].")
		TEST_ASSERT(!isnull(step_b) && !isnan(step_b) && abs(step_b - 1000) < 0.01, "The cold infinite reservoir changed temperature or became invalid at step [attempt]: [step_b].")

/datum/unit_test/dogmos_infinite_heat_capacity_conduction/Destroy()
	if(dogmos_fixture_aborted)
		return ..()
	// Unconditional, matching dogmos_superconduction_golden.dm's convention: a TEST_ASSERT abort in
	// Run() skips its own restore, and blocks_air/temperature are persistent turf state every later
	// test would inherit.
	var/turf/open/turf_a = run_loc_floor_bottom_left
	if(istype(turf_a))
		var/turf/open/turf_b = get_step(turf_a, EAST)
		turf_a.heat_capacity = initial(turf_a.heat_capacity)
		turf_a.set_temperature(T20C)
		resync_turf_for_dogmos(turf_a)
		if(istype(turf_b))
			turf_b.heat_capacity = initial(turf_b.heat_capacity)
			turf_b.blocks_air = initial(turf_b.blocks_air)
			turf_b.set_temperature(T20C)
			resync_turf_for_dogmos(turf_b)
	return ..()
