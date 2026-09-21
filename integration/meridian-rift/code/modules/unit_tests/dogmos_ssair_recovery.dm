/** Verifies SSair recovery preserves DM state without replacing service-owned atmosphere state. */
/datum/unit_test/dogmos_ssair_recovery
	/// Synthetic recovery fields must never be used by subsequent live IPC or test teardown.
	var/list/recovery_air_state
	/* // APHELION EDIT REMOVAL START - DOGMOS
	var/list/recovery_dogmos_state
	*/ // APHELION EDIT REMOVAL END
	var/datum/controller/subsystem/air/recovery_test_copy/recovered_air
	var/datum/controller/subsystem/dogmos/recovery_test_copy/recovered_dogmos

/datum/unit_test/dogmos_ssair_recovery/Run()
	if(!SSdogmos.service_ready || !dogmos_service_health())
		return Fail("dogmosd was not healthy before the SSair recovery test.", __FILE__, __LINE__)
	TEST_ASSERT(dogmos_wait_for_stage_boundary(), "Recovery fixture could not reach a healthy stage boundary.")
	var/datum/controller/subsystem/air/original_air = SSair
	var/original_air_initialized = SSair.initialized
	var/list/original_adjacent_rebuild = SSair.adjacent_rebuild
	var/list/air_recovery_fields = list(
		"equalize_enabled", "kennel_slow_mode", "kennel_high_cost_ms_threshold",
		"kennel_push_cursor", "active_turfs_walk_cursor", "recent_breaches", "active_turfs",
		"kennel_jump_targets", "kennel_jump_target_counts", "can_fire",
		"dogmos_frontier_epoch", "dogmos_stage_epoch", "dogmos_pending_stage",
		"dogmos_async_stages", "dogmos_job", "dogmos_job_last_poll_tick", // APHELION EDIT ADDITION - DOGMOS
		"dogmos_pending_frontier_epoch", "dogmos_committed_frontier",
		"dogmos_stage_remaining_estimate", "dogmos_stage_work_limit",
		"dogmos_active_turf_stages_complete", "dogmos_fdm_steps_completed",
		"dogmos_equalize_stage_complete", // APHELION EDIT ADDITION - DOGMOS
		"dogmos_active_walk_complete", "dogmos_visual_refresh_cursor", "dogmos_visual_refresh_batch", // APHELION EDIT ADDITION - DOGMOS
		"dogmos_reacted_turfs", "dogmos_resume_recovered_cycle", // APHELION EDIT ADDITION - DOGMOS
		"dogmos_walk_prefetch_end", "dogmos_visual_prefetch_end", // APHELION EDIT ADDITION - DOGMOS
		// APHELION EDIT ADDITION START - DOGMOS
		"dogmos_machine_prefetch_start", "dogmos_machine_prefetch_end", "dogmos_machine_prefetch_cursor",
		"dogmos_machine_prefetch_air_cursor", "dogmos_machine_prefetch_ready", "dogmos_machine_prefetch_mixtures",
		"dogmos_frontier_source", "dogmos_frontier_revision", "dogmos_frontier_upload_epoch",
		"dogmos_frontier_journal", "dogmos_frontier_needs_rescan", "dogmos_frontier_candidate",
		"dogmos_frontier_retired", "dogmos_frontier_scan_revision", "dogmos_frontier_scan_cursor",
		"dogmos_frontier_scan_total", "dogmos_frontier_sync_pending", "dogmos_frontier_upload_cursor",
		// APHELION EDIT ADDITION END
	)
	recovery_air_state = list()
	for(var/field_name in air_recovery_fields)
		recovery_air_state[field_name] = SSair.vars[field_name]
	SSair.can_fire = FALSE

	var/datum/controller/subsystem/dogmos/original_dogmos = SSdogmos
	var/original_service_pid = dogmos_service_pid()
	var/list/original_world_generation = dogmos_service_world_generation()
	var/list/original_active_turfs = SSair.active_turfs
	var/turf/jump_target = run_loc_floor_bottom_left
	var/jump_key = REF(jump_target)

	SSair.equalize_enabled = FALSE
	SSair.kennel_slow_mode = FALSE
	SSair.kennel_high_cost_ms_threshold = 7.5
	SSair.kennel_push_cursor = 3
	SSair.active_turfs_walk_cursor = 25
	SSair.dogmos_frontier_epoch = list(1, 2, 3, 4)
	SSair.dogmos_stage_epoch = list(5, 6, 7, 8)
	SSair.dogmos_pending_stage = 4
	SSair.dogmos_pending_frontier_epoch = list(1, 2, 3, 4)
	SSair.dogmos_stage_remaining_estimate = 17
	SSair.dogmos_stage_work_limit = 128
	// APHELION EDIT ADDITION START - DOGMOS
	SSair.dogmos_async_stages = TRUE
	SSair.dogmos_job = allocate(/datum/dogmos_stage_job, 4)
	SSair.dogmos_job.id = list(5, 6, 7, 65535)
	SSair.dogmos_job.ready_unit = list(8, 9, 10, 65535)
	SSair.dogmos_job.status = 3
	SSair.dogmos_job.committed_units = list(65535, 65535, 0, 0)
	SSair.dogmos_job.committed_unit = list(7, 9, 10, 65535)
	SSair.dogmos_job.committed_counts = list(11, 12, 13, 14, 15, 16, 17, 18)
	SSair.dogmos_job_last_poll_tick = world.time
	// APHELION EDIT ADDITION END
	SSair.dogmos_equalize_stage_complete = TRUE // APHELION EDIT ADDITION - DOGMOS
	// APHELION EDIT ADDITION START - DOGMOS
	SSair.dogmos_active_walk_complete = TRUE
	SSair.dogmos_visual_refresh_cursor = 7
	SSair.dogmos_visual_refresh_batch = block(run_loc_floor_bottom_left, run_loc_floor_top_right)
	SSair.dogmos_reacted_turfs = list()
	SSair.dogmos_reacted_turfs[jump_target] = TRUE
	SSair.dogmos_resume_recovered_cycle = TRUE
	SSair.dogmos_walk_prefetch_end = 25
	SSair.dogmos_visual_prefetch_end = 25
	// APHELION EDIT ADDITION END
	var/list/recovery_breaches = list(list(
		"time" = "00:00:00",
		"jump_to" = jump_key,
		"area" = "Recovery Test",
		"moles_lost" = 1,
	))
	SSair.recent_breaches = recovery_breaches
	SSair.kennel_jump_targets = list()
	SSair.kennel_jump_targets[jump_key] = WEAKREF(jump_target)
	SSair.kennel_jump_target_counts = list()
	SSair.kennel_jump_target_counts[jump_key] = 1

	var/datum/gas_mixture/sentinel = allocate(/datum/gas_mixture, CELL_VOLUME)
	sentinel.set_temperature(321.5)
	sentinel.set_moles(/datum/gas/oxygen, 7.25)
	// APHELION EDIT ADDITION START - DOGMOS
	SSair.dogmos_machine_prefetch_start = 65
	SSair.dogmos_machine_prefetch_end = 34
	SSair.dogmos_machine_prefetch_cursor = 60
	SSair.dogmos_machine_prefetch_air_cursor = 257
	SSair.dogmos_machine_prefetch_ready = FALSE
	SSair.dogmos_machine_prefetch_mixtures = list(sentinel)
	SSair.dogmos_frontier_upload_epoch = list(9, 10, 11, 12)
	SSair.dogmos_frontier_upload_cursor = 512
	SSair.dogmos_frontier_candidate = list(jump_target)
	SSair.dogmos_frontier_retired = list(jump_target)
	SSair.dogmos_frontier_needs_rescan = FALSE
	// APHELION EDIT ADDITION END
	var/sentinel_slot = sentinel.dogmos_slot
	var/sentinel_generation = sentinel.dogmos_generation

	// Exercise the production Recover payload without deleting the instance held
	// by the running Master's cached scheduler lists.
	recovered_air = new
	recovered_air.Recover()
	TEST_ASSERT(isnull(recovered_air.dogmos_frontier_upload_cursor), "Recovery retained an upload cursor without its captured revision.") // APHELION EDIT ADDITION - DOGMOS
	// APHELION EDIT ADDITION START - DOGMOS
	TEST_ASSERT(recovered_air.dogmos_async_stages, "SSair recovery changed the boot-selected job mode.")
	TEST_ASSERT_EQUAL(recovered_air.dogmos_job, SSair.dogmos_job, "SSair recovery lost exact job/publication ownership.")
	TEST_ASSERT_EQUAL(recovered_air.dogmos_job_last_poll_tick, SSair.dogmos_job_last_poll_tick, "SSair recovery would poll twice in the same tick.")
	// APHELION EDIT ADDITION END
	TEST_ASSERT_EQUAL(recovered_air.initialized, original_air_initialized, "SSair recovery lost its completed initialization state.")

	TEST_ASSERT_EQUAL(SSdogmos, original_dogmos, \
		"SSair recovery replaced the authoritative Dogmos subsystem datum.")
	TEST_ASSERT_EQUAL(dogmos_service_pid(), original_service_pid, \
		"SSair recovery replaced the healthy dogmosd process.")
	var/list/recovered_world_generation = dogmos_service_world_generation()
	TEST_ASSERT_EQUAL(recovered_world_generation[1], original_world_generation[1], \
		"SSair recovery changed the low word of the dogmosd world generation.")
	TEST_ASSERT_EQUAL(recovered_world_generation[2], original_world_generation[2], \
		"SSair recovery changed the high word of the dogmosd world generation.")
	TEST_ASSERT(dogmos_service_health(), \
		"dogmosd was unhealthy after SSair recovery.")
	TEST_ASSERT_EQUAL(sentinel.dogmos_slot, sentinel_slot, \
		"SSair recovery changed the sentinel mixture slot.")
	TEST_ASSERT_EQUAL(sentinel.dogmos_generation, sentinel_generation, \
		"SSair recovery changed the sentinel mixture generation.")
	TEST_ASSERT_EQUAL(sentinel.return_temperature(), 321.5, \
		"SSair recovery changed the service-owned sentinel temperature.")
	TEST_ASSERT_EQUAL(sentinel.get_moles(/datum/gas/oxygen), 7.25, \
		"SSair recovery changed the service-owned sentinel oxygen amount.")

	TEST_ASSERT_EQUAL(recovered_air.equalize_enabled, FALSE, \
		"SSair recovery did not retain the equalization setting.")
	TEST_ASSERT_EQUAL(recovered_air.kennel_slow_mode, FALSE, \
		"SSair recovery did not retain the Kennel slow-mode setting.")
	TEST_ASSERT_EQUAL(recovered_air.kennel_high_cost_ms_threshold, 7.5, \
		"SSair recovery did not retain the Kennel threshold.")
	TEST_ASSERT_EQUAL(recovered_air.recent_breaches, recovery_breaches, \
		"SSair recovery did not retain the bounded breach history.")
	TEST_ASSERT_EQUAL(recovered_air.active_turfs, original_active_turfs, \
		"SSair recovery did not retain the active-turf runtime queue.")
	TEST_ASSERT_EQUAL(recovered_air.kennel_push_cursor, 0, \
		"SSair recovery retained the old Kennel update cursor.")
	// APHELION EDIT ADDITION START - DOGMOS
	TEST_ASSERT_EQUAL(recovered_air.active_turfs_walk_cursor, 25, \
		"SSair recovery lost the initial snapshot's maintenance cursor.")
	TEST_ASSERT_EQUAL(recovered_air.dogmos_visual_refresh_cursor, 7, "SSair recovery lost the visual continuation cursor.")
	TEST_ASSERT_EQUAL(recovered_air.dogmos_active_walk_complete, TRUE, "SSair recovery lost completed frontier publication.")
	TEST_ASSERT_EQUAL(recovered_air.dogmos_visual_refresh_batch[1], jump_target, "SSair recovery lost the initial walk snapshot.")
	TEST_ASSERT_EQUAL(recovered_air.dogmos_reacted_turfs[jump_target], TRUE, "SSair recovery lost chemical activity before settlement.")
	TEST_ASSERT_EQUAL(recovered_air.dogmos_resume_recovered_cycle, TRUE, "SSair recovery lost its pending cycle continuation.")
	TEST_ASSERT_EQUAL(recovered_air.dogmos_walk_prefetch_end, 25, "SSair recovery lost its prefetched maintenance chunk.")
	TEST_ASSERT_EQUAL(recovered_air.dogmos_visual_prefetch_end, 25, "SSair recovery lost its prefetched visual chunk.")
	TEST_ASSERT_EQUAL(recovered_air.dogmos_machine_prefetch_start, 65, "Recovery lost the reverse machinery range start.")
	TEST_ASSERT_EQUAL(recovered_air.dogmos_machine_prefetch_end, 34, "Recovery lost the reverse machinery range end.")
	TEST_ASSERT_EQUAL(recovered_air.dogmos_machine_prefetch_cursor, 60, "Recovery restarted machinery collection.")
	TEST_ASSERT_EQUAL(recovered_air.dogmos_machine_prefetch_air_cursor, 257, "Recovery restarted an oversized component.")
	TEST_ASSERT_EQUAL(recovered_air.dogmos_machine_prefetch_ready, FALSE, "Recovery skipped incomplete machinery collection.")
	TEST_ASSERT_EQUAL(recovered_air.dogmos_machine_prefetch_mixtures[1], sentinel, "Recovery lost the bounded pending mixture request.")
	recovered_air.dogmos_clear_machinery_prefetch()
	TEST_ASSERT_EQUAL(length(SSair.dogmos_machine_prefetch_mixtures), 1, "Recovered machinery scratch aliases the old subsystem.")
	TEST_ASSERT(recovered_air.dogmos_frontier_needs_rescan, "Recovery did not schedule a bounded frontier reconciliation.")
	TEST_ASSERT_EQUAL(length(recovered_air.dogmos_frontier_journal), 0, "Recovery trusted an incomplete membership journal.")
	TEST_ASSERT_EQUAL(recovered_air.dogmos_committed_frontier, SSair.dogmos_committed_frontier, "Recovery copied the world-sized acknowledged frontier.")
	TEST_ASSERT_EQUAL(recovered_air.dogmos_frontier_candidate, SSair.dogmos_frontier_candidate, "Recovery discarded unpublished scratch before bounded retirement.")
	TEST_ASSERT_EQUAL(recovered_air.dogmos_frontier_retired, SSair.dogmos_frontier_retired, "Recovery lost pending snapshot retirement.")
	TEST_ASSERT(SSdogmos.equal_u64_words(recovered_air.dogmos_frontier_upload_epoch, list(9, 10, 11, 12)), "Recovery lost the attempted upload epoch high water.")
	// APHELION EDIT ADDITION END
	for(var/word_index in 1 to 4)
		TEST_ASSERT_EQUAL(recovered_air.dogmos_frontier_epoch[word_index], word_index, \
			"SSair recovery changed frontier epoch word [word_index].")
		TEST_ASSERT_EQUAL(recovered_air.dogmos_stage_epoch[word_index], word_index + 4, \
			"SSair recovery changed stage epoch word [word_index].")
		TEST_ASSERT_EQUAL(recovered_air.dogmos_pending_frontier_epoch[word_index], word_index, \
			"SSair recovery changed pending frontier epoch word [word_index].")
	TEST_ASSERT_EQUAL(recovered_air.dogmos_pending_stage, 4, \
		"SSair recovery restarted instead of retaining the pending Dogmos stage.")
	TEST_ASSERT_EQUAL(recovered_air.dogmos_stage_remaining_estimate, 17, \
		"SSair recovery did not retain the pending Dogmos work estimate.")
	TEST_ASSERT_EQUAL(recovered_air.dogmos_stage_work_limit, 128, \
		"SSair recovery did not retain the Dogmos stage work limit.")
	// APHELION EDIT ADDITION START - DOGMOS
	TEST_ASSERT_EQUAL(recovered_air.dogmos_equalize_stage_complete, TRUE, \
		"SSair recovery lost completed equalization during a pressure continuation.")
	// APHELION EDIT ADDITION END
	TEST_ASSERT_EQUAL(recovered_air.resolve_kennel_jump_target(jump_key), jump_target, \
		"SSair recovery did not rebuild the bounded Kennel jump-target index.")

	// APHELION EDIT ADDITION START - DOGMOS
	// Copy an explicit test inventory into an inert source: adoption must never revoke
	// the running owner's registry or expose synthetic queue entries to live IPC.
	var/datum/controller/subsystem/dogmos/recovery_test_copy/recovery_source = allocate(/datum/controller/subsystem/dogmos/recovery_test_copy)
	// APHELION EDIT ADDITION END
	var/list/dogmos_recovery_fields = list(
		// APHELION EDIT ADDITION START - DOGMOS
		"initialized",
		// APHELION EDIT ADDITION END
		"gases_registered",
		"service_ready",
		// APHELION EDIT ADDITION START - DOGMOS
		"service_failure_latched",
		"service_shutdown_requested",
		"dogmos_runtime_state_released",
		// APHELION EDIT ADDITION END
		"dogmos_mixture_slots",
		"dogmos_mixture_generations",
		"dogmos_free_mixture_slots",
		"dogmos_pending_mixture_unregistrations", // APHELION EDIT ADDITION - DOGMOS
		"dogmos_gas_ids",
		"dogmos_gas_paths",
		"dogmos_reaction_ids",
		"dogmos_holder_slots",
		"dogmos_holder_generations",
		"dogmos_free_holder_slots",
		"dogmos_next_callback_sequence",
		"dogmos_pending_callback_batch",
		"dogmos_pending_callback_index",
		"dogmos_pending_callback_count",
		"dogmos_pending_service_callbacks",
		"dogmos_stale_callback_count",
		"dogmos_health_preflight_count",
		"turf_registration_batching",
		"dogmos_pending_turf_lifecycle",
		"dogmos_pending_turf_adjacency",
		"dogmos_pending_turf_adjacency_index",
		"dogmos_pending_turf_heat",
		"dogmos_pending_turf_heat_adjacency",
		"dogmos_pending_turf_heat_adjacency_index",
		"dogmos_pending_adjacency_retry",
		"runtime_topology_batching",
		"dogmos_runtime_topology_records",
		"dogmos_runtime_topology_calls",
		"dogmos_runtime_topology_max_queued",
		"dogmos_runtime_topology_deferrals",
		"dogmos_mixture_cache",
		"dogmos_mixture_cache_epoch",
		"dogmos_mixture_cache_hits",
		"dogmos_mixture_cache_misses",
		"dogmos_mixture_cache_collisions",
		"dogmos_mixture_cache_epoch_invalidations",
	)
	var/list/original_dogmos_state = list()
	for(var/field_name in dogmos_recovery_fields)
		original_dogmos_state[field_name] = original_dogmos.vars[field_name] // APHELION EDIT CHANGE - DOGMOS - ORIGINAL: original_dogmos_state[field_name] = SSdogmos.vars[field_name]
		// APHELION EDIT ADDITION START - DOGMOS
		recovery_source.vars[field_name] = original_dogmos.vars[field_name]
		// APHELION EDIT ADDITION END
	/* // APHELION EDIT REMOVAL START - DOGMOS
	recovery_dogmos_state = original_dogmos_state
	*/ // APHELION EDIT REMOVAL END

	recovery_source.dogmos_pending_mixture_unregistrations = list("recovery mixture unregistration") // APHELION EDIT CHANGE - DOGMOS - ORIGINAL: SSdogmos.dogmos_pending_mixture_unregistrations = list("recovery mixture unregistration")
	recovery_source.dogmos_pending_callback_batch = list("recovery callback") // APHELION EDIT CHANGE - DOGMOS - ORIGINAL: SSdogmos.dogmos_pending_callback_batch = list("recovery callback")
	recovery_source.dogmos_pending_callback_index = 1 // APHELION EDIT CHANGE - DOGMOS - ORIGINAL: SSdogmos.dogmos_pending_callback_index = 1
	recovery_source.dogmos_pending_callback_count = 1 // APHELION EDIT CHANGE - DOGMOS - ORIGINAL: SSdogmos.dogmos_pending_callback_count = 1
	recovery_source.dogmos_pending_service_callbacks = 2 // APHELION EDIT CHANGE - DOGMOS - ORIGINAL: SSdogmos.dogmos_pending_service_callbacks = 2
	recovery_source.dogmos_stale_callback_count += 11 // APHELION EDIT CHANGE - DOGMOS - ORIGINAL: SSdogmos.dogmos_stale_callback_count += 11
	recovery_source.dogmos_health_preflight_count += 12 // APHELION EDIT CHANGE - DOGMOS - ORIGINAL: SSdogmos.dogmos_health_preflight_count += 12
	recovery_source.dogmos_pending_turf_lifecycle = list("recovery lifecycle") // APHELION EDIT CHANGE - DOGMOS - ORIGINAL: SSdogmos.dogmos_pending_turf_lifecycle = list("recovery lifecycle")
	recovery_source.dogmos_pending_turf_adjacency = list("recovery adjacency") // APHELION EDIT CHANGE - DOGMOS - ORIGINAL: SSdogmos.dogmos_pending_turf_adjacency = list("recovery adjacency")
	recovery_source.dogmos_pending_turf_adjacency_index = list("recovery adjacency index") // APHELION EDIT CHANGE - DOGMOS - ORIGINAL: SSdogmos.dogmos_pending_turf_adjacency_index = list("recovery adjacency index")
	recovery_source.dogmos_pending_turf_heat = list("recovery heat") // APHELION EDIT CHANGE - DOGMOS - ORIGINAL: SSdogmos.dogmos_pending_turf_heat = list("recovery heat")
	recovery_source.dogmos_pending_turf_heat_adjacency = list("recovery heat adjacency") // APHELION EDIT CHANGE - DOGMOS - ORIGINAL: SSdogmos.dogmos_pending_turf_heat_adjacency = list("recovery heat adjacency")
	recovery_source.dogmos_pending_turf_heat_adjacency_index = list("recovery heat adjacency index") // APHELION EDIT CHANGE - DOGMOS - ORIGINAL: SSdogmos.dogmos_pending_turf_heat_adjacency_index = list("recovery heat adjacency index")
	recovery_source.dogmos_pending_adjacency_retry = list("recovery retry") // APHELION EDIT CHANGE - DOGMOS - ORIGINAL: SSdogmos.dogmos_pending_adjacency_retry = list("recovery retry")
	recovery_source.dogmos_runtime_topology_records += 13 // APHELION EDIT CHANGE - DOGMOS - ORIGINAL: SSdogmos.dogmos_runtime_topology_records += 13
	recovery_source.dogmos_runtime_topology_calls += 14 // APHELION EDIT CHANGE - DOGMOS - ORIGINAL: SSdogmos.dogmos_runtime_topology_calls += 14
	recovery_source.dogmos_runtime_topology_max_queued += 15 // APHELION EDIT CHANGE - DOGMOS - ORIGINAL: SSdogmos.dogmos_runtime_topology_max_queued += 15
	recovery_source.dogmos_runtime_topology_deferrals += 16 // APHELION EDIT CHANGE - DOGMOS - ORIGINAL: SSdogmos.dogmos_runtime_topology_deferrals += 16
	recovery_source.dogmos_mixture_cache = list("recovery cache") // APHELION EDIT CHANGE - DOGMOS - ORIGINAL: SSdogmos.dogmos_mixture_cache = list("recovery cache")
	recovery_source.dogmos_mixture_cache_epoch += 17 // APHELION EDIT CHANGE - DOGMOS - ORIGINAL: SSdogmos.dogmos_mixture_cache_epoch += 17
	recovery_source.dogmos_mixture_cache_hits += 18 // APHELION EDIT CHANGE - DOGMOS - ORIGINAL: SSdogmos.dogmos_mixture_cache_hits += 18
	recovery_source.dogmos_mixture_cache_misses += 19 // APHELION EDIT CHANGE - DOGMOS - ORIGINAL: SSdogmos.dogmos_mixture_cache_misses += 19
	recovery_source.dogmos_mixture_cache_collisions += 20 // APHELION EDIT CHANGE - DOGMOS - ORIGINAL: SSdogmos.dogmos_mixture_cache_collisions += 20
	recovery_source.dogmos_mixture_cache_epoch_invalidations += 21 // APHELION EDIT CHANGE - DOGMOS - ORIGINAL: SSdogmos.dogmos_mixture_cache_epoch_invalidations += 21
	var/list/expected_dogmos_state = list()
	for(var/field_name in dogmos_recovery_fields)
		expected_dogmos_state[field_name] = recovery_source.vars[field_name] // APHELION EDIT CHANGE - DOGMOS - ORIGINAL: expected_dogmos_state[field_name] = SSdogmos.vars[field_name]

	recovered_dogmos = new
	// Boot-discovered copies need SS_NO_INIT, but this local copy must prove that
	// Adoption itself sets the flag rather than inheriting a passing precondition.
	recovered_dogmos.ss_flags &= ~SS_NO_INIT
	recovered_dogmos.adopt_runtime_state(recovery_source) // APHELION EDIT CHANGE - DOGMOS - ORIGINAL: recovered_dogmos.Recover()

	TEST_ASSERT_NOTEQUAL(recovered_dogmos, original_dogmos, \
		"Dogmos recovery needs an independent destination datum.")
	TEST_ASSERT(SSdogmos == original_dogmos, "The recovery copy replaced the authoritative Dogmos subsystem.")
	TEST_ASSERT(recovered_dogmos.ss_flags & SS_NO_INIT, \
		"Dogmos recovery did not suppress cold service initialization.")
	TEST_ASSERT(recovered_dogmos.initialized, \
		"Dogmos recovery did not retain initialized state.")
	for(var/field_name in dogmos_recovery_fields)
		TEST_ASSERT_EQUAL(recovered_dogmos.vars[field_name], expected_dogmos_state[field_name], \
			"Dogmos recovery did not retain [field_name].")
	TEST_ASSERT_EQUAL(dogmos_service_pid(), original_service_pid, \
		"Dogmos recovery replaced the healthy dogmosd process.")
	var/list/dogmos_recovered_world_generation = dogmos_service_world_generation()
	TEST_ASSERT_EQUAL(dogmos_recovered_world_generation[1], original_world_generation[1], \
		"Dogmos recovery changed the low word of the dogmosd world generation.")
	TEST_ASSERT_EQUAL(dogmos_recovered_world_generation[2], original_world_generation[2], \
		"Dogmos recovery changed the high word of the dogmosd world generation.")
	TEST_ASSERT(dogmos_service_health(), \
		"dogmosd was unhealthy after Dogmos recovery.")
	for(var/field_name in dogmos_recovery_fields)
		/* // APHELION EDIT REMOVAL START - DOGMOS
		SSdogmos.vars[field_name] = original_dogmos_state[field_name]
		*/ // APHELION EDIT REMOVAL END
		// APHELION EDIT ADDITION START - DOGMOS
		TEST_ASSERT_EQUAL(original_dogmos.vars[field_name], original_dogmos_state[field_name], \
			"The inert recovery fixture changed the live owner's [field_name].")
		// APHELION EDIT ADDITION END
	TEST_ASSERT_EQUAL(sentinel.return_temperature(), 321.5, \
		"Dogmos recovery invalidated the sentinel mixture temperature.")
	TEST_ASSERT_EQUAL(sentinel.get_moles(/datum/gas/oxygen), 7.25, \
		"Dogmos recovery invalidated the sentinel mixture oxygen amount.")

	restore_recovery_state()
	TEST_ASSERT_EQUAL(SSair, original_air, "The recovery fixture replaced the scheduled Atmospherics subsystem.")
	TEST_ASSERT_EQUAL(SSair.initialized, original_air_initialized, "The recovery fixture changed Atmospherics initialization state.")
	TEST_ASSERT(SSair in Master.subsystems, "The original Atmospherics subsystem was removed from the Master.")
	TEST_ASSERT_EQUAL(SSair.adjacent_rebuild, original_adjacent_rebuild, "Recovery detached the pending adjacency queue.")
	// A healthy process alone cannot detect leaked synthetic epochs. Exercise a real
	// publication and stage after restoration so the native contract validates them.
	TEST_ASSERT(dogmos_run_fixture_stage(4, list(jump_target)), "Recovered atmosphere state could not execute a real native stage after fixture cleanup.")
	// Direct native calls bypass the Master scheduler. A natural completed cycle
	// additionally proves the fixture has not detached the live subsystem.
	var/times_fired_before = SSair.times_fired
	var/deadline = world.time + 60 SECONDS
	while(SSair.times_fired == times_fired_before && world.time < deadline)
		sleep(SSair.wait)
	TEST_ASSERT(SSair.times_fired > times_fired_before, "Atmospherics did not complete a naturally scheduled cycle after the recovery fixture (phase [SSair.currentpart], walk [SSair.active_turfs_walk_cursor]/[length(SSair.dogmos_visual_refresh_batch)], prefetch [SSair.dogmos_walk_prefetch_end], visuals [SSair.dogmos_visual_refresh_cursor], stage [SSair.dogmos_pending_stage]).")

/datum/unit_test/dogmos_ssair_recovery/proc/restore_recovery_state()
	QDEL_NULL(recovered_air)
	QDEL_NULL(recovered_dogmos)
	/* // APHELION EDIT REMOVAL START - DOGMOS
	for(var/field_name in recovery_dogmos_state)
		SSdogmos.vars[field_name] = recovery_dogmos_state[field_name]
	recovery_dogmos_state = null
	*/ // APHELION EDIT REMOVAL END
	for(var/field_name in recovery_air_state)
		SSair.vars[field_name] = recovery_air_state[field_name]
	recovery_air_state = null

/datum/unit_test/dogmos_ssair_recovery/restore_atmos()
	// RunUnitTest restores gas before Destroy(), including after an assertion aborts Run().
	restore_recovery_state()
	return ..()

/datum/unit_test/dogmos_ssair_recovery/Destroy()
	restore_recovery_state()
	return ..()

// Master enumerates all subsystem subtypes. These copies are inert both when
// discovered at boot and when allocated locally; inherited New would swap globals.
/datum/controller/subsystem/air/recovery_test_copy
	name = "Atmos recovery test copy"
	ss_flags = SS_NO_INIT | SS_NO_FIRE
	can_fire = FALSE

/datum/controller/subsystem/air/recovery_test_copy/New()
	return

/datum/controller/subsystem/dogmos/recovery_test_copy
	name = "Dogmos recovery test copy"
	ss_flags = SS_NO_INIT | SS_NO_FIRE
	can_fire = FALSE

/datum/controller/subsystem/dogmos/recovery_test_copy/New()
	return
