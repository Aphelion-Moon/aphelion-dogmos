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

/// Actual shuttle movement must publish a bounded batch and copy gas before its final signal.
/datum/unit_test/dogmos_shuttle_topology_batch
	/// Whether a surrounding operation owns publication throughout the move.
	var/outer_batch_owner = FALSE
	var/turf/open/moving_source
	var/turf/open/moving_destination
	var/list/adjacency_observations
	var/list/shuttle_observation

/datum/unit_test/dogmos_shuttle_topology_batch/outer_owner
	outer_batch_owner = TRUE

/datum/unit_test/dogmos_shuttle_topology_batch/proc/observe_adjacency(turf/source)
	SIGNAL_HANDLER
	adjacency_observations += list(list(moving_source.blocks_air, moving_destination.blocks_air, moving_source.air.get_moles(GAS_O2)))

/datum/unit_test/dogmos_shuttle_topology_batch/proc/observe_shuttle(turf/source, turf/open/destination)
	SIGNAL_HANDLER
	shuttle_observation = list(source.blocks_air, destination.blocks_air, destination.air.get_moles(GAS_O2), SSdogmos.runtime_topology_batching)

/datum/unit_test/dogmos_shuttle_topology_batch/Run()
	if(!dogmos_wait_for_stage_boundary())
		return
	var/original_batching = SSdogmos.runtime_topology_batching
	if(original_batching || SSdogmos.turf_registration_batching)
		return Fail("Shuttle fixture encountered another batch owner.", __FILE__, __LINE__)
	var/list/pair = allocate_turf_pair()
	var/list/restoration = list()
	for(var/turf/fixture_turf as anything in pair)
		restoration += list(list(fixture_turf.x, fixture_turf.y, fixture_turf.z, fixture_turf.type, islist(fixture_turf.baseturfs) ? fixture_turf.baseturfs.Copy() : fixture_turf.baseturfs))
	var/original_can_fire = SSair.can_fire
	SSair.can_fire = FALSE
	var/turf/open/indestructible/plating/airless/dogmos_shuttle_probe/probe
	var/list/measured_calls
	var/failure
	try
		moving_source = pair[1]
		moving_destination = pair[2]
		moving_source = moving_source.ChangeTurf(/turf/open/indestructible/plating/airless/dogmos_shuttle_probe)
		moving_destination = moving_destination.ChangeTurf(/turf/open/indestructible/plating/airless/dogmos_shuttle_probe)
		moving_source.baseturfs = list(/turf/open/space, /turf/baseturf_skipover/shuttle, moving_source.type)
		moving_source.air.clear()
		moving_source.air.set_moles(GAS_O2, 17)
		moving_destination.air.clear()
		moving_destination.air.set_moles(GAS_O2, 3)
		moving_source.air_update_turf(TRUE)
		moving_destination.air_update_turf(TRUE)
		if(!SSdogmos.flush_turf_registration_batch())
			CRASH("Shuttle fixture setup could not publish topology.")
		adjacency_observations = list()
		RegisterSignal(moving_source, COMSIG_TURF_CALCULATED_ADJACENT_ATMOS, PROC_REF(observe_adjacency))
		RegisterSignal(moving_source, COMSIG_TURF_ON_SHUTTLE_MOVE, PROC_REF(observe_shuttle))
		probe = moving_source
		probe.dogmos_shuttle_samples = list()
		SSdogmos.runtime_topology_batching = outer_batch_owner
		if(!moving_source.onShuttleMove(moving_destination, list(), EAST, ignore_area_change = TRUE))
			CRASH("Shuttle fixture did not move its turf.")
		measured_calls = probe.dogmos_shuttle_samples
		probe.dogmos_shuttle_samples = null
		var/native_calls = 0
		for(var/call_count in measured_calls)
			native_calls += call_count
		if(length(measured_calls) != 2 || native_calls > 4)
			failure = "Two blocked shuttle updates published topology repeatedly ([length(measured_calls)] updates, [native_calls] native calls)."
		if(length(shuttle_observation) != 4 || !shuttle_observation[1] || !shuttle_observation[2] || shuttle_observation[3] != 17 || shuttle_observation[4] != outer_batch_owner)
			failure = "The shuttle signal did not see blocked turfs, copied gas and restored batch ownership."
		var/destination_blocked_index = 0
		var/both_blocked_index = 0
		var/observation_index = 0
		for(var/list/observation as anything in adjacency_observations)
			observation_index++
			if(observation[3] != 17)
				failure = "An intermediate adjacency callback read changed source gas."
			if(!destination_blocked_index && !observation[1] && observation[2])
				destination_blocked_index = observation_index
			if(!both_blocked_index && observation[1] && observation[2])
				both_blocked_index = observation_index
		if(!destination_blocked_index || !both_blocked_index || destination_blocked_index >= both_blocked_index)
			failure = "Shuttle movement did not preserve the ordered intermediate adjacency notifications."
		var/pending_topology = length(SSdogmos.dogmos_pending_adjacency_retry) + length(SSdogmos.dogmos_pending_turf_adjacency) + length(SSdogmos.dogmos_pending_turf_heat_adjacency)
		if(!outer_batch_owner && pending_topology)
			failure = "Shuttle movement retained topology after its final signal."
		if(outer_batch_owner && !pending_topology)
			failure = "Shuttle movement prematurely drained its outer owner's topology."
	catch(var/exception/error)
		failure = "Shuttle topology fixture raised [error]."
	if(probe)
		probe.dogmos_shuttle_samples = null
	if(moving_source)
		UnregisterSignal(moving_source, list(COMSIG_TURF_CALCULATED_ADJACENT_ATMOS, COMSIG_TURF_ON_SHUTTLE_MOVE))
	SSdogmos.runtime_topology_batching = original_batching
	file("[GLOB.log_directory]/dogmos-shuttle-topology.json") << json_encode(list("outer_owner" = outer_batch_owner, "calls_inside_updates" = measured_calls, "adjacency" = adjacency_observations, "shuttle" = shuttle_observation))
	moving_source = null
	moving_destination = null
	try
		if(!SSdogmos.flush_turf_registration_batch())
			return dogmos_abort_fixture("Shuttle cleanup could not reach the service.")
		for(var/list/saved_turf as anything in restoration)
			var/turf/current = locate(saved_turf[1], saved_turf[2], saved_turf[3])
			var/turf/restored = current.ChangeTurf(saved_turf[4])
			restored.baseturfs = saved_turf[5]
			if(!isopenturf(restored))
				return dogmos_abort_fixture("Shuttle cleanup did not restore an open floor.")
			restored.air_update_turf(TRUE, FALSE)
			if(saved_turf == restoration[1])
				run_loc_floor_bottom_left = restored
		if(!SSdogmos.flush_turf_registration_batch())
			return dogmos_abort_fixture("Shuttle cleanup could not publish restored topology.")
	catch(var/exception/cleanup_error)
		return dogmos_abort_fixture("Shuttle cleanup raised [cleanup_error].")
	// The normal test runner resets this room's gas and native temperature before Destroy().
	SSair.can_fire = original_can_fire
	if(failure)
		Fail(failure, __FILE__, __LINE__)

/// Counts identity reads only while a bounded topology fixture is measuring work.
/turf/open/indestructible/plating/airless/dogmos_topology_probe
	/// Whether identity lookups belong to the measured interval.
	var/dogmos_probe_enabled = FALSE
	/// Identity lookups made by the measured topology rebuilds.
	var/dogmos_probe_slot_reads = 0
	/// Test-only fault injected at the identity-read boundary, after fixture setup.
	var/dogmos_probe_throw = FALSE

/turf/open/indestructible/plating/airless/dogmos_topology_probe/dogmos_service_slot()
	if(dogmos_probe_throw)
		throw "dogmos batch exception sentinel"
	if(dogmos_probe_enabled)
		dogmos_probe_slot_reads++
	return ..()

/// Repeated notifications in one runtime batch must rebuild the final topology once.
/datum/unit_test/dogmos_runtime_topology_coalesces_notifications

/datum/unit_test/dogmos_runtime_topology_coalesces_notifications/Run()
	if(!dogmos_wait_for_stage_boundary())
		return
	var/original_can_fire = SSair.can_fire
	var/original_batching = SSdogmos.runtime_topology_batching
	if(original_batching || SSdogmos.turf_registration_batching)
		return Fail("Topology fixture encountered another batch owner.", __FILE__, __LINE__)
	var/original_type = run_loc_floor_bottom_left.type
	var/list/original_position = list(run_loc_floor_bottom_left.x, run_loc_floor_bottom_left.y, run_loc_floor_bottom_left.z)
	SSair.can_fire = FALSE
	var/turf/open/indestructible/plating/airless/dogmos_topology_probe/target
	var/calls_before = SSdogmos.dogmos_runtime_topology_calls
	var/failure_message
	var/slot_reads
	try
		target = run_loc_floor_bottom_left.ChangeTurf(/turf/open/indestructible/plating/airless/dogmos_topology_probe)
		target.immediate_calculate_adjacent_turfs()
		if(!SSdogmos.flush_turf_registration_batch())
			CRASH("Topology fixture setup could not reach the service.")
		target.air.set_moles(GAS_O2, 17)
		target.air.set_temperature(321)
		var/original_mixture_slot = target.air.dogmos_slot
		var/original_mixture_generation = target.air.dogmos_generation
		calls_before = SSdogmos.dogmos_runtime_topology_calls
		SSdogmos.runtime_topology_batching = TRUE
		target.dogmos_probe_enabled = TRUE
		for(var/repetition in 1 to 50)
			target.__update_auxtools_turf_adjacency_info(world.maxx, world.maxy)
		SSdogmos.runtime_topology_batching = original_batching
		if(!SSdogmos.flush_turf_registration_batch())
			failure_message = "The runtime batch failed to publish its final topology."
		slot_reads = target.dogmos_probe_slot_reads
		target.dogmos_probe_enabled = FALSE
		if(!failure_message && slot_reads > 4)
			failure_message = "Fifty notifications rebuilt the same turf repeatedly ([slot_reads] identity reads)."
		if(!failure_message && (target.air.dogmos_slot != original_mixture_slot || target.air.dogmos_generation != original_mixture_generation))
			failure_message = "Coalescing topology replaced the gas mixture identity."
		if(!failure_message && (target.air.get_moles(GAS_O2) != 17 || target.air.return_temperature() != 321))
			failure_message = "Coalescing topology changed gas state."
		if(!failure_message && (length(SSdogmos.dogmos_pending_adjacency_retry) || length(SSdogmos.dogmos_pending_turf_adjacency) || length(SSdogmos.dogmos_pending_turf_heat_adjacency)))
			failure_message = "The runtime batch retained pending topology after publication."
	catch(var/exception/error)
		failure_message = "Runtime topology fixture raised [error]."
	if(istype(target))
		target.dogmos_probe_enabled = FALSE
	SSdogmos.runtime_topology_batching = original_batching
	file("[GLOB.log_directory]/dogmos-runtime-topology-coalescing.json") << json_encode(list("notifications" = 50, "identity_reads" = slot_reads, "topology_calls" = SSdogmos.dogmos_runtime_topology_calls - calls_before))
	try
		if(!SSdogmos.flush_turf_registration_batch())
			return dogmos_abort_fixture("Runtime topology cleanup could not reach the service.")
		var/turf/current = locate(original_position[1], original_position[2], original_position[3])
		var/turf/restored = current.ChangeTurf(original_type)
		if(!isopenturf(restored))
			return dogmos_abort_fixture("Runtime topology cleanup could not restore the test floor.")
		run_loc_floor_bottom_left = restored
		if(!SSdogmos.flush_turf_registration_batch())
			return dogmos_abort_fixture("Restored test floor topology did not reach the service.")
	catch(var/exception/cleanup_error)
		return dogmos_abort_fixture("Runtime topology cleanup raised [cleanup_error.name].")
	// The normal low-priority test runner restores this room's numeric atmosphere next.
	SSair.can_fire = original_can_fire
	if(failure_message)
		return Fail(failure_message, __FILE__, __LINE__)

/** Exceptions must release only the batching scope owned by the failing helper. */
/datum/unit_test/dogmos_topology_batch_exception_ownership/Run()
	if(!dogmos_wait_for_stage_boundary())
		return
	var/original_can_fire = SSair.can_fire
	var/original_batching = SSdogmos.runtime_topology_batching
	if(original_batching || SSdogmos.turf_registration_batching)
		return Fail("Exception fixture encountered another batch owner.", __FILE__, __LINE__)
	var/original_type = run_loc_floor_bottom_left.type
	var/list/position = list(run_loc_floor_bottom_left.x, run_loc_floor_bottom_left.y, run_loc_floor_bottom_left.z)
	var/turf/open/indestructible/plating/airless/dogmos_topology_probe/target
	var/failure_message
	SSair.can_fire = FALSE
	try
		target = run_loc_floor_bottom_left.ChangeTurf(/turf/open/indestructible/plating/airless/dogmos_topology_probe)
		target.immediate_calculate_adjacent_turfs()
		if(!SSdogmos.flush_turf_registration_batch())
			CRASH("Exception fixture setup could not reach the service.")
		for(var/outer_owner in list(FALSE, TRUE))
			for(var/helper in list("template", "retry", "frontier"))
				SSdogmos.runtime_topology_batching = outer_owner
				target.dogmos_probe_throw = TRUE
				var/caught_expected = FALSE
				try
					if(helper == "template")
						SSdogmos.update_template_border(list(target))
					else if(helper == "retry")
						SSdogmos.dogmos_pending_adjacency_retry[target] = TRUE
						SSdogmos.retry_pending_turf_adjacencies()
					else
						SSair.dogmos_prepare_frontier_pairs(list(target))
				catch(var/helper_error)
					caught_expected = helper_error == "dogmos batch exception sentinel"
				target.dogmos_probe_throw = FALSE
				if(!caught_expected)
					failure_message = "The [helper] helper did not propagate the injected exception unchanged."
				else if(SSdogmos.runtime_topology_batching != outer_owner)
					failure_message = "The [helper] helper leaked batching ownership after an exception (outer owner [outer_owner])."
				SSdogmos.runtime_topology_batching = original_batching
				// Reconcile the faulted turf from current DM state before the next case.
				target.immediate_calculate_adjacent_turfs()
				if(!SSdogmos.flush_turf_registration_batch())
					CRASH("Exception fixture could not reconcile topology.")
	catch(var/exception/error)
		failure_message = "Exception ownership fixture raised [error]."
	if(istype(target))
		target.dogmos_probe_throw = FALSE
	SSdogmos.runtime_topology_batching = original_batching
	try
		var/turf/current = locate(position[1], position[2], position[3])
		var/turf/restored = current.ChangeTurf(original_type)
		if(!isopenturf(restored))
			return dogmos_abort_fixture("Exception cleanup could not restore the test floor.")
		run_loc_floor_bottom_left = restored
		restored.immediate_calculate_adjacent_turfs()
		if(!SSdogmos.flush_turf_registration_batch())
			return dogmos_abort_fixture("Exception cleanup could not publish restored topology.")
	catch(var/exception/cleanup_error)
		return dogmos_abort_fixture("Exception cleanup raised [cleanup_error].")
	SSair.can_fire = original_can_fire
	if(failure_message)
		return Fail(failure_message, __FILE__, __LINE__)

#undef DOGMOS_WORLD_GENERATION_WORD_MAX
#undef DOGMOS_TEST_STAGE_EXCITED_GROUPS
#undef DOGMOS_TEST_STAGE_EQUALIZE
#undef DOGMOS_TEST_STAGE_TURF_HEAT
#undef DOGMOS_TEST_STAGE_REACTIONS
#undef DOGMOS_TEST_OVERSIZED_PIPELINE_MIXTURES
#undef DOGMOS_TEST_STAGE_BOUNDARY_ATTEMPTS
#undef DOGMOS_TEST_STAGE_RESPONSE_FIELDS
#undef DOGMOS_TEST_STAGE_TURFS
#undef DOGMOS_PIPELINE_TEST_EPSILON
#undef DOGMOS_TEST_IDLE_MC_SETTLE_TIME
#undef DOGMOS_TEST_RESPONSE_APPLIED
#undef DOGMOS_TEST_SNAPSHOT_REVISION_LOW
#undef DOGMOS_TEST_SNAPSHOT_REVISION_HIGH


#endif
