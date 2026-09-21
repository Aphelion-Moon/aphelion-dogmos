/** Opens a synchronous scope and returns the caller's previous publication ownership.
 * Callers must restore this value on normal return and in catch; this helper never yields or flushes.
 */
/datum/controller/subsystem/dogmos/proc/begin_runtime_topology_scope()
	SHOULD_NOT_SLEEP(TRUE)
	var/previous_owner = runtime_topology_batching
	runtime_topology_batching = TRUE
	return previous_owner

/** Restores scope ownership only. The caller still decides whether and when to publish. */
/datum/controller/subsystem/dogmos/proc/restore_runtime_topology_scope(previous_owner)
	SHOULD_NOT_SLEEP(TRUE)
	runtime_topology_batching = previous_owner

/** Canonical undirected key; generations distinguish reused endpoint slots. */
/datum/controller/subsystem/dogmos/proc/pending_edge_key(first_slot, first_generation, second_slot, second_generation)
	return first_slot < second_slot ? "[first_slot]:[first_generation]:[second_slot]:[second_generation]" : "[second_slot]:[second_generation]:[first_slot]:[first_generation]"

/** Compares either endpoint order after the caller validates its family's record width. */
/datum/controller/subsystem/dogmos/proc/pending_edge_endpoints_match(list/edge, first_slot, first_generation, second_slot, second_generation)
	return (edge[1] == first_slot && edge[2] == first_generation && edge[3] == second_slot && edge[4] == second_generation) \
		|| (edge[1] == second_slot && edge[2] == second_generation && edge[3] == first_slot && edge[4] == first_generation)

/** Removes one complete edge and both reverse-index memberships without scanning the batch. */
/datum/controller/subsystem/dogmos/proc/remove_pending_edge(list/edges, list/index, edge_key)
	var/list/edge = edges[edge_key]
	if(!edge)
		return
	edges.Remove(edge_key)
	unindex_pending_edge(index, "[edge[1]]", edge_key)
	unindex_pending_edge(index, "[edge[3]]", edge_key)

/** Starts bounded accumulation of startup turf mutations. */
/datum/controller/subsystem/dogmos/proc/begin_turf_registration_batch()
	if(turf_registration_batching)
		CRASH("Attempted to nest Dogmos turf registration batches.")
	turf_registration_batching = TRUE
	dogmos_pending_turf_lifecycle.Cut()
	dogmos_pending_turf_adjacency.Cut()
	dogmos_pending_turf_adjacency_index.Cut()
	dogmos_pending_turf_heat.Cut()
	dogmos_pending_turf_heat_adjacency.Cut()
	dogmos_pending_turf_heat_adjacency_index.Cut()
	dogmos_pending_adjacency_retry.Cut()

/** Flushes pending turf mutations in bounded batches while preserving lifecycle-before-topology ordering. */
/datum/controller/subsystem/dogmos/proc/flush_turf_registration_batch()
	if(!service_ready)
		return FALSE
	if(SSair?.dogmos_pending_frontier_epoch)
		dogmos_runtime_topology_deferrals++
		return FALSE
	flush_pending_mixture_unregistrations()
	if(!turf_registration_batching)
		retry_pending_turf_adjacencies()
	while(length(dogmos_pending_turf_lifecycle))
		var/list/lifecycle_batch = list()
		var/list/lifecycle_keys = list()
		var/lifecycle_count = 0
		for(var/turf_slot in dogmos_pending_turf_lifecycle)
			var/list/lifecycle_records = dogmos_pending_turf_lifecycle[turf_slot]
			var/record_count = length(lifecycle_records) / DOGMOS_TURF_LIFECYCLE_FIELDS
			if(lifecycle_count && lifecycle_count + record_count > DOGMOS_TURF_BATCH_OPERATIONS)
				break
			lifecycle_batch += lifecycle_records
			lifecycle_keys += turf_slot
			lifecycle_count += record_count
		if(publish_turf_lifecycle_records(lifecycle_batch) != lifecycle_count)
			CRASH("dogmosd rejected a turf lifecycle batch.")
		for(var/lifecycle_key in lifecycle_keys)
			dogmos_pending_turf_lifecycle.Remove(lifecycle_key)
	while(length(dogmos_pending_turf_heat))
		var/list/heat_batch = list()
		var/list/heat_keys = list()
		for(var/heat_turf_slot in dogmos_pending_turf_heat)
			heat_batch += dogmos_pending_turf_heat[heat_turf_slot]
			heat_keys += heat_turf_slot
			if(length(heat_keys) >= DOGMOS_TURF_BATCH_OPERATIONS)
				break
		var/heat_count = length(heat_keys)
		if(publish_turf_heat_records(heat_batch) != heat_count)
			CRASH("dogmosd rejected a turf heat batch.")
		for(var/heat_key in heat_keys)
			dogmos_pending_turf_heat.Remove(heat_key)
	while(length(dogmos_pending_turf_adjacency))
		var/list/adjacency_batch = list()
		var/list/adjacency_keys = list()
		for(var/edge_key in dogmos_pending_turf_adjacency)
			adjacency_batch += dogmos_pending_turf_adjacency[edge_key]
			adjacency_keys += edge_key
			if(length(adjacency_keys) >= DOGMOS_TURF_BATCH_OPERATIONS)
				break
		var/adjacency_count = length(adjacency_keys)
		if(publish_turf_gas_edges(adjacency_batch) != adjacency_count)
			CRASH("dogmosd rejected a turf adjacency batch.")
		for(var/adjacency_key in adjacency_keys)
			remove_pending_gas_edge(adjacency_key)
		if(!turf_registration_batching)
			dogmos_runtime_topology_records += adjacency_count
			dogmos_runtime_topology_calls++
	while(length(dogmos_pending_turf_heat_adjacency))
		var/list/heat_adjacency_batch = list()
		var/list/heat_adjacency_keys = list()
		for(var/heat_edge_key in dogmos_pending_turf_heat_adjacency)
			heat_adjacency_batch += dogmos_pending_turf_heat_adjacency[heat_edge_key]
			heat_adjacency_keys += heat_edge_key
			if(length(heat_adjacency_keys) >= DOGMOS_TURF_BATCH_OPERATIONS)
				break
		var/heat_adjacency_count = length(heat_adjacency_keys)
		if(publish_turf_heat_edges(heat_adjacency_batch) != heat_adjacency_count)
			CRASH("dogmosd rejected a turf heat-adjacency batch.")
		for(var/heat_adjacency_key in heat_adjacency_keys)
			remove_pending_heat_edge(heat_adjacency_key)
		if(!turf_registration_batching)
			dogmos_runtime_topology_records += heat_adjacency_count
			dogmos_runtime_topology_calls++
	return TRUE

/** Submits lifecycle records synchronously; the acknowledged count permits queue retirement. */
/datum/controller/subsystem/dogmos/proc/publish_turf_lifecycle_records(list/records)
	return dogmos_turf_lifecycle_batch(records)

/** Submits heat-property records synchronously; errors leave their pending queue owned by DM. */
/datum/controller/subsystem/dogmos/proc/publish_turf_heat_records(list/records)
	return dogmos_turf_heat_batch(records)

/** Submits gas edges synchronously; the caller retires both reverse indexes only after acknowledgement. */
/datum/controller/subsystem/dogmos/proc/publish_turf_gas_edges(list/records)
	return dogmos_turf_adjacency_batch(records)

/** Submits heat edges synchronously with their independent five-field representation. */
/datum/controller/subsystem/dogmos/proc/publish_turf_heat_edges(list/records)
	return dogmos_turf_heat_adjacency_batch(records)

/** Retires deferred mixture identities before applying dependent turf topology mutations. */
/datum/controller/subsystem/dogmos/proc/flush_pending_mixture_unregistrations()
	while(length(dogmos_pending_mixture_unregistrations))
		var/list/lifecycle_batch = list()
		var/list/retired_slots = list()
		for(var/slot_key in dogmos_pending_mixture_unregistrations)
			lifecycle_batch += dogmos_pending_mixture_unregistrations[slot_key]
			retired_slots += text2num(slot_key)
			if(length(retired_slots) >= DOGMOS_TURF_BATCH_OPERATIONS)
				break
		if(dogmos_mixture_lifecycle_batch(lifecycle_batch) != length(retired_slots))
			CRASH("dogmosd rejected a deferred mixture unregistration batch.")
		for(var/retired_slot in retired_slots)
			dogmos_pending_mixture_unregistrations.Remove("[retired_slot]")
			dogmos_free_mixture_slots += retired_slot

/**
 * Rebuilds deferred turf adjacency records synchronously without nested flushing.
 *
 * Arguments:
 * * retry_turfs - Optional snapshot owned by the startup caller; otherwise drains the pending queue.
 */
/datum/controller/subsystem/dogmos/proc/retry_pending_turf_adjacencies(list/retry_turfs)
	SHOULD_NOT_SLEEP(TRUE)
	if(isnull(retry_turfs))
		if(!length(dogmos_pending_adjacency_retry))
			return
		// Transfer the queue so requeues have a separate owner without copying every source.
		retry_turfs = dogmos_pending_adjacency_retry
		dogmos_pending_adjacency_retry = list()
	if(!length(retry_turfs))
		return
	var/original_runtime_batching = begin_runtime_topology_scope()
	try
		for(var/turf/retry_turf as anything in retry_turfs)
			if(!retry_turf)
				continue
			retry_turf.__update_auxtools_turf_adjacency_info(world.maxx, world.maxy, startup_flush = TRUE)
	catch(var/exception/error)
		restore_runtime_topology_scope(original_runtime_batching)
		throw error
	restore_runtime_topology_scope(original_runtime_batching)

/**
 * Blocks the destination and source of one shuttle turf move in their original order.
 * Only the synchronous atmosphere updates are batched. Adjacency signals and liquid
 * updates still run per turf; their gas reads address mixtures directly. CopyOnTop,
 * the final gas copy and the shuttle movement signal remain outside this helper.
 * An outer batch or frozen frontier retains its existing publication ownership.
 *
 * Arguments:
 * * source_turf - The turf the shuttle is leaving.
 * * destination_turf - The already-copied destination turf.
 */
/datum/controller/subsystem/dogmos/proc/block_shuttle_turfs(turf/source_turf, turf/destination_turf)
	SHOULD_NOT_SLEEP(TRUE)
	var/original_runtime_batching = begin_runtime_topology_scope()
	try
		destination_turf.blocks_air = TRUE
		destination_turf.air_update_turf(TRUE, FALSE)
		source_turf.blocks_air = TRUE
		source_turf.air_update_turf(TRUE, TRUE)
	catch(var/exception/error)
		restore_runtime_topology_scope(original_runtime_batching)
		throw error
	restore_runtime_topology_scope(original_runtime_batching)
	if(!original_runtime_batching && !turf_registration_batching && SSair.initialized)
		flush_turf_registration_batch()

/**
 * Refreshes a loaded template's border with bounded, coalesced topology publication.
 * Only this synchronous final loop is batched: Initialize/LateInitialize may yield and
 * must finish before entering it. Full batches retain the existing wire bounds; the
 * outer owner drains the final partial batch. A pending SSair frontier still defers it.
 */
/datum/controller/subsystem/dogmos/proc/update_template_border(list/turfs)
	SHOULD_NOT_SLEEP(TRUE)
	var/original_runtime_batching = begin_runtime_topology_scope()
	try
		for(var/turf/affected_turf as anything in turfs)
			affected_turf.air_update_turf(TRUE, TRUE)
			affected_turf.levelupdate()
	catch(var/exception/error)
		restore_runtime_topology_scope(original_runtime_batching)
		throw error
	restore_runtime_topology_scope(original_runtime_batching)
	if(!original_runtime_batching && !turf_registration_batching)
		flush_turf_registration_batch()

/** Flushes a full startup turf batch before any wire payload can exceed its bound. */
/datum/controller/subsystem/dogmos/proc/flush_full_turf_registration_batch()
	if(length(dogmos_pending_turf_lifecycle) >= DOGMOS_TURF_BATCH_OPERATIONS \
		|| length(dogmos_pending_turf_adjacency) >= DOGMOS_TURF_BATCH_OPERATIONS \
		|| length(dogmos_pending_turf_heat) >= DOGMOS_TURF_BATCH_OPERATIONS \
		|| length(dogmos_pending_turf_heat_adjacency) >= DOGMOS_TURF_BATCH_OPERATIONS)
		flush_turf_registration_batch()

/** Adds one edge key to a slot's reverse-index bucket. Idempotent - a set, not a list of duplicates. */
/datum/controller/subsystem/dogmos/proc/index_pending_edge(list/index, slot_key, edge_key)
	var/list/entries = index[slot_key]
	if(!entries)
		entries = list()
		index[slot_key] = entries
	entries[edge_key] = TRUE

/** Removes one edge key from a slot's reverse-index bucket, dropping the bucket once empty. */
/datum/controller/subsystem/dogmos/proc/unindex_pending_edge(list/index, slot_key, edge_key)
	var/list/entries = index[slot_key]
	if(!entries)
		return
	entries -= edge_key
	if(!length(entries))
		index -= slot_key

/** Queues a gas edge only when its canonical slot/generation key has changed meaningful payload. */
/datum/controller/subsystem/dogmos/proc/queue_pending_gas_adjacency(first_slot, first_generation, second_slot, second_generation, connected, firelock, edge_key = null)
	if(isnull(edge_key))
		edge_key = pending_edge_key(first_slot, first_generation, second_slot, second_generation)
	var/list/existing = dogmos_pending_turf_adjacency[edge_key]
	if(islist(existing) && length(existing) == 6 && existing[5] == !!connected && existing[6] == !!firelock \
		&& pending_edge_endpoints_match(existing, first_slot, first_generation, second_slot, second_generation))
		return FALSE
	dogmos_pending_turf_adjacency[edge_key] = list(first_slot, first_generation, second_slot, second_generation, !!connected, !!firelock)
	index_pending_edge(dogmos_pending_turf_adjacency_index, "[first_slot]", edge_key)
	index_pending_edge(dogmos_pending_turf_adjacency_index, "[second_slot]", edge_key)
	return TRUE

/** Queues a heat edge only when its canonical slot/generation key has changed meaningful payload. */
/datum/controller/subsystem/dogmos/proc/queue_pending_heat_adjacency(first_slot, first_generation, second_slot, second_generation, connected, edge_key = null)
	if(isnull(edge_key))
		edge_key = pending_edge_key(first_slot, first_generation, second_slot, second_generation)
	var/list/existing = dogmos_pending_turf_heat_adjacency[edge_key]
	if(islist(existing) && length(existing) == 5 && existing[5] == !!connected \
		&& pending_edge_endpoints_match(existing, first_slot, first_generation, second_slot, second_generation))
		return FALSE
	dogmos_pending_turf_heat_adjacency[edge_key] = list(first_slot, first_generation, second_slot, second_generation, !!connected)
	index_pending_edge(dogmos_pending_turf_heat_adjacency_index, "[first_slot]", edge_key)
	index_pending_edge(dogmos_pending_turf_heat_adjacency_index, "[second_slot]", edge_key)
	return TRUE

/** Removes one pending gas-adjacency edge from both the batch and its reverse index. */
/datum/controller/subsystem/dogmos/proc/remove_pending_gas_edge(edge_key)
	remove_pending_edge(dogmos_pending_turf_adjacency, dogmos_pending_turf_adjacency_index, edge_key)

/** Removes one pending heat-adjacency edge from both the batch and its reverse index. */
/datum/controller/subsystem/dogmos/proc/remove_pending_heat_edge(edge_key)
	remove_pending_edge(dogmos_pending_turf_heat_adjacency, dogmos_pending_turf_heat_adjacency_index, edge_key)

/**
 * Removes pending topology that predates a turf's latest registration state.
 *
 * Looks up the reverse index instead of scanning the full pending batch - this runs on every
 * register_dogmos_air() call, so an O(pending batch size) scan here multiplies against every
 * turf touched during a startup or runtime adjacency rebuild. Unnoticeable at unit-test scale
 * (a handful of turfs), it cost minutes on a real map's turf count.
 */
/datum/controller/subsystem/dogmos/proc/discard_pending_turf_adjacencies(turf/target)
	var/slot = target.dogmos_service_slot()
	var/slot_key = "[slot]"
	var/list/gas_candidates = dogmos_pending_turf_adjacency_index[slot_key]
	if(gas_candidates)
		for(var/edge_key in gas_candidates.Copy())
			remove_pending_gas_edge(edge_key)
	var/list/heat_candidates = dogmos_pending_turf_heat_adjacency_index[slot_key]
	if(heat_candidates)
		for(var/heat_edge_key in heat_candidates.Copy())
			remove_pending_heat_edge(heat_edge_key)

/** Rebuilds startup adjacency in bounded chunks, yielding only from the atmosphere initialization caller. */
/datum/controller/subsystem/dogmos/proc/retry_startup_turf_adjacencies()
	if(!turf_registration_batching)
		CRASH("Attempted startup adjacency retries outside a Dogmos turf registration batch.")
	// Every turf has now had its Initalize_Atmos() pass, so retry any turf whose own adjacency
	// pass bailed earlier on an unregistered self or neighbor - both sides should be registered
	// by now, so this is the last chance to pick up edges the slot-ordered boot walk dropped.
	// The local drain owns this snapshot; late retries go into the new pending queue.
	var/list/retry_turfs = dogmos_pending_adjacency_retry
	dogmos_pending_adjacency_retry = list()
	// Only startup may yield. Runtime flushes also run inside non-sleeping lifecycle hooks.
	for(var/retry_index = 1; retry_index <= length(retry_turfs); retry_index += DOGMOS_TURF_BATCH_OPERATIONS)
		retry_pending_turf_adjacencies(retry_turfs.Copy(retry_index, min(retry_index + DOGMOS_TURF_BATCH_OPERATIONS, length(retry_turfs) + 1)))
		if(!SSair.initialized)
			CHECK_TICK

/** Flushes and closes turf mutation accumulation synchronously, including during test cleanup. */
/datum/controller/subsystem/dogmos/proc/finish_turf_registration_batch()
	SHOULD_NOT_SLEEP(TRUE)
	if(!turf_registration_batching)
		CRASH("Attempted to finish an inactive Dogmos turf registration batch.")
	retry_pending_turf_adjacencies()
	if(!flush_turf_registration_batch())
		CRASH("Dogmos startup turf mutations were blocked by an unexpected pending stage.")
	turf_registration_batching = FALSE
