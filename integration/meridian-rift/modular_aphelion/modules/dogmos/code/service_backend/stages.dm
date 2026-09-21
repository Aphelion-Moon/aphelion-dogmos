#if defined(UNIT_TESTS) || defined(SPACEMAN_DMM)
/datum/controller/subsystem/air
	/// Opt-in test aggregates: calls, requested work, RPC ms, peak RPC, budgets, peak limit, executed work, short responses.
	var/list/dogmos_stage_test_samples
#endif

/** Returns the next bounded work limit for the remaining SSair budget. */
/datum/controller/subsystem/air/proc/dogmos_work_limit_for_budget(remaining_ms)
	// Background SSair often receives less than one millisecond. Rejecting every such
	// allocation can starve a pending stage even while the MC repeatedly resumes it.
	if(remaining_ms <= 0)
		return 0
	var/budget_ratio = min(1, remaining_ms / DOGMOS_STAGE_FULL_BUDGET_MS)
	return max(1, min(dogmos_stage_work_limit, floor(dogmos_stage_work_limit * budget_ratio)))

/** Reports an exhausted Dogmos stage so the subsystem can pause after returning. */
/datum/controller/subsystem/air/proc/dogmos_defer_stage_for_budget()
	return TRUE

/** Returns whether a service stage response has the fixed-width numeric wire shape. */
/datum/controller/subsystem/air/proc/dogmos_stage_response_is_valid(stage, response)
	if(!isnum(stage) || !islist(response) || length(response) != DOGMOS_STAGE_RESPONSE_FIELDS)
		return FALSE
	for(var/field in response)
		if(!isnum(field))
			return FALSE
	return TRUE

/** Clears irrecoverable stage state, freezes SSair, and schedules controlled server shutdown.
 *
 * Arguments:
 * * stage - Simulation stage that failed.
 * * schedule_reboot - Whether to schedule the production reboot; FALSE is reserved for unit tests.
 */
/datum/controller/subsystem/air/proc/dogmos_fail_closed_stage(stage, schedule_reboot = TRUE)
	dogmos_clear_machinery_prefetch()
	QDEL_NULL(dogmos_job)
	dogmos_pending_stage = null
	dogmos_pending_frontier_epoch = null
	dogmos_stage_remaining_estimate = 0
	dogmos_active_turf_stages_complete = FALSE
	dogmos_equalize_stage_complete = FALSE
	dogmos_fdm_steps_completed = 0
	dogmos_active_walk_complete = FALSE
	active_turfs_walk_cursor = 0
	dogmos_visual_refresh_cursor = 0
	dogmos_walk_prefetch_end = 0
	dogmos_visual_prefetch_end = 0
	dogmos_visual_refresh_batch = list()
	dogmos_resume_recovered_cycle = FALSE
	dogmos_reacted_turfs = list()
	can_fire = FALSE
	SSdogmos.service_failure_latched = TRUE
	SSdogmos.service_ready = FALSE
	if(schedule_reboot)
		var/reason = "Dogmos atmosphere stage [stage] failed; authoritative atmosphere processing is unavailable."
		log_game(reason)
		SSticker.Reboot(reason, "dogmos service failure", 1 SECONDS)
	return TRUE

/// Fixed-size DM ownership for one service job. It never retains turfs or mixtures.
/datum/dogmos_stage_job
	/// Simulation stage selected at admission.
	var/stage
	/// Exact service job identity, assigned by Submit.
	var/list/id
	/// Exact unpublished unit waiting for a fresh MC budget.
	var/list/ready_unit
	/// Last service status; preparation does not authorize publication.
	var/status = 0
	/// Exact cumulative publication count already acknowledged by DM.
	var/list/committed_units = list(0, 0, 0, 0)
	/// Last committed token, retained for receipt replay validation.
	var/list/committed_unit = list(0, 0, 0, 0)
	/// Exact cumulative equalize/group/heat/callback u32 word pairs.
	var/list/committed_counts = list(0, 0, 0, 0, 0, 0, 0, 0)
	/// Admission time for diagnostic age; it does not change simulated seconds.
	var/started_at

/datum/dogmos_stage_job/New(stage)
	src.stage = stage
	started_at = world.time

/** Validates publication ownership before the caller invalidates or consumes anything. */
/datum/dogmos_stage_job/proc/response_is_valid(list/response, operation)
	if(!islist(response) || length(response) != DOGMOS_JOB_RESPONSE_FIELDS)
		return FALSE
	for(var/word in response)
		if(!isnum(word) || !IS_FINITE(word) || word < 0 || word > 65535 || round(word) != word)
			return FALSE
	if(response[DOGMOS_JOB_STAGE] != stage || !word_group_nonzero(response, DOGMOS_DM_JOB_RESPONSE_JOB, 4))
		return FALSE
	var/next_status = response[DOGMOS_JOB_STATUS]
	if(next_status < DOGMOS_JOB_ACCEPTED || next_status > DOGMOS_JOB_DONE)
		return FALSE
	if(next_status == DOGMOS_JOB_DONE && (response[DOGMOS_DM_JOB_RESPONSE_REMAINING] || response[DOGMOS_DM_JOB_RESPONSE_REMAINING + 1]))
		return FALSE
	if(operation == "submit")
		if(id || next_status != DOGMOS_JOB_ACCEPTED)
			return FALSE
		for(var/index in DOGMOS_DM_JOB_RESPONSE_UNIT to DOGMOS_JOB_RESPONSE_FIELDS)
			if(response[index])
				return FALSE
		return TRUE
	if(!SSdogmos.equal_u64_words(id, response.Copy(DOGMOS_DM_JOB_RESPONSE_JOB, DOGMOS_DM_JOB_RESPONSE_STATUS)))
		return FALSE
	if(operation != "poll" && operation != "commit")
		return FALSE
	var/same_count = SSdogmos.equal_u64_words(committed_units, response.Copy(DOGMOS_DM_JOB_RESPONSE_COMMITTED_UNITS, DOGMOS_DM_JOB_RESPONSE_EQUALIZE_SEEDS))
	var/list/unit = response.Copy(DOGMOS_DM_JOB_RESPONSE_UNIT, DOGMOS_DM_JOB_RESPONSE_WORK_ITEMS)
	if(operation == "commit" && (next_status == DOGMOS_JOB_RUNNING || next_status == DOGMOS_JOB_DONE))
		if(!word_group_nonzero(response, DOGMOS_DM_JOB_RESPONSE_UNIT, 4))
			return FALSE
		if(same_count)
			// Replaying the last receipt cannot reset a newer prepared unit.
			return SSdogmos.equal_u64_words(unit, committed_unit) && counts_match(response)
		if(!SSdogmos.equal_u64_words(unit, ready_unit) || SSdogmos.equal_u64_words(unit, committed_unit))
			return FALSE
		var/list/next_count = committed_units.Copy()
		var/advanced = FALSE
		for(var/index in 1 to 4)
			if(next_count[index] < 65535)
				next_count[index]++
				advanced = TRUE
				break
			next_count[index] = 0
		if(!advanced || !SSdogmos.equal_u64_words(next_count, response.Copy(DOGMOS_DM_JOB_RESPONSE_COMMITTED_UNITS, DOGMOS_DM_JOB_RESPONSE_EQUALIZE_SEEDS)))
			return FALSE
		for(var/index = 1; index <= 8; index += 2)
			if(response[index + DOGMOS_DM_JOB_RESPONSE_EQUALIZE_SEEDS] < committed_counts[index + 1] \
				|| (response[index + DOGMOS_DM_JOB_RESPONSE_EQUALIZE_SEEDS] == committed_counts[index + 1] && response[index + DOGMOS_DM_JOB_RESPONSE_EQUALIZE_SEEDS - 1] < committed_counts[index]))
				return FALSE
		return TRUE
	if(operation == "commit" && next_status != DOGMOS_JOB_RETRYING)
		return FALSE
	if(!same_count || !counts_match(response))
		return FALSE
	if(next_status == DOGMOS_JOB_READY)
		return word_group_nonzero(response, DOGMOS_DM_JOB_RESPONSE_UNIT, 4) && !SSdogmos.equal_u64_words(unit, committed_unit)
	if(next_status == DOGMOS_JOB_ACCEPTED && status != DOGMOS_JOB_ACCEPTED)
		return FALSE
	return SSdogmos.equal_u64_words(unit, committed_unit)

/// Checks a bounded word group without converting a u64 identity to a DM float.
/datum/dogmos_stage_job/proc/word_group_nonzero(list/words, start, count)
	for(var/index in start to (start + count - 1))
		if(words[index])
			return TRUE
	return FALSE

/// Polls and retries must preserve every already acknowledged publication count.
/datum/dogmos_stage_job/proc/counts_match(list/response)
	for(var/index in 1 to 8)
		if(response[index + DOGMOS_DM_JOB_RESPONSE_EQUALIZE_SEEDS - 1] != committed_counts[index])
			return FALSE
	return TRUE

/** Sends one bounded control request. No session lock survives this proc's return. */
/datum/controller/subsystem/air/proc/dogmos_job_request(operation, list/fields)
	switch(operation)
		if("submit")
			return dogmos_stage_job_submit(fields)
		if("poll")
			return dogmos_stage_job_poll(fields)
		if("commit")
			return dogmos_stage_job_commit(fields)
		if("cancel")
			return dogmos_stage_job_cancel(fields)
	CRASH("Invalid internal Dogmos job operation [operation].")

/** Uses both the caller's remaining allowance and the current MC allocation. */
/datum/controller/subsystem/air/proc/dogmos_job_budget_ms(remaining_ms, started_tick_usage)
	return min(remaining_ms - TICK_DELTA_TO_MS(TICK_USAGE - started_tick_usage), \
		TICK_DELTA_TO_MS(Master.current_ticklimit - TICK_USAGE))

/** Invalidates caches at the publication boundary before counters, callbacks or a pause. */
/datum/controller/subsystem/air/proc/dogmos_accept_job_response(list/response, operation)
	if(!dogmos_job?.response_is_valid(response, operation))
		return FALSE
	var/new_publication = !SSdogmos.equal_u64_words(dogmos_job.committed_units, response.Copy(DOGMOS_DM_JOB_RESPONSE_COMMITTED_UNITS, DOGMOS_DM_JOB_RESPONSE_EQUALIZE_SEEDS))
	if(new_publication)
		SSdogmos.invalidate_mixture_snapshot_epoch()
		num_equalize_processed += (response[DOGMOS_DM_JOB_RESPONSE_EQUALIZE_SEEDS] - dogmos_job.committed_counts[1]) \
			+ 65536 * (response[DOGMOS_DM_JOB_RESPONSE_EQUALIZE_SEEDS + 1] - dogmos_job.committed_counts[2])
		num_group_turfs_processed += (response[DOGMOS_DM_JOB_RESPONSE_GROUP_SEEDS] - dogmos_job.committed_counts[3]) \
			+ 65536 * (response[DOGMOS_DM_JOB_RESPONSE_GROUP_SEEDS + 1] - dogmos_job.committed_counts[4])
		dogmos_job.committed_units = response.Copy(DOGMOS_DM_JOB_RESPONSE_COMMITTED_UNITS, DOGMOS_DM_JOB_RESPONSE_EQUALIZE_SEEDS)
		dogmos_job.committed_unit = response.Copy(DOGMOS_DM_JOB_RESPONSE_UNIT, DOGMOS_DM_JOB_RESPONSE_WORK_ITEMS)
		dogmos_job.committed_counts = response.Copy(DOGMOS_DM_JOB_RESPONSE_EQUALIZE_SEEDS, DOGMOS_DM_JOB_RESPONSE_FIELDS + 1)
	else if(operation == "commit" && response[DOGMOS_JOB_STATUS] != DOGMOS_JOB_RETRYING)
		return TRUE // Exact receipt replay: no second invalidation or cursor rewind.
	if(operation == "submit")
		dogmos_job.id = response.Copy(DOGMOS_DM_JOB_RESPONSE_JOB, DOGMOS_DM_JOB_RESPONSE_STATUS)
	dogmos_job.status = response[DOGMOS_JOB_STATUS]
	dogmos_job.ready_unit = dogmos_job.status == DOGMOS_JOB_READY ? response.Copy(DOGMOS_DM_JOB_RESPONSE_UNIT, DOGMOS_DM_JOB_RESPONSE_WORK_ITEMS) : null
	dogmos_stage_remaining_estimate = SSdogmos.join_u32_words(response[DOGMOS_DM_JOB_RESPONSE_REMAINING], response[DOGMOS_DM_JOB_RESPONSE_REMAINING + 1])
	return TRUE

/** Admits once, polls once per game tick, and publishes only under a fresh MC budget. */
/datum/controller/subsystem/air/proc/dogmos_run_async_stage(stage, remaining_ms, started_tick_usage)
	if(!dogmos_job)
		if(!isnull(dogmos_pending_stage))
			return dogmos_fail_closed_stage(stage)
		var/work_limit = dogmos_work_limit_for_budget(dogmos_job_budget_ms(remaining_ms, started_tick_usage))
		if(!work_limit)
			return dogmos_defer_stage_for_budget()
		dogmos_stage_epoch = SSdogmos.increment_u64_words(dogmos_stage_epoch)
		dogmos_pending_stage = stage
		dogmos_job = new(stage)
		var/list/request = list(stage)
		request += dogmos_pending_frontier_epoch
		request += dogmos_stage_epoch
		request += SSdogmos.split_u32_words(work_limit)
		request += wait * 0.1
		request += DOGMOS_JOB_QUANTUM_US
		dogmos_job_last_poll_tick = world.time
		if(!dogmos_accept_job_response(dogmos_job_request("submit", request), "submit"))
			return dogmos_fail_closed_stage(stage)
		return pause_until_next_tick()
	if(dogmos_job.stage != stage || !dogmos_job.id)
		return dogmos_fail_closed_stage(stage)
	if(!dogmos_job.ready_unit)
		if(dogmos_job_last_poll_tick == world.time)
			return pause_until_next_tick()
		if(dogmos_job_budget_ms(remaining_ms, started_tick_usage) <= 0)
			return dogmos_defer_stage_for_budget()
		dogmos_job_last_poll_tick = world.time
		if(!dogmos_accept_job_response(dogmos_job_request("poll", dogmos_job.id), "poll"))
			return dogmos_fail_closed_stage(stage)
	if(dogmos_job.ready_unit)
		if(dogmos_job_budget_ms(remaining_ms, started_tick_usage) <= 0)
			return dogmos_defer_stage_for_budget()
		var/list/request = dogmos_job.id.Copy()
		request += dogmos_job.ready_unit
		if(!dogmos_accept_job_response(dogmos_job_request("commit", request), "commit"))
			return dogmos_fail_closed_stage(stage)
	if(dogmos_job.status == DOGMOS_JOB_DONE)
		QDEL_NULL(dogmos_job)
		dogmos_pending_stage = null
		dogmos_stage_remaining_estimate = 0
		return FALSE
	return pause_until_next_tick()

/** Runs bounded continuations until this stage completes or the caller's time budget is spent. */
/datum/controller/subsystem/air/proc/dogmos_run_stage(stage, remaining_ms)
	var/start_tick_usage = TICK_USAGE
	if(!SSdogmos.service_ready)
		if(!SSdogmos.service_failure_latched && !SSdogmos.service_shutdown_requested)
			CRASH("dogmosd became unavailable during SSair processing.")
		return TRUE
	if(!isnull(dogmos_pending_stage) && dogmos_pending_stage != stage)
		return TRUE
	if(dogmos_job && !dogmos_async_stages)
		return dogmos_fail_closed_stage(stage)
	if(!dogmos_work_limit_for_budget(remaining_ms))
		return dogmos_defer_stage_for_budget()
	if(!dogmos_pending_frontier_epoch)
		if(!sync_dogmos_frontier())
			return dogmos_fail_closed_stage(stage)
		if(dogmos_frontier_sync_pending)
			return TRUE
	if(dogmos_async_stages)
		return dogmos_run_async_stage(stage, remaining_ms, start_tick_usage)
	while(TRUE)
		// Include frontier publication and all prior chunks in this invocation's budget.
		var/budget_left_ms = remaining_ms - TICK_DELTA_TO_MS(TICK_USAGE - start_tick_usage)
		var/work_limit = dogmos_work_limit_for_budget(budget_left_ms)
		if(!work_limit)
			return dogmos_defer_stage_for_budget()
		if(isnull(dogmos_pending_stage))
			dogmos_stage_epoch = SSdogmos.increment_u64_words(dogmos_stage_epoch)
			dogmos_pending_stage = stage
		var/list/request = list(stage)
		request += dogmos_pending_frontier_epoch
		request += dogmos_stage_epoch
		request += SSdogmos.split_u32_words(work_limit)
		request += wait * 0.1
#if defined(UNIT_TESTS) || defined(SPACEMAN_DMM)
		var/diagnostic_tick_start = dogmos_stage_test_samples ? TICK_USAGE : 0
#endif
		var/list/response = dogmos_simulation_stage(request)
#if defined(UNIT_TESTS) || defined(SPACEMAN_DMM)
		if(dogmos_stage_test_samples)
			var/chunk_ms = TICK_DELTA_TO_MS(TICK_USAGE - diagnostic_tick_start)
			var/list/stage_sample = dogmos_stage_test_samples["[stage]"]
			if(!stage_sample)
				stage_sample = list(0, 0, 0, 0, 0, 0, 0, 0)
				dogmos_stage_test_samples["[stage]"] = stage_sample
			stage_sample[1]++
			stage_sample[2] += work_limit
			stage_sample[3] += chunk_ms
			stage_sample[4] = max(stage_sample[4], chunk_ms)
			stage_sample[5] += budget_left_ms
			stage_sample[6] = max(stage_sample[6], work_limit)
#endif
		if(!dogmos_stage_response_is_valid(stage, response))
			stack_trace("dogmosd failed or returned a malformed response for stage [stage]; SSair is failing closed.")
			return dogmos_fail_closed_stage(stage)
		// Diffusion publishes atomically on completion; pending preparation and retries
		// leave authoritative mixtures unchanged. Other stages retain conservative
		// invalidation because component stages can publish while still pending.
		var/executed_work = SSdogmos.join_u32_words(response[DOGMOS_DM_STAGE_RESPONSE_WORK_ITEMS], response[DOGMOS_DM_STAGE_RESPONSE_WORK_ITEMS + 1])
#if defined(UNIT_TESTS) || defined(SPACEMAN_DMM)
		if(dogmos_stage_test_samples)
			var/list/work_sample = dogmos_stage_test_samples["[stage]"]
			work_sample[7] += executed_work
			work_sample[8] += executed_work < work_limit
#endif
		if(executed_work && (stage != DOGMOS_SIMULATION_TURFS || !response[DOGMOS_STAGE_RESPONSE_PENDING]))
			SSdogmos.invalidate_mixture_snapshot_epoch()
		num_equalize_processed += SSdogmos.join_u32_words(response[DOGMOS_DM_STAGE_RESPONSE_EQUALIZE_SEEDS], response[DOGMOS_DM_STAGE_RESPONSE_EQUALIZE_SEEDS + 1])
		num_group_turfs_processed += SSdogmos.join_u32_words(response[DOGMOS_DM_STAGE_RESPONSE_GROUP_SEEDS], response[DOGMOS_DM_STAGE_RESPONSE_GROUP_SEEDS + 1])
		dogmos_stage_remaining_estimate = SSdogmos.join_u32_words(response[DOGMOS_DM_STAGE_RESPONSE_REMAINING], response[DOGMOS_DM_STAGE_RESPONSE_REMAINING + 1])
		if(!response[DOGMOS_STAGE_RESPONSE_PENDING])
			dogmos_pending_stage = null
			dogmos_stage_remaining_estimate = 0
			return FALSE

/**
 * Processes the configured number of active-turf FDM passes in dogmosd.
 *
 * Each pass is independently resumable. The remaining budget is reduced after every completed
 * pass so a more aggressive convergence setting cannot silently consume the next server tick.
 *
 * Arguments:
 * * remaining - Milliseconds remaining in the current SSair budget.
 */
/datum/controller/subsystem/air/proc/process_turfs_auxtools(remaining)
	var/start_tick_usage = TICK_USAGE
	var/remaining_ms = max(0, remaining)
	var/step_limit = max(1, round(share_max_steps))
	while(dogmos_fdm_steps_completed < step_limit)
		if(dogmos_run_stage(DOGMOS_SIMULATION_TURFS, remaining_ms))
			return TRUE
		dogmos_fdm_steps_completed++
		remaining_ms = max(0, remaining - TICK_DELTA_TO_MS(TICK_USAGE - start_tick_usage))
	return FALSE

/// Processes active-turf reactions in dogmosd.
/datum/controller/subsystem/air/proc/process_reactions_auxtools(remaining)
	return dogmos_run_stage(DOGMOS_SIMULATION_REACTIONS, remaining)

/// Processes equalization in dogmosd.
/datum/controller/subsystem/air/proc/process_turf_equalize_auxtools(remaining)
	return dogmos_run_stage(DOGMOS_SIMULATION_TURF_EQUALIZE, remaining)

/// Processes excited groups in dogmosd.
/datum/controller/subsystem/air/proc/process_excited_groups_auxtools(remaining)
	return dogmos_run_stage(DOGMOS_SIMULATION_EXCITED_GROUPS, remaining)

/// Processes the turf heat graph in dogmosd.
/datum/controller/subsystem/air/proc/process_turf_heat()
	var/pending = dogmos_run_stage(DOGMOS_SIMULATION_TURF_HEAT, TICK_DELTA_TO_MS(Master.current_ticklimit - TICK_USAGE))
	if(!pending)
		dogmos_pending_frontier_epoch = null
		dogmos_active_turf_stages_complete = FALSE
		SSdogmos.flush_turf_registration_batch()
	return pending

/// Drains one bounded callback batch after service processing.
/datum/controller/subsystem/air/proc/finish_turf_processing_auxtools(time_remaining)
	return process_atmos_callbacks(time_remaining)
