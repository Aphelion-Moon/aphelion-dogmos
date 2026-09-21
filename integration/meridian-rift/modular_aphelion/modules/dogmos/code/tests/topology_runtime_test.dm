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

/**
 * Owns live topology fixture queues after a drained boundary. Original lists are
 * protected from in-place cuts. Successful bodies keep their publication order;
 * an unexpected exception cannot prove which native mutations were accepted, so
 * it uses the maintained fatal-fixture path instead of reviving old queue state.
 */
/datum/unit_test/dogmos_topology_fixture
	abstract_type = /datum/unit_test/dogmos_topology_fixture
	parent_type = /datum/unit_test/dogmos_admission_fixture

/datum/unit_test/dogmos_topology_fixture/Run()
	if(!dogmos_wait_for_stage_boundary())
		return
	var/list/queue_fields = list("dogmos_pending_mixture_unregistrations", "dogmos_pending_turf_lifecycle", "dogmos_pending_turf_heat", "dogmos_pending_turf_adjacency", "dogmos_pending_turf_adjacency_index", "dogmos_pending_turf_heat_adjacency", "dogmos_pending_turf_heat_adjacency_index", "dogmos_pending_adjacency_retry")
	save_admission_fixture(queue_fields + list("turf_registration_batching", "runtime_topology_batching", "dogmos_runtime_topology_max_queued"), list("dogmos_pending_frontier_epoch", "can_fire"))
	try
		for(var/field in queue_fields)
			SSdogmos.vars[field] = deep_copy_list(SSdogmos.vars[field])
		run_topology_fixture()
		restore_topology_fixture()
	catch(var/error)
		abandon_topology_fixture("Topology fixture [type] raised [error]; accepted native publication cannot be safely rolled back.")

/** The original test body, invoked inside the fixture's exceptional-exit boundary. */
/datum/unit_test/dogmos_topology_fixture/proc/run_topology_fixture()
	return

/** Restore fixture-owned turf properties before the framework restores gas. */
/datum/unit_test/dogmos_topology_fixture/proc/restore_topology_turfs()
	return

/** Complete healthy reconstruction before returning the exact original list owners. */
/datum/unit_test/dogmos_topology_fixture/proc/restore_topology_fixture()
	if(!admission_service_state)
		return
	if(!SSdogmos.service_ready || SSdogmos.service_failure_latched || admission_service_owner != SSdogmos || admission_air_owner != SSair)
		return abandon_topology_fixture("Topology fixture [type] lost its healthy original service owner.")
	restore_topology_turfs()
	if(!SSdogmos.flush_turf_registration_batch())
		return abandon_topology_fixture("Topology fixture [type] could not drain its reconstructed topology.")
	restore_admission_fixture()

/** Leave uncertain publication failed closed; no old queue or admission state is resurrected. */
/datum/unit_test/dogmos_topology_fixture/proc/abandon_topology_fixture(reason)
	admission_service_state = null
	admission_air_state = null
	admission_service_owner = null
	admission_air_owner = null
	return dogmos_abort_fixture(reason)

/datum/unit_test/dogmos_topology_fixture/restore_atmos()
	restore_topology_fixture()
	return ..()

/datum/unit_test/dogmos_topology_fixture/Destroy()
	restore_topology_fixture()
	return ..()

/** Verifies startup coalesces repeated turf visits until all endpoints are initialized. */
/datum/unit_test/dogmos_service_startup_adjacency_coalesces
	parent_type = /datum/unit_test/dogmos_topology_fixture

/datum/unit_test/dogmos_service_startup_adjacency_coalesces/run_topology_fixture()
	if(!dogmos_wait_for_stage_boundary())
		return
	var/turf/target = run_loc_floor_bottom_left
	SSdogmos.begin_turf_registration_batch()
	for(var/repetition in 1 to 3)
		target.sync_dogmos_adjacency()
	var/failure_message
	if(length(SSdogmos.dogmos_pending_turf_adjacency) || length(SSdogmos.dogmos_pending_turf_heat_adjacency))
		failure_message = "Startup constructed intermediate edges before the final adjacency drain."
	else if(length(SSdogmos.dogmos_pending_adjacency_retry) != 1 || !SSdogmos.dogmos_pending_adjacency_retry[target])
		failure_message = "Repeated startup adjacency visits did not coalesce to one turf."
	SSdogmos.finish_turf_registration_batch()
	if(length(SSdogmos.dogmos_pending_adjacency_retry) || length(SSdogmos.dogmos_pending_turf_adjacency) \
		|| length(SSdogmos.dogmos_pending_turf_heat_adjacency))
		failure_message = "Startup adjacency work remained queued after the final drain."
	if(failure_message)
		return Fail(failure_message, __FILE__, __LINE__)

/** Verifies repeated deferred adjacency updates coalesce and drain completely. */
/datum/unit_test/dogmos_service_topology_pressure
	parent_type = /datum/unit_test/dogmos_topology_fixture

/datum/unit_test/dogmos_service_topology_pressure/run_topology_fixture()
	var/reached_stage_boundary = FALSE
	for(var/attempt in 1 to DOGMOS_TEST_STAGE_BOUNDARY_ATTEMPTS)
		if(isnull(SSair.dogmos_pending_stage) && !SSair.dogmos_pending_frontier_epoch && SSdogmos.flush_turf_registration_batch())
			reached_stage_boundary = TRUE
			break
		sleep(SSair.wait)
	if(!reached_stage_boundary)
		return Fail("Dogmos did not reach a safe stage boundary before the topology pressure test.", __FILE__, __LINE__)

	var/list/original_pending_frontier = SSair.dogmos_pending_frontier_epoch
	var/original_runtime_batching = SSdogmos.runtime_topology_batching
	var/list/original_gas_edges = SSdogmos.dogmos_pending_turf_adjacency
	var/list/original_gas_index = SSdogmos.dogmos_pending_turf_adjacency_index
	var/list/original_heat_edges = SSdogmos.dogmos_pending_turf_heat_adjacency
	var/list/original_heat_index = SSdogmos.dogmos_pending_turf_heat_adjacency_index
	var/list/original_adjacency_retry = SSdogmos.dogmos_pending_adjacency_retry
	var/original_max_queued = SSdogmos.dogmos_runtime_topology_max_queued
	var/turf/target = run_loc_floor_bottom_left

	SSdogmos.runtime_topology_batching = TRUE
	SSdogmos.dogmos_pending_turf_adjacency = list()
	SSdogmos.dogmos_pending_turf_adjacency_index = list()
	SSdogmos.dogmos_pending_turf_heat_adjacency = list()
	SSdogmos.dogmos_pending_turf_heat_adjacency_index = list()
	SSdogmos.dogmos_pending_adjacency_retry = list()
	SSdogmos.dogmos_runtime_topology_max_queued = 0
	SSair.dogmos_pending_frontier_epoch = list(1, 0, 0, 0)
	target.__update_auxtools_turf_adjacency_info(world.maxx, world.maxy)
	var/first_gas_count = length(SSdogmos.dogmos_pending_turf_adjacency)
	var/first_heat_count = length(SSdogmos.dogmos_pending_turf_heat_adjacency)
	for(var/repetition in 1 to 20)
		target.__update_auxtools_turf_adjacency_info(world.maxx, world.maxy)

	var/failure_message
	if(length(SSdogmos.dogmos_pending_turf_adjacency) != first_gas_count)
		failure_message = "Deferred gas adjacency work grew with repeated updates instead of coalescing."
	else if(length(SSdogmos.dogmos_pending_turf_heat_adjacency) != first_heat_count)
		failure_message = "Deferred heat adjacency work grew with repeated updates instead of coalescing."
	else if(length(SSdogmos.dogmos_pending_adjacency_retry) != 1)
		failure_message = "Deferred adjacency work did not coalesce to one unique turf retry."
	else if(SSdogmos.dogmos_runtime_topology_max_queued != first_gas_count + first_heat_count)
		failure_message = "Dogmos topology pressure telemetry did not retain the unique queued edge count."

	SSair.dogmos_pending_frontier_epoch = null
	if(!SSdogmos.flush_turf_registration_batch() && !failure_message)
		failure_message = "Dogmos did not flush deferred topology after the committed frontier cleared."
	if((length(SSdogmos.dogmos_pending_turf_adjacency) || length(SSdogmos.dogmos_pending_turf_heat_adjacency) \
			|| length(SSdogmos.dogmos_pending_turf_adjacency_index) || length(SSdogmos.dogmos_pending_turf_heat_adjacency_index)) && !failure_message)
		failure_message = "Dogmos retained topology queue or reverse-index entries after a successful flush."

	SSair.dogmos_pending_frontier_epoch = original_pending_frontier
	SSdogmos.runtime_topology_batching = original_runtime_batching
	SSdogmos.dogmos_pending_turf_adjacency = original_gas_edges
	SSdogmos.dogmos_pending_turf_adjacency_index = original_gas_index
	SSdogmos.dogmos_pending_turf_heat_adjacency = original_heat_edges
	SSdogmos.dogmos_pending_turf_heat_adjacency_index = original_heat_index
	SSdogmos.dogmos_pending_adjacency_retry = original_adjacency_retry
	SSdogmos.dogmos_runtime_topology_max_queued = original_max_queued
	if(failure_message)
		return Fail(failure_message, __FILE__, __LINE__)

/** Verifies a deferred adjacency retry refreshes its own late-created gas registration. */
/datum/unit_test/dogmos_service_adjacency_retry_late_air
	parent_type = /datum/unit_test/dogmos_topology_fixture

/datum/unit_test/dogmos_service_adjacency_retry_late_air/run_topology_fixture()
	if(!dogmos_wait_for_stage_boundary())
		return
	var/list/pair = allocate_turf_pair()
	var/turf/open/target = pair[1]
	var/datum/gas_mixture/original_air = target.air
	var/original_runtime_batching = SSdogmos.runtime_topology_batching
	// Map construction can register a heat node before creating its gas datum.
	target.air = null
	target.register_dogmos_air()
	target.air = original_air
	SSdogmos.runtime_topology_batching = TRUE
	SSdogmos.dogmos_pending_adjacency_retry[target] = TRUE
	SSdogmos.retry_pending_turf_adjacencies()
	var/source_current = target.dogmos_air_registration_is_current()
	// Repair the fixture before flushing even on RED: stale edges must not reach the service.
	if(!source_current)
		target.register_dogmos_air()
		target.__update_auxtools_turf_adjacency_info(world.maxx, world.maxy)
	SSdogmos.runtime_topology_batching = original_runtime_batching
	SSdogmos.flush_turf_registration_batch()
	if(!source_current)
		return Fail("Deferred adjacency rebuilt gas edges while its source still had a heat-only registration.", __FILE__, __LINE__)

/** Verifies the real template finalizer coalesces border edges without resetting live air or heat. */
/datum/unit_test/dogmos_template_border_batch
	parent_type = /datum/unit_test/dogmos_topology_fixture

/datum/unit_test/dogmos_template_border_batch/run_topology_fixture()
	var/reached_stage_boundary = FALSE
	for(var/attempt in 1 to DOGMOS_TEST_STAGE_BOUNDARY_ATTEMPTS)
		if(isnull(SSair.dogmos_pending_stage) && !SSair.dogmos_pending_frontier_epoch && SSdogmos.flush_turf_registration_batch())
			reached_stage_boundary = TRUE
			break
		sleep(SSair.wait)
	if(!reached_stage_boundary)
		return Fail("Template border fixture did not reach a safe stage boundary.", __FILE__, __LINE__)
	var/list/pair = allocate_turf_pair()
	var/turf/open/hot_turf = pair[1]
	var/turf/open/cold_turf = pair[2]
	var/original_hot_temperature = hot_turf.dogmos_heat_temperature()
	var/original_cold_temperature = cold_turf.dogmos_heat_temperature()
	hot_turf.air.set_moles(GAS_O2, 13)
	cold_turf.air.set_moles(GAS_O2, 29)
	hot_turf.set_temperature(420)
	cold_turf.set_temperature(333)
	var/hot_slot = hot_turf.dogmos_registered_mixture_slot
	var/cold_slot = cold_turf.dogmos_registered_mixture_slot
	var/datum/map_template/template = allocate(/datum/map_template)
	var/list/bounds = list(
		hot_turf.x + 1, hot_turf.y + 1, hot_turf.z,
		hot_turf.x + 3, hot_turf.y + 3, hot_turf.z,
	)
	var/original_can_fire = SSair.can_fire
	SSair.can_fire = FALSE
	var/calls_before = SSdogmos.dogmos_runtime_topology_calls
	template.initTemplateBounds(bounds)
	var/calls = SSdogmos.dogmos_runtime_topology_calls - calls_before
	file("[GLOB.log_directory]/dogmos-template-border.json") << json_encode(list("interior_bounds" = bounds, "topology_calls" = calls))
	var/failure_message
	if(hot_turf.dogmos_registered_mixture_slot != hot_slot || cold_turf.dogmos_registered_mixture_slot != cold_slot)
		failure_message = "Template finalization replaced an existing mixture identity."
	else if(hot_turf.air.get_moles(GAS_O2) != 13 || cold_turf.air.get_moles(GAS_O2) != 29)
		failure_message = "Template finalization changed existing gas quantities."
	else if(hot_turf.dogmos_heat_temperature() != 420 || cold_turf.dogmos_heat_temperature() != 333)
		failure_message = "Template finalization reset existing solid temperatures."
	else if(!(cold_turf in hot_turf.atmos_adjacent_turfs) || !(hot_turf in cold_turf.atmos_adjacent_turfs))
		failure_message = "Template finalization lost reciprocal border adjacency."
	else if(SSdogmos.runtime_topology_batching || length(SSdogmos.dogmos_pending_turf_adjacency) || length(SSdogmos.dogmos_pending_turf_heat_adjacency))
		failure_message = "Template finalization leaked its batch ownership or unpublished edges."
	else if(calls > 4)
		failure_message = "A 25-turf template border used [calls] topology calls; its unique edges fit in at most four bounded batches."
	hot_turf.set_temperature(original_hot_temperature)
	cold_turf.set_temperature(original_cold_temperature)
	SSair.can_fire = original_can_fire
	if(failure_message)
		return Fail(failure_message, __FILE__, __LINE__)

/** Verifies template border updates respect an outer batch and a frozen simulation frontier. */
/datum/unit_test/dogmos_template_border_batch_ownership
	parent_type = /datum/unit_test/dogmos_topology_fixture

/datum/unit_test/dogmos_template_border_batch_ownership/run_topology_fixture()
	if(!dogmos_wait_for_stage_boundary())
		return
	var/list/pair = allocate_turf_pair()
	var/original_runtime_batching = SSdogmos.runtime_topology_batching
	var/list/original_frontier = SSair.dogmos_pending_frontier_epoch
	var/calls_before = SSdogmos.dogmos_runtime_topology_calls
	SSdogmos.runtime_topology_batching = TRUE
	SSdogmos.update_template_border(pair)
	var/failure_message
	var/retained_targets = (pair[1] in SSdogmos.dogmos_pending_adjacency_retry) && (pair[2] in SSdogmos.dogmos_pending_adjacency_retry)
	var/retained_edges = length(SSdogmos.dogmos_pending_turf_adjacency) && length(SSdogmos.dogmos_pending_turf_heat_adjacency)
	if(!SSdogmos.runtime_topology_batching || SSdogmos.dogmos_runtime_topology_calls != calls_before)
		failure_message = "Template border update drained or released its outer partial batch."
	else if(!retained_targets && !retained_edges)
		failure_message = "Template border update lost its outer owner's pending topology."
	SSdogmos.runtime_topology_batching = original_runtime_batching
	SSdogmos.flush_turf_registration_batch()
	if(!failure_message && (SSdogmos.dogmos_runtime_topology_calls - calls_before < 2 \
		|| length(SSdogmos.dogmos_pending_adjacency_retry) || length(SSdogmos.dogmos_pending_turf_adjacency) || length(SSdogmos.dogmos_pending_turf_heat_adjacency)))
		failure_message = "Closing the outer batch did not publish and drain gas and heat topology."

	calls_before = SSdogmos.dogmos_runtime_topology_calls
	SSair.dogmos_pending_frontier_epoch = SSair.dogmos_frontier_epoch.Copy()
	SSdogmos.update_template_border(pair)
	if(!failure_message && (SSdogmos.runtime_topology_batching != original_runtime_batching || SSdogmos.dogmos_runtime_topology_calls != calls_before))
		failure_message = "Template border update bypassed a frozen simulation frontier."
	if(!failure_message && !length(SSdogmos.dogmos_pending_adjacency_retry))
		failure_message = "Template border update discarded topology deferred behind the frontier."
	SSair.dogmos_pending_frontier_epoch = original_frontier
	SSdogmos.flush_turf_registration_batch()
	if(!failure_message && (length(SSdogmos.dogmos_pending_adjacency_retry) || length(SSdogmos.dogmos_pending_turf_adjacency) || length(SSdogmos.dogmos_pending_turf_heat_adjacency)))
		failure_message = "Template border topology did not drain after the frontier was released."
	if(failure_message)
		return Fail(failure_message, __FILE__, __LINE__)

/** Verifies runtime topology coalescing does not re-register current neighbor state. */
/datum/unit_test/dogmos_service_runtime_topology_batch_preserves_neighbor_state
	parent_type = /datum/unit_test/dogmos_topology_fixture

/datum/unit_test/dogmos_service_runtime_topology_batch_preserves_neighbor_state/run_topology_fixture()
	var/list/original_pending_frontier = SSair.dogmos_pending_frontier_epoch
	var/original_runtime_batching = SSdogmos.runtime_topology_batching
	var/list/original_lifecycle = SSdogmos.dogmos_pending_turf_lifecycle
	var/list/original_heat = SSdogmos.dogmos_pending_turf_heat
	var/list/original_gas_edges = SSdogmos.dogmos_pending_turf_adjacency
	var/list/original_gas_index = SSdogmos.dogmos_pending_turf_adjacency_index
	var/list/original_heat_edges = SSdogmos.dogmos_pending_turf_heat_adjacency
	var/list/original_heat_index = SSdogmos.dogmos_pending_turf_heat_adjacency_index
	var/list/original_adjacency_retry = SSdogmos.dogmos_pending_adjacency_retry

	SSair.dogmos_pending_frontier_epoch = null
	SSdogmos.runtime_topology_batching = TRUE
	SSdogmos.dogmos_pending_turf_lifecycle = list()
	SSdogmos.dogmos_pending_turf_heat = list()
	SSdogmos.dogmos_pending_turf_adjacency = list()
	SSdogmos.dogmos_pending_turf_adjacency_index = list()
	SSdogmos.dogmos_pending_turf_heat_adjacency = list()
	SSdogmos.dogmos_pending_turf_heat_adjacency_index = list()
	SSdogmos.dogmos_pending_adjacency_retry = list()
	run_loc_floor_bottom_left.__update_auxtools_turf_adjacency_info(world.maxx, world.maxy)
	// Inspect actual edge construction even when notifications are deferred by the owner.
	SSdogmos.retry_pending_turf_adjacencies()
	var/requeued_neighbor_state = length(SSdogmos.dogmos_pending_turf_lifecycle) || length(SSdogmos.dogmos_pending_turf_heat)

	SSair.dogmos_pending_frontier_epoch = original_pending_frontier
	SSdogmos.runtime_topology_batching = original_runtime_batching
	SSdogmos.dogmos_pending_turf_lifecycle = original_lifecycle
	SSdogmos.dogmos_pending_turf_heat = original_heat
	SSdogmos.dogmos_pending_turf_adjacency = original_gas_edges
	SSdogmos.dogmos_pending_turf_adjacency_index = original_gas_index
	SSdogmos.dogmos_pending_turf_heat_adjacency = original_heat_edges
	SSdogmos.dogmos_pending_turf_heat_adjacency_index = original_heat_index
	SSdogmos.dogmos_pending_adjacency_retry = original_adjacency_retry
	if(requeued_neighbor_state)
		return Fail("Runtime topology batching re-registered current neighbor lifecycle or heat state.", __FILE__, __LINE__)

/** Verifies turf replacement discards queued topology from an older generation. */
/datum/unit_test/dogmos_service_stale_topology_discard
	parent_type = /datum/unit_test/dogmos_topology_fixture

/datum/unit_test/dogmos_service_stale_topology_discard/run_topology_fixture()
	var/list/original_gas_edges = SSdogmos.dogmos_pending_turf_adjacency
	var/list/original_gas_index = SSdogmos.dogmos_pending_turf_adjacency_index
	var/list/original_heat_edges = SSdogmos.dogmos_pending_turf_heat_adjacency
	var/list/original_heat_index = SSdogmos.dogmos_pending_turf_heat_adjacency_index
	var/turf/target = run_loc_floor_bottom_left
	var/target_slot = target.dogmos_service_slot()
	var/stale_generation = target.dogmos_service_generation() + 1
	var/neighbor_slot = target_slot + 1
	var/edge_key = "[target_slot]:[stale_generation]:[neighbor_slot]:1"

	SSdogmos.dogmos_pending_turf_adjacency = list()
	SSdogmos.dogmos_pending_turf_adjacency[edge_key] = list(target_slot, stale_generation, neighbor_slot, 1, TRUE, FALSE)
	SSdogmos.dogmos_pending_turf_adjacency_index = list()
	SSdogmos.index_pending_edge(SSdogmos.dogmos_pending_turf_adjacency_index, "[target_slot]", edge_key)
	SSdogmos.index_pending_edge(SSdogmos.dogmos_pending_turf_adjacency_index, "[neighbor_slot]", edge_key)
	SSdogmos.dogmos_pending_turf_heat_adjacency = list()
	SSdogmos.dogmos_pending_turf_heat_adjacency[edge_key] = list(target_slot, stale_generation, neighbor_slot, 1, TRUE)
	SSdogmos.dogmos_pending_turf_heat_adjacency_index = list()
	SSdogmos.index_pending_edge(SSdogmos.dogmos_pending_turf_heat_adjacency_index, "[target_slot]", edge_key)
	SSdogmos.index_pending_edge(SSdogmos.dogmos_pending_turf_heat_adjacency_index, "[neighbor_slot]", edge_key)

	SSdogmos.discard_pending_turf_adjacencies(target)
	var/failure_message
	if(length(SSdogmos.dogmos_pending_turf_adjacency) || length(SSdogmos.dogmos_pending_turf_adjacency_index))
		failure_message = "Dogmos retained stale gas topology after a turf generation changed."
	else if(length(SSdogmos.dogmos_pending_turf_heat_adjacency) || length(SSdogmos.dogmos_pending_turf_heat_adjacency_index))
		failure_message = "Dogmos retained stale heat topology after a turf generation changed."

	SSdogmos.dogmos_pending_turf_adjacency = original_gas_edges
	SSdogmos.dogmos_pending_turf_adjacency_index = original_gas_index
	SSdogmos.dogmos_pending_turf_heat_adjacency = original_heat_edges
	SSdogmos.dogmos_pending_turf_heat_adjacency_index = original_heat_index
	if(failure_message)
		return Fail(failure_message, __FILE__, __LINE__)

/** Machinery preparation must yield before any processing and preserve reverse order on resume. */
/datum/unit_test/dogmos_runtime_prefetch

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
