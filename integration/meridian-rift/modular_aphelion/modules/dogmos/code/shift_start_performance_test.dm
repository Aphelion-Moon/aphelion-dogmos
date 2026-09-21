/**
 * Opt-in first-three-minute observation on the real loaded map.
 * RIFT supplies a fixed UNIT_TESTS seed and starts actual gameplay. No test gases or
 * workloads are injected. Test-build overhead must be matched in control runs.
 */
/datum/unit_test/dogmos_shift_start_performance

/** Diagnostic variant with separate initialization and gameplay BYOND procedure profiles. */
/datum/unit_test/dogmos_shift_start_performance/profile

/datum/controller/subsystem/dogmos
	/// TRUE after the focused sampler observes three wall-clock minutes of gameplay.
	var/shift_start_performance_complete = FALSE
	/// Number of gameplay samples, without retaining a history in DreamDaemon memory.
	var/shift_start_performance_samples = 0
	/// Whether atmosphere processing became unavailable during the measured gameplay window.
	var/shift_start_performance_failed = FALSE

/** Records cheap counters and sparse turf identities from initialization through gameplay. */
/datum/controller/subsystem/dogmos/proc/record_shift_start_performance()
	var/output = "[GLOB.log_directory]/dogmos-performance.jsonl"
	var/start_wall = REALTIMEOFDAY
	var/round_wall
	var/sample_index = 0
	// Focusing the parent also focuses its children through inherited test_flags.
	// Only a separately focused diagnostic subtype should enable profiling overhead.
	var/list/focused_tests = GLOB.focused_tests
	var/profile_procs = !focused_tests?.Find(/datum/unit_test/dogmos_shift_start_performance) \
		&& focused_tests?.Find(/datum/unit_test/dogmos_shift_start_performance/profile)
	if(profile_procs)
		world.Profile(PROFILE_RESTART)
	while(!shift_start_performance_complete)
		var/current_wall = REALTIMEOFDAY
		var/playing = SSticker.current_state == GAME_STATE_PLAYING
		if(playing && isnull(round_wall))
			round_wall = current_wall
			if(profile_procs)
				file("[GLOB.log_directory]/dogmos-initialization-profile.json") << world.Profile(PROFILE_REFRESH, format = "json")
				world.Profile(PROFILE_RESTART)
		var/list/sample = list(
			"utc" = rustg_unix_timestamp(),
			"elapsed_seconds" = (current_wall - start_wall) / 10,
			"shift_seconds" = isnull(round_wall) ? null : (current_wall - round_wall) / 10,
			"state" = SSticker.current_state,
			"seed" = num2text(Master.random_seed, 20),
			"procedure_profiling" = !!profile_procs,
			"map" = SSmapping.current_map?.map_name,
			"world_time" = world.time,
			"z_levels" = world.maxz,
			"round_start_time" = SSticker.round_start_time,
			"air_cycles" = SSair.times_fired,
			"active_turfs" = length(SSair.active_turfs),
			"walk_cursor" = SSair.active_turfs_walk_cursor,
			"current_part" = SSair.currentpart,
			"stage_work_limit" = SSair.dogmos_stage_work_limit,
			"pipenets_cost_ms" = SSair.cost_pipenets,
			"machinery_cost_ms" = SSair.cost_atmos_machinery,
			"rebuild_cost" = SSair.cost_rebuilds,
			"adjacency_cost" = SSair.cost_adjacent,
			"turf_cost_ms" = SSair.cost_turfs,
			"groups_cost_ms" = SSair.cost_groups,
			"equalize_cost_ms" = SSair.cost_equalize,
			"pending_stage" = SSair.dogmos_pending_stage,
			"remaining_work" = SSair.dogmos_stage_remaining_estimate,
			"cache_misses" = dogmos_mixture_cache_misses,
			"cache_hits" = dogmos_mixture_cache_hits,
			"cache_collisions" = dogmos_mixture_cache_collisions,
			"topology_calls" = dogmos_runtime_topology_calls,
			"service_ready" = service_ready,
			"async_stages" = SSair.dogmos_async_stages,
		)
		// One diagnostic RPC per sample, in both cohorts. Raw counter words retain exact values.
		if(service_ready)
			sample["job_observations"] = dogmos_job_observations_snapshot()
		if(sample_index % 10 == 0)
			var/list/locations = list()
			for(var/turf/active as anything in SSair.active_turfs.Copy(1, min(17, length(SSair.active_turfs) + 1)))
				if(!active)
					continue
				locations += list(list("x" = active.x, "y" = active.y, "z" = active.z, "type" = "[active.type]"))
			sample["active_locations"] = locations
		if(playing)
			shift_start_performance_samples++
			if(!service_ready || !SSair.can_fire || service_failure_latched)
				shift_start_performance_failed = TRUE
			if(current_wall - round_wall >= 3 MINUTES)
				shift_start_performance_complete = TRUE
		sample["complete"] = shift_start_performance_complete
		file(output) << json_encode(sample)
		sample_index++
		if(current_wall - start_wall > 15 MINUTES)
			shift_start_performance_failed = TRUE
			break
		sleep(1 SECONDS)
	if(profile_procs)
		file("[GLOB.log_directory]/dogmos-gameplay-profile.json") << world.Profile(PROFILE_REFRESH, format = "json")
		world.Profile(PROFILE_STOP)

/datum/unit_test/dogmos_shift_start_performance/Run()
	var/list/focused_tests = GLOB.focused_tests
	if(!focused_tests?.Find(type))
		return
	var/deadline = REALTIMEOFDAY + 5 MINUTES
	while(!SSdogmos.shift_start_performance_complete && REALTIMEOFDAY < deadline)
		sleep(1 SECONDS)
	if(!SSdogmos.shift_start_performance_complete)
		return Fail("Three minutes of gameplay were not recorded.", __FILE__, __LINE__)
	if(SSdogmos.shift_start_performance_samples < 30)
		return Fail("Too few gameplay samples; inspect scheduling stalls.", __FILE__, __LINE__)
	if(SSdogmos.shift_start_performance_failed)
		return Fail("Atmosphere processing became unavailable during measurement.", __FILE__, __LINE__)
