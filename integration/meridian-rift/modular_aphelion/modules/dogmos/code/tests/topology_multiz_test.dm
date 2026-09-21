#if defined(UNIT_TESTS) || defined(SPACEMAN_DMM)
#define DOGMOS_MULTIZ_TEST_STAGE_TURFS 4


/datum/unit_test/dogmos_multiz_gas_adjacency
	var/turf/open/floor/plating/dogmos_multiz_vertical_gate/lower
	var/turf/open/openspace/upper
	var/lower_z
	var/upper_z
	var/saved_lower_multiz_row
	var/saved_upper_multiz_row
	var/cache_active = FALSE
	var/list/saved_turfs
	var/list/cleanup_failures
	var/last_rebuild_error
	var/last_restore_link_error
	var/list/saved_active_turfs
	var/list/saved_frontier
	var/list/saved_frontier_tickers
	var/list/saved_owned_turfs
	var/cleanup_attempted = FALSE
	var/saved_max_queued
	var/datum/gas_mixture/immutable/space/canonical_space_gas
	var/list/canonical_space_snapshot

/datum/unit_test/dogmos_multiz_gas_adjacency/proc/edge_key(turf/first, turf/second)
	var/first_slot = first.dogmos_service_slot()
	var/first_generation = first.dogmos_service_generation()
	var/second_slot = second.dogmos_service_slot()
	var/second_generation = second.dogmos_service_generation()
	return first_slot < second_slot ? "[first_slot]:[first_generation]:[second_slot]:[second_generation]" : "[second_slot]:[second_generation]:[first_slot]:[first_generation]"

/datum/unit_test/dogmos_multiz_gas_adjacency/proc/pending_topology_empty()
	return !length(SSdogmos.dogmos_pending_turf_lifecycle) && !length(SSdogmos.dogmos_pending_turf_adjacency) \
		&& !length(SSdogmos.dogmos_pending_turf_adjacency_index) && !length(SSdogmos.dogmos_pending_turf_heat) \
		&& !length(SSdogmos.dogmos_pending_turf_heat_adjacency) && !length(SSdogmos.dogmos_pending_turf_heat_adjacency_index) \
		&& !length(SSdogmos.dogmos_pending_adjacency_retry) && !length(SSdogmos.dogmos_pending_mixture_unregistrations)

/datum/unit_test/dogmos_multiz_gas_adjacency/proc/record_cleanup_failure(phase, detail)
	if(!cleanup_failures)
		cleanup_failures = list()
	cleanup_failures += detail ? "[phase]: [detail]" : phase

/datum/unit_test/dogmos_multiz_gas_adjacency/proc/cleanup_failure_summary()
	return length(cleanup_failures) ? cleanup_failures.Join("; ") : "no cleanup diagnostic was recorded"

/datum/unit_test/dogmos_multiz_gas_adjacency/proc/pending_topology_counts()
	return "lifecycle=[length(SSdogmos.dogmos_pending_turf_lifecycle)], gas_adjacency=[length(SSdogmos.dogmos_pending_turf_adjacency)], gas_index=[length(SSdogmos.dogmos_pending_turf_adjacency_index)], turf_heat=[length(SSdogmos.dogmos_pending_turf_heat)], heat_adjacency=[length(SSdogmos.dogmos_pending_turf_heat_adjacency)], heat_index=[length(SSdogmos.dogmos_pending_turf_heat_adjacency_index)], retry=[length(SSdogmos.dogmos_pending_adjacency_retry)], unregister=[length(SSdogmos.dogmos_pending_mixture_unregistrations)]"

/datum/unit_test/dogmos_multiz_gas_adjacency/proc/open_turf_state_detail(turf/open/target)
	var/list/content_types = list()
	for(var/atom/contained as anything in target.contents)
		content_types += "[contained.type]"
	var/content_detail = length(content_types) ? content_types.Join(", ") : "none"
	var/reservation_flags = target.turf_flags & (RESERVATION_TURF | UNUSED_RESERVATION_TURF)
	return "type=[target.type], flags_1=[target.flags_1], turf_flags=[target.turf_flags], reservation_flags=[reservation_flags], contents=[length(target.contents)] ([content_detail]), active=[target in SSair.active_turfs], currentrun=[SSair.currentrun && (target in SSair.currentrun)], excited=[target.excited], group=[!!target.excited_group], canonical_air=[target.air == canonical_space_gas]"

/datum/unit_test/dogmos_multiz_gas_adjacency/proc/is_dormant_initialized_space(turf/target)
	if(!istype(target, /turf/open/space))
		return FALSE
	var/turf/open/space/open_space = target
	return (open_space.type == /turf/open/space || open_space.type == /turf/open/space/basic) \
		&& (open_space.flags_1 & INITIALIZED_1) && !(open_space.turf_flags & (RESERVATION_TURF | UNUSED_RESERVATION_TURF)) && !length(open_space.contents) \
		&& !(open_space in SSair.active_turfs) && !open_space.excited && !open_space.excited_group

/datum/unit_test/dogmos_multiz_gas_adjacency/proc/is_dormant_frontier_turf(turf/target)
	if(!istype(target, /turf/open))
		return FALSE
	var/turf/open/open_turf = target
	return (open_turf.flags_1 & INITIALIZED_1) && open_turf.air && !length(open_turf.contents) \
		&& !(open_turf in SSair.active_turfs) && !open_turf.excited && !open_turf.excited_group \
		&& !(SSair.currentrun && (open_turf in SSair.currentrun))

/datum/unit_test/dogmos_multiz_gas_adjacency/proc/build_fixture_frontier(list/owned_turfs)
	var/list/frontier = list()
	for(var/turf/open/owned as anything in owned_turfs)
		if(!(owned in frontier))
			frontier += owned
		for(var/turf/neighbor as anything in owned.atmos_adjacent_turfs)
			if(!(neighbor in frontier))
				frontier += neighbor
	return frontier

/datum/unit_test/dogmos_multiz_gas_adjacency/proc/frontier_is_safe(list/frontier)
	if(!islist(frontier) || !length(frontier))
		return FALSE
	for(var/target as anything in frontier)
		if(!is_dormant_frontier_turf(target))
			return FALSE
	return TRUE

/datum/unit_test/dogmos_multiz_gas_adjacency/proc/capture_fixture_frontier(list/owned_turfs)
	var/list/frontier = build_fixture_frontier(owned_turfs)
	if(!frontier_is_safe(frontier))
		return FALSE
	saved_owned_turfs = list()
	for(var/turf/owned_turf as anything in owned_turfs)
		saved_owned_turfs += list(list(owned_turf.x, owned_turf.y, owned_turf.z))
	saved_frontier = list()
	saved_active_turfs = SSair.active_turfs.Copy()
	saved_frontier_tickers = list()
	for(var/turf/open/frontier_turf as anything in frontier)
		var/frontier_key = "[frontier_turf.x],[frontier_turf.y],[frontier_turf.z]"
		saved_frontier += list(list(frontier_turf.x, frontier_turf.y, frontier_turf.z))
		saved_frontier_tickers[frontier_key] = frontier_turf.significant_share_ticker
	return TRUE

/datum/unit_test/dogmos_multiz_gas_adjacency/proc/active_turfs_match_snapshot()
	if(!islist(saved_active_turfs) || length(SSair.active_turfs) != length(saved_active_turfs))
		return FALSE
	for(var/index in 1 to length(saved_active_turfs))
		if(SSair.active_turfs[index] != saved_active_turfs[index])
			return FALSE
	return TRUE

/datum/unit_test/dogmos_multiz_gas_adjacency/proc/restore_fixture_frontier()
	var/success = TRUE
	for(var/list/state as anything in saved_frontier)
		var/turf/frontier_target = locate(state[1], state[2], state[3])
		if(!istype(frontier_target, /turf/open))
			record_cleanup_failure("active frontier", "[state[1]],[state[2]],[state[3]] lost open-turf identity")
			success = FALSE
			continue
		var/turf/open/frontier_turf = frontier_target
		var/frontier_key = "[frontier_turf.x],[frontier_turf.y],[frontier_turf.z]"
		try
			if(frontier_turf.excited || (frontier_turf in SSair.active_turfs) || (SSair.currentrun && (frontier_turf in SSair.currentrun)))
				SSair.sleep_active_turf(frontier_turf)
			frontier_turf.significant_share_ticker = saved_frontier_tickers[frontier_key]
		catch(var/exception/restore_frontier_error)
			record_cleanup_failure("active frontier", "[frontier_turf.x],[frontier_turf.y],[frontier_turf.z] restoration raised [restore_frontier_error.name]")
			success = FALSE
			continue
		if(!is_dormant_frontier_turf(frontier_turf) || frontier_turf.significant_share_ticker != saved_frontier_tickers[frontier_key])
			record_cleanup_failure("active frontier", "[frontier_turf.x],[frontier_turf.y],[frontier_turf.z] [open_turf_state_detail(frontier_turf)], ticker=[frontier_turf.significant_share_ticker], saved_ticker=[saved_frontier_tickers[frontier_key]]")
			success = FALSE
	if(!active_turfs_match_snapshot())
		record_cleanup_failure("active frontier", "SSair.active_turfs identities or order differ from the pre-mutation snapshot")
		success = FALSE
	return success

/datum/unit_test/dogmos_multiz_gas_adjacency/proc/owned_turfs_are_dormant()
	for(var/list/state as anything in saved_owned_turfs)
		var/turf/target = locate(state[1], state[2], state[3])
		if(!is_dormant_initialized_space(target))
			return FALSE
	return TRUE

/datum/unit_test/dogmos_multiz_gas_adjacency/proc/empty_space_ring(turf/center, list/result)
	for(var/direction in GLOB.cardinals)
		var/turf/neighbor = get_step(center, direction)
		if(!is_dormant_initialized_space(neighbor))
			return FALSE
		result += neighbor
	return TRUE

/** Physical stacking locates candidates; map-cache rows are the only logical z-link authority. */
/datum/unit_test/dogmos_multiz_gas_adjacency/proc/find_fixture_pair()
	if(world.maxz < 2)
		return FALSE
	for(var/z_index in 1 to world.maxz - 1)
		for(var/turf/candidate as anything in Z_TURFS(z_index))
			// This search precedes all fixture mutation; yielding here cannot expose temporary links.
			CHECK_TICK
			if(!istype(candidate, /turf/open/space))
				continue
			var/turf/open/space/space_candidate = candidate
			if(!is_dormant_initialized_space(space_candidate))
				continue
			var/turf/candidate_above = locate(candidate.x, candidate.y, candidate.z + 1)
			if(!istype(candidate_above, /turf/open/space))
				continue
			var/turf/open/space/space_candidate_above = candidate_above
			if(!is_dormant_initialized_space(space_candidate_above))
				continue
			var/list/ring = list()
			if(!empty_space_ring(candidate, ring) || !empty_space_ring(candidate_above, ring))
				continue
			var/list/owned_turfs = list(candidate, candidate_above)
			owned_turfs += ring
			if(!frontier_is_safe(build_fixture_frontier(owned_turfs)))
				continue
			lower = candidate
			upper = candidate_above
			lower_z = candidate.z
			upper_z = candidate_above.z
			return ring
	return FALSE


/datum/unit_test/dogmos_multiz_gas_adjacency/proc/save_turf(turf/open/space/target)
	if(!is_dormant_initialized_space(target) || target.air != canonical_space_gas)
		return FALSE
	var/original_baseturfs = islist(target.baseturfs) ? target.baseturfs.Copy() : target.baseturfs
	saved_turfs += list(list(
		target.x, target.y, target.z, target.type, original_baseturfs, target.turf_flags, get_area(target), target.blocks_air,
		target.current_cycle, target.archived_cycle, target.pressure_difference, target.pressure_direction, target.temperature))
	return TRUE

/datum/unit_test/dogmos_multiz_gas_adjacency/proc/baseturfs_match(current_baseturfs, saved_baseturfs)
	if(!islist(saved_baseturfs))
		return current_baseturfs == saved_baseturfs
	if(!islist(current_baseturfs) || length(current_baseturfs) != length(saved_baseturfs))
		return FALSE
	for(var/index in 1 to length(saved_baseturfs))
		if(current_baseturfs[index] != saved_baseturfs[index])
			return FALSE
	return TRUE

/datum/unit_test/dogmos_multiz_gas_adjacency/proc/canonical_space_is_unchanged()
	if(!canonical_space_gas?.is_immutable())
		return FALSE
	var/list/current_snapshot = canonical_space_gas.dogmos_snapshot()
	if(!islist(current_snapshot) || length(current_snapshot) != length(canonical_space_snapshot))
		return FALSE
	for(var/index in 1 to length(current_snapshot))
		if(current_snapshot[index] != canonical_space_snapshot[index])
			return FALSE
	return TRUE

/datum/unit_test/dogmos_multiz_gas_adjacency/proc/activate_fixture_link()
	saved_lower_multiz_row = SSmapping.multiz_levels[lower_z]
	saved_upper_multiz_row = SSmapping.multiz_levels[upper_z]
	// Replace both rows, retaining no external vertical route during the measured interval.
	var/list/lower_row = new /list(LARGEST_Z_LEVEL_INDEX)
	var/list/upper_row = new /list(LARGEST_Z_LEVEL_INDEX)
	lower_row[Z_LEVEL_UP] = TRUE
	upper_row[Z_LEVEL_DOWN] = TRUE
	SSmapping.multiz_levels[lower_z] = lower_row
	SSmapping.multiz_levels[upper_z] = upper_row
	cache_active = TRUE
	if(get_step_multiz(lower, UP) == upper && get_step_multiz(upper, DOWN) == lower)
		return TRUE
	// No turf changed yet; undo this failed logical-link attempt before returning to Run().
	restore_fixture_link()
	saved_turfs = null
	return FALSE

/datum/unit_test/dogmos_multiz_gas_adjacency/proc/restore_fixture_link()
	if(!cache_active)
		return TRUE
	last_restore_link_error = null
	var/success = TRUE
	try
		SSmapping.multiz_levels[lower_z] = saved_lower_multiz_row
	catch(var/exception/restore_lower_row_error)
		last_restore_link_error = "lower cache row raised [restore_lower_row_error.name]"
		success = FALSE
	try
		SSmapping.multiz_levels[upper_z] = saved_upper_multiz_row
	catch(var/exception/restore_upper_row_error)
		last_restore_link_error = last_restore_link_error ? "[last_restore_link_error], upper cache row raised [restore_upper_row_error.name]" : "upper cache row raised [restore_upper_row_error.name]"
		success = FALSE
	if(success)
		cache_active = FALSE
	return success

/datum/unit_test/dogmos_multiz_gas_adjacency/proc/fixture_link_is_restored()
	return !cache_active && SSmapping.multiz_levels[lower_z] == saved_lower_multiz_row \
		&& SSmapping.multiz_levels[upper_z] == saved_upper_multiz_row

/** Uses the DM adjacency path; retry is the maintained deferred publication path. */
/datum/unit_test/dogmos_multiz_gas_adjacency/proc/rebuild_deferred(reverse_order = FALSE)
	last_rebuild_error = null
	if(SSdogmos.turf_registration_batching || SSdogmos.runtime_topology_batching || !lower || !upper)
		last_rebuild_error = "precondition failed: registration_batching=[SSdogmos.turf_registration_batching], runtime_batching=[SSdogmos.runtime_topology_batching], lower=[!!lower], upper=[!!upper]"
		return FALSE
	SSdogmos.runtime_topology_batching = TRUE
	try
		if(reverse_order)
			upper.immediate_calculate_adjacent_turfs()
			lower.immediate_calculate_adjacent_turfs()
		else
			lower.immediate_calculate_adjacent_turfs()
			upper.immediate_calculate_adjacent_turfs()
	catch(var/exception/rebuild_error)
		SSdogmos.runtime_topology_batching = FALSE
		last_rebuild_error = "immediate adjacency raised [rebuild_error.name]"
		return FALSE
	SSdogmos.runtime_topology_batching = FALSE
	try
		SSdogmos.retry_pending_turf_adjacencies()
	catch(var/exception/rebuild_retry_error)
		last_rebuild_error = "retry publication raised [rebuild_retry_error.name]"
		return FALSE
	if(!lower.dogmos_air_registration_is_current(FALSE) || !upper.dogmos_air_registration_is_current(FALSE))
		last_rebuild_error = "air registrations were not current"
		return FALSE
	return TRUE

/datum/unit_test/dogmos_multiz_gas_adjacency/proc/edge_matches(list/edge, turf/first, turf/second, connected)
	if(!islist(edge) || length(edge) != 6 || edge[5] != !!connected || edge[6])
		return FALSE
	var/first_slot = first.dogmos_service_slot()
	var/first_generation = first.dogmos_service_generation()
	var/second_slot = second.dogmos_service_slot()
	var/second_generation = second.dogmos_service_generation()
	return (edge[1] == first_slot && edge[2] == first_generation && edge[3] == second_slot && edge[4] == second_generation) \
		|| (edge[1] == second_slot && edge[2] == second_generation && edge[3] == first_slot && edge[4] == first_generation)

/datum/unit_test/dogmos_multiz_gas_adjacency/proc/pending_pair_matches(turf/first, turf/second, connected)
	var/key = edge_key(first, second)
	var/list/edge = SSdogmos.dogmos_pending_turf_adjacency[key]
	if(!edge_matches(edge, first, second, connected))
		return FALSE
	var/list/first_index = SSdogmos.dogmos_pending_turf_adjacency_index["[first.dogmos_service_slot()]"]
	var/list/second_index = SSdogmos.dogmos_pending_turf_adjacency_index["[second.dogmos_service_slot()]"]
	if(!first_index?[key] || !second_index?[key] || SSdogmos.dogmos_pending_turf_heat_adjacency[key])
		return FALSE
	var/matches = 0
	for(var/other_key in SSdogmos.dogmos_pending_turf_adjacency)
		if(edge_matches(SSdogmos.dogmos_pending_turf_adjacency[other_key], first, second, connected))
			matches++
	return matches == 1

/datum/unit_test/dogmos_multiz_gas_adjacency/proc/flush_topology()
	return !SSdogmos.runtime_topology_batching && !SSdogmos.turf_registration_batching && SSdogmos.flush_turf_registration_batch()

/datum/unit_test/dogmos_multiz_gas_adjacency/proc/restore_saved_turfs(turf/only_turf = null)
	var/success = TRUE
	for(var/list/state as anything in saved_turfs)
		var/turf/current = locate(state[1], state[2], state[3])
		if(only_turf && current != only_turf)
			continue
		var/turf/restored_turf
		try
			// ChangeTurf deliberately rewrites loader-only /space/basic to initialized runtime /space.
			restored_turf = current?.ChangeTurf(/turf/open/space, state[5], CHANGETURF_RECALC_ADJACENT | CHANGETURF_NO_AREA_CHANGE)
		catch(var/exception/restore_turf_error)
			record_cleanup_failure("restore turf [state[1]],[state[2]],[state[3]]", "ChangeTurf raised [restore_turf_error.name]")
			success = FALSE
			continue
		if(!restored_turf)
			record_cleanup_failure("restore turf [state[1]],[state[2]],[state[3]]", "ChangeTurf returned null")
			success = FALSE
			continue
		if(restored_turf.type != /turf/open/space)
			record_cleanup_failure("restore turf [state[1]],[state[2]],[state[3]] identity", "got [restored_turf.type], expected /turf/open/space")
			success = FALSE
			continue
		var/turf/open/space/restored = restored_turf
		if(get_area(restored) != state[7])
			record_cleanup_failure("restore turf [state[1]],[state[2]],[state[3]] area", "area identity changed")
			success = FALSE
		if(!baseturfs_match(restored.baseturfs, state[5]))
			record_cleanup_failure("restore turf [state[1]],[state[2]],[state[3]] baseturfs", "saved baseturfs values were not restored")
			success = FALSE
		if(!(restored.flags_1 & INITIALIZED_1))
			record_cleanup_failure("restore turf [state[1]],[state[2]],[state[3]] initialization", "INITIALIZED_1 is absent")
			success = FALSE
		if(restored.air != canonical_space_gas)
			record_cleanup_failure("restore turf [state[1]],[state[2]],[state[3]] canonical air", "restored air identity differs")
			success = FALSE
		if(restored.air != canonical_space_gas)
			continue
		// No INHERIT_AIR: /space Initialize restores its shared immutable space_gas.
		restored.turf_flags = state[6]
		restored.blocks_air = state[8]
		try
			restored.immediate_calculate_adjacent_turfs()
		catch(var/exception/restore_adjacency_error)
			record_cleanup_failure("restore turf [state[1]],[state[2]],[state[3]] adjacency", "rebuild raised [restore_adjacency_error.name]")
			success = FALSE
		// Selection requires dormant source space; normalize rather than revive a stale group pointer.
		try
			SSair.sleep_active_turf(restored)
			restored.excited_group = null
			restored.current_cycle = state[9]
			restored.archived_cycle = state[10]
			restored.pressure_difference = state[11]
			restored.pressure_direction = state[12]
			restored.set_temperature(state[13])
		catch(var/exception/restore_state_error)
			record_cleanup_failure("restore turf [state[1]],[state[2]],[state[3]] state", "normalization raised [restore_state_error.name]")
			success = FALSE
			continue
		try
			if(!is_dormant_initialized_space(restored) || restored.air != canonical_space_gas)
				record_cleanup_failure("restore turf [state[1]],[state[2]],[state[3]] dormant witness", open_turf_state_detail(restored))
				success = FALSE
		catch(var/exception/restore_witness_error)
			record_cleanup_failure("restore turf [state[1]],[state[2]],[state[3]] dormant witness", "check raised [restore_witness_error.name]")
			success = FALSE
	return success

/** No sleep is legal after activate_fixture_link(): immediate/retry/flush are synchronous. */
/datum/unit_test/dogmos_multiz_gas_adjacency/proc/cleanup_fixture()
	if(!cache_active && !length(saved_turfs))
		return TRUE
	cleanup_failures = list()
	var/was_runtime_batching = SSdogmos.runtime_topology_batching
	var/was_registration_batching = SSdogmos.turf_registration_batching
	try
		if(cache_active && !was_runtime_batching && !was_registration_batching && SSdogmos.service_ready)
			if(!istype(lower, /turf/open/floor/plating/dogmos_multiz_vertical_gate) || !istype(upper, /turf/open/openspace))
				record_cleanup_failure("failed close", "fixture gate or upper turf identity was lost")
			else
				SSdogmos.runtime_topology_batching = TRUE
				lower.dogmos_multiz_open = FALSE
				lower.immediate_calculate_adjacent_turfs()
				upper.immediate_calculate_adjacent_turfs()
				SSdogmos.runtime_topology_batching = FALSE
				SSdogmos.retry_pending_turf_adjacencies()
				if(!flush_topology())
					record_cleanup_failure("failed close", "closure topology flush returned false")
		else if(cache_active)
			record_cleanup_failure("failed close", "runtime_batching=[was_runtime_batching], registration_batching=[was_registration_batching], service_ready=[SSdogmos.service_ready]")
	catch(var/exception/close_error)
		record_cleanup_failure("failed close", "raised [close_error.name]")
	SSdogmos.runtime_topology_batching = was_runtime_batching
	SSdogmos.turf_registration_batching = was_registration_batching
	// Restore the upper openspace center while temporary rows still resolve its maintained transparency cleanup.
	if(cache_active)
		SSdogmos.runtime_topology_batching = TRUE
		SSdogmos.turf_registration_batching = was_registration_batching
		try
			if(!restore_saved_turfs(upper))
				record_cleanup_failure("restore upper center", "the upper openspace center failed restoration before cache-row removal")
		catch(var/exception/restore_upper_center_error)
			record_cleanup_failure("restore upper center", "raised [restore_upper_center_error.name]")
	// Keep publication batched through map-row and turf restoration; never publish the temporary upper replacement.
	var/link_was_active = cache_active
	try
		if(!restore_fixture_link())
			record_cleanup_failure("restore link", last_restore_link_error || "cache-row restoration returned false")
	catch(var/exception/restore_link_error)
		record_cleanup_failure("restore link", "raised [restore_link_error.name]")
	try
		if(link_was_active && !fixture_link_is_restored())
			record_cleanup_failure("restore link", "saved multiz cache-row identities were not restored")
	catch(var/exception/restore_link_witness_error)
		record_cleanup_failure("restore link", "identity witness raised [restore_link_witness_error.name]")
	SSdogmos.runtime_topology_batching = TRUE
	SSdogmos.turf_registration_batching = was_registration_batching
	try
		if(!restore_saved_turfs())
			record_cleanup_failure("restore turfs", "one or more saved turf witnesses failed")
	catch(var/exception/restore_turfs_error)
		record_cleanup_failure("restore turfs", "raised [restore_turfs_error.name]")
	SSdogmos.runtime_topology_batching = was_runtime_batching
	SSdogmos.turf_registration_batching = was_registration_batching
	if(!was_runtime_batching && !was_registration_batching && SSdogmos.service_ready)
		try
			SSdogmos.retry_pending_turf_adjacencies()
			if(!flush_topology())
				record_cleanup_failure("final topology", "flush returned false")
		catch(var/exception/final_topology_error)
			record_cleanup_failure("final topology", "retry or flush raised [final_topology_error.name]")
	else
		record_cleanup_failure("final topology", "skipped with runtime_batching=[was_runtime_batching], registration_batching=[was_registration_batching], service_ready=[SSdogmos.service_ready]")
	SSdogmos.runtime_topology_batching = was_runtime_batching
	SSdogmos.turf_registration_batching = was_registration_batching
	try
		if(!restore_fixture_frontier())
			record_cleanup_failure("active frontier", "one or more frontier members did not return to the pre-mutation dormant state")
	catch(var/exception/restore_frontier_cleanup_error)
		record_cleanup_failure("active frontier", "restoration raised [restore_frontier_cleanup_error.name]")
	if(!owned_turfs_are_dormant())
		record_cleanup_failure("owned dormancy", "one or more of the ten owned turfs did not return to dormant initialized space")
	if(!pending_topology_empty())
		record_cleanup_failure("final pending queues", pending_topology_counts())
	try
		if(!canonical_space_is_unchanged())
			record_cleanup_failure("canonical witness", "immutable space gas identity or snapshot changed")
	catch(var/exception/canonical_witness_error)
		record_cleanup_failure("canonical witness", "snapshot check raised [canonical_witness_error.name]")
	SSdogmos.dogmos_runtime_topology_max_queued = saved_max_queued
	var/success = !length(cleanup_failures)
	if(success)
		saved_turfs = null
		saved_active_turfs = null
		saved_frontier = null
		saved_frontier_tickers = null
		saved_owned_turfs = null
		lower = null
		upper = null
	return success

/datum/unit_test/dogmos_multiz_gas_adjacency/proc/run_fixture()
	var/list/ring = find_fixture_pair()
	if(!islist(ring))
		return "No empty, physically stacked space cells with sealed cardinal rings are available for the bounded multiz fixture."
	// CHECK_TICK may have yielded while searching. Re-establish the boundary before any global mutation.
	if(!dogmos_wait_for_stage_boundary() || dogmos_fixture_aborted)
		return null
	if(SSdogmos.runtime_topology_batching || SSdogmos.turf_registration_batching || !pending_topology_empty())
		return "The multiz fixture did not regain an empty Dogmos topology boundary after its search."
	saved_max_queued = SSdogmos.dogmos_runtime_topology_max_queued
	canonical_space_gas = lower.air
	var/list/initial_space_snapshot = canonical_space_gas?.dogmos_snapshot()
	canonical_space_snapshot = initial_space_snapshot?.Copy()
	if(!canonical_space_gas?.is_immutable() || !islist(canonical_space_snapshot) || upper.air != canonical_space_gas)
		return "The selected initialized base/basic space cells did not share one immutable canonical space mixture."
	for(var/turf/open/space/ring_turf as anything in ring)
		if(!is_dormant_initialized_space(ring_turf) || ring_turf.air != canonical_space_gas)
			return "A selected cardinal ring turf did not retain the canonical space-air witness."
	var/list/owned_turfs = list(lower, upper)
	owned_turfs += ring
	// Capture after a fresh stage boundary and before mutation. No later fixture operation sleeps.
	if(!capture_fixture_frontier(owned_turfs))
		return "The selected turfs or their pre-mutation adjacency frontier were active, grouped, nonempty, uninitialized, or queued in the current air run."
	// Capture only after all ten inputs validate, so a pre-activation failure leaves no turf touched.
	if(!save_turf(lower) || !save_turf(upper))
		return "The selected base/basic space cells could not retain their canonical space-air witness."
	for(var/turf/open/space/ring_turf as anything in ring)
		if(!save_turf(ring_turf))
			return "The validated cardinal ring could not retain its canonical space-air witness."
	if(!activate_fixture_link())
		return "Temporary multiz cache rows did not make the selected pair resolve through get_step_multiz()."
	SSdogmos.runtime_topology_batching = TRUE
	try
		for(var/turf/open/space/ring_turf as anything in ring)
			ring_turf.ChangeTurf(/turf/closed/indestructible, flags = CHANGETURF_RECALC_ADJACENT | CHANGETURF_NO_AREA_CHANGE)
		lower = lower.ChangeTurf(/turf/open/floor/plating/dogmos_multiz_vertical_gate, flags = CHANGETURF_RECALC_ADJACENT | CHANGETURF_NO_AREA_CHANGE)
		upper = upper.ChangeTurf(/turf/open/openspace, flags = CHANGETURF_RECALC_ADJACENT | CHANGETURF_NO_AREA_CHANGE)
	catch(var/exception/fixture_conversion_error)
		SSdogmos.runtime_topology_batching = FALSE
		return "The multiz fixture could not create its contained mutable-air pair: [fixture_conversion_error.name]."
	SSdogmos.runtime_topology_batching = FALSE
	if(!lower?.air || !upper?.air || !rebuild_deferred())
		var/rebuild_detail = last_rebuild_error || "missing lower or upper air"
		return "The multiz fixture could not rebuild current native registrations through the DM adjacency path: [rebuild_detail]."
	if(!CANATMOSPASS(lower, upper, TRUE) || !CANATMOSPASS(upper, lower, TRUE) || !(upper in lower.atmos_adjacent_turfs) || !(lower in upper.atmos_adjacent_turfs))
		return "The linked open pair did not form reciprocal DM vertical gas adjacency."
	if(!pending_pair_matches(lower, upper, TRUE))
		return "The open vertical pair did not produce one literal six-field gas edge with both reverse-index memberships and no heat edge."
	if(!flush_topology())
		return "The multiz fixture could not publish its open topology."
	lower.air.clear()
	upper.air.clear()
	lower.air.set_moles(GAS_O2, 200)
	upper.air.set_moles(GAS_O2, 0)
	var/open_lower_before = lower.air.get_moles(GAS_O2)
	var/open_upper_before = upper.air.get_moles(GAS_O2)
	if(!dogmos_run_fixture_stage(DOGMOS_MULTIZ_TEST_STAGE_TURFS, list(lower, upper)))
		return "The bounded native stage did not complete."
	var/open_lower_after = lower.air.get_moles(GAS_O2)
	var/open_upper_after = upper.air.get_moles(GAS_O2)
	if(open_lower_after >= open_lower_before || open_upper_after <= open_upper_before || open_lower_after <= open_upper_after || abs((open_lower_after + open_upper_after) - (open_lower_before + open_upper_before)) > 0.02)
		return "The published open vertical gas edge did not mix oxygen within the bounded native stage."
	var/lower_turf_generation = lower.dogmos_service_generation()
	var/lower_mix_slot = lower.air.dogmos_slot
	var/lower_mix_generation = lower.air.dogmos_generation
	var/upper_turf_generation = upper.dogmos_service_generation()
	var/upper_mix_slot = upper.air.dogmos_slot
	var/upper_mix_generation = upper.air.dogmos_generation
	lower.dogmos_multiz_open = FALSE
	if(CANATMOSPASS(lower, upper, TRUE) || CANATMOSPASS(upper, lower, TRUE))
		return "The retained-air z gate left one vertical CANATMOSPASS direction open."
	if(!rebuild_deferred(TRUE))
		return "The retained-air z gate could not rebuild through reverse DM endpoint order: [last_rebuild_error]."
	if(!rebuild_deferred())
		return "The retained-air z gate could not rebuild through forward DM endpoint order: [last_rebuild_error]."
	if(lower.dogmos_service_generation() != lower_turf_generation || lower.air.dogmos_slot != lower_mix_slot || lower.air.dogmos_generation != lower_mix_generation || upper.dogmos_service_generation() != upper_turf_generation || upper.air.dogmos_slot != upper_mix_slot || upper.air.dogmos_generation != upper_mix_generation)
		return "Closing the z gate replaced a turf or mixture identity instead of exercising adjacency publication."
	if((upper in lower.atmos_adjacent_turfs) || (lower in upper.atmos_adjacent_turfs) || !pending_pair_matches(lower, upper, FALSE))
		return "The retained-air z gate did not publish one stable disconnected vertical gas edge through both DM rebuild orders."
	if(!flush_topology())
		return "The multiz fixture could not publish its closed topology."
	var/closed_lower_before = lower.air.get_moles(GAS_O2)
	var/closed_upper_before = upper.air.get_moles(GAS_O2)
	if(!dogmos_run_fixture_stage(DOGMOS_MULTIZ_TEST_STAGE_TURFS, list(lower, upper)))
		return "The bounded closed native stage did not complete."
	if(abs(lower.air.get_moles(GAS_O2) - closed_lower_before) > 0.0001 || abs(upper.air.get_moles(GAS_O2) - closed_upper_before) > 0.0001)
		return "A rebuilt closed vertical edge transferred oxygen while both mixtures retained their identities."
	return null

/datum/unit_test/dogmos_multiz_gas_adjacency/Run()
	saved_turfs = list()
	cleanup_failures = list()
	cleanup_attempted = FALSE
	var/failure
	try
		failure = run_fixture()
	catch(var/exception/run_fixture_error)
		failure = "The multiz fixture raised [run_fixture_error.name]."
	var/cleanup_succeeded
	try
		cleanup_attempted = TRUE
		cleanup_succeeded = cleanup_fixture()
	catch(var/exception/run_cleanup_error)
		record_cleanup_failure("cleanup", "cleanup_fixture raised [run_cleanup_error.name]")
		cleanup_succeeded = FALSE
	if(!cleanup_succeeded)
		var/primary_failure = failure || "The multiz fixture run completed without returning a failure string."
		return dogmos_abort_fixture("The multiz fixture run failure: [primary_failure] Cleanup diagnostics: [cleanup_failure_summary()].")
	if(dogmos_fixture_aborted)
		return
	if(failure)
		return Fail(failure, __FILE__, __LINE__)

/datum/unit_test/dogmos_multiz_gas_adjacency/Destroy()
	// RunUnitTest invokes restore_atmos() before Destroy(); never retry a failed Run cleanup afterwards.
	if(!cleanup_attempted && (cache_active || length(saved_turfs)) && !cleanup_fixture())
		dogmos_abort_fixture("The multiz fixture fallback cleanup failed after Run() returned early.")
	return ..()

#undef DOGMOS_MULTIZ_TEST_STAGE_TURFS


#endif
