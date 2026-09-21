#if defined(UNIT_TESTS) || defined(SPACEMAN_DMM)

/** Controlled job replies exercise actual SSair scheduling and its fresh MC budget. */
/datum/unit_test/dogmos_runtime_scheduling/Run()
	var/datum/controller/subsystem/air/recovery_test_copy/job_probe/probe = allocate(/datum/controller/subsystem/air/recovery_test_copy/job_probe)
	var/original_limit = Master.current_ticklimit
	var/failure
	try
		Master.current_ticklimit = TICK_USAGE + 1000
		probe.start_sentinel()
		if(!probe.dogmos_run_stage(4, 100) || probe.submit_calls != 1 || probe.poll_calls || probe.commit_calls)
			failure = "Submit did not return pending without polling or publishing."
		probe.dogmos_run_stage(4, 100)
		if(!failure && (probe.submit_calls != 1 || probe.poll_calls))
			failure = "The same MC tick submitted twice or polled immediately."
		sleep(world.tick_lag)
		Master.current_ticklimit = TICK_USAGE + 1000
		probe.dogmos_run_stage(4, 100)
		if(!failure && (!probe.sentinel_visits || probe.poll_calls != 1 || probe.commit_calls))
			failure = "Another DM proc did not advance while the controlled native job was pending."
		probe.dogmos_run_stage(4, 100)
		if(!failure && probe.poll_calls != 1)
			failure = "A pending job was polled more than once in one tick."
		sleep(world.tick_lag)
		Master.current_ticklimit = TICK_USAGE + 1000
		probe.exhaust_ready_budget = TRUE
		probe.dogmos_run_stage(4, 100)
		if(!failure && (probe.poll_calls != 2 || probe.commit_calls || !probe.dogmos_job?.ready_unit))
			failure = "Ready work was committed using the budget from before Poll."
		sleep(world.tick_lag)
		Master.current_ticklimit = TICK_USAGE + 1000
		if(probe.dogmos_run_stage(4, 100) || probe.commit_calls != 1 || probe.poll_calls != 2)
			failure = "The next eligible tick did not publish the retained ready unit exactly once."
		if(!failure && (probe.dogmos_job || !isnull(probe.dogmos_pending_stage) || probe.num_equalize_processed != 7))
			failure = "The completed job retained its fence or consumed its cumulative count incorrectly."
	catch(var/exception/error)
		failure = "Scheduling fixture raised [error.name]."
	Master.current_ticklimit = original_limit
	probe.sentinel_running = FALSE
	sleep(world.tick_lag)
	qdel(probe)
	if(failure)
		return Fail(failure, __FILE__, __LINE__)

/datum/controller/subsystem/air/recovery_test_copy/job_probe
	dogmos_async_stages = TRUE
	dogmos_pending_frontier_epoch = list(1, 0, 0, 0)
	var/submit_calls = 0
	var/poll_calls = 0
	var/commit_calls = 0
	var/exhaust_ready_budget = FALSE
	var/sentinel_running = FALSE
	var/sentinel_visits = 0

/datum/controller/subsystem/air/recovery_test_copy/job_probe/proc/start_sentinel()
	set waitfor = FALSE
	sentinel_running = TRUE
	while(sentinel_running)
		sleep(world.tick_lag)
		if(sentinel_running)
			sentinel_visits++

/datum/controller/subsystem/air/recovery_test_copy/job_probe/dogmos_job_request(operation, list/fields)
	// Literal 26-word oracle: high-word job identity, stage 4, initially no publication.
	var/list/response = list(1, 2, 3, 65535, 1, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	switch(operation)
		if("submit")
			submit_calls++
		if("poll")
			poll_calls++
			response[5] = poll_calls == 1 ? 2 : 3
			response[11] = 12
			if(poll_calls > 1)
				response[7] = 9
				if(exhaust_ready_budget)
					Master.current_ticklimit = TICK_USAGE
		if("commit")
			commit_calls++
			response[5] = 5
			response[7] = 9
			response[11] = 12
			response[15] = 1
			response[19] = 7
	return response

/** A pending native job must leave MC time available without repeated same-tick resumes. */
/datum/unit_test/dogmos_runtime_scheduling/mc_wait
	var/test_queue_flags = NONE

/datum/unit_test/dogmos_runtime_scheduling/mc_wait/Run()
	var/datum/controller/subsystem/air/recovery_test_copy/job_probe/mc_wait/probe = allocate(/datum/controller/subsystem/air/recovery_test_copy/job_probe/mc_wait)
	var/datum/controller/subsystem/air/recovery_test_copy/job_probe/mc_sentinel/sentinel = allocate(/datum/controller/subsystem/air/recovery_test_copy/job_probe/mc_sentinel)
	var/list/master_fields = list("queue_head", "queue_tail", "queue_priority_count", "queue_priority_count_bg", "current_ticklimit", "skip_ticks", "use_rolling_usage", "last_type_processed")
	var/list/saved_master = list()
	var/failure
	var/original_processing = Master.processing
	Master.processing = FALSE
	for(var/attempt in 1 to 20)
		sleep(world.tick_lag)
		if(TICK_USAGE < TICK_LIMIT_MC * 0.5)
			break
	for(var/field in master_fields)
		saved_master[field] = Master.vars[field]
	try
		Master.queue_head = probe
		Master.queue_tail = sentinel
		Master.queue_priority_count = test_queue_flags & SS_BACKGROUND ? 0 : 20
		Master.queue_priority_count_bg = test_queue_flags & SS_BACKGROUND ? 20 : 0
		Master.skip_ticks = 0
		Master.use_rolling_usage = FALSE
		probe.ss_flags = test_queue_flags
		sentinel.ss_flags = test_queue_flags
		probe.queued_priority = 10
		sentinel.queued_priority = 10
		probe.state = SS_PAUSED
		sentinel.state = SS_QUEUED
		probe.queue_next = sentinel
		sentinel.queue_prev = probe
		var/queue_result = Master.RunQueue()
		if(queue_result != 1 || probe.fire_calls != 1 || sentinel.fire_calls != 1)
			failure = "Pending job spun in the MC queue: atmos=[probe.fire_calls], other subsystem=[sentinel.fire_calls], queue result=[queue_result]; expected one visit each."
		else if(probe.times_fired || probe.state != SS_PAUSED || Master.queue_head != probe || Master.queue_tail != probe || Master.queue_priority_count + Master.queue_priority_count_bg != 10)
			failure = "Waiting for native work completed or removed the unfinished atmosphere cycle."
		else
			Master.RunQueue()
			if(probe.fire_calls != 1 || probe.submit_calls != 1 || probe.poll_calls || probe.commit_calls)
				failure = "A second MC queue pass resumed or polled the pending job during the same game tick."
		if(!failure)
			// Advance the eligibility boundary without leaving the borrowed MC queue installed across a sleep.
			probe.resume_after = world.time
			probe.dogmos_job_last_poll_tick = world.time - world.tick_lag
			Master.RunQueue()
			if(probe.fire_calls != 2 || probe.poll_calls != 1 || probe.commit_calls || probe.times_fired || probe.state != SS_PAUSED)
				failure = "An eligible pending job did not poll once and wait again."
		if(!failure)
			probe.resume_after = world.time
			probe.dogmos_job_last_poll_tick = world.time - world.tick_lag
			Master.RunQueue()
			if(probe.fire_calls != 3 || probe.poll_calls != 2 || probe.commit_calls != 1 || probe.times_fired != 1 || probe.dogmos_job || Master.queue_head || Master.queue_tail || Master.queue_priority_count || Master.queue_priority_count_bg)
				failure = "A ready job did not publish once and complete its queued run."
		if(!failure)
			// An ordinary budget pause must still reuse time left by other subsystems in the same tick.
			sentinel.fire_calls = 0
			sentinel.pause_once = TRUE
			sentinel.state = SS_QUEUED
			sentinel.queue_prev = null
			Master.queue_head = sentinel
			Master.queue_tail = sentinel
			Master.queue_priority_count = test_queue_flags & SS_BACKGROUND ? 0 : 10
			Master.queue_priority_count_bg = test_queue_flags & SS_BACKGROUND ? 10 : 0
			Master.RunQueue()
			if(sentinel.fire_calls != 2 || sentinel.times_fired != 2 || Master.queue_head || Master.queue_tail || Master.queue_priority_count || Master.queue_priority_count_bg)
				failure = "Ordinary budget pauses lost same-tick reuse or completion accounting."
	catch(var/exception/error)
		failure = "MC scheduling fixture raised [error.name]."
	for(var/field in master_fields)
		Master.vars[field] = saved_master[field]
	Master.processing = original_processing
	probe.queue_next = null
	probe.queue_prev = null
	sentinel.queue_next = null
	sentinel.queue_prev = null
	QDEL_NULL(probe.dogmos_job)
	qdel(probe)
	qdel(sentinel)
	if(failure)
		return Fail(failure, __FILE__, __LINE__)

/datum/unit_test/dogmos_runtime_scheduling/mc_wait/background
	test_queue_flags = SS_BACKGROUND

/datum/controller/subsystem/air/recovery_test_copy/job_probe/mc_wait
	var/fire_calls = 0

/datum/controller/subsystem/air/recovery_test_copy/job_probe/mc_wait/fire(resumed = FALSE)
	fire_calls++
	// Bound the failing baseline instead of burning the complete MC allowance.
	if(fire_calls >= 4)
		return
	if(dogmos_run_stage(4, 100))
		pause()

/datum/controller/subsystem/air/recovery_test_copy/job_probe/mc_sentinel
	var/fire_calls = 0
	var/pause_once = FALSE

/datum/controller/subsystem/air/recovery_test_copy/job_probe/mc_sentinel/fire(resumed = FALSE)
	fire_calls++
	if(pause_once && fire_calls == 1)
		pause()

/** Exact receipts cannot publish during Poll, regress counts, or invalidate twice. */
/datum/unit_test/dogmos_runtime_scheduling/receipts/Run()
	var/datum/controller/subsystem/air/recovery_test_copy/job_probe/probe = allocate(/datum/controller/subsystem/air/recovery_test_copy/job_probe)
	var/datum/gas_mixture/mixture = allocate(/datum/gas_mixture, CELL_VOLUME)
	mixture.set_moles(/datum/gas/oxygen, 12)
	mixture.dogmos_snapshot()
	var/epoch_before = SSdogmos.dogmos_mixture_cache_epoch
	var/list/sequence_before = SSdogmos.dogmos_next_callback_sequence.Copy()
	probe.dogmos_job = allocate(/datum/dogmos_stage_job, 4)
	var/list/accepted = list(1, 2, 3, 65535, 1, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
	var/list/ready = accepted.Copy()
	ready[5] = 3
	ready[7] = 9
	ready[11] = 12
	var/list/committed = ready.Copy()
	committed[5] = 2
	committed[15] = 1
	committed[19] = 7
	var/failure
	if(!probe.dogmos_accept_job_response(accepted, "submit") || !probe.dogmos_accept_job_response(ready, "poll"))
		failure = "Valid high-word job admission/readiness was rejected."
	if(!failure && (SSdogmos.dogmos_mixture_cache_epoch != epoch_before || !SSdogmos.lookup_mixture_snapshot_cache(mixture.dogmos_slot, mixture.dogmos_generation)))
		failure = "Unpublished preparation invalidated a warm cache."
	// Neither Poll nor a malformed Commit may advance cumulative publication counts.
	if(!failure && probe.dogmos_accept_job_response(committed, "poll"))
		failure = "Poll was allowed to acknowledge an unauthorized publication."
	for(var/mutation in list("job", "unit", "count", "stage", "fraction", "cancelled", "short"))
		var/list/malformed = committed.Copy()
		switch(mutation)
			if("job")
				malformed[4]--
			if("unit")
				malformed[7]++
			if("count")
				malformed[15] = 2
			if("stage")
				malformed[6] = 3
			if("fraction")
				malformed[19] = 0.5
			if("cancelled")
				malformed[5] = 6
			if("short")
				malformed.len--
		if(!failure && probe.dogmos_accept_job_response(malformed, "commit"))
			failure = "Malformed [mutation] receipt was accepted."
	if(!failure && SSdogmos.dogmos_mixture_cache_epoch != epoch_before)
		failure = "Rejected receipt changed the snapshot epoch."
	if(!failure && !probe.dogmos_accept_job_response(committed, "commit"))
		failure = "Valid publication receipt was rejected."
	var/committed_epoch = SSdogmos.dogmos_mixture_cache_epoch
	if(!failure && (committed_epoch == epoch_before || SSdogmos.lookup_mixture_snapshot_cache(mixture.dogmos_slot, mixture.dogmos_generation) || probe.num_equalize_processed != 7))
		failure = "Commit did not invalidate the warm cache and consume its count."
	// A later Ready token must survive a replay of the preceding commit receipt.
	var/list/later_ready = committed.Copy()
	later_ready[5] = 3
	later_ready[7] = 10
	if(!failure && (!probe.dogmos_accept_job_response(later_ready, "poll") || !probe.dogmos_accept_job_response(committed, "commit")))
		failure = "The previous committed receipt was not replayable."
	if(!failure && (SSdogmos.dogmos_mixture_cache_epoch != committed_epoch || probe.num_equalize_processed != 7 || probe.dogmos_job.ready_unit[1] != 10))
		failure = "Receipt replay invalidated twice, double-counted work, or rewound the ready token."
	if(!failure && !SSdogmos.equal_u64_words(sequence_before, SSdogmos.dogmos_next_callback_sequence))
		failure = "Receipt handling dispatched callbacks before the existing phase boundary."
	qdel(probe.dogmos_job)
	probe.dogmos_job = null
	qdel(probe)
	if(failure)
		return Fail(failure, __FILE__, __LINE__)

/** Real preparation stays invisible; a different consumer's write survives conflict retry. */
/datum/unit_test/dogmos_runtime_scheduling/native_cache/Run()
	if(!dogmos_wait_for_stage_boundary())
		return
	var/list/original_active = SSair.active_turfs
	var/original_can_fire = SSair.can_fire
	var/original_mode = SSair.dogmos_async_stages
	var/original_work_limit = SSair.dogmos_stage_work_limit
	var/original_poll_tick = SSair.dogmos_job_last_poll_tick
	var/original_tick_limit = Master.current_ticklimit
	var/list/original_pressure_queue = SSair.high_pressure_delta.Copy()
	var/list/original_pressure = list()
	var/list/room_turfs = block(run_loc_floor_bottom_left, run_loc_floor_top_right)
	for(var/turf/open/fixture_turf as anything in room_turfs)
		original_pressure[fixture_turf] = list(fixture_turf.pressure_difference, fixture_turf.pressure_direction)
	var/turf/open/target = run_loc_floor_bottom_left
	var/failure
	var/native_clear = FALSE
	var/restored = FALSE
	SSair.can_fire = FALSE
	try
		Master.current_ticklimit = TICK_USAGE + 1000
		SSair.dogmos_async_stages = TRUE
		SSair.dogmos_stage_work_limit = 1
		SSair.dogmos_replace_active_frontier(room_turfs.Copy())
		SSair.dogmos_pending_frontier_epoch = null
		if(!dogmos_sync_fixture_frontier())
			CRASH("Could not publish the native job fixture frontier.")
		var/seeded = target.air.get_moles(/datum/gas/oxygen) + 100
		target.air.set_moles(/datum/gas/oxygen, seeded)
		target.air.dogmos_snapshot()
		var/list/seed_snapshot = dogmos_mixture_snapshot(list(target.air.dogmos_slot, target.air.dogmos_generation))
		var/epoch_before = SSdogmos.dogmos_mixture_cache_epoch
		if(!SSair.dogmos_run_stage(4, 100) || !SSair.dogmos_job?.id)
			CRASH("Real asynchronous diffusion was not admitted once.")
		// A real unrelated reader deliberately collides with our cache bucket while pending.
		var/bucket_count = length(SSdogmos.dogmos_mixture_cache)
		var/displaced = FALSE
		for(var/other_slot = ((target.air.dogmos_slot - 1) % bucket_count) + 1; other_slot <= length(SSdogmos.dogmos_mixture_slots); other_slot += bucket_count)
			if(other_slot == target.air.dogmos_slot || !SSdogmos.dogmos_mixture_slots[other_slot])
				continue
			SSdogmos.mixture_snapshot(other_slot, SSdogmos.dogmos_mixture_generations[other_slot])
			displaced = !SSdogmos.lookup_mixture_snapshot_cache(target.air.dogmos_slot, target.air.dogmos_generation)
			break
		if(!displaced)
			CRASH("The cache fixture could not establish a real unrelated bucket collision.")
		if(!wait_until_ready())
			CRASH("The native job did not reach its first Ready boundary.")
		// Other consumers may displace this direct-mapped bucket while the fixture sleeps.
		// Observe the service independently: a warm cache alone could hide early publication.
		var/list/cached_before_commit = SSdogmos.lookup_mixture_snapshot_cache(target.air.dogmos_slot, target.air.dogmos_generation)
		var/list/bucket_entry = SSdogmos.dogmos_mixture_cache[SSdogmos.mixture_snapshot_cache_bucket(target.air.dogmos_slot)]
		log_world("Native cache fixture witness: epoch [epoch_before] -> [SSdogmos.dogmos_mixture_cache_epoch], target [target.air.dogmos_slot]:[target.air.dogmos_generation], bucket [bucket_entry ? "[bucket_entry[1]]:[bucket_entry[2]]" : "empty"], resident [!!cached_before_commit].")
		if(SSdogmos.dogmos_mixture_cache_epoch != epoch_before)
			CRASH("Native preparation changed cache epoch [epoch_before] -> [SSdogmos.dogmos_mixture_cache_epoch] before Commit.")
		var/list/prepared_snapshot = dogmos_mixture_snapshot(list(target.air.dogmos_slot, target.air.dogmos_generation))
		if(!islist(seed_snapshot) || !islist(prepared_snapshot) || length(seed_snapshot) != 42 || length(prepared_snapshot) != 42)
			CRASH("Native preparation returned an invalid snapshot witness.")
		for(var/field in 1 to 42)
			if(prepared_snapshot[field] != seed_snapshot[field])
				CRASH("Native preparation published snapshot field [field]: [seed_snapshot[field]] -> [prepared_snapshot[field]] before Commit.")
		if(target.air.get_moles(/datum/gas/oxygen) != seeded)
			CRASH("The game gas reader disagrees with unpublished native preparation.")
		// The ordinary game API remains synchronous and sees its own committed write.
		var/live_write = seeded + 100
		target.air.set_moles(/datum/gas/oxygen, live_write)
		target.air.dogmos_snapshot()
		var/epoch_after_write = SSdogmos.dogmos_mixture_cache_epoch
		var/list/commit_fields = SSair.dogmos_job.id.Copy()
		commit_fields += SSair.dogmos_job.ready_unit
		var/list/retry = SSair.dogmos_job_request("commit", commit_fields)
		if(!SSair.dogmos_accept_job_response(retry, "commit") || retry[5] != 4)
			CRASH("A concurrent gas write did not force retry of unpublished preparation.")
		if(target.air.get_moles(/datum/gas/oxygen) != live_write || SSdogmos.dogmos_mixture_cache_epoch != epoch_after_write || !SSdogmos.lookup_mixture_snapshot_cache(target.air.dogmos_slot, target.air.dogmos_generation))
			CRASH("Failed publication overwrote the live write or invalidated its warm cache.")
		if(!wait_until_ready())
			CRASH("The native job did not prepare a replacement publication unit.")
		// Rewarm after the yielding preparation interval so this assertion witnesses Commit.
		target.air.dogmos_snapshot()
		if(!SSdogmos.lookup_mixture_snapshot_cache(target.air.dogmos_slot, target.air.dogmos_generation))
			CRASH("The publication fixture could not establish a warm snapshot immediately before Commit.")
		Master.current_ticklimit = TICK_USAGE + 1000
		if(SSair.dogmos_run_stage(4, 100) || SSair.dogmos_job || !isnull(SSair.dogmos_pending_stage))
			CRASH("The real SSair scheduler did not commit and retire the retried diffusion job.")
		native_clear = TRUE
		if(SSdogmos.dogmos_mixture_cache_epoch == epoch_after_write || SSdogmos.lookup_mixture_snapshot_cache(target.air.dogmos_slot, target.air.dogmos_generation))
			CRASH("Successful publication left a stale cached snapshot available.")
		if(target.air.get_moles(/datum/gas/oxygen) >= live_write)
			CRASH("The post-commit gas read did not observe real diffusion.")
	catch(var/exception/error)
		failure = "Native cache fixture raised [error.name]."
	try
		// Only a validated native cancellation allows restoration after a failed assertion.
		if(SSair.dogmos_job?.id && SSdogmos.service_ready)
			var/list/cancelled = SSair.dogmos_job_request("cancel", SSair.dogmos_job.id)
			if(islist(cancelled) && length(cancelled) == 26 && (cancelled[5] == 5 || cancelled[5] == 6) && SSdogmos.equal_u64_words(cancelled.Copy(1, 5), SSair.dogmos_job.id))
				QDEL_NULL(SSair.dogmos_job)
				SSair.dogmos_pending_stage = null
				native_clear = TRUE
		else if(!SSair.dogmos_job && isnull(SSair.dogmos_pending_stage))
			native_clear = TRUE
		if(native_clear && SSdogmos.service_ready && dogmos_drain_fixture_callbacks())
			SSair.dogmos_pending_frontier_epoch = null
			// The detached saved list misses ChangeTurf/removal hooks while this fixture sleeps.
			// Revalidate it and retain unrelated activations recorded in the borrowed live list.
			SSair.dogmos_replace_active_frontier(dogmos_restored_fixture_frontier(original_active, room_turfs, SSair.active_turfs))
			restored = dogmos_sync_fixture_frontier()
			SSair.dogmos_pending_frontier_epoch = null
	catch(var/exception/cleanup_error)
		failure = "[failure] Native cache cleanup raised [cleanup_error.name]."
	SSair.dogmos_async_stages = original_mode
	SSair.dogmos_stage_work_limit = original_work_limit
	SSair.dogmos_job_last_poll_tick = original_poll_tick
	Master.current_ticklimit = original_tick_limit
	SSair.high_pressure_delta.Cut()
	SSair.high_pressure_delta += original_pressure_queue
	for(var/turf/open/fixture_turf as anything in room_turfs)
		var/list/pressure = original_pressure[fixture_turf]
		fixture_turf.pressure_difference = pressure[1]
		fixture_turf.pressure_direction = pressure[2]
	if(!native_clear || !restored)
		return dogmos_abort_fixture("[failure] Native job cleanup could not prove a safe restored frontier.")
	SSair.can_fire = original_can_fire
	if(failure)
		return Fail(failure, __FILE__, __LINE__)

/// Polls at separated ticks without authorizing publication, within a fixed fixture bound.
/datum/unit_test/dogmos_runtime_scheduling/native_cache/proc/wait_until_ready()
	for(var/attempt in 1 to 100)
		sleep(world.tick_lag)
		if(!SSdogmos.service_ready || !SSair.dogmos_job?.id)
			return FALSE
		var/list/response = SSair.dogmos_job_request("poll", SSair.dogmos_job.id)
		if(!SSair.dogmos_accept_job_response(response, "poll"))
			return FALSE
		if(SSair.dogmos_job.ready_unit)
			return TRUE
	return FALSE

/** Reconciles saved fixture membership with turf lifetimes and unrelated live activations. */
/datum/unit_test/proc/dogmos_restored_fixture_frontier(list/original, list/owned, list/current)
	var/list/restored = list()
	for(var/turf/open/member in original)
		if(member.air)
			restored |= member
	for(var/turf/open/member in current)
		if(member.air && !(member in owned))
			restored |= member
	return restored

/datum/unit_test/dogmos_runtime_scheduling/fixture_frontier/Run()
	var/turf/open/original = run_loc_floor_bottom_left
	var/turf/open/activated = get_step(original, EAST)
	var/turf/open/owned = get_step(activated, EAST)
	var/turf/closed/closed
	for(var/turf/closed/candidate in Z_TURFS(original.z))
		closed = candidate
		break
	if(!closed)
		return Fail("The fixture needs a closed turf to represent a saved reference retargeted by ChangeTurf.", __FILE__, __LINE__)
	var/list/restored = dogmos_restored_fixture_frontier(list(original, closed, original), list(owned), list(activated, owned, closed))
	if(length(restored) != 2 || restored[1] != original || restored[2] != activated)
		return Fail("Fixture restoration retained a closed/duplicate/owned-only turf or lost an unrelated activation.", __FILE__, __LINE__)

/** Malformed control replies close admission without a cache publication or fallback. */
/datum/unit_test/dogmos_runtime_scheduling/failures/Run()
	var/original_limit = Master.current_ticklimit
	var/original_ready = SSdogmos.service_ready
	var/original_latched = SSdogmos.service_failure_latched
	var/original_sequence = SSdogmos.dogmos_next_callback_sequence.Copy()
	var/failure
	for(var/failure_point in list("submit", "poll", "commit", "mixed mode", "missing identity", "wrong stage"))
		var/datum/controller/subsystem/air/recovery_test_copy/job_probe/failure_probe/probe = allocate(/datum/controller/subsystem/air/recovery_test_copy/job_probe/failure_probe)
		try
			Master.current_ticklimit = TICK_USAGE + 1000
			SSdogmos.service_ready = original_ready
			SSdogmos.service_failure_latched = original_latched
			probe.can_fire = TRUE
			if(failure_point != "submit")
				probe.dogmos_pending_stage = 4
				probe.dogmos_job = allocate(/datum/dogmos_stage_job, 4)
				if(!probe.dogmos_accept_job_response(probe.dogmos_job_request("submit", list()), "submit"))
					CRASH("Could not establish the controlled job before [failure_point].")
				probe.dogmos_job_last_poll_tick = -1
				if(failure_point == "commit")
					probe.dogmos_job.status = 3
					probe.dogmos_job.ready_unit = list(9, 0, 0, 0)
				if(failure_point == "mixed mode")
					probe.dogmos_async_stages = FALSE
				if(failure_point == "missing identity")
					probe.dogmos_job.id = null
				if(failure_point == "wrong stage")
					probe.dogmos_job.stage = 5
			probe.failure_operation = failure_point
			var/epoch_before = SSdogmos.dogmos_mixture_cache_epoch
			if(!probe.dogmos_run_stage(4, 100) || probe.failure_calls != 1)
				CRASH("[failure_point] did not route through the failure latch exactly once.")
			if(probe.can_fire || SSdogmos.service_ready || !SSdogmos.service_failure_latched)
				CRASH("[failure_point] left atmosphere processing available after a fatal reply.")
			if(probe.dogmos_job || probe.dogmos_pending_frontier_epoch || !isnull(probe.dogmos_pending_stage))
				CRASH("[failure_point] retained failed job ownership.")
			if(probe.num_equalize_processed || SSdogmos.dogmos_mixture_cache_epoch != epoch_before || !SSdogmos.equal_u64_words(SSdogmos.dogmos_next_callback_sequence, original_sequence))
				CRASH("[failure_point] consumed publication or callbacks from an invalid response.")
			var/requests_before = probe.submit_calls + probe.poll_calls + probe.commit_calls
			probe.dogmos_run_stage(4, 100)
			if(probe.failure_calls != 1 || requests_before != probe.submit_calls + probe.poll_calls + probe.commit_calls)
				CRASH("[failure_point] retried a failed job instead of retaining the latch.")
		catch(var/exception/error)
			failure = "Failure-path fixture at [failure_point] raised [error.name]."
		SSdogmos.service_ready = original_ready
		SSdogmos.service_failure_latched = original_latched
		QDEL_NULL(probe.dogmos_job)
		qdel(probe)
		if(failure)
			break
	Master.current_ticklimit = original_limit
	if(failure)
		return Fail(failure, __FILE__, __LINE__)

/datum/controller/subsystem/air/recovery_test_copy/job_probe/failure_probe
	var/failure_operation
	var/failure_calls = 0

/datum/controller/subsystem/air/recovery_test_copy/job_probe/failure_probe/dogmos_job_request(operation, list/fields)
	var/list/response = ..()
	if(operation == failure_operation)
		if(operation == "submit")
			return null
		if(operation == "poll")
			response[4] = 65534 // A different exact high word must not be treated as our job.
		if(operation == "commit")
			response[7] = 8 // A stale publication unit must not acknowledge the current one.
	return response

/datum/controller/subsystem/air/recovery_test_copy/job_probe/failure_probe/dogmos_fail_closed_stage(stage, schedule_reboot = TRUE)
	failure_calls++
	return ..(stage, FALSE)

/** Recovery preserves one owner across admission, preparation, readiness and callback draining. */
/datum/unit_test/dogmos_runtime_scheduling/recovery_phases/Run()
	var/list/saved = list()
	for(var/field in list("dogmos_async_stages", "dogmos_job", "dogmos_job_last_poll_tick"))
		saved[field] = SSair.vars[field]
	var/datum/controller/subsystem/air/recovery_test_copy/recovered
	var/datum/dogmos_stage_job/fixture_job = allocate(/datum/dogmos_stage_job, 4)
	fixture_job.id = list(1, 2, 3, 65535)
	fixture_job.committed_units = list(65535, 65535, 0, 0)
	fixture_job.committed_unit = list(8, 7, 6, 65535)
	fixture_job.committed_counts = list(11, 12, 13, 14, 15, 16, 17, 18)
	var/list/callback_sequence = SSdogmos.dogmos_next_callback_sequence
	var/list/callback_batch = SSdogmos.dogmos_pending_callback_batch
	var/callback_cursor = SSdogmos.dogmos_pending_callback_index
	var/failure
	try
		for(var/job_status in list(1, 2, 3, 4, 5))
			fixture_job.status = job_status
			fixture_job.ready_unit = job_status == 3 ? list(9, 7, 6, 65535) : null
			SSair.dogmos_async_stages = TRUE
			SSair.dogmos_job = fixture_job
			SSair.dogmos_job_last_poll_tick = world.time
			recovered = allocate(/datum/controller/subsystem/air/recovery_test_copy)
			recovered.Recover()
			if(!recovered.dogmos_async_stages || recovered.dogmos_job != fixture_job || recovered.dogmos_job_last_poll_tick != SSair.dogmos_job_last_poll_tick)
				CRASH("Job status [job_status] lost its owner, mode or poll fence during recovery.")
			if(recovered.dogmos_job.status != job_status || recovered.dogmos_job.committed_units != fixture_job.committed_units || recovered.dogmos_job.ready_unit != fixture_job.ready_unit)
				CRASH("Job status [job_status] lost its exact publication state during recovery.")
			if(SSdogmos.dogmos_next_callback_sequence != callback_sequence || SSdogmos.dogmos_pending_callback_batch != callback_batch || SSdogmos.dogmos_pending_callback_index != callback_cursor)
				CRASH("Job status [job_status] moved the service-owned callback cursor during air recovery.")
			QDEL_NULL(recovered)
	catch(var/exception/error)
		failure = "Job recovery fixture raised [error.name]."
	QDEL_NULL(recovered)
	for(var/field in saved)
		SSair.vars[field] = saved[field]
	qdel(fixture_job)
	if(failure)
		return Fail(failure, __FILE__, __LINE__)


#endif
