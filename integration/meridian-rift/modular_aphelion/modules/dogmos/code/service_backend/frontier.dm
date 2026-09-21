/** Adds an already validated, inactive member without repeating activation side effects. */
/datum/controller/subsystem/air/proc/dogmos_add_frontier_member(turf/active_turf)
	active_turfs += active_turf
	dogmos_note_frontier_add(active_turf)

/** Removes membership only; callers retain ownership of excited groups, visuals and walk cursors. */
/datum/controller/subsystem/air/proc/dogmos_remove_frontier_member(turf/active_turf)
	var/previous_count = length(active_turfs)
	active_turfs -= active_turf
	if(length(active_turfs) == previous_count)
		return FALSE
	dogmos_note_frontier_remove(active_turf)
	return TRUE

/** Clears the canonical list during setup while preserving existing list aliases. */
/datum/controller/subsystem/air/proc/dogmos_clear_active_frontier()
	active_turfs.Cut()
	dogmos_note_frontier_reset()

/** Replaces the desired frontier and schedules a bounded atomic publication. */
/datum/controller/subsystem/air/proc/dogmos_replace_active_frontier(list/replacement)
	active_turfs = replacement
	dogmos_note_frontier_reset()

/** Invalidates unpublished reconciliation without dropping world-sized scratch on this caller. */
/datum/controller/subsystem/air/proc/dogmos_note_frontier_reset()
	dogmos_frontier_source = active_turfs
	dogmos_frontier_revision = SSdogmos.increment_u64_words(dogmos_frontier_revision)
	dogmos_frontier_needs_rescan = TRUE
	dogmos_frontier_journal.Cut()

/** Records last-add order in bounded scratch; an acknowledged member must be removed before re-add. */
/datum/controller/subsystem/air/proc/dogmos_note_frontier_add(turf/active_turf)
	dogmos_frontier_revision = SSdogmos.increment_u64_words(dogmos_frontier_revision)
	if(dogmos_frontier_needs_rescan)
		return
	var/list/entry = dogmos_frontier_journal[active_turf]
	if(!entry)
		if(length(dogmos_frontier_journal) >= DOGMOS_TURF_BATCH_OPERATIONS)
			dogmos_frontier_needs_rescan = TRUE
			return
		var/list/old_pair = dogmos_committed_frontier?[active_turf]
		entry = list(old_pair?.Copy(), TRUE, !isnull(old_pair))
	else
		entry[2] = TRUE
		entry[3] = !isnull(entry[1])
		// A repeated add after removal takes the latest addition's position.
		dogmos_frontier_journal -= active_turf
	dogmos_frontier_journal[active_turf] = entry

/** Preserves the accepted handle even if ChangeTurf has already changed the referenced turf. */
/datum/controller/subsystem/air/proc/dogmos_note_frontier_remove(turf/active_turf)
	dogmos_frontier_revision = SSdogmos.increment_u64_words(dogmos_frontier_revision)
	if(dogmos_frontier_needs_rescan)
		return
	var/list/entry = dogmos_frontier_journal[active_turf]
	var/list/old_pair = entry ? entry[1] : dogmos_committed_frontier?[active_turf]
	if(!old_pair)
		// An unpublished insertion followed by removal has no service-visible effect.
		dogmos_frontier_journal -= active_turf
		return
	if(!entry)
		if(length(dogmos_frontier_journal) >= DOGMOS_TURF_BATCH_OPERATIONS)
			dogmos_frontier_needs_rescan = TRUE
			return
		entry = list(old_pair.Copy(), FALSE, FALSE)
	else
		entry[2] = FALSE
	dogmos_frontier_journal[active_turf] = entry

/** Allocates an epoch above both acknowledged state and abandoned upload attempts. */
/datum/controller/subsystem/air/proc/dogmos_next_frontier_epoch()
	var/list/high_water = dogmos_frontier_epoch
	for(var/word_index = 4; word_index >= 1; word_index--)
		if(dogmos_frontier_upload_epoch[word_index] > dogmos_frontier_epoch[word_index])
			high_water = dogmos_frontier_upload_epoch
			break
		if(dogmos_frontier_upload_epoch[word_index] < dogmos_frontier_epoch[word_index])
			break
	return SSdogmos.increment_u64_words(high_water)

/** Starts an upload and validates its exact epoch receipt. */
/datum/controller/subsystem/air/proc/dogmos_begin_frontier_upload(list/epoch, total)
	var/list/fields = epoch.Copy()
	fields += SSdogmos.split_u32_words(total)
	if(!SSdogmos.equal_u64_words(dogmos_frontier_begin(fields), epoch))
		stack_trace("dogmosd rejected or returned a malformed active-frontier begin response.")
		return FALSE
	return TRUE

/** Appends one bounded ordered handle batch and validates the exact accepted count. */
/datum/controller/subsystem/air/proc/dogmos_append_frontier_upload(list/epoch, offset, list/pairs)
	var/list/fields = epoch.Copy()
	fields += SSdogmos.split_u32_words(offset)
	for(var/turf/active_turf as anything in pairs)
		var/list/pair = pairs[active_turf]
		if(!dogmos_frontier_pair_is_valid(pair))
			return FALSE
		fields += SSdogmos.split_u32_words(pair[1])
		fields += SSdogmos.split_u32_words(pair[2])
	var/list/accepted = dogmos_frontier_append(fields)
	if(!SSdogmos.u32_words_are_valid(accepted) || SSdogmos.join_u32_words(accepted[1], accepted[2]) != length(pairs))
		stack_trace("dogmosd rejected an active-frontier append at offset [offset].")
		return FALSE
	return TRUE

/** Publishes only a complete upload with a matching epoch and member count. */
/datum/controller/subsystem/air/proc/dogmos_commit_frontier_upload(list/epoch, total)
	var/list/committed = dogmos_frontier_commit(epoch.Copy())
	if(!islist(committed) || length(committed) != 6 || !SSdogmos.equal_u64_words(committed.Copy(1, 5), epoch) || !SSdogmos.u32_words_are_valid(committed.Copy(5, 7)) || SSdogmos.join_u32_words(committed[5], committed[6]) != total)
		stack_trace("dogmosd returned a malformed active-frontier commit for candidate epoch [json_encode(epoch)].")
		return FALSE
	return TRUE

/** Visits at most max_entries members in one reconciliation step.
 * Returns null on failure, FALSE while pending, TRUE when reconciliation and retired cleanup finish.
 * Native Begin/Commit and topology flush retain their existing service-side costs.
 */
/datum/controller/subsystem/air/proc/dogmos_reconcile_frontier_chunk(max_entries = DOGMOS_TURF_BATCH_OPERATIONS)
	if(!isnum(max_entries) || !IS_FINITE(max_entries) || max_entries < 1 || max_entries > DOGMOS_TURF_BATCH_OPERATIONS || round(max_entries) != max_entries)
		return null
	if(length(dogmos_frontier_retired))
		// Removing from the tail avoids repeatedly shifting the entire remaining snapshot.
		var/retained = max(0, length(dogmos_frontier_retired) - max_entries)
		dogmos_frontier_retired.Cut(retained + 1)
		if(!retained)
			dogmos_frontier_retired = null
		return FALSE
	if(!dogmos_frontier_needs_rescan)
		return TRUE
	if(!isnull(dogmos_frontier_candidate) && !SSdogmos.equal_u64_words(dogmos_frontier_scan_revision, dogmos_frontier_revision))
		dogmos_frontier_retired = dogmos_frontier_candidate
		dogmos_frontier_candidate = null
		dogmos_frontier_scan_revision = null
		dogmos_frontier_upload_cursor = null
		return FALSE
	if(isnull(dogmos_frontier_candidate))
		dogmos_frontier_scan_revision = dogmos_frontier_revision.Copy()
		dogmos_frontier_scan_total = length(active_turfs)
		dogmos_frontier_scan_cursor = 0
		dogmos_frontier_upload_cursor = null
		dogmos_frontier_candidate = list()
		return FALSE
	if(dogmos_frontier_scan_cursor < dogmos_frontier_scan_total)
		var/end = min(dogmos_frontier_scan_cursor + max_entries, dogmos_frontier_scan_total)
		var/list/chunk = active_turfs.Copy(dogmos_frontier_scan_cursor + 1, end + 1)
		var/list/pairs = dogmos_prepare_frontier_pairs(chunk)
		if(isnull(pairs))
			return null
		// Registration can invalidate a replacement's identity. Do not collect a mixed snapshot.
		if(!SSdogmos.equal_u64_words(dogmos_frontier_scan_revision, dogmos_frontier_revision))
			return FALSE
		for(var/turf/active_turf as anything in pairs)
			dogmos_frontier_candidate[active_turf] = pairs[active_turf]
		dogmos_frontier_scan_cursor = end
		return FALSE
	// Source entries may repeat. Declare the unique count only after bounded collection finishes.
	var/unique_total = length(dogmos_frontier_candidate)
	if(isnull(dogmos_frontier_upload_cursor))
		dogmos_frontier_upload_epoch = dogmos_next_frontier_epoch()
		if(!dogmos_begin_frontier_upload(dogmos_frontier_upload_epoch, unique_total))
			return null
		dogmos_frontier_upload_cursor = 0
		return FALSE
	if(dogmos_frontier_upload_cursor < unique_total)
		var/end = min(dogmos_frontier_upload_cursor + max_entries, unique_total)
		var/list/pairs = dogmos_frontier_candidate.Copy(dogmos_frontier_upload_cursor + 1, end + 1)
		if(!dogmos_append_frontier_upload(dogmos_frontier_upload_epoch, dogmos_frontier_upload_cursor, pairs))
			return null
		dogmos_frontier_upload_cursor = end
		return FALSE
	if(!dogmos_commit_frontier_upload(dogmos_frontier_upload_epoch, unique_total))
		return null
	dogmos_frontier_epoch = dogmos_frontier_upload_epoch.Copy()
	dogmos_frontier_retired = dogmos_committed_frontier
	dogmos_committed_frontier = dogmos_frontier_candidate
	dogmos_frontier_candidate = null
	dogmos_frontier_scan_revision = null
	dogmos_frontier_upload_cursor = null
	dogmos_frontier_needs_rescan = FALSE
	dogmos_frontier_journal.Cut()
	return !length(dogmos_frontier_retired)

/** Compatibility entry point: bootstrap now advances one bounded reconciliation slice. */
/datum/controller/subsystem/air/proc/bootstrap_dogmos_frontier()
	if(dogmos_pending_frontier_epoch)
		CRASH("Attempted to replace the Dogmos frontier while a simulation cycle is pending.")
	return sync_dogmos_frontier()


/** Registers stale active turfs, flushes their topology, and returns validated frontier pairs. */
/datum/controller/subsystem/air/proc/dogmos_prepare_frontier_pairs(list/frontier_turfs)
	var/original_runtime_batching = SSdogmos.begin_runtime_topology_scope()
	try
		for(var/turf/open/active_turf as anything in frontier_turfs)
			if(!active_turf || !active_turf.air)
				SSdogmos.restore_runtime_topology_scope(original_runtime_batching)
				stack_trace("SSair active frontier contains an invalid turf reference.")
				return null
			if(!dogmos_frontier_turf_registration_is_current(active_turf))
				active_turf.register_dogmos_air()
			active_turf.__update_auxtools_turf_adjacency_info(world.maxx, world.maxy)
	catch(var/exception/error)
		SSdogmos.restore_runtime_topology_scope(original_runtime_batching)
		throw error
	SSdogmos.restore_runtime_topology_scope(original_runtime_batching)
	if(!SSdogmos.flush_turf_registration_batch())
		stack_trace("Dogmos topology remained blocked before active-frontier publication.")
		return null

	var/list/frontier_pairs = list()
	for(var/turf/open/active_turf as anything in frontier_turfs)
		var/datum/gas_mixture/mixture = active_turf.air
		var/generation = active_turf.dogmos_registration_generation
		var/slot = active_turf.dogmos_service_slot()
		var/list/pair = list(slot, generation)
		if(!dogmos_frontier_pair_is_valid(pair) || !dogmos_frontier_turf_registration_is_current(active_turf))
			stack_trace("Dogmos active frontier turf [active_turf.type] at [active_turf.x],[active_turf.y],[active_turf.z] remained invalid after registration catch-up: init_air=[active_turf.init_air], air=[!isnull(mixture)], generation=[generation], registered_mixture=[active_turf.dogmos_registered_mixture_slot]:[active_turf.dogmos_registered_mixture_generation], current_mixture=[mixture?.dogmos_slot]:[mixture?.dogmos_generation].")
			return null
		frontier_pairs[active_turf] = pair
	return frontier_pairs

/** Returns whether a frontier pair contains two positive exact IPC identities. */
/datum/controller/subsystem/air/proc/dogmos_frontier_pair_is_valid(list/pair)
	if(!islist(pair) || length(pair) != 2)
		return FALSE
	for(var/field in pair)
		if(!isnum(field) || !IS_FINITE(field) || field <= 0 || field > DOGMOS_MAX_EXACT_INTEGER || round(field) != field)
			return FALSE
	return TRUE

/** Returns whether an active turf has a valid current service identity. */
/datum/controller/subsystem/air/proc/dogmos_frontier_turf_registration_is_current(turf/open/active_turf)
	var/generation = active_turf?.dogmos_registration_generation
	return active_turf?.air && isnum(generation) && IS_FINITE(generation) \
		&& generation > 0 && generation <= DOGMOS_MAX_EXACT_INTEGER && round(generation) == generation

/** Returns whether a committed frontier pair matches the turf's current service identity.
 *
 * Arguments:
 * * active_turf - Turf whose current slot and generation are authoritative.
 * * committed_pair - Previously committed slot and generation.
 */
/datum/controller/subsystem/air/proc/dogmos_frontier_pair_is_current(turf/open/active_turf, list/committed_pair)
	return dogmos_frontier_turf_registration_is_current(active_turf) \
		&& islist(committed_pair) && length(committed_pair) == 2 \
		&& committed_pair[1] == active_turf.dogmos_service_slot() \
		&& committed_pair[2] == active_turf.dogmos_registration_generation

/** Publishes journaled membership in last-add order; unchanged cycles do no full-frontier discovery.
 * TRUE means no failure. Callers must pause while dogmos_frontier_sync_pending is set.
 */
/datum/controller/subsystem/air/proc/sync_dogmos_frontier()
	dogmos_frontier_sync_pending = FALSE
	if(dogmos_pending_frontier_epoch || !isnull(dogmos_pending_stage))
		return TRUE
	if(dogmos_frontier_source != active_turfs)
		dogmos_note_frontier_reset()
	if(isnull(dogmos_committed_frontier))
		dogmos_frontier_needs_rescan = TRUE
	if(dogmos_frontier_needs_rescan || length(dogmos_frontier_retired))
		var/reconciled = dogmos_reconcile_frontier_chunk()
		if(isnull(reconciled))
			return FALSE
		if(!reconciled)
			dogmos_frontier_sync_pending = TRUE
			return TRUE
	if(!length(dogmos_frontier_journal))
		dogmos_pending_frontier_epoch = dogmos_frontier_epoch.Copy()
		return TRUE
	var/list/added = list()
	var/list/removed_pairs = list()
	var/list/removed_turfs = list()
	for(var/turf/changed_turf as anything in dogmos_frontier_journal)
		var/list/entry = dogmos_frontier_journal[changed_turf]
		if(entry[1] && (!entry[2] || entry[3]))
			removed_pairs += list(entry[1])
			removed_turfs += changed_turf
		if(entry[2])
			added += changed_turf
	var/list/added_pairs_by_turf = list()
	if(length(added))
		var/list/preparation_revision = dogmos_frontier_revision.Copy()
		added_pairs_by_turf = dogmos_prepare_frontier_pairs(added)
		if(isnull(added_pairs_by_turf))
			return FALSE
		if(!SSdogmos.equal_u64_words(preparation_revision, dogmos_frontier_revision))
			dogmos_frontier_sync_pending = TRUE
			return TRUE
	if(length(removed_pairs))
		if(!dogmos_frontier_send_chunks(/proc/dogmos_frontier_remove, removed_pairs, "remove"))
			return FALSE
		for(var/turf/removed_turf as anything in removed_turfs)
			dogmos_committed_frontier -= removed_turf
	if(length(added))
		var/list/added_pairs = list()
		for(var/turf/added_turf as anything in added)
			added_pairs += list(added_pairs_by_turf[added_turf])
		if(!dogmos_frontier_send_chunks(/proc/dogmos_frontier_add, added_pairs, "add"))
			return FALSE
		for(var/turf/added_turf as anything in added)
			dogmos_committed_frontier[added_turf] = added_pairs_by_turf[added_turf]
	dogmos_frontier_journal.Cut()
	dogmos_pending_frontier_epoch = dogmos_frontier_epoch.Copy()
	return TRUE


/** Sends one incremental frontier mutation (add or remove) to dogmosd in bounded chunks. Each
 * chunk is its own atomic add/remove call (no begin/append/commit two-phase for this path), and
 * dogmosd requires a strictly increasing epoch per call - so the epoch is bumped once per chunk,
 * not once for the whole added/removed list. Removing an already-absent handle is not an error
 * (dogmosd tolerates it - see FrontierState::remove()'s doc comment), so only the add path
 * enforces an exact accepted-count match; a short remove count is expected, not a fault.
 */
/datum/controller/subsystem/air/proc/dogmos_frontier_send_chunks(mutate_proc, list/pairs, label)
	for(var/list/pair as anything in pairs)
		if(!dogmos_frontier_pair_is_valid(pair))
			log_game("Dogmos rejected a malformed incremental frontier [label] pair before service mutation.")
			return FALSE
	var/offset = 0
	var/pair_total = length(pairs)
	var/list/fields = list()
	for(var/list/pair as anything in pairs)
		fields += SSdogmos.split_u32_words(pair[1])
		fields += SSdogmos.split_u32_words(pair[2])
		offset++
		if((offset % DOGMOS_TURF_BATCH_OPERATIONS) != 0 && offset != pair_total)
			continue
		var/chunk_size = offset % DOGMOS_TURF_BATCH_OPERATIONS
		if(!chunk_size)
			chunk_size = DOGMOS_TURF_BATCH_OPERATIONS
		var/list/candidate_epoch = dogmos_next_frontier_epoch()
		var/list/chunk_fields = candidate_epoch.Copy()
		chunk_fields += fields
		var/list/response = call(mutate_proc)(chunk_fields)
		if(!SSdogmos.u32_words_are_valid(response))
			log_game("dogmosd returned a malformed incremental frontier [label] response at offset [offset - chunk_size].")
			return FALSE
		var/accepted = SSdogmos.join_u32_words(response[1], response[2])
		if(accepted > chunk_size || (mutate_proc == /proc/dogmos_frontier_add && accepted != chunk_size))
			log_game("dogmosd rejected an incremental frontier [label] chunk at offset [offset - chunk_size].")
			return FALSE
		dogmos_frontier_epoch = candidate_epoch
		fields = list()
	return TRUE
