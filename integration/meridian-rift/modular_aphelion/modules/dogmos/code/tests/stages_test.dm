#if defined(UNIT_TESTS) || defined(SPACEMAN_DMM)
#define DOGMOS_WORLD_GENERATION_WORD_MAX 65535
#define DOGMOS_TEST_STAGE_EXCITED_GROUPS 1
#define DOGMOS_TEST_STAGE_EQUALIZE 2
#define DOGMOS_TEST_STAGE_TURF_HEAT 3
#define DOGMOS_TEST_STAGE_TURFS 4
#define DOGMOS_TEST_STAGE_REACTIONS 5
#define DOGMOS_TEST_STAGE_BOUNDARY_ATTEMPTS 100
#define DOGMOS_TEST_STAGE_RESPONSE_FIELDS 13
#define DOGMOS_PIPELINE_TEST_EPSILON 0.001
#define DOGMOS_TEST_OVERSIZED_PIPELINE_MIXTURES 228
#define DOGMOS_TEST_IDLE_MC_SETTLE_TIME 30 SECONDS
#define DOGMOS_TEST_RESPONSE_APPLIED 1
#define DOGMOS_TEST_SNAPSHOT_REVISION_LOW 1
#define DOGMOS_TEST_SNAPSHOT_REVISION_HIGH 2

/** Verifies an exhausted MC budget returns control without sleeping inside SSair. */
/datum/unit_test/dogmos_service_stage_budget_progress

/datum/unit_test/dogmos_service_stage_budget_progress/Run()
	var/original_work_limit = SSair.dogmos_stage_work_limit
	SSair.dogmos_stage_work_limit = 128
	var/zero_budget_limit = SSair.dogmos_work_limit_for_budget(0)
	var/overrun_budget_limit = SSair.dogmos_work_limit_for_budget(-1)
	SSair.dogmos_stage_work_limit = original_work_limit
	var/defer_start = world.time
	var/deferred = SSair.dogmos_defer_stage_for_budget()

	if(zero_budget_limit)
		return Fail("Dogmos scheduled service work despite an exhausted MC budget.", __FILE__, __LINE__)
	if(overrun_budget_limit)
		return Fail("Dogmos scheduled service work after an MC overrun.", __FILE__, __LINE__)
	if(!deferred)
		return Fail("Dogmos did not report an exhausted stage as deferred.", __FILE__, __LINE__)
	if(world.time != defer_start)
		return Fail("Dogmos slept inside SSair while deferring an exhausted stage.", __FILE__, __LINE__)

/** Verifies a positive fractional MC allocation can finish bounded native diffusion work. */
/datum/unit_test/dogmos_service_fractional_budget_progress

/datum/unit_test/dogmos_service_fractional_budget_progress/Run()
	if(!SSair.dogmos_work_limit_for_budget(0.25))
		return Fail("Dogmos refuses all native work for a positive 0.25 ms MC allocation.", __FILE__, __LINE__)
	if(!dogmos_wait_for_stage_boundary())
		return
	var/list/pair = allocate_turf_pair()
	var/turf/open/hot_turf = pair[1]
	var/turf/open/cold_turf = pair[2]
	hot_turf.air.set_moles(GAS_O2, 100)
	cold_turf.air.set_moles(GAS_O2, 10)
	// The active pair exchanges gas with passive neighbors. The sealed test room,
	// rather than just the active frontier, is the conserved volume.
	var/list/room_turfs = block(run_loc_floor_bottom_left, run_loc_floor_top_right)
	var/oxygen_before = 0
	for(var/turf/open/room_turf in room_turfs)
		oxygen_before += room_turf.air.get_moles(GAS_O2)
	var/original_work_limit = SSair.dogmos_stage_work_limit
	SSair.dogmos_stage_work_limit = 1
	var/completed = dogmos_run_fixture_stage(DOGMOS_TEST_STAGE_TURFS, pair, chunk_budget_ms = 0.25)
	SSair.dogmos_stage_work_limit = original_work_limit
	if(!completed)
		return
	var/hot_moles = hot_turf.air.get_moles(GAS_O2)
	var/cold_moles = cold_turf.air.get_moles(GAS_O2)
	if(hot_moles >= 100 || cold_moles <= 10)
		return Fail("Fractional-budget continuation did not diffuse the fixture's oxygen.", __FILE__, __LINE__)
	var/oxygen_after = 0
	for(var/turf/open/room_turf in room_turfs)
		oxygen_after += room_turf.air.get_moles(GAS_O2)
	if(abs(oxygen_after - oxygen_before) > DOGMOS_PIPELINE_TEST_EPSILON * length(room_turfs))
		return Fail("Fractional-budget continuation changed the sealed room's oxygen from [oxygen_before] to [oxygen_after] moles.", __FILE__, __LINE__)

/** Verifies native continuations consume the caller's remaining budget before yielding. */
/datum/unit_test/dogmos_service_stage_uses_remaining_budget

/datum/unit_test/dogmos_service_stage_uses_remaining_budget/Run()
	if(!dogmos_wait_for_stage_boundary())
		return
	var/list/pair = allocate_turf_pair()
	var/original_work_limit = SSair.dogmos_stage_work_limit
	SSair.dogmos_stage_work_limit = 1
	dogmos_run_fixture_stage(DOGMOS_TEST_STAGE_TURFS, pair, chunk_budget_ms = 100, require_budget_use = TRUE)
	SSair.dogmos_stage_work_limit = original_work_limit

/** Resuming after an exhausted entry budget must still start the equalizer. */
/datum/unit_test/dogmos_equalize_resume_after_empty_budget

/datum/unit_test/dogmos_equalize_resume_after_empty_budget/Run()
	if(!dogmos_wait_for_stage_boundary())
		return
	var/list/original_active = SSair.active_turfs
	var/list/original_pressure = SSair.high_pressure_delta
	var/list/original_samples = SSair.dogmos_stage_test_samples
	var/original_state = SSair.state
	var/original_tick_limit = Master.current_ticklimit
	var/list/fixture_turfs = block(run_loc_floor_bottom_left, run_loc_floor_top_right)
	var/list/original_pressure_fields = list()
	for(var/turf/open/fixture_turf as anything in fixture_turfs)
		original_pressure_fields[fixture_turf] = list(fixture_turf.pressure_difference, fixture_turf.pressure_direction)
	var/completion_field = "dogmos_equalize_stage_complete"
	var/original_completion = (completion_field in SSair.vars) ? SSair.vars[completion_field] : null
	var/failure
	var/restored = FALSE
	try
		SSair.dogmos_replace_active_frontier(fixture_turfs.Copy())
		SSair.high_pressure_delta = list()
		SSair.dogmos_stage_test_samples = list()
		if(!dogmos_sync_fixture_frontier())
			failure = "The equalizer-resume fixture could not publish its frontier."
		else
			SSair.state = SS_RUNNING
			Master.current_ticklimit = TICK_USAGE
			SSair.process_high_pressure_delta(FALSE)
			if(!isnull(SSair.dogmos_pending_stage))
				failure = "The exhausted initial budget unexpectedly started a native stage."
			else
				for(var/chunk in 1 to 4096)
					SSair.state = SS_RUNNING
					Master.current_ticklimit = TICK_USAGE + 100 / world.tick_lag
					SSair.process_high_pressure_delta(TRUE)
					if(isnull(SSair.dogmos_pending_stage) || !SSdogmos.service_ready)
						break
				var/list/equalize_calls = SSair.dogmos_stage_test_samples["[DOGMOS_TEST_STAGE_EQUALIZE]"]
				if(!equalize_calls || !equalize_calls[1])
					failure = "The equalizer was skipped when resuming after an exhausted entry budget."
				else if(isnull(SSair.dogmos_pending_stage))
					var/completed_call_count = equalize_calls[1]
					var/turf/open/first_pressure_turf = fixture_turfs[1]
					var/turf/open/second_pressure_turf = fixture_turfs[2]
					first_pressure_turf.pressure_difference = 0
					second_pressure_turf.pressure_difference = 0
					SSair.high_pressure_delta = list(first_pressure_turf, second_pressure_turf)
					SSair.state = SS_RUNNING
					Master.current_ticklimit = TICK_USAGE - 1
					SSair.process_high_pressure_delta(TRUE)
					if(length(SSair.high_pressure_delta) != 1 || SSair.state != SS_PAUSED)
						failure = "The pressure queue fixture did not yield with one entry remaining."
					SSair.state = SS_RUNNING
					Master.current_ticklimit = TICK_USAGE + 100 / world.tick_lag
					SSair.process_high_pressure_delta(TRUE)
					if(equalize_calls[1] != completed_call_count)
						failure = "A resumed pressure phase repeated an already completed equalizer."
					else if(length(SSair.high_pressure_delta))
						failure = "The resumed pressure phase left its final queue entry undrained."
		if(isnull(SSair.dogmos_pending_stage) && SSdogmos.service_ready && dogmos_drain_fixture_callbacks())
			SSair.dogmos_replace_active_frontier(original_active)
			SSair.dogmos_pending_frontier_epoch = null
			restored = dogmos_sync_fixture_frontier()
			SSair.dogmos_pending_frontier_epoch = null
	catch(var/exception/error)
		failure = "The equalizer-resume fixture raised [error.name]."
	SSair.dogmos_replace_active_frontier(original_active)
	SSair.high_pressure_delta = original_pressure
	for(var/turf/open/fixture_turf as anything in fixture_turfs)
		var/list/pressure_fields = original_pressure_fields[fixture_turf]
		fixture_turf.pressure_difference = pressure_fields[1]
		fixture_turf.pressure_direction = pressure_fields[2]
	SSair.dogmos_stage_test_samples = original_samples
	SSair.state = original_state
	Master.current_ticklimit = original_tick_limit
	if(completion_field in SSair.vars)
		SSair.vars[completion_field] = original_completion
	if(!restored)
		return dogmos_abort_fixture("The equalizer-resume fixture did not safely restore its frontier.")
	if(failure)
		return Fail(failure, __FILE__, __LINE__)

/** Matching neighboring gas is not sufficient to retire an unevaluated chemical reaction. */
/datum/unit_test/dogmos_uniform_reaction_before_settlement
	/// Second reactant and temperature select native fire or a continued non-fire DM reaction.
	var/second_gas = /datum/gas/oxygen
	var/seed_temperature = PLASMA_MINIMUM_BURN_TEMPERATURE + 500
	var/product_gas = /datum/gas/carbon_dioxide
	var/reaction_cycles = 1

/** BZ formation remains active across multiple identical-neighbor reaction cycles. */
/datum/unit_test/dogmos_uniform_reaction_before_settlement/slow_reaction
	second_gas = /datum/gas/nitrous_oxide
	seed_temperature = T20C
	product_gas = /datum/gas/bz
	reaction_cycles = 2

/datum/unit_test/dogmos_uniform_reaction_before_settlement/Run()
	if(!dogmos_wait_for_stage_boundary())
		return
	var/list/fixture_turfs = block(run_loc_floor_bottom_left, run_loc_floor_top_right)
	if(length(fixture_turfs) != 25)
		return Fail("The uniform reaction fixture needs its sealed 25-turf room.", __FILE__, __LINE__)
	var/list/saved_air = list()
	var/list/saved_turfs = list()
	for(var/field in list("active_turfs", "currentrun", "state", "times_fired", "high_pressure_delta", "active_turfs_walk_cursor", "dogmos_visual_refresh_batch", "dogmos_visual_refresh_cursor", "dogmos_active_walk_complete", "dogmos_active_turf_stages_complete", "dogmos_fdm_steps_completed", "dogmos_reacted_turfs", "dogmos_walk_prefetch_end", "dogmos_visual_prefetch_end", "kennel_reaction_magnitude_threshold", "kennel_fire_group_notable_size"))
		saved_air[field] = SSair.vars[field]
	var/saved_tick_limit = Master.current_ticklimit
	var/datum/gas_mixture/seed = allocate(/datum/gas_mixture, CELL_VOLUME)
	seed.set_moles(/datum/gas/plasma, 50)
	seed.set_moles(second_gas, 200)
	seed.set_temperature(seed_temperature)
	var/datum/gas_mixture/reference = seed.copy()
	allocated += reference
	for(var/turf/open/fixture_turf as anything in fixture_turfs)
		if(!fixture_turf.air || fixture_turf.active_hotspot || !fixture_turf.dogmos_air_registration_is_current())
			return Fail("The uniform reaction needs an open fixture without an existing hotspot.", __FILE__, __LINE__)
		for(var/turf/neighbor as anything in fixture_turf.atmos_adjacent_turfs)
			if(!(neighbor in fixture_turfs))
				return Fail("The uniform reaction fixture is not sealed from outside gas.", __FILE__, __LINE__)
			if(!(fixture_turf in neighbor.atmos_adjacent_turfs))
				return Fail("The uniform reaction fixture has asymmetric gas adjacency.", __FILE__, __LINE__)
		var/datum/gas_mixture/saved_mix = fixture_turf.air.copy()
		allocated += saved_mix
		saved_turfs[fixture_turf] = list(saved_mix, fixture_turf.excited, fixture_turf.excited_group, fixture_turf.current_cycle, fixture_turf.archived_cycle, fixture_turf.pressure_difference, fixture_turf.pressure_direction, fixture_turf.air.reaction_results?.Copy(), fixture_turf.kennel_last_reaction_results?.Copy())
	var/failure
	var/restored = FALSE
	try
		// Keep this numerical fixture out of the shared Kennel event/overlay history.
		SSair.kennel_reaction_magnitude_threshold = INFINITY
		SSair.kennel_fire_group_notable_size = INFINITY
		// A turf fire also creates a hotspot whose initialization reacts gas again.
		// Obtain the reference through the same real holder and callback behavior.
		var/turf/open/reference_turf = fixture_turfs[1]
		reference_turf.air.copy_from(seed)
		reference_turf.air.react(reference_turf)
		reference.copy_from(reference_turf.air)
		if(reference.get_moles(product_gas) <= 0)
			failure = "The uniform-reaction reference did not produce its expected gas."
		if(reference_turf.active_hotspot)
			qdel(reference_turf.active_hotspot)
		for(var/turf/open/fixture_turf as anything in fixture_turfs)
			fixture_turf.air.copy_from(seed)
			fixture_turf.air.reaction_results = list()
			fixture_turf.excited = TRUE
			fixture_turf.excited_group = null
			fixture_turf.archived_cycle = SSair.times_fired
		SSair.dogmos_replace_active_frontier(fixture_turfs.Copy())
		SSair.currentrun = list()
		SSair.high_pressure_delta = list()
		for(var/reaction_cycle in 1 to reaction_cycles)
			if(reaction_cycle > 1)
				// Each fixture phase finished its native cursor and callbacks. Release
				// its frontier token without rewinding the accepted service epoch.
				SSair.dogmos_pending_frontier_epoch = null
				SSair.times_fired++
				reference.react(null)
			for(var/chunk in 1 to 4096)
				SSair.state = SS_RUNNING
				Master.current_ticklimit = TICK_USAGE + 100 / world.tick_lag
				SSair.process_active_turfs(chunk != 1)
				if(SSair.state == SS_RUNNING || !SSdogmos.service_ready)
					break
			if(SSair.state != SS_RUNNING)
				failure = "The uniform reaction phase did not finish within its bound."
				break
			for(var/turf/open/fixture_turf as anything in fixture_turfs)
				for(var/gas_id in list(/datum/gas/plasma, second_gas, product_gas, /datum/gas/water_vapor))
					if(abs(fixture_turf.air.get_moles(gas_id) - reference.get_moles(gas_id)) > 0.001)
						failure += " Gas [gas_id]: [fixture_turf.air.get_moles(gas_id)] versus [reference.get_moles(gas_id)] in cycle [reaction_cycle]."
				if(abs(fixture_turf.air.return_temperature() - reference.return_temperature()) > 0.1)
					failure += " Temperature [fixture_turf.air.return_temperature()] versus [reference.return_temperature()] in cycle [reaction_cycle]."
				if(reaction_cycle < reaction_cycles && (!fixture_turf.excited || !(fixture_turf in SSair.active_turfs)))
					failure = "A reacting turf was retired before its next chemical evaluation."
		if(isnull(SSair.dogmos_pending_stage) && SSdogmos.service_ready && dogmos_drain_fixture_callbacks())
			for(var/turf/open/fixture_turf as anything in fixture_turfs)
				var/list/restoring_turf_state = saved_turfs[fixture_turf]
				fixture_turf.air.copy_from(restoring_turf_state[1])
				fixture_turf.air.reaction_results = restoring_turf_state[8]
				fixture_turf.kennel_last_reaction_results = restoring_turf_state[9]
				if(fixture_turf.active_hotspot)
					qdel(fixture_turf.active_hotspot)
				fixture_turf.update_visuals()
			SSair.dogmos_replace_active_frontier(saved_air["active_turfs"])
			SSair.dogmos_pending_frontier_epoch = null
			restored = dogmos_sync_fixture_frontier()
			SSair.dogmos_pending_frontier_epoch = null
	catch(var/exception/error)
		failure = "The uniform-reaction fixture raised [error.name]."
	for(var/field in saved_air)
		SSair.vars[field] = saved_air[field]
	Master.current_ticklimit = saved_tick_limit
	for(var/turf/open/fixture_turf as anything in fixture_turfs)
		var/list/turf_state = saved_turfs[fixture_turf]
		fixture_turf.excited = turf_state[2]
		fixture_turf.excited_group = turf_state[3]
		fixture_turf.current_cycle = turf_state[4]
		fixture_turf.archived_cycle = turf_state[5]
		fixture_turf.pressure_difference = turf_state[6]
		fixture_turf.pressure_direction = turf_state[7]
	if(!restored)
		return dogmos_abort_fixture("The uniform-reaction fixture could not safely restore its native frontier.")
	if(failure)
		return Fail(failure, __FILE__, __LINE__)

/** A recreated subsystem must enter its saved phase even when the scheduler calls fire(FALSE). */
/datum/unit_test/dogmos_ssair_recreated_phase_resume

/datum/unit_test/dogmos_ssair_recreated_phase_resume/Run()
	if(!dogmos_wait_for_stage_boundary())
		return
	var/original_state = SSair.state
	var/original_part = SSair.currentpart
	var/original_cycle = SSair.times_fired
	var/original_tick_limit = Master.current_ticklimit
	var/datum/controller/subsystem/air/recovery_test_copy/phase_probe/probe = allocate(/datum/controller/subsystem/air/recovery_test_copy/phase_probe)
	var/failure
	try
		SSair.state = SS_PAUSED
		SSair.currentpart = SSAIR_ACTIVETURFS
		SSair.times_fired = 37
		probe.Recover()
		// These queues precede the saved phase in fire(); isolate them from the real world.
		probe.adjacent_rebuild = list()
		probe.rebuild_queue = list()
		probe.expansion_queue = list()
		probe.state = SS_RUNNING
		Master.current_ticklimit = TICK_USAGE + 100 / world.tick_lag
		probe.fire(FALSE)
		if(probe.entered_phase != SSAIR_ACTIVETURFS || !probe.received_resume || probe.times_fired != 37)
			failure = "A recreated SSair restarted the cycle instead of resuming its saved active phase and cycle id."
		else
			probe.state = SS_RUNNING
			probe.fire(FALSE)
			if(probe.entered_phase != SSAIR_PIPENETS || probe.received_resume)
				failure = "SSair reused its recovery resume override for a later new cycle."
	catch(var/exception/error)
		failure = "The recreated-phase fixture raised [error.name]."
	SSair.state = original_state
	SSair.currentpart = original_part
	SSair.times_fired = original_cycle
	Master.current_ticklimit = original_tick_limit
	qdel(probe)
	if(failure)
		return Fail(failure, __FILE__, __LINE__)

/** Observes scheduler routing without advancing native stages or mutating live queues. */
/datum/controller/subsystem/air/recovery_test_copy/phase_probe
	/// First phase chosen by the real fire() dispatcher.
	var/entered_phase
	/// Whether the dispatcher preserves a recovered continuation.
	var/received_resume

/datum/controller/subsystem/air/recovery_test_copy/phase_probe/process_pipenets(resumed = FALSE)
	entered_phase = SSAIR_PIPENETS
	received_resume = resumed
	pause()

/datum/controller/subsystem/air/recovery_test_copy/phase_probe/process_active_turfs(resumed = FALSE)
	entered_phase = SSAIR_ACTIVETURFS
	received_resume = resumed
	pause()

/** Every initially active turf must receive maintenance before the cycle publishes its frontier. */
/datum/unit_test/dogmos_active_walk_full_cycle
	/// Counts actual turf exposure signals, independently of the traversal cursor.
	var/list/exposures
	/// Force two budget pauses to check that resuming does not refill a shifted window.
	var/yield_count = 0

/datum/unit_test/dogmos_active_walk_full_cycle/proc/count_exposure(turf/source)
	SIGNAL_HANDLER
	exposures[source]++
	if(yield_count < 2)
		yield_count++
		Master.current_ticklimit = TICK_USAGE - 1

/datum/unit_test/dogmos_active_walk_full_cycle/Run()
	var/datum/turf_reservation/fixture = SSmapping.request_turf_block_reservation(11, 11, turf_type_override = /turf/open/floor/plating/airless)
	if(!fixture)
		return Fail("Could not reserve the 121-turf traversal fixture.", __FILE__, __LINE__)
	allocated += fixture
	if(!dogmos_wait_for_stage_boundary())
		return
	var/list/fixture_turfs = fixture.reserved_turfs.Copy()
	if(length(fixture_turfs) != 121)
		return Fail("The traversal fixture needs 121 distinct real turfs.", __FILE__, __LINE__)
	var/list/saved_fields = list()
	for(var/field in list("active_turfs", "currentrun", "state", "active_turfs_walk_cursor", "dogmos_visual_refresh_batch", "dogmos_active_walk_complete", "dogmos_visual_refresh_cursor", "dogmos_active_turf_stages_complete", "dogmos_fdm_steps_completed", "high_pressure_delta", "dogmos_reacted_turfs", "dogmos_walk_prefetch_end", "dogmos_visual_prefetch_end"))
		saved_fields[field] = SSair.vars[field]
	var/original_tick_limit = Master.current_ticklimit
	var/list/turf_states = list()
	exposures = list()
	for(var/turf/open/fixture_turf as anything in fixture_turfs)
		if(!fixture_turf.air || !fixture_turf.dogmos_air_registration_is_current())
			return Fail("A reserved traversal turf lacks its current native gas registration.", __FILE__, __LINE__)
	for(var/turf/open/fixture_turf as anything in fixture_turfs)
		turf_states[fixture_turf] = list(fixture_turf.atmos_adjacent_turfs, fixture_turf.excited, fixture_turf.excited_group, fixture_turf.current_cycle, fixture_turf.archived_cycle)
		fixture_turf.atmos_adjacent_turfs = list()
		fixture_turf.excited = TRUE
		fixture_turf.excited_group = null
		fixture_turf.archived_cycle = SSair.times_fired
		RegisterSignal(fixture_turf, COMSIG_TURF_EXPOSE, PROC_REF(count_exposure))
	var/failure
	var/restored = FALSE
	try
		SSair.dogmos_replace_active_frontier(fixture_turfs.Copy())
		SSair.currentrun = list()
		SSair.active_turfs_walk_cursor = 0
		SSair.high_pressure_delta = list()
		var/original_frontier_epoch = SSair.dogmos_frontier_epoch.Join(":")
		var/turf/open/prefetch_probe = fixture_turfs[50]
		var/list/retained_probe_snapshot
		for(var/chunk in 1 to 4096)
			SSair.state = SS_RUNNING
			Master.current_ticklimit = TICK_USAGE + 100 / world.tick_lag
			SSair.process_active_turfs(chunk != 1)
			if(chunk == 1)
				if(SSair.state != SS_PAUSED || length(exposures) != 1 || SSair.active_turfs_walk_cursor != 1)
					failure = "The maintenance walk did not retain its position after the first exposure exhausted its budget."
				else if(SSair.dogmos_frontier_epoch.Join(":") != original_frontier_epoch || SSair.dogmos_active_walk_complete)
					failure = "The active frontier was published before the initial maintenance snapshot completed."
				retained_probe_snapshot = SSdogmos.lookup_mixture_snapshot_cache(prefetch_probe.air.dogmos_slot, prefetch_probe.air.dogmos_generation)
				if(!retained_probe_snapshot)
					failure = "The first chunk did not populate the untouched prefetch probe."
			if(chunk == 2 && retained_probe_snapshot != SSdogmos.lookup_mixture_snapshot_cache(prefetch_probe.air.dogmos_slot, prefetch_probe.air.dogmos_generation))
				failure = "Resuming after one exposure fetched a replacement snapshot for the untouched prefetch window."
			if(SSair.state == SS_RUNNING || !SSdogmos.service_ready)
				break
		if(SSair.state != SS_RUNNING)
			failure = "The full active phase did not finish within the fixture bound."
		for(var/turf/open/fixture_turf as anything in fixture_turfs)
			if(exposures[fixture_turf] != 1)
				failure = "A completed active phase exposed only [length(exposures)] of 121 initially active turfs exactly once."
				break
		if(!failure && length(SSair.active_turfs))
			failure = "Settled fixture turfs remained active after the full walk."
		// The current cycle's frontier remains frozen through equalization and heat.
		// All initial entries must have reached its reaction pass before retirement.
		if(!failure && length(SSair.dogmos_committed_frontier) != length(fixture_turfs))
			failure = "An initial fixture turf was retired before native reaction evaluation."
		if(!failure && (length(SSair.dogmos_visual_refresh_batch) || SSair.active_turfs_walk_cursor || SSair.dogmos_visual_refresh_cursor || SSair.dogmos_walk_prefetch_end || SSair.dogmos_visual_prefetch_end))
			failure = "The completed visual pass retained its snapshot or cursors."
		if(isnull(SSair.dogmos_pending_stage) && SSdogmos.service_ready && dogmos_drain_fixture_callbacks())
			SSair.dogmos_replace_active_frontier(saved_fields["active_turfs"])
			SSair.dogmos_pending_frontier_epoch = null
			restored = dogmos_sync_fixture_frontier()
			SSair.dogmos_pending_frontier_epoch = null
	catch(var/exception/error)
		failure = "The full-walk fixture raised [error.name]."
	for(var/field in saved_fields)
		SSair.vars[field] = saved_fields[field]
	Master.current_ticklimit = original_tick_limit
	for(var/turf/open/fixture_turf as anything in fixture_turfs)
		UnregisterSignal(fixture_turf, COMSIG_TURF_EXPOSE)
		var/list/turf_state = turf_states[fixture_turf]
		fixture_turf.atmos_adjacent_turfs = turf_state[1]
		fixture_turf.excited = turf_state[2]
		fixture_turf.excited_group = turf_state[3]
		fixture_turf.current_cycle = turf_state[4]
		fixture_turf.archived_cycle = turf_state[5]
	exposures = null
	if(!restored)
		return dogmos_abort_fixture("The full-walk fixture could not safely restore the native frontier.")
	if(failure)
		return Fail(failure, __FILE__, __LINE__)

/** Keeps the next maintenance batch fair when a settled entry leaves the live list. */
/datum/unit_test/dogmos_active_walk_removal_cursor
	/// Exposure counts for the four real fixture turfs, including repeated filler entries.
	var/list/exposures

/datum/unit_test/dogmos_active_walk_removal_cursor/proc/count_exposure(turf/source)
	SIGNAL_HANDLER
	exposures[source]++
	// Model a real callback removing a live entry while the initial snapshot is in use.
	if(source == run_loc_floor_bottom_left)
		SSair.remove_from_active(source)

/datum/unit_test/dogmos_active_walk_removal_cursor/Run()
	if(!dogmos_wait_for_stage_boundary())
		return
	var/turf/open/settler = run_loc_floor_bottom_left
	var/turf/open/filler = get_step(settler, EAST)
	var/turf/open/sentinel = get_step(filler, EAST)
	var/turf/open/tail = get_step(sentinel, EAST)
	var/list/fixture_turfs = list(settler, filler, sentinel, tail)
	var/list/original_turf_state = list()
	var/list/original_active = SSair.active_turfs
	var/list/original_run = SSair.currentrun
	var/list/original_visuals = SSair.dogmos_visual_refresh_batch
	var/original_prefetch_end = SSair.dogmos_walk_prefetch_end
	var/original_cursor = SSair.active_turfs_walk_cursor
	var/original_state = SSair.state
	var/original_tick_limit = Master.current_ticklimit
	var/original_oxygen = tail.air.get_moles(/datum/gas/oxygen)
	var/batch_limit = 100 // The public maintenance bound; air.dm's define is file-local.
	exposures = list()
	for(var/turf/open/fixture_turf as anything in fixture_turfs)
		original_turf_state[fixture_turf] = list(fixture_turf.atmos_adjacent_turfs, fixture_turf.excited, fixture_turf.excited_group, fixture_turf.current_cycle, fixture_turf.archived_cycle)
		fixture_turf.excited = TRUE
		fixture_turf.excited_group = null
		// This fixture checks traversal, so preserve the native archived air state.
		fixture_turf.archived_cycle = SSair.times_fired
		RegisterSignal(fixture_turf, COMSIG_TURF_EXPOSE, PROC_REF(count_exposure))
	settler.atmos_adjacent_turfs = list()
	filler.atmos_adjacent_turfs = list(tail)
	sentinel.atmos_adjacent_turfs = list(tail)
	tail.atmos_adjacent_turfs = list(filler)
	tail.excited = FALSE
	var/failure
	try
		tail.air.set_moles(/datum/gas/oxygen, filler.air.get_moles(/datum/gas/oxygen) + 100)
		var/list/queue = list(settler)
		for(var/index in 1 to batch_limit - 1)
			queue += filler
		queue += sentinel
		// The differing tail starts outside the queue and is appended by filler comparisons.
		SSair.dogmos_replace_active_frontier(queue)
		SSair.currentrun = list()
		SSair.active_turfs_walk_cursor = 0
		SSair.dogmos_visual_refresh_batch = queue.Copy()
		SSair.dogmos_walk_prefetch_end = 0
		SSair.state = SS_RUNNING
		Master.current_ticklimit = TICK_USAGE + 100 / world.tick_lag
		SSair.walk_active_turfs_batch()
		if(exposures[settler] != 1 || exposures[filler] != batch_limit - 1 || exposures[sentinel] || exposures[tail])
			failure = "The first walk did not process exactly its bounded fixture batch."
		else if(settler in SSair.active_turfs)
			failure = "The isolated settled turf did not leave the active list."
		else if(!tail.excited || !(tail in SSair.active_turfs))
			failure = "The differing inactive tail was not appended during the first batch."
		else
			SSair.walk_active_turfs_batch()
			if(exposures[sentinel] != 1)
				failure = "Removing the first settled turf skipped the next unprocessed turf on the second walk."
			else if(exposures[tail])
				failure = "An activation outside the initial snapshot was exposed during the same cycle."
	catch(var/exception/error)
		failure = "The removal-cursor fixture raised [error.name]."

	SSair.dogmos_replace_active_frontier(original_active)
	SSair.currentrun = original_run
	SSair.dogmos_visual_refresh_batch = original_visuals
	SSair.dogmos_walk_prefetch_end = original_prefetch_end
	SSair.active_turfs_walk_cursor = original_cursor
	SSair.state = original_state
	Master.current_ticklimit = original_tick_limit
	tail.air.set_moles(/datum/gas/oxygen, original_oxygen)
	for(var/turf/open/fixture_turf as anything in fixture_turfs)
		UnregisterSignal(fixture_turf, COMSIG_TURF_EXPOSE)
		var/list/saved_turf_state = original_turf_state[fixture_turf]
		fixture_turf.atmos_adjacent_turfs = saved_turf_state[1]
		fixture_turf.excited = saved_turf_state[2]
		fixture_turf.excited_group = saved_turf_state[3]
		fixture_turf.current_cycle = saved_turf_state[4]
		fixture_turf.archived_cycle = saved_turf_state[5]
	exposures = null
	if(failure)
		return Fail(failure, __FILE__, __LINE__)

/** Verifies atomic stage candidates do not invalidate warm snapshots before publication. */
/datum/unit_test/dogmos_service_atomic_stage_cache_boundary

/datum/unit_test/dogmos_service_atomic_stage_cache_boundary/Run()
	if(!dogmos_wait_for_stage_boundary())
		return
	var/list/original_active = SSair.active_turfs
	var/list/original_pressure_queue = SSair.high_pressure_delta.Copy()
	var/list/original_pressure = list()
	var/original_work_limit = SSair.dogmos_stage_work_limit
	var/list/room_turfs = block(run_loc_floor_bottom_left, run_loc_floor_top_right)
	var/turf/open/target = run_loc_floor_bottom_left
	for(var/turf/open/fixture_turf as anything in room_turfs)
		original_pressure[fixture_turf] = list(fixture_turf.pressure_difference, fixture_turf.pressure_direction)
	var/list/original_stage_samples = SSair.dogmos_stage_test_samples
	var/failure
	var/restored = FALSE
	var/pending = FALSE
	var/stage_complete = FALSE
	try
		SSair.dogmos_stage_test_samples = list()
		SSdogmos.reset_mixture_snapshot_cache()
		SSair.dogmos_replace_active_frontier(room_turfs.Copy())
		SSair.dogmos_pending_frontier_epoch = null
		if(!dogmos_sync_fixture_frontier())
			failure = "The atomic stage cache fixture could not publish its temporary frontier."
		else
			// Seed a real diffusion mutation, then warm the exact service snapshot that must remain
			// readable until the atomic candidate is finally published.
			var/seeded_oxygen = target.air.get_moles(/datum/gas/oxygen) + 100
			target.air.set_moles(/datum/gas/oxygen, seeded_oxygen)
			target.air.dogmos_snapshot()
			var/cache_epoch_before = SSdogmos.dogmos_mixture_cache_epoch
			SSair.dogmos_stage_work_limit = 1
			// A 0.01 ms allocation can be consumed by the DM entry checks before any
			// native request. Keep the fixture large enough that this positive allocation
			// must return a real bounded response with preparation work remaining.
			pending = SSair.dogmos_run_stage(DOGMOS_TEST_STAGE_TURFS, 0.25)
			var/list/first_sample = SSair.dogmos_stage_test_samples["[DOGMOS_TEST_STAGE_TURFS]"]
			if(!pending)
				failure = "The atomic diffusion fixture completed before exposing a pending native chunk."
			else if(!islist(first_sample) || first_sample[1] < 1 || first_sample[2] < 1 || SSair.dogmos_stage_remaining_estimate <= 0 || SSair.dogmos_stage_remaining_estimate >= length(room_turfs))
				failure = "The atomic diffusion fixture did not record native work in its first pending response."
			else if(SSdogmos.dogmos_mixture_cache_epoch != cache_epoch_before || !SSdogmos.lookup_mixture_snapshot_cache(target.air.dogmos_slot, target.air.dogmos_generation))
				failure = "An atomic diffusion chunk invalidated a warm snapshot before publication."
			if(pending)
				for(var/attempt in 1 to 4096)
					if(!pending)
						break
					pending = SSair.dogmos_run_stage(DOGMOS_TEST_STAGE_TURFS, 100)
			if(pending)
				failure = "The atomic diffusion fixture did not complete within its bounded retry count."
			else if(!isnull(SSair.dogmos_pending_stage))
				failure = "The atomic diffusion fixture reported completion while retaining a native cursor."
			else
				stage_complete = TRUE
				if(SSdogmos.lookup_mixture_snapshot_cache(target.air.dogmos_slot, target.air.dogmos_generation))
					failure = "The atomic diffusion publication left a stale warm snapshot readable."
				if(target.air.get_moles(/datum/gas/oxygen) >= seeded_oxygen)
					failure = "The atomic diffusion fixture did not publish a numeric gas change."
	catch(var/exception/error)
		failure = "The atomic stage cache fixture raised [error.name]."
	try
		if(stage_complete && SSdogmos.service_ready && !dogmos_drain_fixture_callbacks())
			failure = "The atomic stage cache fixture left callbacks pending after publication."
			stage_complete = FALSE
	catch(var/exception/drain_error)
		failure = "The atomic stage cache fixture callback drain raised [drain_error.name]."
		stage_complete = FALSE
	// Restore DM-local state for diagnostics even when the native cursor is
	// incomplete. Do not clear its frontier or call sync while that cursor is live;
	// there is no safe DM cancellation API for an in-flight native stage.
	var/native_cursor_open = !stage_complete || pending || !isnull(SSair.dogmos_pending_stage)
	SSair.dogmos_stage_work_limit = original_work_limit
	SSair.dogmos_replace_active_frontier(original_active)
	SSair.high_pressure_delta.Cut()
	SSair.high_pressure_delta += original_pressure_queue
	for(var/turf/open/fixture_turf as anything in room_turfs)
		var/list/pressure = original_pressure[fixture_turf]
		fixture_turf.pressure_difference = pressure[1]
		fixture_turf.pressure_direction = pressure[2]
	if(!native_cursor_open && SSdogmos.service_ready)
		try
			SSair.dogmos_pending_frontier_epoch = null
			restored = dogmos_sync_fixture_frontier()
			SSair.dogmos_pending_frontier_epoch = null
		catch(var/exception/restore_error)
			failure = "The atomic stage cache fixture restoration raised [restore_error.name]."
	SSair.dogmos_stage_test_samples = original_stage_samples
	SSdogmos.reset_mixture_snapshot_cache()
	if(native_cursor_open)
		return dogmos_abort_fixture("The atomic stage cache fixture left a native stage pending; its frontier was not touched.")
	if(!restored)
		return dogmos_abort_fixture("The atomic stage cache fixture could not restore its normal frontier.")
	if(!isnull(SSair.dogmos_pending_stage) || SSair.dogmos_pending_frontier_epoch)
		return dogmos_abort_fixture("The atomic stage cache fixture left a native stage or frontier pending.")
	if(failure)
		return Fail(failure, __FILE__, __LINE__)

/** Verifies one Dogmos turf-processing cycle performs the configured FDM pass count. */
/datum/unit_test/dogmos_service_fdm_linda_cadence

/datum/unit_test/dogmos_service_fdm_linda_cadence/Run()
	if(!dogmos_wait_for_stage_boundary())
		return
	var/list/pair = allocate_turf_pair()
	if(length(pair) != 2)
		return Fail("The FDM cadence fixture needs two adjacent turfs.", __FILE__, __LINE__)
	var/turf/open/turf_a = pair[1]
	var/turf/open/turf_b = pair[2]
	turf_a.air.set_moles(/datum/gas/oxygen, turf_a.air.get_moles(/datum/gas/oxygen) * 3)
	var/a_before = turf_a.air.get_moles(/datum/gas/oxygen)
	var/b_before = turf_b.air.get_moles(/datum/gas/oxygen)
	var/expected_steps = max(1, round(SSair.share_max_steps))
	var/list/expected_stage_epoch = SSair.dogmos_stage_epoch.Copy()
	for(var/step in 1 to expected_steps)
		expected_stage_epoch = SSdogmos.increment_u64_words(expected_stage_epoch)
	var/original_fdm_steps_completed = SSair.dogmos_fdm_steps_completed
	SSair.dogmos_fdm_steps_completed = 0
	var/completed = dogmos_run_fixture_stage(DOGMOS_TEST_STAGE_TURFS, pair, use_fdm_cadence = TRUE)
	var/completed_steps = SSair.dogmos_fdm_steps_completed
	SSair.dogmos_fdm_steps_completed = original_fdm_steps_completed
	if(!completed)
		return
	if(completed_steps != expected_steps)
		return Fail("Dogmos completed [completed_steps] FDM passes instead of the configured [expected_steps].", __FILE__, __LINE__)
	for(var/word_index in 1 to 4)
		if(SSair.dogmos_stage_epoch[word_index] != expected_stage_epoch[word_index])
			return Fail("The reported FDM pass count did not match the number of native stage epochs.", __FILE__, __LINE__)
	if(turf_a.air.get_moles(/datum/gas/oxygen) >= a_before || turf_b.air.get_moles(/datum/gas/oxygen) <= b_before)
		return Fail("The configured FDM passes did not actually redistribute the seeded oxygen.", __FILE__, __LINE__)

/** Verifies malformed stage responses are rejected before SSair reads their fields. */
/datum/unit_test/dogmos_service_stage_response_failure
	parent_type = /datum/unit_test/dogmos_admission_fixture

/datum/unit_test/dogmos_service_stage_response_failure/Run()
	var/list/valid_response = new/list(DOGMOS_TEST_STAGE_RESPONSE_FIELDS)
	for(var/field_index in 1 to DOGMOS_TEST_STAGE_RESPONSE_FIELDS)
		valid_response[field_index] = 0
	var/list/short_response = valid_response.Copy()
	short_response.Cut(length(short_response), length(short_response) + 1)
	var/list/non_numeric_response = valid_response.Copy()
	non_numeric_response[1] = "invalid"

	if(SSair.dogmos_stage_response_is_valid(DOGMOS_TEST_STAGE_EQUALIZE, null))
		return Fail("Dogmos accepted a null stage response.", __FILE__, __LINE__)
	if(SSair.dogmos_stage_response_is_valid(DOGMOS_TEST_STAGE_EQUALIZE, 1))
		return Fail("Dogmos accepted a scalar stage response.", __FILE__, __LINE__)
	if(SSair.dogmos_stage_response_is_valid(DOGMOS_TEST_STAGE_EQUALIZE, short_response))
		return Fail("Dogmos accepted a short stage response.", __FILE__, __LINE__)
	if(SSair.dogmos_stage_response_is_valid(DOGMOS_TEST_STAGE_EQUALIZE, non_numeric_response))
		return Fail("Dogmos accepted a non-numeric stage response.", __FILE__, __LINE__)
	if(!SSair.dogmos_stage_response_is_valid(DOGMOS_TEST_STAGE_EQUALIZE, valid_response))
		return Fail("Dogmos rejected a fixed-width numeric stage response.", __FILE__, __LINE__)

	var/original_pending_stage = SSair.dogmos_pending_stage
	var/list/original_pending_frontier = SSair.dogmos_pending_frontier_epoch
	var/original_remaining_estimate = SSair.dogmos_stage_remaining_estimate
	var/original_active_stages_complete = SSair.dogmos_active_turf_stages_complete
	var/original_equalize_stages_complete = SSair.dogmos_equalize_stage_complete
	var/list/original_walk_state = list()
	for(var/field in list("dogmos_active_walk_complete", "active_turfs_walk_cursor", "dogmos_visual_refresh_cursor", "dogmos_visual_refresh_batch"))
		original_walk_state[field] = SSair.vars[field]
	var/original_fdm_steps_completed = SSair.dogmos_fdm_steps_completed
	var/original_can_fire = SSair.can_fire
	var/original_service_ready = SSdogmos.service_ready
	var/original_failure_latched = SSdogmos.service_failure_latched
	save_rejected_admission_fixture()
	SSair.dogmos_pending_stage = DOGMOS_TEST_STAGE_REACTIONS
	SSair.dogmos_pending_frontier_epoch = list(1, 0, 0, 0)
	SSair.dogmos_stage_remaining_estimate = 77
	SSair.dogmos_active_turf_stages_complete = TRUE
	SSair.dogmos_equalize_stage_complete = TRUE
	SSair.dogmos_fdm_steps_completed = 3
	SSair.dogmos_active_walk_complete = TRUE
	SSair.active_turfs_walk_cursor = 1
	SSair.dogmos_visual_refresh_cursor = 1
	SSair.dogmos_visual_refresh_batch = list(run_loc_floor_bottom_left)
	var/failure_pending = SSair.dogmos_fail_closed_stage(DOGMOS_TEST_STAGE_REACTIONS, FALSE)
	var/failure_message
	if(!failure_pending)
		failure_message = "Dogmos did not pause SSair after an irrecoverable stage response."
	else if(!isnull(SSair.dogmos_pending_stage) || !isnull(SSair.dogmos_pending_frontier_epoch))
		failure_message = "Dogmos retained failed stage state for another retry."
	else if(SSair.dogmos_stage_remaining_estimate || SSair.dogmos_active_turf_stages_complete || SSair.dogmos_equalize_stage_complete || SSair.dogmos_fdm_steps_completed)
		failure_message = "Dogmos retained failed-cycle progress after the stage failure."
	else if(SSair.can_fire || SSdogmos.service_ready || !SSdogmos.service_failure_latched)
		failure_message = "Dogmos did not fail closed after the stage failure."
	else if(SSair.dogmos_active_walk_complete || SSair.active_turfs_walk_cursor || SSair.dogmos_visual_refresh_cursor || length(SSair.dogmos_visual_refresh_batch))
		failure_message = "Dogmos retained a failed maintenance or visual continuation."

	SSair.dogmos_pending_stage = original_pending_stage
	SSair.dogmos_pending_frontier_epoch = original_pending_frontier
	SSair.dogmos_stage_remaining_estimate = original_remaining_estimate
	SSair.dogmos_active_turf_stages_complete = original_active_stages_complete
	SSair.dogmos_equalize_stage_complete = original_equalize_stages_complete
	for(var/field in original_walk_state)
		SSair.vars[field] = original_walk_state[field]
	SSair.dogmos_fdm_steps_completed = original_fdm_steps_completed
	SSair.can_fire = original_can_fire
	SSdogmos.service_ready = original_service_ready
	SSdogmos.service_failure_latched = original_failure_latched
	restore_admission_fixture()
	if(failure_message)
		return Fail(failure_message, __FILE__, __LINE__)

/** Verifies a resumed SSair stage does not repeat the cycle health preflight. */
/datum/unit_test/dogmos_service_resumed_health_preflight

/datum/unit_test/dogmos_service_resumed_health_preflight/Run()
	if(SSair.dogmos_health_preflight_required(TRUE))
		return Fail("A resumed SSair stage repeated the Dogmos cycle health preflight.", __FILE__, __LINE__)
	if(!SSair.dogmos_health_preflight_required(FALSE))
		return Fail("A new SSair cycle skipped the Dogmos health preflight.", __FILE__, __LINE__)

/** Verifies SSair completes a real Runtime Station or MetaStation cycle after startup. */
/datum/unit_test/dogmos_service_idle_cycle_progress

/datum/unit_test/dogmos_service_idle_cycle_progress/Run()
	var/initial_fire_count = SSair.times_fired
	var/deadline = world.time + 30 SECONDS
	while(SSair.times_fired <= initial_fire_count && world.time < deadline)
		sleep(1 SECONDS)
	if(SSair.times_fired <= initial_fire_count)
		return Fail("Dogmos did not allow SSair to complete an idle cycle within 30 seconds.", __FILE__, __LINE__)


#undef DOGMOS_WORLD_GENERATION_WORD_MAX
#undef DOGMOS_TEST_STAGE_EXCITED_GROUPS
#undef DOGMOS_TEST_STAGE_EQUALIZE
#undef DOGMOS_TEST_STAGE_TURF_HEAT
#undef DOGMOS_TEST_STAGE_TURFS
#undef DOGMOS_TEST_STAGE_REACTIONS
#undef DOGMOS_TEST_STAGE_BOUNDARY_ATTEMPTS
#undef DOGMOS_TEST_STAGE_RESPONSE_FIELDS
#undef DOGMOS_PIPELINE_TEST_EPSILON
#undef DOGMOS_TEST_OVERSIZED_PIPELINE_MIXTURES
#undef DOGMOS_TEST_IDLE_MC_SETTLE_TIME
#undef DOGMOS_TEST_RESPONSE_APPLIED
#undef DOGMOS_TEST_SNAPSHOT_REVISION_LOW
#undef DOGMOS_TEST_SNAPSHOT_REVISION_HIGH
#endif
