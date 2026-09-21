/** Resets the bounded mixture snapshot cache and its counters. */
/datum/controller/subsystem/dogmos/proc/reset_mixture_snapshot_cache()
	dogmos_mixture_cache = new/list(DOGMOS_MIXTURE_CACHE_BUCKETS)
	dogmos_mixture_cache_epoch = 1
	dogmos_mixture_cache_hits = 0
	dogmos_mixture_cache_misses = 0
	dogmos_mixture_cache_collisions = 0
	dogmos_mixture_cache_epoch_invalidations = 0

/** Returns the direct-mapped cache bucket for one positive mixture slot. */
/datum/controller/subsystem/dogmos/proc/mixture_snapshot_cache_bucket(slot)
	return (slot % DOGMOS_MIXTURE_CACHE_BUCKETS) + 1

/** Returns a cached snapshot only for the exact current handle and cache epoch. */
/datum/controller/subsystem/dogmos/proc/lookup_mixture_snapshot_cache(slot, generation)
	if(!dogmos_mixture_cache)
		reset_mixture_snapshot_cache()
	var/list/entry = dogmos_mixture_cache[mixture_snapshot_cache_bucket(slot)]
	if(!entry || entry[1] != slot || entry[2] != generation || entry[3] != dogmos_mixture_cache_epoch)
		return null
	var/list/cached = entry[4]
	// store_mixture_snapshot_cache() is the only writer and only runs after mixture_snapshot() has
	// validated length, so a malformed entry should be unreachable. Checked anyway because the failure
	// mode if it ever is reachable is silent and remote: a short list here is returned straight to
	// callers that index it by field constant, surfacing as "cannot read from list" in return_pressure()
	// and friends with nothing pointing back at the cache. Treated as a miss so the fresh-fetch path's
	// own validation produces the real diagnosis.
	if(!islist(cached) || length(cached) != DOGMOS_MIXTURE_SNAPSHOT_FIELDS)
		stack_trace("Discarded a malformed cached mixture snapshot for [slot]:[generation]: length [islist(cached) ? length(cached) : "not a list"], expected [DOGMOS_MIXTURE_SNAPSHOT_FIELDS].")
		dogmos_mixture_cache[mixture_snapshot_cache_bucket(slot)] = null
		return null
	dogmos_mixture_cache_hits++
	return cached

/** Stores one validated service snapshot in its direct-mapped cache bucket. */
/datum/controller/subsystem/dogmos/proc/store_mixture_snapshot_cache(slot, generation, list/snapshot)
	if(!dogmos_mixture_cache)
		reset_mixture_snapshot_cache()
	var/bucket = mixture_snapshot_cache_bucket(slot)
	var/list/displaced = dogmos_mixture_cache[bucket]
	if(displaced && displaced[3] == dogmos_mixture_cache_epoch && (displaced[1] != slot || displaced[2] != generation))
		dogmos_mixture_cache_collisions++
	dogmos_mixture_cache[bucket] = list(slot, generation, dogmos_mixture_cache_epoch, snapshot)
	return snapshot

/** Evicts a cached snapshot only when the direct-mapped entry matches the exact handle. */
/datum/controller/subsystem/dogmos/proc/evict_mixture_snapshot_cache(slot, generation)
	if(!dogmos_mixture_cache || !slot)
		return
	var/bucket = mixture_snapshot_cache_bucket(slot)
	var/list/entry = dogmos_mixture_cache[bucket]
	if(entry && entry[1] == slot && entry[2] == generation)
		dogmos_mixture_cache[bucket] = null

/** Invalidates every mixture snapshot in O(1), clearing once at exact-integer rollover. */
/datum/controller/subsystem/dogmos/proc/invalidate_mixture_snapshot_epoch()
	if(!dogmos_mixture_cache)
		reset_mixture_snapshot_cache()
	dogmos_mixture_cache_epoch_invalidations++
	if(dogmos_mixture_cache_epoch >= DOGMOS_MAX_EXACT_INTEGER)
		dogmos_mixture_cache = new/list(DOGMOS_MIXTURE_CACHE_BUCKETS)
		dogmos_mixture_cache_epoch = 1
		return
	dogmos_mixture_cache_epoch++

/** Returns one validated cached or freshly fetched service-owned mixture snapshot. */
/datum/controller/subsystem/dogmos/proc/mixture_snapshot(slot, generation)
	var/list/cached = lookup_mixture_snapshot_cache(slot, generation)
	if(cached)
		return cached
	if(!service_ready)
		var/list/failed_snapshot = new/list(DOGMOS_MIXTURE_SNAPSHOT_FIELDS)
		failed_snapshot[1] = slot || 0
		failed_snapshot[2] = generation || 0
		failed_snapshot[DOGMOS_MIXTURE_SNAPSHOT_GAS_COUNT] = 0
		failed_snapshot[DOGMOS_MIXTURE_SNAPSHOT_TEMPERATURE] = T20C
		failed_snapshot[DOGMOS_MIXTURE_SNAPSHOT_VOLUME] = CELL_VOLUME
		return failed_snapshot
	dogmos_mixture_cache_misses++
	var/list/snapshot = dogmos_mixture_snapshot(list(slot, generation))
	if(!islist(snapshot) || length(snapshot) != DOGMOS_MIXTURE_SNAPSHOT_FIELDS)
		CRASH("dogmosd returned a malformed mixture snapshot for [slot]:[generation].")
	var/gas_count = snapshot[DOGMOS_MIXTURE_SNAPSHOT_GAS_COUNT]
	if(gas_count < 0 || gas_count > length(dogmos_gas_paths) || round(gas_count) != gas_count)
		// The actuals are the whole diagnosis here: this rejection aborts mixture_snapshot(), which then
		// returns null to every caller, so the visible symptom is a flood of downstream "cannot read from
		// list" runtimes in return_pressure()/return_volume() rather than this root cause. Without the
		// numbers there is no way to tell an out-of-range count from a non-integer one, or a genuine
		// service fault from dogmos_gas_paths not having been populated.
		CRASH("dogmosd returned an invalid mixture gas count for [slot]:[generation]: got [gas_count], registered gas paths [length(dogmos_gas_paths)].")
	return store_mixture_snapshot_cache(slot, generation, snapshot)

/**
 * Warms the snapshot cache for a working set of mixtures with bounded service batches.
 *
 * mixture_snapshot() costs a round trip per cache miss, so reading N cold mixtures costs N round
 * trips. Naming them up front batches those reads, which is worth doing whenever the caller
 * already knows what it is about to read - a subsystem's turf frontier, a pipenet, an atmos
 * machine's connected mixtures.
 *
 * Only worth calling when the results will actually be read this tick: the cache is invalidated
 * wholesale by epoch, so a prefetch that nothing consumes is a wasted round trip. The request is
 * capped at DOGMOS_MIXTURE_PREFETCH_LIMIT because the cache is direct-mapped and a larger
 * prefetch would evict itself.
 *
 * The service omits handles it can no longer resolve rather than failing the whole batch, so
 * records are matched by the handle they carry and not by request position, and the returned
 * count may be lower than the number requested. Returns how many snapshots were cached.
 */
/datum/controller/subsystem/dogmos/proc/prefetch_mixture_snapshots(list/datum/gas_mixture/gas_mixture_list)
	if(!service_ready || !length(gas_mixture_list))
		return 0

	var/list/request_fields = list()
	var/list/seen = list()
	var/inspected = 0
	var/cached = 0
	for(var/datum/gas_mixture/gas_mixture as anything in gas_mixture_list)
		if(inspected >= DOGMOS_MIXTURE_PREFETCH_LIMIT)
			break
		inspected++
		if(!gas_mixture || seen[gas_mixture])
			continue
		seen[gas_mixture] = TRUE
		var/slot = gas_mixture.dogmos_slot
		var/generation = gas_mixture.dogmos_generation
		if(!slot || isnull(generation))
			continue
		request_fields += slot
		request_fields += generation
		if(length(request_fields) == DOGMOS_MIXTURE_SNAPSHOT_BATCH_LIMIT * 2)
			cached += prefetch_mixture_snapshot_chunk(request_fields)
			request_fields.Cut()
	if(length(request_fields))
		cached += prefetch_mixture_snapshot_chunk(request_fields)
	return cached

/** Fetches and validates one compact snapshot reply that fits the production IPC window. */
/datum/controller/subsystem/dogmos/proc/prefetch_mixture_snapshot_chunk(list/request_fields)
	var/requested = length(request_fields) / 2
	var/list/response_fields = dogmos_mixture_snapshot_batch(request_fields)
	if(!islist(response_fields))
		CRASH("dogmosd returned a malformed mixture snapshot batch: not a list.")
	var/field_count = length(response_fields)
	if(field_count % DOGMOS_PIPENET_RECONCILE_RECORD_FIELDS)
		CRASH("dogmosd returned a truncated mixture snapshot batch: [field_count] fields is not a whole number of [DOGMOS_PIPENET_RECONCILE_RECORD_FIELDS]-field records.")
	var/record_count = field_count / DOGMOS_PIPENET_RECONCILE_RECORD_FIELDS
	// Records may be omitted, never invented. More back than went out means the service and this
	// caller disagree about the record layout, which would silently poison the cache.
	if(record_count > requested)
		CRASH("dogmosd returned [record_count] mixture snapshots for [requested] requested handles.")

	var/cached = 0
	for(var/record_index in 1 to record_count)
		var/record_start = (record_index - 1) * DOGMOS_PIPENET_RECONCILE_RECORD_FIELDS + 1
		var/slot = response_fields[record_start]
		var/generation = response_fields[record_start + 1]
		// Keyed by the exact handle, so a snapshot that went stale between the request and now is
		// simply never matched by lookup_mixture_snapshot_cache() rather than being served.
		var/list/snapshot = response_fields.Copy(record_start + 2, record_start + DOGMOS_PIPENET_RECONCILE_RECORD_FIELDS)
		store_mixture_snapshot_cache(slot, generation, snapshot)
		cached++

	return cached
