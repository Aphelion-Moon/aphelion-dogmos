#if defined(UNIT_TESTS) || defined(SPACEMAN_DMM)
#define DOGMOS_FAILURE_FENCE_STAGE 4

/** Fixed snapshots may retain a turf that no longer has open-turf fields. */
/datum/unit_test/dogmos_walk_prefetch_closed_turf/Run()
	var/turf/open/interior = run_loc_floor_bottom_left
	var/turf/boundary = get_step(interior, WEST)
	if(!interior.air || !boundary || isopenturf(boundary))
		return Fail("The stale-snapshot fixture needs an open interior and a closed room boundary.", __FILE__, __LINE__)
	var/list/original_neighbors = interior.atmos_adjacent_turfs
	var/failure
	try
		// Exercise both a stale snapshot entry and a stale neighbor reference.
		interior.atmos_adjacent_turfs = list(boundary)
		SSair.dogmos_prefetch_walk_snapshots(list(boundary, interior))
	catch(var/exception/error)
		failure = "Prefetch accessed open-turf fields on a closed snapshot entry: [error.name]."
	interior.atmos_adjacent_turfs = original_neighbors
	if(failure)
		return Fail(failure, __FILE__, __LINE__)

/datum/unit_test/dogmos_active_walk_failure_fence
	var/list/exposure_count
	var/failed_once = FALSE

/datum/unit_test/dogmos_active_walk_failure_fence/proc/fail_from_exposure(turf/source)
	SIGNAL_HANDLER
	exposure_count[source]++
	if(!failed_once)
		failed_once = TRUE
		SSair.dogmos_fail_closed_stage(DOGMOS_FAILURE_FENCE_STAGE, FALSE)

/datum/unit_test/dogmos_active_walk_failure_fence/proc/count_exposure(turf/source)
	SIGNAL_HANDLER
	exposure_count[source]++

/datum/unit_test/dogmos_active_walk_failure_fence/proc/frontier_matches(list/before, list/after)
	if(isnull(before) || isnull(after))
		return isnull(before) && isnull(after)
	if(!islist(after) || length(before) != length(after))
		return FALSE
	for(var/turf/fixture_turf in before)
		var/list/before_pair = before[fixture_turf]
		var/list/after_pair = after[fixture_turf]
		if(!islist(before_pair) || !islist(after_pair) || length(before_pair) != length(after_pair))
			return FALSE
		for(var/index in 1 to length(before_pair))
			if(before_pair[index] != after_pair[index])
				return FALSE
	return TRUE

/datum/unit_test/dogmos_active_walk_failure_fence/proc/frontier_copy(list/frontier)
	if(isnull(frontier))
		return null
	var/list/result = list()
	for(var/turf/fixture_turf in frontier)
		var/list/pair = frontier[fixture_turf]
		result[fixture_turf] = islist(pair) ? pair.Copy() : pair
	return result

/datum/unit_test/dogmos_active_walk_failure_fence/Run()
	if(!dogmos_wait_for_stage_boundary())
		return

	var/list/pair = allocate_turf_pair()
	if(!islist(pair) || length(pair) != 2)
		return Fail("The failure-fence fixture needs exactly two real turfs.", __FILE__, __LINE__)
	var/turf/open/first = pair[1]
	var/turf/open/second = pair[2]
	if(!istype(first) || !istype(second) || !first.air || !second.air)
		return Fail("The failure-fence fixture did not receive two live open turfs with gas.", __FILE__, __LINE__)
	if(!first.dogmos_air_registration_is_current() || !second.dogmos_air_registration_is_current())
		return Fail("The failure-fence fixture did not receive current native gas registrations.", __FILE__, __LINE__)

	var/list/saved_fields = list()
	for(var/field in list(
		"active_turfs", "currentrun", "state", "can_fire",
		"active_turfs_walk_cursor", "dogmos_visual_refresh_batch",
		"dogmos_visual_refresh_cursor", "dogmos_active_walk_complete",
		"dogmos_active_turf_stages_complete", "dogmos_equalize_stage_complete",
		"dogmos_fdm_steps_completed", "high_pressure_delta",
		"dogmos_pending_stage", "dogmos_pending_frontier_epoch",
		"dogmos_stage_remaining_estimate", "dogmos_stage_test_samples", "dogmos_resume_recovered_cycle",
		"dogmos_reacted_turfs", "dogmos_walk_prefetch_end", "dogmos_visual_prefetch_end"))
		saved_fields[field] = SSair.vars[field]

	// These are accepted native state. Save copies for comparison only; never restore them.
	var/list/saved_frontier_epoch = SSair.dogmos_frontier_epoch.Copy()
	var/list/saved_stage_epoch = islist(SSair.dogmos_stage_epoch) ? SSair.dogmos_stage_epoch.Copy() : null
	var/list/saved_committed_frontier = frontier_copy(SSair.dogmos_committed_frontier)
	var/list/saved_pending_frontier = islist(SSair.dogmos_pending_frontier_epoch) ? SSair.dogmos_pending_frontier_epoch.Copy() : null
	var/saved_pending_stage = SSair.dogmos_pending_stage
	if(saved_pending_stage || length(saved_pending_frontier))
		return dogmos_abort_fixture("The failure-fence fixture did not start at a native stage boundary.")

	var/saved_service_ready = SSdogmos.service_ready
	var/saved_failure_latched = SSdogmos.service_failure_latched
	var/saved_shutdown_requested = SSdogmos.service_shutdown_requested
	var/saved_pending_callback_count = SSdogmos.dogmos_pending_callback_count
	var/saved_stale_callback_count = SSdogmos.dogmos_stale_callback_count
	var/saved_tick_limit = Master.current_ticklimit
	var/list/saved_turf_state = list()
	for(var/turf/open/fixture_turf as anything in pair)
		saved_turf_state[fixture_turf] = list(
			fixture_turf.atmos_adjacent_turfs, fixture_turf.excited, fixture_turf.excited_group,
			fixture_turf.current_cycle, fixture_turf.archived_cycle,
			fixture_turf.pressure_difference, fixture_turf.pressure_direction)

	exposure_count = list()
	exposure_count[first] = 0
	exposure_count[second] = 0
	failed_once = FALSE
	var/first_signal_registered = FALSE
	var/second_signal_registered = FALSE
	var/failure
	var/restore_allowed = FALSE

	try
		RegisterSignal(first, COMSIG_TURF_EXPOSE, PROC_REF(fail_from_exposure))
		first_signal_registered = TRUE
		RegisterSignal(second, COMSIG_TURF_EXPOSE, PROC_REF(count_exposure))
		second_signal_registered = TRUE

		SSair.dogmos_replace_active_frontier(pair.Copy())
		SSair.currentrun = list()
		SSair.high_pressure_delta = list()
		SSair.active_turfs_walk_cursor = 0
		SSair.dogmos_visual_refresh_batch = pair.Copy()
		SSair.dogmos_visual_refresh_cursor = 0
		SSair.dogmos_active_walk_complete = FALSE
		SSair.dogmos_active_turf_stages_complete = FALSE
		SSair.dogmos_fdm_steps_completed = 0
		SSair.dogmos_stage_remaining_estimate = 0
		SSair.dogmos_stage_test_samples = list()
		for(var/turf/open/fixture_turf as anything in pair)
			fixture_turf.excited = TRUE
			fixture_turf.excited_group = null
			fixture_turf.archived_cycle = SSair.times_fired

		SSair.state = SS_RUNNING
		Master.current_ticklimit = TICK_USAGE + max(1, 100 / world.tick_lag)
		SSair.process_active_turfs(FALSE)

		if(!failed_once || exposure_count[first] != 1)
			failure = "COMSIG_TURF_EXPOSE did not fail closed exactly once on the first real turf."
		else if(exposure_count[second] != 0)
			failure = "The second real turf was exposed after the failure fence fired."
		else if(SSair.can_fire || SSdogmos.service_ready || !SSdogmos.service_failure_latched)
			failure = "The failure fence did not leave SSair and the service unavailable."
		else if(SSair.dogmos_active_walk_complete || SSair.dogmos_active_turf_stages_complete || SSair.dogmos_equalize_stage_complete || SSair.dogmos_fdm_steps_completed || length(SSair.dogmos_visual_refresh_batch) || SSair.active_turfs_walk_cursor || SSair.dogmos_visual_refresh_cursor || SSair.dogmos_walk_prefetch_end || SSair.dogmos_visual_prefetch_end)
			failure = "The failure fence left active-walk snapshot state usable after closing the service."
		else if(!isnull(SSair.dogmos_pending_stage) || !isnull(SSair.dogmos_pending_frontier_epoch))
			failure = "The failure fence left a native stage or frontier pending."
		else if(!SSdogmos.equal_u64_words(SSair.dogmos_frontier_epoch, saved_frontier_epoch) || !SSdogmos.equal_u64_words(SSair.dogmos_stage_epoch, saved_stage_epoch))
			failure = "The failure callback changed an accepted native epoch before frontier publication."
		else if(!frontier_matches(saved_committed_frontier, SSair.dogmos_committed_frontier))
			failure = "The failure callback changed the committed native frontier before publication."
		else if(length(SSair.dogmos_stage_test_samples))
			failure = "A native stage ran after the exposure failure fence."
		else if(SSdogmos.dogmos_pending_callback_count != saved_pending_callback_count || SSdogmos.dogmos_stale_callback_count != saved_stale_callback_count)
			failure = "Callback bookkeeping changed after the failure fence."
	catch(var/exception/error)
		failure = "The failure-fence walk raised [error.name] after its snapshot was cleared."

	var/native_epochs_unchanged = SSdogmos.equal_u64_words(SSair.dogmos_frontier_epoch, saved_frontier_epoch) \
		&& SSdogmos.equal_u64_words(SSair.dogmos_stage_epoch, saved_stage_epoch)
	var/committed_frontier_unchanged = frontier_matches(saved_committed_frontier, SSair.dogmos_committed_frontier)
	var/no_pending_native_state = isnull(SSair.dogmos_pending_stage) && isnull(SSair.dogmos_pending_frontier_epoch)
	// Assertion failures and a pure DM indexing exception can be reported after a safe
	// restore when every accepted native value and pending boundary stayed unchanged.
	// Pending state, epoch changes, and frontier changes cannot be repaired by restoring
	// DM variables without hiding an accepted native mutation.
	restore_allowed = native_epochs_unchanged && committed_frontier_unchanged && no_pending_native_state \
		&& !length(SSair.dogmos_stage_test_samples) \
		&& SSdogmos.dogmos_pending_callback_count == saved_pending_callback_count \
		&& SSdogmos.dogmos_stale_callback_count == saved_stale_callback_count

	if(first_signal_registered)
		UnregisterSignal(first, COMSIG_TURF_EXPOSE)
	if(second_signal_registered)
		UnregisterSignal(second, COMSIG_TURF_EXPOSE)

	// No sync/republish is needed: the test proves the accepted epochs and committed
	// frontier never changed. A changed epoch, committed frontier, or pending value is
	// an actual mutation and must remain failed closed rather than being hidden by restore.
	if(!restore_allowed)
		SSair.dogmos_fail_closed_stage("failure-fence unit test", FALSE)
	else
		for(var/field in saved_fields)
			SSair.vars[field] = saved_fields[field]
		SSdogmos.service_ready = saved_service_ready
		SSdogmos.service_failure_latched = saved_failure_latched
		SSdogmos.service_shutdown_requested = saved_shutdown_requested
		Master.current_ticklimit = saved_tick_limit
		SSair.can_fire = saved_fields["can_fire"]

	for(var/turf/open/fixture_turf as anything in pair)
		var/list/turf_state = saved_turf_state[fixture_turf]
		fixture_turf.atmos_adjacent_turfs = turf_state[1]
		fixture_turf.excited = turf_state[2]
		fixture_turf.excited_group = turf_state[3]
		fixture_turf.current_cycle = turf_state[4]
		fixture_turf.archived_cycle = turf_state[5]
		fixture_turf.pressure_difference = turf_state[6]
		fixture_turf.pressure_direction = turf_state[7]
	exposure_count = null

	if(!restore_allowed)
		return dogmos_abort_fixture("The failure-fence fixture could not prove a safe synchronous restoration.")
	if(failure)
		return Fail(failure, __FILE__, __LINE__)

#undef DOGMOS_FAILURE_FENCE_STAGE


#endif
