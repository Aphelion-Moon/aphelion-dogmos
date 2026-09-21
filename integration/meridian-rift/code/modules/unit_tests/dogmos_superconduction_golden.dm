/// Finite stand-in for the test room's heat_capacity, which is INFINITY (inherited from base /turf -
/// neither /turf/open/indestructible nor /turf/closed/indestructible overrides it). Rust's
/// get_share_energy() computes (c1*c2)/(c1+c2), which is INF/INF = NaN for two infinite capacities, so
/// a test using the room's stock values would measure the NaN path rather than real conduction. Value
/// mirrors /turf/open/floor's real 20000.
#define SUPERCONDUCTION_TEST_HEAT_CAPACITY 20000

/**
 * The real correctness check for the SSAIR_SUPERCONDUCTIVITY cutover to Rust's turf-to-turf heat
 * conduction (process_turf_heat, aphelion-dogmos src/turfs/superconduct.rs, driven from
 * SSair.process_super_conductivity(), code/controllers/subsystem/air.dm). Checks the same class of
 * physical invariant dogmos_gas_fdm_golden.dm checks for gas diffusion: heat flows hot -> cold, and
 * conduction doesn't overshoot into reversing which turf is hotter.
 *
 * Setting blocks_air on turf_b is the whole point of the setup, not incidental. Superconduction moves
 * heat where gas CANNOT flow, so two gas-adjacent turfs deliberately get no heat edge at all:
 * /turf/open/conductivity_directions() returns only directions whose neighbor is absent from
 * atmos_adjacent_turfs, and sync_dogmos_adjacency() (LINDA_system.dm) then stores the INVERSE of that
 * as conductivity_blocked_directions, which is what Rust builds its heat graph from
 * (ALL_CARDINALS_MULTIZ - blocked_dirs). A plain adjacent pair - which is exactly what
 * allocate_turf_pair() guarantees, since it asserts gas-adjacency - therefore can never conduct, and an
 * earlier version of this test that used one failed for precisely that reason. Marking turf_b
 * blocks_air breaks gas adjacency, which is what CREATES the heat edge:
 * * immediate_calculate_adjacent_turfs() drops turf_b from turf_a's atmos_adjacent_turfs (its
 *   `!(blocks_air || current_turf.blocks_air)` branch), so that direction becomes non-gas-adjacent and
 *   is left out of turf_a's conductivity_blocked_directions.
 * * turf_b, being blocks_air, takes /turf/open/conductivity_directions()'s `return ..()` branch to the
 *   base /turf version (ALL_CARDINALS), so nothing is blocked for it and the reverse edge exists too.
 * * Both keep init_air = TRUE and so both still register - closed turfs would NOT, since /turf/closed
 *   sets init_air = FALSE and register_dogmos_air() early-returns on that, which is why this can't
 *   simply test against a real wall.
 * This mirrors dogmos_turf_registration.dm's own blocks_air case, which exists to prove heat-only
 * registration works.
 *
 * The live SSair owns frontier publication and resumable stage ordering. The test therefore activates
 * the hot turf and observes bounded live subsystem cycles instead of calling a stage proc directly.
 */
/datum/unit_test/dogmos_superconduction_golden

/datum/unit_test/dogmos_superconduction_golden/Run()
	// The unit-test z-level is loaded lazily by /datum/unit_test/New(), which only QUEUES its turfs
	// into SSair.adjacent_rebuild; SSair drains that across many MC_TICK_CHECK-bounded fire() cycles.
	// Any turf we resync while that queue is still live gets its heat edge recomputed out from under
	// us by immediate_calculate_adjacent_turfs(). Let SSair finish before we touch topology. The bound
	// is generous on purpose - the queue is a whole z-level drained under a tick budget shared with the
	// rest of SSair, so a small one flakes on a loaded runner.
	for(var/attempt in 1 to 200)
		if(!length(SSair.adjacent_rebuild))
			break
		sleep(SSair.wait)
	TEST_ASSERT(!length(SSair.adjacent_rebuild), \
		"SSair.adjacent_rebuild still holds [length(SSair.adjacent_rebuild)] turfs after waiting; the lazy-loaded test z-level has not settled and any heat edge we build will be recomputed away.")

	var/list/pair = allocate_turf_pair()
	var/turf/open/turf_a = pair[1]
	var/turf/open/turf_b = pair[2]

	turf_a.heat_capacity = SUPERCONDUCTION_TEST_HEAT_CAPACITY
	turf_b.heat_capacity = SUPERCONDUCTION_TEST_HEAT_CAPACITY
	turf_b.blocks_air = TRUE
	resync_turf_for_dogmos(turf_a)
	resync_turf_for_dogmos(turf_b)

	TEST_ASSERT(!(turf_b in turf_a.atmos_adjacent_turfs), \
		"turf_b is still gas-adjacent to turf_a after being marked blocks_air - the heat edge this test depends on only exists for NON-gas-adjacent neighbors, so the setup did not take.")
	TEST_ASSERT(!(turf_a.conductivity_blocked_directions & EAST) && !(turf_b.conductivity_blocked_directions & WEST), \
		"The test pair's directional conductivity masks do not expose a reciprocal east-west heat edge.")

	for(var/attempt in 1 to 20)
		if(!length(SSair.adjacent_rebuild) && !SSair.dogmos_pending_frontier_epoch && SSdogmos.flush_turf_registration_batch())
			break
		sleep(SSair.wait)
	// SSair.adjacent_rebuild is re-checked here, not just above: a re-queue landing between setup and
	// seeding would silently net our heat edge back to disconnected, which is exactly the failure mode
	// the Dogmos-side pending dicts have no visibility into.
	TEST_ASSERT(!length(SSdogmos.dogmos_pending_turf_heat) && !length(SSdogmos.dogmos_pending_turf_heat_adjacency) && !length(SSair.adjacent_rebuild), \
		"The test pair's heat topology did not reach dogmosd before temperature seeding (SSair.adjacent_rebuild: [length(SSair.adjacent_rebuild)]).")
	turf_a.set_temperature(700)
	turf_b.set_temperature(T20C)
	SSair.remove_from_active(turf_a)
	SSair.remove_from_active(turf_b)
	SSair.add_to_active(turf_a)
	SSair.add_to_active(turf_b)

	var/a_before = turf_a.dogmos_heat_temperature()
	var/b_before = turf_b.dogmos_heat_temperature()
	TEST_ASSERT(a_before > b_before, \
		"Seeding turf_a at 700K and turf_b at T20C did not produce an asymmetric pair ([a_before] vs [b_before]) - test setup is broken, not the thing under test.")

	var/a_after = a_before
	var/b_after = b_before
	// APHELION EDIT ADDITION START - DOGMOS
	var/list/progress_samples = list()
	SSair.dogmos_stage_test_samples = list()
	// APHELION EDIT ADDITION END
	for(var/attempt in 1 to 20)
		sleep(SSair.wait)
		a_after = turf_a.dogmos_heat_temperature()
		b_after = turf_b.dogmos_heat_temperature()
		// APHELION EDIT ADDITION START - DOGMOS
		progress_samples += list(list(
			"world_time" = world.time,
			"air_cycles" = SSair.times_fired,
			"part" = SSair.currentpart,
			"active" = length(SSair.active_turfs),
			"walk" = SSair.active_turfs_walk_cursor,
			"snapshot" = length(SSair.dogmos_visual_refresh_batch),
			"prefetch" = SSair.dogmos_walk_prefetch_end,
			"visual" = SSair.dogmos_visual_refresh_cursor,
			"adjacency" = length(SSair.adjacent_rebuild),
			"current_run" = length(SSair.currentrun),
			"stage" = SSair.dogmos_pending_stage,
			"remaining" = SSair.dogmos_stage_remaining_estimate,
			"fdm_steps" = SSair.dogmos_fdm_steps_completed,
			"allocation" = SSair.tick_allocation_last,
			"hot" = a_after,
			"cold" = b_after,
		))
		// APHELION EDIT ADDITION END
		if(a_after != a_before && b_after != b_before)
			break
	// APHELION EDIT ADDITION START - DOGMOS
	file("[GLOB.log_directory]/dogmos-superconduction-progress.json") << json_encode(progress_samples)
	file("[GLOB.log_directory]/dogmos-stage-budget.json") << json_encode(SSair.dogmos_stage_test_samples)
	SSair.dogmos_stage_test_samples = null
	// APHELION EDIT ADDITION END

	TEST_ASSERT(a_after < a_before, \
		"turf_a's temperature ([a_before] -> [a_after]) did not decrease after conducting with cooler turf_b (cost_superconductivity [SSair.cost_superconductivity]) - heat is not flowing out of the hotter turf.")
	TEST_ASSERT(b_after > b_before, \
		"turf_b's temperature ([b_before] -> [b_after]) did not increase after conducting with hotter turf_a - heat is not flowing into the cooler turf.")
	TEST_ASSERT(a_after > b_after, \
		"turf_a's temperature ([a_after]) dropped to or below turf_b's ([b_after]) after conduction - this should not overshoot past equilibrium.")

/datum/unit_test/dogmos_superconduction_golden/Destroy()
	// Unconditional, matching dogmos_turf_registration.dm's convention: a TEST_ASSERT abort in Run()
	// skips any cleanup there, and blocks_air/heat_capacity are persistent turf state every later test
	// would inherit. restore_atmos() does not cover either of them.
	var/turf/open/turf_a = run_loc_floor_bottom_left
	if(istype(turf_a))
		var/turf/open/turf_b = get_step(turf_a, EAST)
		turf_a.heat_capacity = initial(turf_a.heat_capacity)
		turf_a.set_temperature(T20C)
		resync_turf_for_dogmos(turf_a)
		if(istype(turf_b))
			turf_b.blocks_air = initial(turf_b.blocks_air)
			turf_b.heat_capacity = initial(turf_b.heat_capacity)
			turf_b.set_temperature(T20C)
			resync_turf_for_dogmos(turf_b)
	return ..()

#undef SUPERCONDUCTION_TEST_HEAT_CAPACITY
