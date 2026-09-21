#if defined(UNIT_TESTS) || defined(SPACEMAN_DMM)

/** Recovery must not reopen admission for a failed or intentionally stopped session. */
/datum/unit_test/dogmos_recovery_closed_admission/Run()
	for(var/intentional_shutdown in list(FALSE, TRUE))
		var/datum/controller/subsystem/dogmos/recovery_test_copy/source = allocate(/datum/controller/subsystem/dogmos/recovery_test_copy)
		var/datum/controller/subsystem/dogmos/recovery_test_copy/recovered = allocate(/datum/controller/subsystem/dogmos/recovery_test_copy)
		source.initialized = TRUE
		source.gases_registered = TRUE
		source.service_failure_latched = !intentional_shutdown
		source.service_shutdown_requested = intentional_shutdown
		recovered.adopt_runtime_state(source)
		if(recovered.service_ready || recovered.service_failure_latched != !intentional_shutdown || recovered.service_shutdown_requested != intentional_shutdown)
			return Fail("Recovery reopened admission or lost the original failure/shutdown state.", __FILE__, __LINE__)

/** Recovery keeps partially consumed callback, topology and invalidated-cache state together. */
/datum/unit_test/dogmos_recovery_partial_state

/** Uses inert subsystem copies; synthetic handles never enter the real service. */
/datum/unit_test/dogmos_recovery_partial_state/Run()
	if(!dogmos_wait_for_stage_boundary())
		return
	var/service_pid = dogmos_service_pid()
	var/list/world_generation = dogmos_service_world_generation()
	var/datum/gas_mixture/sentinel = allocate(/datum/gas_mixture, CELL_VOLUME)
	sentinel.set_temperature(321.5)
	sentinel.set_moles(/datum/gas/oxygen, 7.25)
	var/failure
	try
		for(var/consumed in list(0, 1, 2))
			var/datum/controller/subsystem/dogmos/recovery_test_copy/source = allocate(/datum/controller/subsystem/dogmos/recovery_test_copy)
			var/datum/controller/subsystem/dogmos/recovery_test_copy/recovered = allocate(/datum/controller/subsystem/dogmos/recovery_test_copy)
			source.initialized = TRUE
			source.gases_registered = TRUE
			source.service_ready = TRUE
			source.dogmos_mixture_generations = list(17, 29)
			source.dogmos_free_mixture_slots = list(2)
			source.dogmos_pending_mixture_unregistrations = list(list(2, 1, 17))
			source.dogmos_holder_generations = list(31)
			source.dogmos_next_callback_sequence = list(65535, 42, 9, 1)
			source.dogmos_pending_callback_batch = new/list(120) // 12 header fields plus three 36-field events.
			source.dogmos_pending_callback_count = 3
			source.dogmos_pending_service_callbacks = 7
			source.runtime_topology_batching = 2
			source.dogmos_pending_turf_lifecycle = list("1" = list(1, 1, 17, 1, 17, 0))
			source.dogmos_pending_turf_adjacency = list(list(1, 17, 2, 29, 1, 0))
			source.dogmos_pending_turf_adjacency_index = list("1:2" = 1)
			source.dogmos_pending_turf_heat = list("1" = list(1, 17, 300, 10, 0.5, 0, 0))
			source.dogmos_pending_turf_heat_adjacency = list(list(1, 17, 2, 29, 1))
			source.dogmos_pending_turf_heat_adjacency_index = list("1:2" = 1)
			source.reset_mixture_snapshot_cache()
			source.store_mixture_snapshot_cache(1, 17, new/list(42))
			source.invalidate_mixture_snapshot_epoch()
			var/list/expected = list(
				"dogmos_pending_callback_batch" = source.dogmos_pending_callback_batch,
				"dogmos_next_callback_sequence" = source.dogmos_next_callback_sequence,
				"dogmos_mixture_generations" = source.dogmos_mixture_generations,
				"dogmos_free_mixture_slots" = source.dogmos_free_mixture_slots,
				"dogmos_pending_mixture_unregistrations" = source.dogmos_pending_mixture_unregistrations,
				"dogmos_holder_generations" = source.dogmos_holder_generations,
				"dogmos_pending_turf_lifecycle" = source.dogmos_pending_turf_lifecycle,
				"dogmos_pending_turf_adjacency" = source.dogmos_pending_turf_adjacency,
				"dogmos_pending_turf_adjacency_index" = source.dogmos_pending_turf_adjacency_index,
				"dogmos_pending_turf_heat" = source.dogmos_pending_turf_heat,
				"dogmos_pending_turf_heat_adjacency" = source.dogmos_pending_turf_heat_adjacency,
				"dogmos_pending_turf_heat_adjacency_index" = source.dogmos_pending_turf_heat_adjacency_index,
				"dogmos_mixture_cache" = source.dogmos_mixture_cache,
			)
			source.dogmos_pending_callback_index = consumed
			recovered.ss_flags &= ~SS_NO_INIT
			recovered.adopt_runtime_state(source)
			if(!source.dogmos_runtime_state_released || source.gases_registered || source.service_ready || !source.service_shutdown_requested || source.dogmos_mixture_slots || source.dogmos_pending_callback_batch || source.dogmos_pending_turf_adjacency_index || source.dogmos_mixture_cache)
				CRASH("The previous owner retained admission or transferred references.")
			source.release_runtime_state() // Repeated retirement cannot clear the new owner's lists.
			if(!recovered.initialized || !recovered.gases_registered || !recovered.service_ready || !(recovered.ss_flags & SS_NO_INIT))
				CRASH("Recovery lost initialized admission state or allowed cold initialization.")
			if(recovered.dogmos_pending_callback_batch != expected["dogmos_pending_callback_batch"] || recovered.dogmos_pending_callback_index != consumed || recovered.dogmos_pending_callback_count != 3 || recovered.dogmos_pending_service_callbacks != 7 || recovered.dogmos_next_callback_sequence != expected["dogmos_next_callback_sequence"])
				CRASH("Recovery after [consumed] callbacks changed the batch, cursor or exact sequence.")
			if(recovered.dogmos_mixture_generations != expected["dogmos_mixture_generations"] || recovered.dogmos_free_mixture_slots != expected["dogmos_free_mixture_slots"] || recovered.dogmos_pending_mixture_unregistrations != expected["dogmos_pending_mixture_unregistrations"] || recovered.dogmos_holder_generations != expected["dogmos_holder_generations"])
				CRASH("Recovery lost a generation or reused a pending retirement.")
			if(recovered.runtime_topology_batching != 2 || recovered.dogmos_pending_turf_lifecycle != expected["dogmos_pending_turf_lifecycle"] || recovered.dogmos_pending_turf_adjacency != expected["dogmos_pending_turf_adjacency"] || recovered.dogmos_pending_turf_adjacency_index != expected["dogmos_pending_turf_adjacency_index"] || recovered.dogmos_pending_turf_heat != expected["dogmos_pending_turf_heat"] || recovered.dogmos_pending_turf_heat_adjacency != expected["dogmos_pending_turf_heat_adjacency"] || recovered.dogmos_pending_turf_heat_adjacency_index != expected["dogmos_pending_turf_heat_adjacency_index"])
				CRASH("Recovery lost nested batching or separated queued topology from its index.")
			if(recovered.dogmos_mixture_cache != expected["dogmos_mixture_cache"] || recovered.dogmos_mixture_cache_epoch != 2 || recovered.lookup_mixture_snapshot_cache(1, 17))
				CRASH("Recovery revived a snapshot invalidated before recovery.")
			recovered.Shutdown() // An inert destination cannot stop the global owner's service.
	catch(var/exception/error)
		failure = "Partial-state recovery fixture raised [error.name]."
	if(failure)
		return Fail(failure, __FILE__, __LINE__)
	var/list/current_generation = dogmos_service_world_generation()
	if(dogmos_service_pid() != service_pid || current_generation[1] != world_generation[1] || current_generation[2] != world_generation[2])
		return Fail("Recovery replaced the service PID or world generation.", __FILE__, __LINE__)
	if(sentinel.return_temperature() != 321.5 || sentinel.get_moles(/datum/gas/oxygen) != 7.25)
		return Fail("Recovery changed authoritative sentinel gas state.", __FILE__, __LINE__)


#endif
