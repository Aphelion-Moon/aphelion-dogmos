#if defined(UNIT_TESTS) || defined(SPACEMAN_DMM)

/// Counts cold reads caused by direct-cache aliases within each ordered 100-entry prefetch window.
/proc/dogmos_startup_prefetch_expected_misses(list/buckets)
	var/expected_misses = 0
	for(var/start = 1, start <= length(buckets), start += 100)
		var/list/bucket_counts = list()
		for(var/index in start to min(start + 99, length(buckets)))
			var/bucket = "[buckets[index]]"
			var/previous_count = bucket_counts[bucket] || 0
			bucket_counts[bucket] = previous_count + 1
			// Prefetch leaves the last alias resident. Reading the first alias evicts
			// it, so every distinct slot in a colliding bucket needs one cold read.
			if(previous_count == 1)
				expected_misses += 2
			else if(previous_count > 1)
				expected_misses++
	return expected_misses

/datum/unit_test/dogmos_startup_prefetch_collision_accounting

/datum/unit_test/dogmos_startup_prefetch_collision_accounting/Run()
	var/list/buckets = list()
	for(var/slot in 1 to 121)
		buckets += slot
	if(dogmos_startup_prefetch_expected_misses(buckets) != 0)
		return Fail("Unique buckets must stay warm.", __FILE__, __LINE__)
	buckets[2] = 1
	if(dogmos_startup_prefetch_expected_misses(buckets) != 2)
		return Fail("Both slots in a colliding bucket must miss.", __FILE__, __LINE__)
	buckets[3] = 1
	if(dogmos_startup_prefetch_expected_misses(buckets) != 3)
		return Fail("Every distinct alias must miss.", __FILE__, __LINE__)
	buckets[102] = buckets[101]
	if(dogmos_startup_prefetch_expected_misses(buckets) != 5)
		return Fail("Tail-window collisions must also count.", __FILE__, __LINE__)
	for(var/index in 1 to 121)
		buckets[index] = index
	buckets[101] = buckets[100]
	if(dogmos_startup_prefetch_expected_misses(buckets) != 0)
		return Fail("Aliases across separate prefetch windows must stay warm.", __FILE__, __LINE__)

/datum/unit_test/dogmos_startup_own_prefetch_regression

/// Captures one real turf without reading neighboring mixtures.
/datum/unit_test/dogmos_startup_own_prefetch_regression/proc/capture_turf_state(turf/open/target, save_air_copy = FALSE)
	var/list/result = list()
	var/list/air_snapshot = target.air.dogmos_snapshot()
	result["air"] = air_snapshot?.Copy()
	if(save_air_copy)
		var/datum/gas_mixture/air_copy = target.air.copy()
		allocated += air_copy
		result["air_copy"] = air_copy
	result["visuals"] = target.atmos_overlay_types?.Copy()
	result["adjacency"] = target.atmos_adjacent_turfs?.Copy()
	result["excited"] = target.excited
	result["current_cycle"] = target.current_cycle
	result["archived_cycle"] = target.archived_cycle
	result["reaction_results"] = target.air.reaction_results?.Copy()
	return result

/// Compares ordered visual and difference-check lists by identity.
/datum/unit_test/dogmos_startup_own_prefetch_regression/proc/list_matches(list/left, list/right)
	if(isnull(left) || isnull(right))
		return isnull(left) && isnull(right)
	if(length(left) != length(right))
		return FALSE
	for(var/index in 1 to length(left))
		if(left[index] != right[index])
			return FALSE
	return TRUE

/// Compares physical gas fields while excluding the first two revision words.
/datum/unit_test/dogmos_startup_own_prefetch_regression/proc/air_matches(list/left, list/right)
	if(isnull(left) || isnull(right))
		return isnull(left) && isnull(right)
	if(length(left) < 3 || length(left) != length(right))
		return FALSE
	for(var/index in 3 to length(left))
		if(left[index] != right[index])
			return FALSE
	return TRUE

/// Compares keyed reaction bookkeeping without depending on list identity.
/datum/unit_test/dogmos_startup_own_prefetch_regression/proc/associative_lists_match(list/left, list/right)
	if(isnull(left) || isnull(right))
		return isnull(left) && isnull(right)
	if(length(left) != length(right))
		return FALSE
	for(var/key in left)
		if(right[key] != left[key])
			return FALSE
	return TRUE

/// Compares reciprocal adjacency maps and their edge flags.
/datum/unit_test/dogmos_startup_own_prefetch_regression/proc/adjacency_matches(list/left, list/right)
	if(isnull(left) || isnull(right))
		return isnull(left) && isnull(right)
	if(length(left) != length(right))
		return FALSE
	for(var/turf/neighbor as anything in left)
		if(right[neighbor] != left[neighbor])
			return FALSE
	return TRUE

/// Captures the ordered fixture state for control/candidate parity or restoration.
/datum/unit_test/dogmos_startup_own_prefetch_regression/proc/capture_states(list/turfs, save_air_copy = FALSE)
	var/list/result = list()
	for(var/turf/open/target as anything in turfs)
		result[target] = capture_turf_state(target, save_air_copy)
	return result

/// Restores only owned real turfs from registered gas copies.
/datum/unit_test/dogmos_startup_own_prefetch_regression/proc/restore_turfs(list/turfs, list/states)
	for(var/turf/open/target as anything in turfs)
		var/list/saved = states[target]
		var/datum/gas_mixture/saved_air = saved["air_copy"]
		if(!saved_air)
			return FALSE
		target.air.copy_from(saved_air)
		var/list/reaction_results = saved["reaction_results"]
		var/list/visuals = saved["visuals"]
		var/list/adjacency = saved["adjacency"]
		target.air.reaction_results = reaction_results?.Copy()
		target.apply_visual_overlays(visuals?.Copy())
		target.atmos_adjacent_turfs = adjacency?.Copy()
		target.excited = saved["excited"]
		target.current_cycle = saved["current_cycle"]
		target.archived_cycle = saved["archived_cycle"]
	return TRUE

/// Runs the existing setup ordering without any startup prefetch.
/datum/unit_test/dogmos_startup_own_prefetch_regression/proc/run_control(list/turfs)
	var/list/difference_check = list()
	var/time = -1
	SSdogmos.begin_turf_registration_batch()
	for(var/turf/open/target as anything in turfs)
		target.Initalize_Atmos(time)
		difference_check += target
		if(CHECK_TICK)
			time--
	SSdogmos.finish_turf_registration_batch()
	return list(time, difference_check)

/// Runs the proposed own-mixture helper in the exact 100+21 windows.
/datum/unit_test/dogmos_startup_own_prefetch_regression/proc/run_candidate(list/turfs)
	var/list/difference_check = list()
	var/time = -1
	var/has_helper = hascall(SSair, "dogmos_initialize_turf_batch")
	SSdogmos.begin_turf_registration_batch()
	for(var/start in list(1, 101))
		var/end = min(start + 99, length(turfs))
		var/list/batch = turfs.Copy(start, end + 1)
		if(has_helper)
			var/result = call(SSair, "dogmos_initialize_turf_batch")(batch, difference_check, time)
			if(!isnum(result))
				return list(null, difference_check, FALSE, "The startup helper returned a nonnumeric time.")
			time = result
		else
			// Intentional RED fallback: it exercises the old actual path so the artifact
			// remains useful before the helper is inserted, but cannot claim a cache win.
			for(var/turf/open/target as anything in batch)
				target.Initalize_Atmos(time)
				difference_check += target
				if(CHECK_TICK)
					time--
	SSdogmos.finish_turf_registration_batch()
	return list(time, difference_check, has_helper, null)

/datum/unit_test/dogmos_startup_own_prefetch_regression/Run()
	var/datum/turf_reservation/fixture = SSmapping.request_turf_block_reservation(11, 11, turf_type_override = /turf/open/floor/plating/airless)
	if(!fixture)
		return Fail("Could not reserve the 121-turf startup prefetch fixture.", __FILE__, __LINE__)
	allocated += fixture
	for(var/turf/open/fixture_turf as anything in fixture.reserved_turfs)
		fixture_turf.immediate_calculate_adjacent_turfs()
	// Reservation itself queues native lifecycle/topology work; only now is the
	// boundary meaningful.
	var/adjacency_deadline = world.time + 180 SECONDS
	while(length(SSair.adjacent_rebuild) && world.time < adjacency_deadline)
		sleep(SSair.wait)
	if(length(SSair.adjacent_rebuild))
		return dogmos_abort_fixture("Startup fixture adjacency did not drain within three simulated minutes: [length(SSair.adjacent_rebuild)] turfs remain.")
	if(!dogmos_wait_for_stage_boundary())
		return
	var/list/turfs = fixture.reserved_turfs.Copy()
	if(length(turfs) != 121)
		return Fail("The startup prefetch fixture needs 121 reserved turfs.", __FILE__, __LINE__)
	for(var/turf/open/target as anything in turfs)
		if(!istype(target) || !target.air || !target.dogmos_air_registration_is_current())
			return Fail("The startup prefetch fixture contains an unregistered or non-open turf.", __FILE__, __LINE__)

	var/turf/open/boundary_left
	var/turf/open/boundary_right
	for(var/turf/open/left as anything in turfs)
		for(var/turf/open/right as anything in left.atmos_adjacent_turfs)
			if((right in turfs) && (left in right.atmos_adjacent_turfs))
				boundary_left = left
				boundary_right = right
				break
		if(boundary_left)
			break
	if(!boundary_left)
		return Fail("The startup prefetch fixture has no reciprocal real-turf boundary pair.", __FILE__, __LINE__)
	var/list/reordered_turfs = list()
	for(var/turf/open/target as anything in turfs)
		if(target != boundary_left && target != boundary_right)
			reordered_turfs += target
	reordered_turfs.Insert(100, boundary_left)
	reordered_turfs.Insert(101, boundary_right)
	turfs = reordered_turfs
	var/list/unique_turfs = list()
	for(var/turf/open/target as anything in turfs)
		if(unique_turfs[target])
			return Fail("The startup prefetch fixture reordered a turf more than once.", __FILE__, __LINE__)
		unique_turfs[target] = TRUE
	if(length(turfs) != 121 || length(unique_turfs) != 121)
		return Fail("The startup prefetch fixture lost a turf while placing its boundary pair.", __FILE__, __LINE__)
	if(!(boundary_left in boundary_right.atmos_adjacent_turfs) || !(boundary_right in boundary_left.atmos_adjacent_turfs))
		return Fail("The startup prefetch fixture did not place a reciprocal pair across the 100-entry boundary.", __FILE__, __LINE__)
	var/list/fixture_slots = list()
	var/list/fixture_generations = list()
	var/list/fixture_buckets = list()
	for(var/turf/open/target as anything in turfs)
		if(target.air.dogmos_slot in fixture_slots)
			return Fail("The startup prefetch fixture needs distinct live mixture slots.", __FILE__, __LINE__)
		fixture_slots += target.air.dogmos_slot
		fixture_generations += target.air.dogmos_generation
		fixture_buckets += SSdogmos.mixture_snapshot_cache_bucket(target.air.dogmos_slot)
	var/expected_candidate_misses = dogmos_startup_prefetch_expected_misses(fixture_buckets)

	var/list/saved_air_fields = list()
	for(var/field in list("active_turfs", "currentrun", "state", "can_fire", "times_fired", "dogmos_pending_stage", "dogmos_pending_frontier_epoch"))
		saved_air_fields[field] = SSair.vars[field]
	var/list/saved_frontier_epoch = SSair.dogmos_frontier_epoch.Copy()
	var/list/saved_stage_epoch = SSair.dogmos_stage_epoch.Copy()
	var/saved_pending_callbacks = SSdogmos.dogmos_pending_callback_count
	var/saved_stale_callbacks = SSdogmos.dogmos_stale_callback_count
	var/saved_tick_limit = Master.current_ticklimit
	var/saved_batching = SSdogmos.turf_registration_batching
	var/list/initial_states = capture_states(turfs, TRUE)
	var/list/seeded_states
	var/failure
	var/helper_used = FALSE
	var/control_misses = 0
	var/candidate_misses = 0
	var/control_hits = 0
	var/candidate_hits = 0
	var/control_topology_calls = 0
	var/candidate_topology_calls = 0
	var/list/control_result
	var/list/candidate_result

	try
		if(SSdogmos.turf_registration_batching || length(SSdogmos.dogmos_pending_turf_lifecycle) || length(SSdogmos.dogmos_pending_turf_adjacency) || length(SSdogmos.dogmos_pending_turf_heat) || length(SSdogmos.dogmos_pending_turf_heat_adjacency))
			return dogmos_abort_fixture("The startup prefetch fixture did not start with an empty registration batch.")
		SSair.can_fire = FALSE
		// Keep the bounded 121-turf counter measurement synchronous: unrelated subsystem
		// cache reads during CHECK_TICK would otherwise contaminate these deltas.
		Master.current_ticklimit = INFINITY
		for(var/index in 1 to length(turfs))
			var/turf/open/target = turfs[index]
			target.air.set_moles(/datum/gas/oxygen, 0)
			target.air.set_moles(/datum/gas/plasma, (index % 2) ? max(1, MOLES_GAS_VISIBLE * 2) : max(0.01, MOLES_GAS_VISIBLE * 0.25))
			target.air.set_temperature(T20C)
		seeded_states = capture_states(turfs, TRUE)

		SSdogmos.reset_mixture_snapshot_cache()
		var/control_misses_before = SSdogmos.dogmos_mixture_cache_misses
		var/control_hits_before = SSdogmos.dogmos_mixture_cache_hits
		var/control_topology_before = SSdogmos.dogmos_runtime_topology_calls
		control_result = run_control(turfs)
		control_misses = SSdogmos.dogmos_mixture_cache_misses - control_misses_before
		control_hits = SSdogmos.dogmos_mixture_cache_hits - control_hits_before
		control_topology_calls = SSdogmos.dogmos_runtime_topology_calls - control_topology_before
		var/list/control_states = capture_states(turfs)
		if(!restore_turfs(turfs, seeded_states))
			failure = "The startup prefetch control path could not restore its fixture state."

		if(!failure)
			SSdogmos.reset_mixture_snapshot_cache()
			var/candidate_misses_before = SSdogmos.dogmos_mixture_cache_misses
			var/candidate_hits_before = SSdogmos.dogmos_mixture_cache_hits
			var/candidate_topology_before = SSdogmos.dogmos_runtime_topology_calls
			candidate_result = run_candidate(turfs)
			if(!candidate_result || !isnum(candidate_result[1]))
				failure = candidate_result?[4] || "The startup prefetch candidate did not return a valid time."
			else
				helper_used = candidate_result[3]
				candidate_misses = SSdogmos.dogmos_mixture_cache_misses - candidate_misses_before
				candidate_hits = SSdogmos.dogmos_mixture_cache_hits - candidate_hits_before
				candidate_topology_calls = SSdogmos.dogmos_runtime_topology_calls - candidate_topology_before
				var/list/candidate_states = capture_states(turfs)
				if(length(control_result[2]) != length(candidate_result[2]))
					failure = "Control and candidate initialization returned different turf order lengths."
				else
					var/control_previous_cycle
					var/candidate_previous_cycle
					for(var/index in 1 to length(turfs))
						if(control_result[2][index] != turfs[index] || candidate_result[2][index] != turfs[index] || control_result[2][index] != candidate_result[2][index])
							failure = "Candidate initialization changed difference-check order at [index]."
							break
						var/list/control_state = control_states[turfs[index]]
						var/list/candidate_state = candidate_states[turfs[index]]
						var/control_cycle = control_state["current_cycle"]
						var/candidate_cycle = candidate_state["current_cycle"]
						if(!air_matches(control_state["air"], candidate_state["air"]) || !list_matches(control_state["visuals"], candidate_state["visuals"]) || !adjacency_matches(control_state["adjacency"], candidate_state["adjacency"]) || !associative_lists_match(control_state["reaction_results"], candidate_state["reaction_results"]) || control_state["excited"] != candidate_state["excited"] || control_state["archived_cycle"] != candidate_state["archived_cycle"] || !isnum(control_cycle) || !isnum(candidate_cycle) || control_cycle > -1 || candidate_cycle > -1 || (!isnull(control_previous_cycle) && control_cycle > control_previous_cycle) || (!isnull(candidate_previous_cycle) && candidate_cycle > candidate_previous_cycle))
							failure = "Candidate initialization changed gas, visual, or adjacency state at [index]."
							break
						control_previous_cycle = control_cycle
						candidate_previous_cycle = candidate_cycle
				if(!failure && (!helper_used || candidate_misses >= control_misses))
					failure = "Own-mixture startup prefetch did not reduce cold misses: control [control_misses], candidate [candidate_misses], helper [helper_used]."
				if(!failure && candidate_hits + candidate_misses != control_hits + control_misses)
					failure = "Startup prefetch changed the total number of snapshot reads."
				if(!failure && (candidate_misses != expected_candidate_misses || control_misses != length(turfs)))
					failure = "Startup cache misses differ from the fixture's bucket aliases: control [control_misses] (expected [length(turfs)]), candidate [candidate_misses] (expected [expected_candidate_misses])."
		if(!failure && (!SSdogmos.equal_u64_words(SSair.dogmos_frontier_epoch, saved_frontier_epoch) || !SSdogmos.equal_u64_words(SSair.dogmos_stage_epoch, saved_stage_epoch) || SSdogmos.dogmos_pending_callback_count != saved_pending_callbacks || SSdogmos.dogmos_stale_callback_count != saved_stale_callbacks || SSair.dogmos_pending_stage || SSair.dogmos_pending_frontier_epoch))
			failure = "Initialization changed native stage, frontier epoch, or callback state."
	catch(var/exception/error)
		failure = "The startup prefetch fixture raised [error.name]."

	var/list/counter_report = list(
		"fixture_turfs" = length(turfs),
		"boundary_index" = 100,
		"control_misses" = control_misses,
		"candidate_misses" = candidate_misses,
		"expected_candidate_misses" = expected_candidate_misses,
		"fixture_slots" = fixture_slots,
		"fixture_generations" = fixture_generations,
		"fixture_buckets" = fixture_buckets,
		"control_hits" = control_hits,
		"candidate_hits" = candidate_hits,
		"control_topology_calls" = control_topology_calls,
		"candidate_topology_calls" = candidate_topology_calls,
		"helper_used" = helper_used)
	if(failure)
		counter_report["failure"] = failure
	file("[GLOB.log_directory]/dogmos-startup-own-prefetch.json") << json_encode(counter_report)

	if(SSdogmos.turf_registration_batching || length(SSdogmos.dogmos_pending_turf_lifecycle) || length(SSdogmos.dogmos_pending_turf_adjacency) || length(SSdogmos.dogmos_pending_turf_heat) || length(SSdogmos.dogmos_pending_turf_heat_adjacency))
		return dogmos_abort_fixture("The startup prefetch fixture left a registration batch pending after an initialization path.")
	if(!restore_turfs(turfs, initial_states))
		return dogmos_abort_fixture("The startup prefetch fixture could not restore its reserved turf state.")
	if(SSair.dogmos_pending_stage || SSair.dogmos_pending_frontier_epoch || !SSdogmos.equal_u64_words(SSair.dogmos_frontier_epoch, saved_frontier_epoch) || !SSdogmos.equal_u64_words(SSair.dogmos_stage_epoch, saved_stage_epoch))
		return dogmos_abort_fixture("The startup prefetch fixture changed accepted native state during restoration.")
	SSdogmos.reset_mixture_snapshot_cache()
	for(var/field in saved_air_fields)
		SSair.vars[field] = saved_air_fields[field]
	Master.current_ticklimit = saved_tick_limit
	SSdogmos.turf_registration_batching = saved_batching
	if(failure)
		return Fail(failure, __FILE__, __LINE__)


#endif
