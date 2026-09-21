/** Verifies that a discovered space neighbor registers and receives diffused gas. */
/datum/unit_test/dogmos_space_boundary_registration
	/// The EAST neighbor's original type, so Destroy() can restore it even if Run() aborts partway
	/// through via a TEST_ASSERT failure.
	var/original_neighbor_type

/datum/unit_test/dogmos_space_boundary_registration/Run()
	var/turf/open/interior = run_loc_floor_bottom_left
	TEST_ASSERT(istype(interior), "run_loc_floor_bottom_left is not an open turf - this test needs one.")

	var/datum/gas_mixture/air_interior = interior.air
	var/before_moles = air_interior.total_moles()
	TEST_ASSERT(before_moles > 0, \
		"The interior test turf has no gas to begin with - test setup is broken, not the thing under test.")

	var/list/conversion = convert_neighbor_to_space(interior)
	var/turf/open/space/vacuum_neighbor = conversion[1]
	original_neighbor_type = conversion[2]

	TEST_ASSERT(vacuum_neighbor.dogmos_air_registration_is_current(register_space_boundary = TRUE), \
		"The real space neighbor did not retain the current shared-boundary mixture identity after registration.")

	SSair.add_to_active(interior)
	var/after_moles = before_moles
	/* // APHELION EDIT REMOVAL START - DOGMOS
	for(var/attempt in 1 to 10)
		sleep(1 SECONDS)
		after_moles = air_interior.total_moles()
		if(after_moles < before_moles)
			break
	TEST_ASSERT(after_moles < before_moles, \
		"The interior turf's total moles ([before_moles] -> [after_moles]) did not decrease across ten real SSair cycles with a registered space neighbor - gas is not actually diffusing into space.")
	*/ // APHELION EDIT REMOVAL END
	// APHELION EDIT ADDITION START - DOGMOS
	// A full-map startup can spend many ticks rebuilding topology before its first fire.
	// Count completed SSair fires; sleeping ten times does not establish ten cycles.
	var/initial_cycle = SSair.times_fired
	var/start_time = world.time
	var/deadline = start_time + 180 SECONDS
	while(SSair.times_fired - initial_cycle < 10 && world.time < deadline)
		sleep(SSair.wait)
		after_moles = air_interior.total_moles()
		if(after_moles < before_moles)
			break
	TEST_ASSERT(after_moles < before_moles, \
		"The interior turf's total moles ([before_moles] -> [after_moles]) did not decrease after [SSair.times_fired - initial_cycle] completed SSair fires over [(world.time - start_time) / (1 SECONDS)] seconds (limits: ten fires or 180 seconds); state: [SSair.state], enabled: [SSair.can_fire], adjacency queue: [length(SSair.adjacent_rebuild)], pending stage: [SSair.dogmos_pending_stage].")
	log_test("Space boundary diffusion: [before_moles] -> [after_moles] moles after [SSair.times_fired - initial_cycle] completed fires over [(world.time - start_time) / (1 SECONDS)] seconds.")
	// APHELION EDIT ADDITION END

	restore_neighbor_from_space(interior, original_neighbor_type)
	original_neighbor_type = null

/datum/unit_test/dogmos_space_boundary_registration/Destroy()
	// Unconditional, not just on success: a TEST_ASSERT abort in Run() skips its own restore and would
	// otherwise leave a real space turf sitting in the test room for every test that runs after this
	// one.
	restore_neighbor_from_space(run_loc_floor_bottom_left, original_neighbor_type)
	restore_atmos()
	return ..()

// APHELION EDIT ADDITION START - DOGMOS
/** Verifies an immutable space frontier entry settles after waking its mutable neighbor. */
/datum/unit_test/dogmos_space_boundary_frontier_settlement
	/// The EAST neighbor's original type, restored even when the test fails.
	var/original_neighbor_type
	/// SSair's active-turf queue before the isolated frontier walk.
	var/list/original_active_turfs
	/// SSair's active-turf walk cursor before the isolated frontier walk.
	var/original_active_turfs_walk_cursor
	/// Whether the mutable interior turf was active before the isolated frontier walk.
	var/original_interior_excited
	/// Whether the immutable space turf was active before the isolated frontier walk.
	var/original_vacuum_excited
	/// Mutable turf that must be activated when the immutable source observes a difference.
	var/turf/open/interior
	/// Immutable frontier source that must leave the active queue after one comparison walk.
	var/turf/open/space/vacuum_neighbor

/datum/unit_test/dogmos_space_boundary_frontier_settlement/Run()
	interior = run_loc_floor_bottom_left
	TEST_ASSERT(istype(interior), "run_loc_floor_bottom_left is not an open turf - this test needs one.")

	var/list/conversion = convert_neighbor_to_space(interior)
	vacuum_neighbor = conversion[1]
	original_neighbor_type = conversion[2]
	original_active_turfs = SSair.active_turfs
	original_active_turfs_walk_cursor = SSair.active_turfs_walk_cursor
	original_interior_excited = interior.excited
	original_vacuum_excited = vacuum_neighbor.excited

	interior.excited = FALSE
	vacuum_neighbor.excited = TRUE
	SSair.dogmos_replace_active_frontier(list(vacuum_neighbor))
	SSair.active_turfs_walk_cursor = 0
	var/list/original_snapshot = SSair.dogmos_visual_refresh_batch
	var/list/original_reacted_turfs = SSair.dogmos_reacted_turfs
	var/original_walk_prefetch_end = SSair.dogmos_walk_prefetch_end
	var/original_visual_prefetch_end = SSair.dogmos_visual_prefetch_end
	var/original_visual_cursor = SSair.dogmos_visual_refresh_cursor
	var/original_state = SSair.state
	var/original_tick_limit = Master.current_ticklimit
	SSair.dogmos_visual_refresh_batch = SSair.active_turfs.Copy()
	SSair.dogmos_reacted_turfs = list()
	SSair.dogmos_walk_prefetch_end = 0
	SSair.dogmos_visual_prefetch_end = 0
	SSair.dogmos_visual_refresh_cursor = 0
	SSair.state = SS_RUNNING
	Master.current_ticklimit = TICK_USAGE + 100 / world.tick_lag
	SSair.walk_active_turfs_batch()
	SSair.refresh_dogmos_visuals()
	SSair.dogmos_visual_refresh_batch = original_snapshot
	SSair.dogmos_reacted_turfs = original_reacted_turfs
	SSair.dogmos_walk_prefetch_end = original_walk_prefetch_end
	SSair.dogmos_visual_prefetch_end = original_visual_prefetch_end
	SSair.dogmos_visual_refresh_cursor = original_visual_cursor
	SSair.state = original_state
	Master.current_ticklimit = original_tick_limit

	var/vacuum_settled = !(vacuum_neighbor in SSair.active_turfs)
	var/interior_activated = (interior in SSair.active_turfs)
	restore_frontier_test_state()

	TEST_ASSERT(vacuum_settled, \
		"An immutable space turf remained in SSair.active_turfs after comparing its mutable neighbor - immutable frontier sources cannot converge and must settle after waking mutable neighbors.")
	TEST_ASSERT(interior_activated, \
		"The mutable interior turf was not activated when an immutable space frontier source observed a gas difference.")

/** Restores the temporary active-turf queue and converted space turf. */
/datum/unit_test/dogmos_space_boundary_frontier_settlement/proc/restore_frontier_test_state()
	if(!isnull(original_active_turfs))
		SSair.dogmos_replace_active_frontier(original_active_turfs)
		SSair.active_turfs_walk_cursor = original_active_turfs_walk_cursor
		original_active_turfs = null
	if(interior)
		interior.excited = original_interior_excited
	if(vacuum_neighbor)
		vacuum_neighbor.excited = original_vacuum_excited
	restore_neighbor_from_space(interior, original_neighbor_type)
	original_neighbor_type = null
	interior = null
	vacuum_neighbor = null

/datum/unit_test/dogmos_space_boundary_frontier_settlement/Destroy()
	restore_frontier_test_state()
	restore_atmos()
	return ..()
// APHELION EDIT ADDITION END
