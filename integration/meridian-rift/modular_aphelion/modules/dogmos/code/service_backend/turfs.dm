/** Returns the deterministic numeric turf identity used across IPC. */
/turf/proc/dogmos_service_slot()
	var/slot = x + world.maxx * (y - 1 + world.maxy * (z - 1))
	if(slot <= 0 || slot > DOGMOS_MAX_EXACT_INTEGER)
		CRASH("Turf [x],[y],[z] exceeds Dogmos' exact IPC identity range.")
	return slot

/** Returns the turf generation after enforcing the exact IPC integer range. */
/turf/proc/dogmos_service_generation()
	if(isnull(dogmos_registration_generation) || dogmos_registration_generation <= 0 || dogmos_registration_generation > DOGMOS_MAX_EXACT_INTEGER)
		CRASH("Turf [x],[y],[z] has invalid Dogmos generation [dogmos_registration_generation].")
	return dogmos_registration_generation

/** Registers or removes this turf's service-owned gas and heat state. */
/turf/proc/update_air_ref(flag)
	if(!SSdogmos.service_ready)
		if(!SSdogmos.service_failure_latched && !SSdogmos.service_shutdown_requested)
			CRASH("Attempted to update a turf while dogmosd is unavailable.")
		return

	var/slot = dogmos_service_slot()
	var/generation = dogmos_service_generation()
	var/registered_heat_temperature
	if(!isnull(dogmos_registered_mixture_slot))
		registered_heat_temperature = __dogmos_heat_temperature()
	if(flag == DOGMOS_SIMULATION_REMOVE)
		var/list/removal = list(
			DOGMOS_LIFECYCLE_REGISTER, slot, generation, FALSE, 0, 0,
			DOGMOS_LIFECYCLE_UNREGISTER, slot, generation, FALSE, 0, 0,
		)
		SSdogmos.discard_pending_turf_adjacencies(src)
		SSdogmos.dogmos_pending_turf_lifecycle["[slot]"] = removal
		SSdogmos.dogmos_pending_turf_heat.Remove("[slot]")
		dogmos_registered_mixture_slot = null
		dogmos_registered_mixture_generation = null
		if(!SSdogmos.turf_registration_batching && !SSdogmos.runtime_topology_batching)
			SSdogmos.flush_turf_registration_batch()
		mark_dogmos_turf_replacement()
		return

	var/turf/open/open_turf = isopenturf(src) ? src : null
	var/datum/gas_mixture/mixture = (flag != DOGMOS_SIMULATION_NONE) ? open_turf?.air : null
	var/mixture_present = !isnull(mixture)
	var/mixture_slot = mixture?.dogmos_slot || 0
	var/mixture_generation = mixture?.dogmos_generation || 0
	var/list/lifecycle = list(DOGMOS_LIFECYCLE_REGISTER, slot, generation, mixture_present, mixture_slot, mixture_generation)
	SSdogmos.dogmos_pending_turf_lifecycle["[slot]"] = lifecycle
	dogmos_registered_mixture_slot = mixture_slot
	dogmos_registered_mixture_generation = mixture_generation

	if(flag == DOGMOS_SIMULATION_SPACE_BOUNDARY)
		var/list/space_heat = list(slot, generation, FALSE, 0, 0, 0, FALSE)
		SSdogmos.discard_pending_turf_adjacencies(src)
		SSdogmos.dogmos_pending_turf_heat["[slot]"] = space_heat
		SSdogmos.flush_full_turf_registration_batch()
		if(!SSdogmos.turf_registration_batching && !SSdogmos.runtime_topology_batching)
			SSdogmos.flush_turf_registration_batch()
		return

	var/heat_present = thermal_conductivity > 0 && heat_capacity > 0
	var/list/heat = list(
		slot,
		generation,
		heat_present,
		heat_present ? (isnull(registered_heat_temperature) ? initial_temperature : registered_heat_temperature) : 0,
		heat_present ? thermal_conductivity : 0,
		heat_present ? heat_capacity : 0,
		heat_present && should_conduct_to_space(),
	)
	SSdogmos.discard_pending_turf_adjacencies(src)
	SSdogmos.dogmos_pending_turf_heat["[slot]"] = heat
	SSdogmos.flush_full_turf_registration_batch()
	if(!SSdogmos.turf_registration_batching && !SSdogmos.runtime_topology_batching)
		SSdogmos.flush_turf_registration_batch()

/** Updates this turf's service-owned heat temperature. */
/turf/proc/__set_temperature(new_temperature)
	var/slot = dogmos_service_slot()
	var/generation = dogmos_service_generation()
	var/heat_present = thermal_conductivity > 0 && heat_capacity > 0
	var/list/heat = list(
		slot,
		generation,
		heat_present,
		heat_present ? new_temperature : 0,
		heat_present ? thermal_conductivity : 0,
		heat_present ? heat_capacity : 0,
		heat_present && should_conduct_to_space(),
	)
	SSdogmos.dogmos_pending_turf_heat["[slot]"] = heat
	SSdogmos.flush_full_turf_registration_batch()
	if(!SSdogmos.turf_registration_batching && !SSdogmos.runtime_topology_batching)
		SSdogmos.flush_turf_registration_batch()
	return new_temperature

/** Returns the service-owned turf temperature. */
/turf/proc/__dogmos_heat_temperature()
	if(!SSdogmos.service_ready)
		return null
	if(!init_air || thermal_conductivity <= 0 || heat_capacity <= 0 || isnull(dogmos_registration_generation))
		return null
	var/slot = dogmos_service_slot()
	var/generation = dogmos_service_generation()
	var/list/pending_heat = SSdogmos.dogmos_pending_turf_heat["[slot]"]
	if(islist(pending_heat) && length(pending_heat) == 7 && pending_heat[2] == generation)
		return pending_heat[3] ? pending_heat[4] : null
	var/list/snapshot = dogmos_turf_heat_snapshot(list(slot, generation))
	if(length(snapshot) != 5)
		CRASH("dogmosd returned a malformed turf heat snapshot.")
	if(!snapshot[1])
		return null
	return snapshot[2]

/** Rebuilds this turf's gas and heat adjacency edges in dogmosd.
 *
 * Arguments:
 * * max_x - Current world width, checked against stale caller dimensions.
 * * max_y - Current world height, checked against stale caller dimensions.
 * * startup_flush - Rebuild deferred work after the batch has updated DM adjacency.
 */
/turf/proc/__update_auxtools_turf_adjacency_info(max_x, max_y, startup_flush = FALSE)
	if(max_x != world.maxx || max_y != world.maxy)
		CRASH("Dogmos received stale world dimensions for turf adjacency.")
	if((SSdogmos.turf_registration_batching || SSdogmos.runtime_topology_batching) && !startup_flush)
		// Startup and runtime batches visit endpoints repeatedly as neighbors change.
		// Retain one identity and rebuild its final topology at the existing flush.
		SSdogmos.dogmos_pending_adjacency_retry[src] = TRUE
		return TRUE
	if(isnull(dogmos_registration_generation))
		// Boot-time slot ordering means this turf's own registration can still be pending when its
		// pass runs. Queue a retry rather than dropping every edge this turf owns permanently.
		if(SSdogmos.turf_registration_batching)
			SSdogmos.dogmos_pending_adjacency_retry[src] = TRUE
		return
	if(SSair?.dogmos_pending_frontier_epoch && !SSdogmos.turf_registration_batching)
		SSdogmos.dogmos_pending_adjacency_retry[src] = TRUE
		return

	// A deferred source may have acquired air since its heat-only registration.
	// Refresh it before constructing edges, just as we do for each neighbor below.
	if((init_air || isspaceturf(src)) && !dogmos_air_registration_is_current(isspaceturf(src)))
		register_dogmos_air()
	var/slot = dogmos_service_slot()
	var/generation = dogmos_service_generation()
	var/heat_present = thermal_conductivity > 0 && heat_capacity > 0
	for(var/direction in GLOB.cardinals_multiz)
		var/is_vertical = direction & (UP | DOWN)
		// Vertical gas links follow both map-cache and reservation routing.
		var/turf/neighbor = is_vertical ? get_step_multiz(src, direction) : get_step(src, direction)
		if(!neighbor)
			continue
		var/neighbor_slot = neighbor.dogmos_service_slot()
		if((neighbor.init_air || isspaceturf(neighbor)) \
			&& ((!SSdogmos.turf_registration_batching && !SSdogmos.runtime_topology_batching) \
				|| !neighbor.dogmos_air_registration_is_current(isspaceturf(neighbor))))
			neighbor.register_dogmos_air()
		if(isnull(neighbor.dogmos_registration_generation))
			// Same as above, but the neighbor is the one not yet registered - retry this turf's
			// whole pass later instead of silently dropping just this one edge.
			if(SSdogmos.turf_registration_batching)
				SSdogmos.dogmos_pending_adjacency_retry[src] = TRUE
			continue
		var/neighbor_generation = neighbor.dogmos_service_generation()
		var/turf/open/open_turf = isopenturf(src) ? src : null
		var/turf/open/open_neighbor = isopenturf(neighbor) ? neighbor : null
		var/source_has_gas = (init_air || isspaceturf(src)) && open_turf?.air
		var/neighbor_has_gas = (neighbor.init_air || isspaceturf(neighbor)) && open_neighbor?.air
		var/edge_key = null
		if(source_has_gas && neighbor_has_gas && open_turf.air != open_neighbor.air && !blocks_air && !neighbor.blocks_air)
			edge_key = SSdogmos.pending_edge_key(slot, generation, neighbor_slot, neighbor_generation)
			var/connected = (neighbor in atmos_adjacent_turfs)
			var/firelock = !!(connected && (atmos_adjacent_turfs[neighbor] & DOGMOS_ADJACENT_FIRELOCK))
			SSdogmos.queue_pending_gas_adjacency(slot, generation, neighbor_slot, neighbor_generation, connected, firelock, edge_key)
		// Turf heat conduction remains horizontal.
		if(!is_vertical && heat_present && neighbor.thermal_conductivity > 0 && neighbor.heat_capacity > 0 && init_air && neighbor.init_air && !isspaceturf(src) && !isspaceturf(neighbor))
			if(isnull(edge_key))
				edge_key = SSdogmos.pending_edge_key(slot, generation, neighbor_slot, neighbor_generation)
			var/heat_connected = !(conductivity_blocked_directions & direction) && !(neighbor.conductivity_blocked_directions & turn(direction, 180))
			SSdogmos.queue_pending_heat_adjacency(slot, generation, neighbor_slot, neighbor_generation, heat_connected, edge_key)

	var/queued_topology = length(SSdogmos.dogmos_pending_turf_adjacency) + length(SSdogmos.dogmos_pending_turf_heat_adjacency)
	SSdogmos.dogmos_runtime_topology_max_queued = max(SSdogmos.dogmos_runtime_topology_max_queued, queued_topology)
	SSdogmos.flush_full_turf_registration_batch()
	if(!SSdogmos.turf_registration_batching && !SSdogmos.runtime_topology_batching)
		SSdogmos.flush_turf_registration_batch()
	return TRUE
