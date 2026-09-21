#if defined(UNIT_TESTS) || defined(SPACEMAN_DMM)

/** Pending topology keeps the first directional record only for identical canonical payloads. */
/datum/unit_test/dogmos_service_pending_topology_payload_dedup

/datum/unit_test/dogmos_service_pending_topology_payload_dedup/Run()
	if(!hascall(SSdogmos, "queue_pending_gas_adjacency") || !hascall(SSdogmos, "queue_pending_heat_adjacency"))
		// The adjacent measurement fixture is intentionally source-compatible with the old backend.
		return
	var/list/original_gas_edges = SSdogmos.dogmos_pending_turf_adjacency
	var/list/original_gas_index = SSdogmos.dogmos_pending_turf_adjacency_index
	var/list/original_heat_edges = SSdogmos.dogmos_pending_turf_heat_adjacency
	var/list/original_heat_index = SSdogmos.dogmos_pending_turf_heat_adjacency_index
	var/gas_key = "10:5:20:7"
	var/heat_key = gas_key
	var/failure_message

	try
		SSdogmos.dogmos_pending_turf_adjacency = list()
		SSdogmos.dogmos_pending_turf_adjacency_index = list()
		SSdogmos.dogmos_pending_turf_heat_adjacency = list()
		SSdogmos.dogmos_pending_turf_heat_adjacency_index = list()

		if(!call(SSdogmos, "queue_pending_gas_adjacency")(10, 5, 20, 7, TRUE, FALSE, gas_key))
			failure_message = "The first pending gas edge was not queued."
		var/list/first_gas_edge = SSdogmos.dogmos_pending_turf_adjacency[gas_key]
		if(!failure_message && call(SSdogmos, "queue_pending_gas_adjacency")(20, 7, 10, 5, TRUE, FALSE))
			failure_message = "A reverse gas edge with matching payload replaced the pending record."
		var/original_gas_slot = first_gas_edge?[1]
		if(!failure_message && first_gas_edge)
			first_gas_edge[1] = -101
			if(SSdogmos.dogmos_pending_turf_adjacency[gas_key]?[1] != -101)
				failure_message = "A matching reverse gas edge did not retain its original pending record."
			first_gas_edge[1] = original_gas_slot
		var/list/reversed_gas_edge = SSdogmos.dogmos_pending_turf_adjacency[gas_key]
		if(!failure_message && (!islist(reversed_gas_edge) || length(reversed_gas_edge) != 6 || reversed_gas_edge[5] != TRUE || reversed_gas_edge[6] != FALSE \
			|| !((reversed_gas_edge[1] == 20 && reversed_gas_edge[2] == 7 && reversed_gas_edge[3] == 10 && reversed_gas_edge[4] == 5) \
				|| (reversed_gas_edge[1] == 10 && reversed_gas_edge[2] == 5 && reversed_gas_edge[3] == 20 && reversed_gas_edge[4] == 7))))
			failure_message = "The retained gas edge changed its canonical state."
		if(!failure_message && !call(SSdogmos, "queue_pending_gas_adjacency")(20, 7, 10, 5, TRUE, TRUE))
			failure_message = "A changed gas firelock payload was not replaced."
		if(!failure_message)
			first_gas_edge[1] = -101
			if(SSdogmos.dogmos_pending_turf_adjacency[gas_key]?[1] == -101)
				failure_message = "A changed gas payload updated the old pending record instead of replacing it."
			first_gas_edge[1] = original_gas_slot
		var/list/replaced_gas_edge = SSdogmos.dogmos_pending_turf_adjacency[gas_key]
		if(!failure_message && (!islist(replaced_gas_edge) || length(replaced_gas_edge) != 6 || replaced_gas_edge[5] != TRUE || replaced_gas_edge[6] != TRUE \
			|| !((replaced_gas_edge[1] == 10 && replaced_gas_edge[2] == 5 && replaced_gas_edge[3] == 20 && replaced_gas_edge[4] == 7) \
				|| (replaced_gas_edge[1] == 20 && replaced_gas_edge[2] == 7 && replaced_gas_edge[3] == 10 && replaced_gas_edge[4] == 5))))
			failure_message = "Gas replacement did not retain the changed connected/firelock payload."
		if(!failure_message && (length(SSdogmos.dogmos_pending_turf_adjacency) != 1 || length(SSdogmos.dogmos_pending_turf_adjacency_index["10"]) != 1 || length(SSdogmos.dogmos_pending_turf_adjacency_index["20"]) != 1))
			failure_message = "Gas replacement did not retain one canonical edge and reverse-index entry per endpoint."

		SSdogmos.dogmos_pending_turf_adjacency = list()
		SSdogmos.dogmos_pending_turf_adjacency_index = list()
		if(!failure_message && !call(SSdogmos, "queue_pending_gas_adjacency")(10, 5, 20, 7, TRUE, FALSE))
			failure_message = "The gas-only topology record was not queued."
		if(!failure_message && (length(SSdogmos.dogmos_pending_turf_adjacency) != 1 || length(SSdogmos.dogmos_pending_turf_heat_adjacency)))
			failure_message = "A gas-only update affected the heat queue."
		SSdogmos.dogmos_pending_turf_adjacency = list()
		SSdogmos.dogmos_pending_turf_adjacency_index = list()
		if(!failure_message && !call(SSdogmos, "queue_pending_heat_adjacency")(10, 5, 20, 7, TRUE, heat_key))
			failure_message = "The heat-only topology record was not queued."
		var/list/first_heat_edge = SSdogmos.dogmos_pending_turf_heat_adjacency[heat_key]
		if(!failure_message && call(SSdogmos, "queue_pending_heat_adjacency")(20, 7, 10, 5, TRUE))
			failure_message = "A reverse heat edge with matching payload replaced the pending record."
		var/original_heat_slot = first_heat_edge?[1]
		if(!failure_message && first_heat_edge)
			first_heat_edge[1] = -101
			if(SSdogmos.dogmos_pending_turf_heat_adjacency[heat_key]?[1] != -101)
				failure_message = "A matching reverse heat edge did not retain its original pending record."
			first_heat_edge[1] = original_heat_slot
		if(!failure_message && !call(SSdogmos, "queue_pending_heat_adjacency")(20, 7, 10, 5, FALSE))
			failure_message = "A changed heat connectivity payload was not replaced."
		if(!failure_message)
			first_heat_edge[1] = -101
			if(SSdogmos.dogmos_pending_turf_heat_adjacency[heat_key]?[1] == -101)
				failure_message = "A changed heat payload updated the old pending record instead of replacing it."
			first_heat_edge[1] = original_heat_slot
		var/list/replaced_heat_edge = SSdogmos.dogmos_pending_turf_heat_adjacency[heat_key]
		if(!failure_message && (!islist(replaced_heat_edge) || length(replaced_heat_edge) != 5 || replaced_heat_edge[5] != FALSE \
			|| !((replaced_heat_edge[1] == 10 && replaced_heat_edge[2] == 5 && replaced_heat_edge[3] == 20 && replaced_heat_edge[4] == 7) \
				|| (replaced_heat_edge[1] == 20 && replaced_heat_edge[2] == 7 && replaced_heat_edge[3] == 10 && replaced_heat_edge[4] == 5))))
			failure_message = "Heat replacement did not retain the changed connectivity payload."
		if(!failure_message && (length(SSdogmos.dogmos_pending_turf_adjacency) || length(SSdogmos.dogmos_pending_turf_heat_adjacency) != 1))
			failure_message = "A heat-only update affected the gas queue or lost its canonical heat edge."

		var/turf/target = run_loc_floor_bottom_left
		var/target_slot = target.dogmos_service_slot()
		var/target_generation = target.dogmos_service_generation()
		var/rebuild_slot = target_slot + 500
		SSdogmos.dogmos_pending_turf_heat_adjacency = list()
		SSdogmos.dogmos_pending_turf_heat_adjacency_index = list()
		call(SSdogmos, "queue_pending_gas_adjacency")(target_slot, target_generation, rebuild_slot, 1, TRUE, FALSE)
		call(SSdogmos, "queue_pending_heat_adjacency")(target_slot, target_generation, rebuild_slot, 1, TRUE)
		SSdogmos.discard_pending_turf_adjacencies(target)
		if(!failure_message && (length(SSdogmos.dogmos_pending_turf_adjacency) || length(SSdogmos.dogmos_pending_turf_heat_adjacency) || length(SSdogmos.dogmos_pending_turf_adjacency_index) || length(SSdogmos.dogmos_pending_turf_heat_adjacency_index)))
			failure_message = "Discard did not remove both gas and heat records for the old generation."
		var/rebuild_gas = call(SSdogmos, "queue_pending_gas_adjacency")(target_slot, target_generation + 1, rebuild_slot, 1, TRUE, FALSE)
		var/rebuild_heat = call(SSdogmos, "queue_pending_heat_adjacency")(target_slot, target_generation + 1, rebuild_slot, 1, TRUE)
		if(!failure_message && (!rebuild_gas || !rebuild_heat || length(SSdogmos.dogmos_pending_turf_adjacency) != 1 || length(SSdogmos.dogmos_pending_turf_heat_adjacency) != 1))
			failure_message = "A replacement generation did not rebuild independent gas and heat topology."
	catch(var/exception/error)
		failure_message = "The pending topology payload test raised [error.name]."

	SSdogmos.dogmos_pending_turf_adjacency = original_gas_edges
	SSdogmos.dogmos_pending_turf_adjacency_index = original_gas_index
	SSdogmos.dogmos_pending_turf_heat_adjacency = original_heat_edges
	SSdogmos.dogmos_pending_turf_heat_adjacency_index = original_heat_index
	if(failure_message)
		return Fail(failure_message, __FILE__, __LINE__)

/**
 * Reports reverse-pass record retention using only queued-list identity, so this exact fixture
 * can compare an old service_backend.dm against the staged candidate without production counters.
 */
/datum/unit_test/dogmos_service_pending_topology_dedup_measurement

/datum/unit_test/dogmos_service_pending_topology_dedup_measurement/proc/gas_state_matches(list/edge, first_slot, first_generation, second_slot, second_generation, connected, firelock)
	if(!islist(edge) || length(edge) != 6 || edge[5] != !!connected || edge[6] != !!firelock)
		return FALSE
	return (edge[1] == first_slot && edge[2] == first_generation && edge[3] == second_slot && edge[4] == second_generation) \
		|| (edge[1] == second_slot && edge[2] == second_generation && edge[3] == first_slot && edge[4] == first_generation)

/datum/unit_test/dogmos_service_pending_topology_dedup_measurement/proc/heat_state_matches(list/edge, first_slot, first_generation, second_slot, second_generation, connected)
	if(!islist(edge) || length(edge) != 5 || edge[5] != !!connected)
		return FALSE
	return (edge[1] == first_slot && edge[2] == first_generation && edge[3] == second_slot && edge[4] == second_generation) \
		|| (edge[1] == second_slot && edge[2] == second_generation && edge[3] == first_slot && edge[4] == first_generation)

/datum/unit_test/dogmos_service_pending_topology_dedup_measurement/proc/registration_ring_is_current(turf/first, turf/second)
	for(var/turf/source as anything in list(first, second))
		for(var/direction in GLOB.cardinals)
			var/turf/neighbor = get_step(source, direction)
			if((neighbor?.init_air || isspaceturf(neighbor)) && !neighbor.dogmos_air_registration_is_current(isspaceturf(neighbor)))
				return FALSE
	return TRUE

/datum/unit_test/dogmos_service_pending_topology_dedup_measurement/Run()
	if(!dogmos_wait_for_stage_boundary())
		return
	var/turf/open/target = run_loc_floor_bottom_left
	var/turf/open/neighbor = get_step(target, EAST)
	if(!target?.air || !neighbor?.air || isnull(target.dogmos_registration_generation) || isnull(neighbor.dogmos_registration_generation) || !target.dogmos_air_registration_is_current(FALSE) || !neighbor.dogmos_air_registration_is_current(FALSE) || !registration_ring_is_current(target, neighbor))
		return Fail("The topology retention measurement needs two registered open atmosphere turfs with current cardinal rings.", __FILE__, __LINE__)
	var/list/original_pending_frontier = SSair.dogmos_pending_frontier_epoch
	var/original_runtime_batching = SSdogmos.runtime_topology_batching
	var/list/original_lifecycle = SSdogmos.dogmos_pending_turf_lifecycle
	var/list/original_heat = SSdogmos.dogmos_pending_turf_heat
	var/list/original_gas_edges = SSdogmos.dogmos_pending_turf_adjacency
	var/list/original_gas_index = SSdogmos.dogmos_pending_turf_adjacency_index
	var/list/original_heat_edges = SSdogmos.dogmos_pending_turf_heat_adjacency
	var/list/original_heat_index = SSdogmos.dogmos_pending_turf_heat_adjacency_index
	var/list/original_adjacency_retry = SSdogmos.dogmos_pending_adjacency_retry
	var/original_max_queued = SSdogmos.dogmos_runtime_topology_max_queued
	var/target_slot = target.dogmos_service_slot()
	var/target_generation = target.dogmos_service_generation()
	var/neighbor_slot = neighbor.dogmos_service_slot()
	var/neighbor_generation = neighbor.dogmos_service_generation()
	var/edge_key = target_slot < neighbor_slot ? "[target_slot]:[target_generation]:[neighbor_slot]:[neighbor_generation]" : "[neighbor_slot]:[neighbor_generation]:[target_slot]:[target_generation]"
	var/failure_message
	var/list/measurement = list()

	try
		SSair.dogmos_pending_frontier_epoch = null
		SSdogmos.runtime_topology_batching = TRUE
		SSdogmos.dogmos_pending_turf_adjacency = list()
		SSdogmos.dogmos_pending_turf_adjacency_index = list()
		SSdogmos.dogmos_pending_turf_heat_adjacency = list()
		SSdogmos.dogmos_pending_turf_heat_adjacency_index = list()
		target.__update_auxtools_turf_adjacency_info(world.maxx, world.maxy, TRUE)
		var/list/first_gas_edge = SSdogmos.dogmos_pending_turf_adjacency[edge_key]
		var/list/first_heat_edge = SSdogmos.dogmos_pending_turf_heat_adjacency[edge_key]
		if(!first_gas_edge || !first_heat_edge)
			failure_message = "The forward topology pass did not queue both gas and heat records."
		else
			var/first_gas_connected = first_gas_edge[5]
			var/first_gas_firelock = first_gas_edge[6]
			var/first_heat_connected = first_heat_edge[5]
			neighbor.__update_auxtools_turf_adjacency_info(world.maxx, world.maxy, TRUE)
			measurement["gas_state_matches_reverse"] = gas_state_matches(SSdogmos.dogmos_pending_turf_adjacency[edge_key], target_slot, target_generation, neighbor_slot, neighbor_generation, first_gas_connected, first_gas_firelock)
			measurement["heat_state_matches_reverse"] = heat_state_matches(SSdogmos.dogmos_pending_turf_heat_adjacency[edge_key], target_slot, target_generation, neighbor_slot, neighbor_generation, first_heat_connected)
			if(measurement["gas_state_matches_reverse"] && measurement["heat_state_matches_reverse"])
				var/original_gas_slot = first_gas_edge[1]
				var/original_heat_slot = first_heat_edge[1]
				first_gas_edge[1] = -101
				first_heat_edge[1] = -101
				measurement["gas_record_retained"] = SSdogmos.dogmos_pending_turf_adjacency[edge_key]?[1] == -101
				measurement["heat_record_retained"] = SSdogmos.dogmos_pending_turf_heat_adjacency[edge_key]?[1] == -101
				first_gas_edge[1] = original_gas_slot
				first_heat_edge[1] = original_heat_slot
			else
				failure_message = "The forward and reverse topology passes did not agree on canonical gas/heat payloads."
			measurement["gas_edge_count"] = length(SSdogmos.dogmos_pending_turf_adjacency)
			measurement["heat_edge_count"] = length(SSdogmos.dogmos_pending_turf_heat_adjacency)
			measurement["gas_index_has_edge"] = !!(SSdogmos.dogmos_pending_turf_adjacency_index["[target_slot]"]?[edge_key] && SSdogmos.dogmos_pending_turf_adjacency_index["[neighbor_slot]"]?[edge_key])
			measurement["heat_index_has_edge"] = !!(SSdogmos.dogmos_pending_turf_heat_adjacency_index["[target_slot]"]?[edge_key] && SSdogmos.dogmos_pending_turf_heat_adjacency_index["[neighbor_slot]"]?[edge_key])
			if(!failure_message && (!measurement["gas_index_has_edge"] || !measurement["heat_index_has_edge"]))
				failure_message = "The reverse topology pass changed canonical gas/heat state or lost its reverse-index membership."
	catch(var/exception/error)
		failure_message = "The topology retention measurement raised [error.name]."

	SSair.dogmos_pending_frontier_epoch = original_pending_frontier
	SSdogmos.runtime_topology_batching = original_runtime_batching
	SSdogmos.dogmos_pending_turf_lifecycle = original_lifecycle
	SSdogmos.dogmos_pending_turf_heat = original_heat
	SSdogmos.dogmos_pending_turf_adjacency = original_gas_edges
	SSdogmos.dogmos_pending_turf_adjacency_index = original_gas_index
	SSdogmos.dogmos_pending_turf_heat_adjacency = original_heat_edges
	SSdogmos.dogmos_pending_turf_heat_adjacency_index = original_heat_index
	SSdogmos.dogmos_pending_adjacency_retry = original_adjacency_retry
	SSdogmos.dogmos_runtime_topology_max_queued = original_max_queued
	file("[GLOB.log_directory]/dogmos-pending-topology-dedup.json") << json_encode(measurement)
	if(failure_message)
		return Fail(failure_message, __FILE__, __LINE__)

#define DOGMOS_MULTIZ_TEST_STAGE_TURFS 4

/** A mutable vertical gate: closing it must not replace the turf or its air datum. */
/turf/open/floor/plating/dogmos_multiz_vertical_gate
	var/dogmos_multiz_open = TRUE

/turf/open/floor/plating/dogmos_multiz_vertical_gate/zAirOut(direction, turf/source)
	return dogmos_multiz_open && ..()

/turf/open/floor/plating/dogmos_multiz_vertical_gate/zAirIn(direction, turf/source)
	return dogmos_multiz_open && ..()

#undef DOGMOS_MULTIZ_TEST_STAGE_TURFS
#endif
