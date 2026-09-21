/**
 * Opt-in first-three-minute observer shared by the Dogmos checkout and a clean
 * no-Dogmos checkout. The comparison wrapper includes this file in a run-owned
 * scratch DME, so neither repository's tracked source is changed.
 */

/// Read a metric only when the host checkout provides the named variable.
/proc/dogmos_baseline_optional_var(datum/target, variable_name)
	if(!target || !target.vars || !(variable_name in target.vars))
		return null
	return target.vars[variable_name]

/** Starts before map atom construction and records without firing as a regular subsystem. */
SUBSYSTEM_DEF(dogmos_shared_observer)
	name = "Shared baseline observer"
	init_stage = INITSTAGE_EARLY
	ss_flags = SS_NO_FIRE
	dependents = list(
		/datum/controller/subsystem/mapping,
		/datum/controller/subsystem/atoms,
	)

	var/observation_start_wall
	var/round_start_wall
	var/output_path
	var/sample_count = 0
	var/gameplay_sample_count = 0
	var/complete = FALSE
	var/failed = FALSE

/datum/controller/subsystem/dogmos_shared_observer/Initialize()
	observation_start_wall = REALTIMEOFDAY
	INVOKE_ASYNC(src, PROC_REF(run_observation))
	return SS_INIT_SUCCESS

/datum/controller/subsystem/dogmos_shared_observer/proc/run_observation()
	set waitfor = FALSE
	var/start_deadline = observation_start_wall + 20 MINUTES
	while(!GLOB.log_directory && REALTIMEOFDAY < start_deadline)
		sleep(1 SECONDS)
	if(!GLOB.log_directory)
		failed = TRUE
		return

	output_path = "[GLOB.log_directory]/dogmos-performance.jsonl"
	while(!complete && REALTIMEOFDAY < start_deadline)
		if(isnull(round_start_wall) && SSticker?.current_state == GAME_STATE_PLAYING)
			round_start_wall = REALTIMEOFDAY
		if(!isnull(round_start_wall) && SSticker?.current_state != GAME_STATE_PLAYING)
			failed = TRUE
			return
		if(!isnull(round_start_wall) && (!SSair || !SSair.can_fire))
			failed = TRUE
			return
		var/complete_sample = record_sample(output_path, round_start_wall, sample_count)
		sample_count++
		if(SSticker?.current_state == GAME_STATE_PLAYING)
			gameplay_sample_count++
		complete = complete_sample
		if(!complete)
			sleep(1 SECONDS)
	if(!complete)
		failed = TRUE

/// Write one sample without requiring Dogmos-specific globals or procs.
/datum/controller/subsystem/dogmos_shared_observer/proc/record_sample(output, round_wall, sample_index)
	var/current_wall = REALTIMEOFDAY
	var/elapsed_seconds = (current_wall - observation_start_wall) / 10
	var/shift_seconds = isnull(round_wall) ? null : (current_wall - round_wall) / 10
	var/list/active_turfs = dogmos_baseline_optional_var(SSair, "active_turfs")
	var/seed = dogmos_baseline_optional_var(Master, "random_seed")
	var/list/sample = list(
		"utc" = rustg_unix_timestamp(),
		"elapsed_seconds" = elapsed_seconds,
		"shift_seconds" = shift_seconds,
		"state" = SSticker?.current_state,
		"seed" = isnull(seed) ? "unknown" : num2text(seed, 20),
		"map" = SSmapping.current_map?.map_name,
		"world_time" = world.time,
		"z_levels" = world.maxz,
		"round_start_time" = SSticker?.round_start_time,
		"air_cycles" = dogmos_baseline_optional_var(SSair, "times_fired"),
		"active_turfs" = islist(active_turfs) ? length(active_turfs) : null,
		"walk_cursor" = dogmos_baseline_optional_var(SSair, "active_turfs_walk_cursor"),
		"current_part" = dogmos_baseline_optional_var(SSair, "currentpart"),
		"adjacency_queue" = length(dogmos_baseline_optional_var(SSair, "adjacent_rebuild")),
		"pipe_rebuild_queue" = length(dogmos_baseline_optional_var(SSair, "rebuild_queue")),
		"pipe_expansion_queue" = length(dogmos_baseline_optional_var(SSair, "expansion_queue")),
		"currentrun_remaining" = length(dogmos_baseline_optional_var(SSair, "currentrun")),
		"stage_work_limit" = dogmos_baseline_optional_var(SSair, "dogmos_stage_work_limit"),
		"pipenets_cost_ms" = dogmos_baseline_optional_var(SSair, "cost_pipenets"),
		"machinery_cost_ms" = dogmos_baseline_optional_var(SSair, "cost_atmos_machinery"),
		"rebuild_cost" = dogmos_baseline_optional_var(SSair, "cost_rebuilds"),
		"adjacency_cost" = dogmos_baseline_optional_var(SSair, "cost_adjacent"),
		"turf_cost_ms" = dogmos_baseline_optional_var(SSair, "cost_turfs"),
		"groups_cost_ms" = dogmos_baseline_optional_var(SSair, "cost_groups"),
		"equalize_cost_ms" = dogmos_baseline_optional_var(SSair, "cost_equalize"),
		"pending_stage" = dogmos_baseline_optional_var(SSair, "dogmos_pending_stage"),
		"remaining_work" = dogmos_baseline_optional_var(SSair, "dogmos_stage_remaining_estimate"),
		"procedure_profiling" = null,
		"diagnostic_procedure_profiling" = FALSE,
		"complete" = !isnull(shift_seconds) && shift_seconds >= 180,
	)
	if(!(sample_index % 10) && islist(active_turfs))
		var/list/locations = list()
		for(var/index in 1 to min(17, length(active_turfs)))
			var/turf/active = active_turfs[index]
			if(!active)
				continue
			locations += list(list("x" = active.x, "y" = active.y, "z" = active.z, "type" = "[active.type]"))
		sample["active_locations"] = locations
	file(output) << json_encode(sample)
	return sample["complete"]

/datum/unit_test/dogmos_shared_baseline_observer

/datum/unit_test/dogmos_shared_baseline_observer/Run()
	var/start_deadline = REALTIMEOFDAY + 20 MINUTES
	while(!SSdogmos_shared_observer.complete && !SSdogmos_shared_observer.failed && REALTIMEOFDAY < start_deadline)
		sleep(1 SECONDS)
	if(SSdogmos_shared_observer.failed)
		return Fail("The shared observer failed before completing its observation.", __FILE__, __LINE__)
	if(!SSdogmos_shared_observer.complete)
		return Fail("The shared observer did not complete its 180-second window before its bound.", __FILE__, __LINE__)
	if(SSdogmos_shared_observer.gameplay_sample_count < 30)
		return Fail("The shared observer recorded too few gameplay samples: [SSdogmos_shared_observer.gameplay_sample_count].", __FILE__, __LINE__)
