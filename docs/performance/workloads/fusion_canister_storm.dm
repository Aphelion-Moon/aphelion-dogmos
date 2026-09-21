#include "fusion_damage_regressions.dm"

/** Opt-in full-map diagnostic; included only by run_fusion_profile.ps1. */
SUBSYSTEM_DEF(fusion_profile)
	name = "Fusion diagnostic"
	init_stage = INITSTAGE_LAST
	ss_flags = SS_NO_FIRE
	/// Actual number of scripted canister ruptures.
	var/ruptures = 0
	/// Monotonic-enough wall observation anchor (wrap handled by subtraction helper).
	var/started

/datum/controller/subsystem/fusion_profile/Initialize()
	// This unattended workload has no connected player to wake the world.
	Master.sleep_offline_after_initializations = FALSE
	INVOKE_ASYNC(src, PROC_REF(run_profile))
	return SS_INIT_SUCCESS

/** Owns the diagnostic lifecycle and always terminates this isolated world. */
/datum/controller/subsystem/fusion_profile/proc/run_profile()
	try
		while(SSticker.current_state != GAME_STATE_PLAYING)
			sleep(1 SECONDS)
		SSticker.roundend_check_paused = TRUE
		run_workload()
	catch(var/exception/error)
		file("[GLOB.log_directory]/fusion-failure.json") << json_encode(list("error" = error.name))
	finish_fusion_profile()

/** Use global scope: a subsystem's shutdown() resolves to its inherited Shutdown(). */
/proc/finish_fusion_profile()
	Master.processing = FALSE
	file("[GLOB.log_directory]/fusion-shutdown-start.json") << json_encode(list("native_shutdown_started" = TRUE))
	SSdogmos.Shutdown()
	file("[GLOB.log_directory]/fusion-shutdown-complete.json") << json_encode(list("native_shutdown_complete" = TRUE))
	del(world)

/** Runs the explicitly compiled workload; never included in the game DME. */
/datum/controller/subsystem/fusion_profile/proc/run_workload()
	if(SSmapping.current_map.map_name != "MetaStation")
		CRASH("Full MetaStation required.")
	if(!SSdogmos.gases_registered || !SSair.can_fire)
		CRASH("Atmosphere must be ready.")
	verify_fusion_damage_regressions()
	// The native substage must leave the whole DM phase's cost counter alone.
	// This synchronous probe runs before observation and restores its sentinel.
	var/previous_cost = SSair.cost_turfs
	SSair.cost_turfs = 1234
	SSair.process_turfs_auxtools(0)
	var/probed_cost = SSair.cost_turfs
	SSair.cost_turfs = previous_cost
	if(probed_cost != 1234)
		CRASH("Native FDM overwrote the DM-owned active-turf cost.")
	started = REALTIMEOFDAY
	world.Profile(PROFILE_RESTART)
	var/initial_cycles = SSair.times_fired
	observe("baseline", 30)
	for(var/wave in 1 to 2)
		var/list/sites = list()
		for(var/turf/open/floor/site in world)
			if(is_station_level(site.z) && istype(get_area(site), /area/station/hallway) && !site.density)
				sites += site
		if(length(sites) < 80)
			CRASH("Not enough station hallway floors.")
		var/wave_count = wave == 1 ? 40 : 80
		for(var/index in 1 to wave_count)
			var/turf/site = sites[1 + ((index * 17 + wave * 31) % length(sites))]
			var/obj/machinery/portable_atmospherics/canister/fusion_test/canister = new(site)
			// Use the stock gas inventory and normal rupture path. The scripted blast
			// matches the common 0/0/3 fusion-canister event in the supplied playtests.
			canister.canister_break()
			explosion(canister, devastation_range = 0, heavy_impact_range = 0, light_impact_range = 3)
			ruptures++
			CHECK_TICK
		observe("wave[wave]", 90)
	observe("recovery", 90)
	if(ruptures != 120)
		CRASH("All scripted canisters must rupture.")
	if(SSair.times_fired <= initial_cycles + 10)
		CRASH("Atmosphere cycles did not advance.")
	if(!SSair.can_fire || !SSdogmos.gases_registered)
		CRASH("Atmosphere stopped during the workload.")
	if(dogmos_ffi_panic_count() || dogmos_callback_enqueue_failures())
		CRASH("Native panic or callback enqueue failure during workload.")
	file("[GLOB.log_directory]/fusion-complete.json") << json_encode(list("ruptures" = ruptures, "cycles" = SSair.times_fired - initial_cycles, "elapsed_seconds" = elapsed()))
	world.Profile(PROFILE_STOP)

/** Wall seconds since the workload began, including a midnight wrap. */
/datum/controller/subsystem/fusion_profile/proc/elapsed()
	return ((REALTIMEOFDAY - started + 24 HOURS) % (24 HOURS)) / 10

/** Saves real gameplay counters and a cumulative procedure snapshot per phase. */
/datum/controller/subsystem/fusion_profile/proc/observe(phase, seconds)
	var/deadline = elapsed() + seconds
	while(elapsed() < deadline)
		var/list/sample = list(
			"phase" = phase,
			"utc" = rustg_unix_timestamp(),
			"wall_seconds" = elapsed(),
			"world_time" = world.time,
			"cycles" = SSair.times_fired,
			"current_part" = SSair.currentpart,
			"active_turfs" = length(SSair.active_turfs),
			"hotspots" = length(SSair.hotspots),
			"ruptures" = ruptures,
			"turf_cost_ms" = SSair.cost_turfs,
			"pipenets_cost_ms" = SSair.cost_pipenets,
			"machinery_cost_ms" = SSair.cost_atmos_machinery,
			"heat_edges" = SSair.dogmos_heat_edges_applied,
			"host" = json_decode(dogmos_in_process_metrics()),
		)
		file("[GLOB.log_directory]/fusion-samples.jsonl") << json_encode(sample)
		sleep(1 SECONDS)
	file("[GLOB.log_directory]/fusion-profile-[phase].json") << world.Profile(PROFILE_REFRESH, format = "json")
	file("[GLOB.log_directory]/fusion-native-[phase].json") << dogmos_perf_snapshot()
