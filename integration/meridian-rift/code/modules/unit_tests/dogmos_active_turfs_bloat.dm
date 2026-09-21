/// Maximum entries permitted in one active-turf maintenance chunk.
#define ACTIVE_TURFS_BLOAT_TEST_MAX_ENTRIES 100

/** Bounds the legacy active-turf walk independently of gas movement. */
/datum/unit_test/dogmos_active_turfs_bloat

/datum/unit_test/dogmos_active_turfs_bloat/Run()
	var/list/pair = allocate_turf_pair()
	var/turf/open/turf_a = pair[1]
	var/turf/open/turf_b = pair[2]

	// The regression is driven by list length, so repeated turfs are sufficient.
	var/list/original_active_turfs = SSair.active_turfs
	var/list/bloated = list(turf_a, turf_b)
	for(var/i in 1 to 1900)
		bloated += turf_a
		bloated += turf_b
	SSair.dogmos_replace_active_frontier(bloated) // APHELION EDIT CHANGE - DOGMOS - ORIGINAL: SSair.active_turfs = bloated
	var/original_cursor = SSair.active_turfs_walk_cursor
	SSair.active_turfs_walk_cursor = 0
	// APHELION EDIT ADDITION START - DOGMOS
	var/list/original_snapshot = SSair.dogmos_visual_refresh_batch
	var/original_prefetch_end = SSair.dogmos_walk_prefetch_end
	SSair.dogmos_walk_prefetch_end = 0
	var/original_state = SSair.state
	var/original_tick_limit = Master.current_ticklimit
	var/list/original_turf_states = list()
	for(var/turf/open/fixture_turf as anything in pair)
		original_turf_states[fixture_turf] = list(fixture_turf.excited, fixture_turf.excited_group, fixture_turf.current_cycle, fixture_turf.archived_cycle)
		fixture_turf.excited = TRUE
		fixture_turf.excited_group = null
		fixture_turf.archived_cycle = SSair.times_fired
	SSair.dogmos_visual_refresh_batch = bloated.Copy()
	SSair.state = SS_RUNNING
	Master.current_ticklimit = TICK_USAGE + 100 / world.tick_lag
	// APHELION EDIT ADDITION END

	var/start_tick_usage = TICK_USAGE_REAL
	// APHELION EDIT ADDITION START - DOGMOS
	var/more_work = SSair.walk_active_turfs_batch()
	var/visited_entries = SSair.active_turfs_walk_cursor
	var/prefetched_entries = SSair.dogmos_walk_prefetch_end
	// APHELION EDIT ADDITION END
	var/cost_ms = TICK_USAGE_TO_MS(start_tick_usage)

	SSair.dogmos_replace_active_frontier(original_active_turfs) // APHELION EDIT CHANGE - DOGMOS - ORIGINAL: SSair.active_turfs = original_active_turfs
	SSair.active_turfs_walk_cursor = original_cursor
	// APHELION EDIT ADDITION START - DOGMOS
	SSair.dogmos_visual_refresh_batch = original_snapshot
	SSair.dogmos_walk_prefetch_end = original_prefetch_end
	SSair.state = original_state
	Master.current_ticklimit = original_tick_limit
	for(var/turf/open/fixture_turf as anything in pair)
		var/list/original_turf_state = original_turf_states[fixture_turf]
		fixture_turf.excited = original_turf_state[1]
		fixture_turf.excited_group = original_turf_state[2]
		fixture_turf.current_cycle = original_turf_state[3]
		fixture_turf.archived_cycle = original_turf_state[4]
	// APHELION EDIT ADDITION END

	// APHELION EDIT ADDITION START - DOGMOS
	// Shared CI runner speed and IPC latency are observations, not a work-bound contract.
	log_test("Active-turf bloat walk: [visited_entries] visited, [prefetched_entries] prefetched, [cost_ms]ms.")
	TEST_ASSERT(prefetched_entries > 0 && prefetched_entries <= ACTIVE_TURFS_BLOAT_TEST_MAX_ENTRIES, \
		"Active-turf maintenance must prefetch at most [ACTIVE_TURFS_BLOAT_TEST_MAX_ENTRIES] entries, got [prefetched_entries].")
	TEST_ASSERT(visited_entries >= 0 && visited_entries <= prefetched_entries, \
		"Active-turf maintenance walked outside its prefetched chunk: [visited_entries] visited, [prefetched_entries] prefetched.")
	TEST_ASSERT(more_work, "A single bounded maintenance call must leave work pending in the bloated snapshot.")
	// APHELION EDIT ADDITION END

#undef ACTIVE_TURFS_BLOAT_TEST_MAX_ENTRIES
