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

/** Verifies non-conducting turfs remain absent from the service heat graph. */
/datum/unit_test/dogmos_service_turf_heat_absence
	parent_type = /datum/unit_test/dogmos_topology_fixture
	/// Turf restored after the assertion run.
	var/turf/target
	/// Original thermal conductivity restored during teardown.
	var/original_thermal_conductivity
	/// Original heat capacity restored during teardown.
	var/original_heat_capacity

/datum/unit_test/dogmos_service_turf_heat_absence/run_topology_fixture()
	if(!SSdogmos.service_ready)
		return Fail("dogmosd did not pass startup identity and health checks.", __FILE__, __LINE__)
	var/reached_stage_boundary = FALSE
	for(var/attempt in 1 to 20)
		if(!SSair.dogmos_pending_frontier_epoch && SSdogmos.flush_turf_registration_batch())
			reached_stage_boundary = TRUE
			break
		sleep(SSair.wait)
	if(!reached_stage_boundary)
		return Fail("Dogmos did not reach a safe stage boundary before the turf heat absence test.", __FILE__, __LINE__)
	target = run_loc_floor_bottom_left
	original_thermal_conductivity = target.thermal_conductivity
	original_heat_capacity = target.heat_capacity
	target.thermal_conductivity = 0
	target.heat_capacity = 0
	target.register_dogmos_air()
	target.sync_dogmos_adjacency()

	var/list/heat_snapshot = dogmos_turf_heat_snapshot(list(target.dogmos_service_slot(), target.dogmos_service_generation()))
	if(length(heat_snapshot) != 5)
		return Fail("Dogmos returned a malformed turf heat snapshot with [length(heat_snapshot)] fields.", __FILE__, __LINE__)
	if(heat_snapshot[1] != FALSE)
		return Fail("Dogmos retained a heat-graph node for a turf with zero conductivity and heat capacity.", __FILE__, __LINE__)

/datum/unit_test/dogmos_service_turf_heat_absence/restore_topology_turfs()
	if(target)
		target.thermal_conductivity = original_thermal_conductivity
		target.heat_capacity = original_heat_capacity
		target.register_dogmos_air()
	target = null
	return

/** Verifies startup turf mutations remain deferred until the bounded batch flush. */
/datum/unit_test/dogmos_service_turf_batching
	parent_type = /datum/unit_test/dogmos_topology_fixture
	/// Turf restored after the assertion run.
	var/turf/target
	/// Adjacent turf restored after the assertion run.
	var/turf/neighbor
	/// Original thermal conductivity restored during teardown.
	var/original_thermal_conductivity
	/// Original heat capacity restored during teardown.
	var/original_heat_capacity
	/// Original adjacent-turf atmosphere initialization state restored during teardown.
	var/original_neighbor_init_air

/datum/unit_test/dogmos_service_turf_batching/run_topology_fixture()
	if(!SSdogmos.service_ready)
		return Fail("dogmosd did not pass startup identity and health checks.", __FILE__, __LINE__)
	var/reached_stage_boundary = FALSE
	for(var/attempt in 1 to 20)
		if(!SSair.dogmos_pending_frontier_epoch && SSdogmos.flush_turf_registration_batch())
			reached_stage_boundary = TRUE
			break
		sleep(SSair.wait)
	if(!reached_stage_boundary)
		return Fail("Dogmos did not reach a safe stage boundary before the turf batching test.", __FILE__, __LINE__)
	target = run_loc_floor_bottom_left
	original_thermal_conductivity = target.thermal_conductivity
	original_heat_capacity = target.heat_capacity
	target.thermal_conductivity = 0
	target.heat_capacity = 0
	target.register_dogmos_air()

	SSdogmos.begin_turf_registration_batch()
	target.thermal_conductivity = original_thermal_conductivity
	target.heat_capacity = original_heat_capacity
	target.register_dogmos_air()
	var/list/deferred_snapshot = dogmos_turf_heat_snapshot(list(target.dogmos_service_slot(), target.dogmos_service_generation()))
	if(deferred_snapshot[1] != FALSE)
		return Fail("Dogmos applied a startup turf mutation before its explicit batch flush.", __FILE__, __LINE__)
	SSdogmos.finish_turf_registration_batch()
	var/list/flushed_snapshot = dogmos_turf_heat_snapshot(list(target.dogmos_service_slot(), target.dogmos_service_generation()))
	if(flushed_snapshot[1] != TRUE)
		return Fail("Dogmos did not apply a startup turf mutation during its explicit batch flush.", __FILE__, __LINE__)

	var/turf/candidate_neighbor = get_step(target, EAST)
	if(!isopenturf(candidate_neighbor) || !candidate_neighbor.init_air)
		return Fail("The Dogmos batching test requires an atmosphere-enabled open turf to the east.", __FILE__, __LINE__)
	neighbor = candidate_neighbor
	original_neighbor_init_air = neighbor.init_air
	neighbor.init_air = FALSE
	neighbor.register_dogmos_air(remove_uninitialized = TRUE)
	neighbor.init_air = original_neighbor_init_air
	target.sync_dogmos_adjacency()
	var/list/neighbor_snapshot = dogmos_turf_heat_snapshot(list(neighbor.dogmos_service_slot(), neighbor.dogmos_service_generation()))
	if(neighbor_snapshot[1] != TRUE)
		return Fail("Dogmos adjacency synchronization did not re-register an atmosphere-enabled endpoint.", __FILE__, __LINE__)

/datum/unit_test/dogmos_service_turf_batching/restore_topology_turfs()
	if(SSdogmos.turf_registration_batching)
		SSdogmos.finish_turf_registration_batch()
	if(target)
		target.thermal_conductivity = original_thermal_conductivity
		target.heat_capacity = original_heat_capacity
		target.register_dogmos_air()
	if(neighbor)
		neighbor.init_air = original_neighbor_init_air
		neighbor.register_dogmos_air()
	target = null
	neighbor = null
	return

/** Verifies startup adjacency rebuilds do not re-register current turfs. */
/datum/unit_test/dogmos_service_startup_registration_deduplication
	parent_type = /datum/unit_test/dogmos_topology_fixture

/datum/unit_test/dogmos_service_startup_registration_deduplication/run_topology_fixture()
	var/turf/target = run_loc_floor_bottom_left
	var/turf/neighbor = get_step(target, EAST)
	if(!target.init_air || isnull(target.dogmos_registration_generation) || !neighbor?.init_air || isnull(neighbor.dogmos_registration_generation))
		return Fail("The Dogmos startup registration test requires two registered atmosphere turfs.", __FILE__, __LINE__)

	var/original_batching = SSdogmos.turf_registration_batching
	var/list/original_lifecycle = SSdogmos.dogmos_pending_turf_lifecycle
	var/list/original_adjacency = SSdogmos.dogmos_pending_turf_adjacency
	var/list/original_adjacency_index = SSdogmos.dogmos_pending_turf_adjacency_index
	var/list/original_heat = SSdogmos.dogmos_pending_turf_heat
	var/list/original_heat_adjacency = SSdogmos.dogmos_pending_turf_heat_adjacency
	var/list/original_heat_adjacency_index = SSdogmos.dogmos_pending_turf_heat_adjacency_index
	var/list/original_retry = SSdogmos.dogmos_pending_adjacency_retry
	SSdogmos.turf_registration_batching = TRUE
	SSdogmos.dogmos_pending_turf_lifecycle = list()
	SSdogmos.dogmos_pending_turf_adjacency = list()
	SSdogmos.dogmos_pending_turf_adjacency_index = list()
	SSdogmos.dogmos_pending_turf_heat = list()
	SSdogmos.dogmos_pending_turf_heat_adjacency = list()
	SSdogmos.dogmos_pending_turf_heat_adjacency_index = list()
	SSdogmos.dogmos_pending_adjacency_retry = list()
	var/target_key = "[target.dogmos_service_slot()]"
	var/neighbor_key = "[neighbor.dogmos_service_slot()]"
	SSdogmos.dogmos_pending_turf_lifecycle[target_key] = list("target sentinel")
	SSdogmos.dogmos_pending_turf_lifecycle[neighbor_key] = list("neighbor sentinel")

	target.sync_dogmos_adjacency()

	var/list/target_lifecycle = SSdogmos.dogmos_pending_turf_lifecycle[target_key]
	var/list/neighbor_lifecycle = SSdogmos.dogmos_pending_turf_lifecycle[neighbor_key]
	var/failure_message
	if(target_lifecycle?[1] != "target sentinel")
		failure_message = "Dogmos re-registered the current turf during startup adjacency synchronization."
	else if(neighbor_lifecycle?[1] != "neighbor sentinel")
		failure_message = "Dogmos re-registered a current neighbor during startup adjacency synchronization."
	var/original_registered_mixture_slot = target.dogmos_registered_mixture_slot
	var/original_registered_mixture_generation = target.dogmos_registered_mixture_generation
	if(!failure_message)
		target.dogmos_registered_mixture_slot = null
		target.dogmos_registered_mixture_generation = null
		SSdogmos.dogmos_pending_turf_lifecycle[target_key] = list("stale target sentinel")
		target.sync_dogmos_adjacency()
		target_lifecycle = SSdogmos.dogmos_pending_turf_lifecycle[target_key]
		if(target_lifecycle?[1] == "stale target sentinel")
			failure_message = "Dogmos did not refresh a startup turf whose gas mixture became available."
	target.dogmos_registered_mixture_slot = original_registered_mixture_slot
	target.dogmos_registered_mixture_generation = original_registered_mixture_generation

	SSdogmos.turf_registration_batching = original_batching
	SSdogmos.dogmos_pending_turf_lifecycle = original_lifecycle
	SSdogmos.dogmos_pending_turf_adjacency = original_adjacency
	SSdogmos.dogmos_pending_turf_adjacency_index = original_adjacency_index
	SSdogmos.dogmos_pending_turf_heat = original_heat
	SSdogmos.dogmos_pending_turf_heat_adjacency = original_heat_adjacency
	SSdogmos.dogmos_pending_turf_heat_adjacency_index = original_heat_adjacency_index
	SSdogmos.dogmos_pending_adjacency_retry = original_retry
	if(failure_message)
		return Fail(failure_message, __FILE__, __LINE__)


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
