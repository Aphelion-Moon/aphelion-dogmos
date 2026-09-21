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

/** Verifies runtime topology remains deferred for the full committed-frontier cycle. */
/datum/unit_test/dogmos_service_topology_stage_barrier

/datum/unit_test/dogmos_service_topology_stage_barrier/Run()
	var/list/original_pending_frontier = SSair.dogmos_pending_frontier_epoch
	var/deferrals_before = SSdogmos.dogmos_runtime_topology_deferrals
	SSair.dogmos_pending_frontier_epoch = list(1, 0, 0, 0)
	var/flushed = SSdogmos.flush_turf_registration_batch()
	var/deferrals_after = SSdogmos.dogmos_runtime_topology_deferrals
	SSair.dogmos_pending_frontier_epoch = original_pending_frontier
	SSdogmos.dogmos_runtime_topology_deferrals = deferrals_before
	if(flushed)
		return Fail("Dogmos flushed runtime topology while a committed frontier remained pending.", __FILE__, __LINE__)
	if(deferrals_after != deferrals_before + 1)
		return Fail("Dogmos did not count a committed-frontier topology deferral.", __FILE__, __LINE__)

/** Verifies mixture slots remain retired until the committed-frontier topology barrier. */
/datum/unit_test/dogmos_service_mixture_retirement_stage_barrier
	/// Mixture retired while the committed frontier is pending.
	var/datum/gas_mixture/retired_mixture
	/// Mixture used to detect premature slot reuse.
	var/datum/gas_mixture/replacement_mixture

/datum/unit_test/dogmos_service_mixture_retirement_stage_barrier/Run()
	var/reached_stage_boundary = FALSE
	for(var/attempt in 1 to DOGMOS_TEST_STAGE_BOUNDARY_ATTEMPTS)
		if(isnull(SSair.dogmos_pending_stage) && !SSair.dogmos_pending_frontier_epoch && SSdogmos.flush_turf_registration_batch())
			reached_stage_boundary = TRUE
			break
		sleep(SSair.wait)
	if(!reached_stage_boundary)
		return Fail("Dogmos did not reach a safe stage boundary before the mixture retirement test.", __FILE__, __LINE__)

	retired_mixture = new(CELL_VOLUME)
	var/retired_slot = retired_mixture.dogmos_slot
	SSair.dogmos_pending_frontier_epoch = list(1, 0, 0, 0)
	retired_mixture.__gasmixture_unregister()
	replacement_mixture = new(CELL_VOLUME)
	var/reused_pending_slot = replacement_mixture.dogmos_slot == retired_slot
	SSair.dogmos_pending_frontier_epoch = null
	SSdogmos.flush_turf_registration_batch()
	var/released_at_barrier = SSdogmos.dogmos_free_mixture_slots.Find(retired_slot)
	if(reused_pending_slot)
		return Fail("Dogmos reused a retired mixture slot while a committed frontier remained pending.", __FILE__, __LINE__)
	if(!released_at_barrier)
		return Fail("Dogmos did not release a retired mixture slot at the committed-frontier topology barrier.", __FILE__, __LINE__)

/datum/unit_test/dogmos_service_mixture_retirement_stage_barrier/Destroy()
	SSair.dogmos_pending_frontier_epoch = null
	SSdogmos.flush_turf_registration_batch()
	QDEL_NULL(retired_mixture)
	QDEL_NULL(replacement_mixture)
	return ..()

/** Verifies frontier identity includes the turf generation, not only the DM turf reference. */
/datum/unit_test/dogmos_service_frontier_generation_identity

/datum/unit_test/dogmos_service_frontier_generation_identity/Run()
	var/turf/open/target = run_loc_floor_bottom_left
	if(!istype(target) || isnull(target.dogmos_registration_generation))
		return Fail("The Dogmos frontier identity test requires a registered open turf.", __FILE__, __LINE__)
	var/list/current_pair = list(target.dogmos_service_slot(), target.dogmos_service_generation())
	if(!SSair.dogmos_frontier_pair_is_current(target, current_pair))
		return Fail("Dogmos rejected the turf's current frontier identity.", __FILE__, __LINE__)
	var/list/stale_pair = list(current_pair[1], current_pair[2] + 1)
	if(SSair.dogmos_frontier_pair_is_current(target, stale_pair))
		return Fail("Dogmos treated a mismatched turf generation as a current frontier identity.", __FILE__, __LINE__)

/** Verifies a rejected incremental frontier chunk cannot publish its candidate epoch. */
/datum/unit_test/dogmos_service_frontier_rejection_preserves_epoch

/datum/unit_test/dogmos_service_frontier_rejection_preserves_epoch/Run()
	var/list/original_epoch = SSair.dogmos_frontier_epoch
	var/list/start_epoch = list(41, 0, 0, 0)
	SSair.dogmos_frontier_epoch = start_epoch.Copy()
	var/accepted = SSair.dogmos_frontier_send_chunks(
		/proc/dogmos_test_reject_frontier_chunk,
		list(list(1, 1)),
		"test rejection",
	)
	var/epoch_changed = !SSdogmos.equal_u64_words(SSair.dogmos_frontier_epoch, start_epoch)
	SSair.dogmos_frontier_epoch = original_epoch
	if(accepted)
		return Fail("Dogmos accepted a malformed incremental frontier response.", __FILE__, __LINE__)
	if(epoch_changed)
		return Fail("Dogmos published a frontier epoch before the service accepted its chunk.", __FILE__, __LINE__)

/** Verifies frontier changes wait without publication while an older stage remains resumable. */
/datum/unit_test/dogmos_service_frontier_mutation_waits_for_pending_stage

/** Probes the deferred-mutation fence with a private snapshot, including before the first SSair cycle. */
/datum/unit_test/dogmos_service_frontier_mutation_waits_for_pending_stage/Run()
	var/reached_stage_boundary = FALSE
	for(var/attempt in 1 to DOGMOS_TEST_STAGE_BOUNDARY_ATTEMPTS)
		if(isnull(SSair.dogmos_pending_stage) && !SSair.dogmos_pending_frontier_epoch)
			reached_stage_boundary = TRUE
			break
		sleep(SSair.wait)
	if(!reached_stage_boundary)
		return Fail("Dogmos did not reach a safe stage boundary before the pending-stage frontier test.", __FILE__, __LINE__)

	// A focused run can start before the lazy committed frontier exists. Keep the injected
	// pending-stage fixture local and restore the original snapshot after probing the fence.
	var/list/original_committed_frontier = SSair.dogmos_committed_frontier
	SSair.dogmos_committed_frontier = isnull(original_committed_frontier) ? list() : original_committed_frontier.Copy()
	var/turf/open/target = run_loc_floor_bottom_left
	var/was_active = SSair.active_turfs.Find(target)
	var/list/original_pair = SSair.dogmos_committed_frontier[target]
	var/original_committed_count = length(SSair.dogmos_committed_frontier)
	var/list/original_epoch = SSair.dogmos_frontier_epoch.Copy()
	var/original_pending_stage = SSair.dogmos_pending_stage
	var/list/original_pending_frontier = SSair.dogmos_pending_frontier_epoch
	if(original_pair)
		SSair.dogmos_remove_frontier_member(target)
	else
		if(!SSair.active_turfs.Find(target))
			SSair.dogmos_add_frontier_member(target)
	SSair.dogmos_pending_stage = DOGMOS_TEST_STAGE_EQUALIZE
	SSair.dogmos_pending_frontier_epoch = original_epoch.Copy()
	var/synced = dogmos_sync_fixture_frontier()
	var/epoch_changed = !SSdogmos.equal_u64_words(SSair.dogmos_frontier_epoch, original_epoch)
	var/frontier_changed = length(SSair.dogmos_committed_frontier) != original_committed_count || SSair.dogmos_committed_frontier[target] != original_pair
	var/pending_changed = SSair.dogmos_pending_stage != DOGMOS_TEST_STAGE_EQUALIZE || !SSdogmos.equal_u64_words(SSair.dogmos_pending_frontier_epoch, original_epoch)
	if(was_active)
		if(!SSair.active_turfs.Find(target))
			SSair.dogmos_add_frontier_member(target)
	else
		SSair.dogmos_remove_frontier_member(target)
	SSair.dogmos_pending_stage = original_pending_stage
	SSair.dogmos_pending_frontier_epoch = original_pending_frontier
	SSair.dogmos_committed_frontier = original_committed_frontier
	SSair.dogmos_note_frontier_reset()
	if(!synced)
		return Fail("Dogmos rejected a deferred frontier mutation while an older stage was pending.", __FILE__, __LINE__)
	if(epoch_changed || frontier_changed || pending_changed)
		return Fail("Dogmos published or changed frontier state while an older stage was pending.", __FILE__, __LINE__)

/** Literal ordering and rejected-acknowledgment oracles for the bounded frontier journal. */
/datum/unit_test/dogmos_runtime_frontier_journal/Run()
	var/datum/controller/subsystem/air/recovery_test_copy/frontier_journal_probe/probe = allocate(/datum/controller/subsystem/air/recovery_test_copy/frontier_journal_probe)
	var/failure
	try
		if(!hascall(probe, "dogmos_note_frontier_add") || !hascall(probe, "dogmos_note_frontier_remove"))
			failure = "Frontier publication has no bounded membership journal; unchanged cycles still discover changes by a full rescan."
		else
			var/list/turfs = block(run_loc_floor_bottom_left, run_loc_floor_top_right)
			var/turf/open/turf_a = turfs[1]
			var/turf/open/turf_b = turfs[2]
			var/turf/open/turf_c = turfs[3]
			var/turf/open/turf_d = turfs[4]
			probe.fixture_pairs[turf_a] = list(1, 1)
			probe.fixture_pairs[turf_b] = list(2, 1)
			probe.fixture_pairs[turf_c] = list(3, 1)
			probe.fixture_pairs[turf_d] = list(4, 1)
			probe.active_turfs = list(turf_a, turf_b, turf_c)
			probe.dogmos_committed_frontier = list()
			for(var/turf/entry as anything in probe.active_turfs)
				probe.dogmos_committed_frontier[entry] = probe.fixture_pairs[entry].Copy()
			probe.service_order = list("1:1", "2:1", "3:1")
			probe.vars["dogmos_frontier_needs_rescan"] = FALSE
			probe.vars["dogmos_frontier_source"] = probe.active_turfs
			probe.active_turfs -= turf_b
			call(probe, "dogmos_note_frontier_remove")(turf_b)
			probe.active_turfs += turf_b
			call(probe, "dogmos_note_frontier_add")(turf_b)
			if(!probe.sync_dogmos_frontier() || json_encode(probe.service_order) != json_encode(list("1:1", "3:1", "2:1")))
				failure = "Remove/re-add lost the acknowledged member's new position."
			probe.dogmos_pending_frontier_epoch = null
			probe.active_turfs -= turf_a
			call(probe, "dogmos_note_frontier_remove")(turf_a)
			probe.fixture_pairs[turf_a] = list(1, 2)
			probe.active_turfs += turf_a
			call(probe, "dogmos_note_frontier_add")(turf_a)
			if(!failure && (!probe.sync_dogmos_frontier() || json_encode(probe.service_order) != json_encode(list("3:1", "2:1", "1:2"))))
				failure = "Replacement did not retire the old handle and append its new generation."
			probe.dogmos_pending_frontier_epoch = null
			var/list/epoch_before = probe.dogmos_frontier_epoch.Copy()
			var/calls_before = probe.native_calls
			probe.active_turfs += turf_d
			call(probe, "dogmos_note_frontier_add")(turf_d)
			probe.active_turfs -= turf_d
			call(probe, "dogmos_note_frontier_remove")(turf_d)
			probe.pair_checks = 0
			if(!failure && (!probe.sync_dogmos_frontier() || probe.native_calls != calls_before || probe.pair_checks || !SSdogmos.equal_u64_words(probe.dogmos_frontier_epoch, epoch_before)))
				failure = "An unpublished add/remove or unchanged cycle performed discovery or native publication."
			probe.dogmos_pending_frontier_epoch = null
			probe.active_turfs += turf_d
			call(probe, "dogmos_note_frontier_add")(turf_d)
			probe.reject_next_add = TRUE
			if(!failure && (probe.sync_dogmos_frontier() || probe.dogmos_committed_frontier[turf_d] || !SSdogmos.equal_u64_words(probe.dogmos_frontier_epoch, epoch_before)))
				failure = "A rejected addition advanced its acknowledged epoch or handle."
	catch(var/exception/error)
		failure = "Frontier journal fixture raised [error.name]."
	probe.active_turfs = list()
	probe.dogmos_committed_frontier = list()
	probe.fixture_pairs = list()
	qdel(probe)
	if(failure)
		return Fail(failure, __FILE__, __LINE__)

/** Isolated transport oracle; its fixed replies never alter the loaded world's native frontier. */
/datum/controller/subsystem/air/recovery_test_copy/frontier_journal_probe
	/// Fixture-defined handles, independent of live turf registration.
	var/list/fixture_pairs = list()
	/// Simulated service order, changed only by accepted wire operations.
	var/list/service_order = list()
	/// Count of attempted wire mutations.
	var/native_calls = 0
	/// Count of acknowledged-member discovery checks.
	var/pair_checks = 0
	/// Reject one addition before accepting any state.
	var/reject_next_add = FALSE
	/// Pending upload order, invisible until an accepted commit.
	var/list/upload_order = list()
	/// Last begin epoch accepted by the fixture.
	var/list/accepted_upload_epoch
	/// Exact unique-handle count declared by Begin.
	var/upload_expected = 0
	/// Largest preparation batch observed by the transport oracle.
	var/max_prepared = 0
	/// Reject one full-upload operation before accepting its state.
	var/reject_upload_phase

/datum/controller/subsystem/air/recovery_test_copy/frontier_journal_probe/dogmos_prepare_frontier_pairs(list/frontier_turfs)
	max_prepared = max(max_prepared, length(frontier_turfs))
	var/list/result = list()
	for(var/turf/entry as anything in frontier_turfs)
		result[entry] = fixture_pairs[entry].Copy()
	return result

/datum/controller/subsystem/air/recovery_test_copy/frontier_journal_probe/dogmos_frontier_pair_is_current(turf/open/active_turf, list/committed_pair)
	pair_checks++
	return json_encode(committed_pair) == json_encode(fixture_pairs[active_turf])

/datum/controller/subsystem/air/recovery_test_copy/frontier_journal_probe/dogmos_frontier_send_chunks(mutate_proc, list/pairs, label)
	native_calls++
	if(label == "add" && reject_next_add)
		reject_next_add = FALSE
		return FALSE
	for(var/list/pair as anything in pairs)
		var/key = "[pair[1]]:[pair[2]]"
		if(label == "remove")
			service_order -= key
		else if(!(key in service_order))
			service_order += key
	dogmos_frontier_epoch = SSdogmos.increment_u64_words(dogmos_frontier_epoch)
	return TRUE

/** Models atomic upload visibility without using the world's service frontier. */
/datum/controller/subsystem/air/recovery_test_copy/frontier_journal_probe/dogmos_begin_frontier_upload(list/epoch, total)
	native_calls++
	if(reject_upload_phase == "begin" || SSdogmos.equal_u64_words(epoch, accepted_upload_epoch))
		return FALSE
	accepted_upload_epoch = epoch.Copy()
	upload_expected = total
	upload_order = list()
	return TRUE

/datum/controller/subsystem/air/recovery_test_copy/frontier_journal_probe/dogmos_append_frontier_upload(list/epoch, offset, list/pairs)
	native_calls++
	if(reject_upload_phase == "append" || !SSdogmos.equal_u64_words(epoch, accepted_upload_epoch) || offset != length(upload_order) || offset + length(pairs) > upload_expected)
		return FALSE
	var/list/incoming = list()
	for(var/turf/entry as anything in pairs)
		var/list/pair = pairs[entry]
		var/key = "[pair[1]]:[pair[2]]"
		if((key in upload_order) || (key in incoming))
			return FALSE
		incoming += key
	upload_order += incoming
	return TRUE

/datum/controller/subsystem/air/recovery_test_copy/frontier_journal_probe/dogmos_commit_frontier_upload(list/epoch, total)
	native_calls++
	if(reject_upload_phase == "commit" || !SSdogmos.equal_u64_words(epoch, accepted_upload_epoch) || length(upload_order) != total || total != upload_expected)
		return FALSE
	service_order = upload_order.Copy()
	return TRUE

/** A reused turf ref may lose all identity fields before AfterChange marks its replacement. */
/datum/unit_test/dogmos_runtime_frontier_journal/reset_identity/Run()
	var/list/turfs = block(run_loc_floor_bottom_left, run_loc_floor_top_right)
	var/turf/open/target = turfs[1]
	var/turf/open/other = turfs[2]
	var/list/original_active = SSair.active_turfs
	var/list/original_source = SSair.dogmos_frontier_source
	var/list/original_journal = SSair.dogmos_frontier_journal
	var/list/original_revision = SSair.dogmos_frontier_revision
	var/original_needs_rescan = SSair.dogmos_frontier_needs_rescan
	var/original_generation = target.dogmos_registration_generation
	var/original_mixture_slot = target.dogmos_registered_mixture_slot
	var/original_mixture_generation = target.dogmos_registered_mixture_generation
	var/failure
	try
		SSair.dogmos_frontier_journal = list()
		SSair.dogmos_replace_active_frontier(list(target, other))
		var/list/before_revision = SSair.dogmos_frontier_revision.Copy()
		// Model the reset that happens before AfterChange, without native registration or turf deletion.
		target.dogmos_registration_generation = null
		target.mark_dogmos_turf_replacement()
		if(SSair.active_turfs[1] != other || SSair.active_turfs[2] != target || SSdogmos.equal_u64_words(before_revision, SSair.dogmos_frontier_revision))
			failure = "Replacement after an identity reset did not reorder membership and invalidate a pending upload."
	catch(var/exception/error)
		failure = "Reset-identity frontier fixture raised [error.name]."
	target.dogmos_registration_generation = original_generation
	target.dogmos_registered_mixture_slot = original_mixture_slot
	target.dogmos_registered_mixture_generation = original_mixture_generation
	SSair.dogmos_replace_active_frontier(original_active)
	SSair.dogmos_frontier_source = original_source
	SSair.dogmos_frontier_journal = original_journal
	SSair.dogmos_frontier_revision = original_revision
	SSair.dogmos_frontier_needs_rescan = original_needs_rescan
	if(failure)
		return Fail(failure, __FILE__, __LINE__)

/** Exercises the real ChangeTurf hook and accepted shim/service frontier receipts. */
/datum/unit_test/dogmos_runtime_frontier_journal/native_replacement/Run()
	if(!dogmos_wait_for_stage_boundary())
		return
	var/list/turfs = allocate_turf_pair()
	var/turf/open/target = turfs[1]
	var/turf/open/other = turfs[2]
	var/original_type = target.type
	var/replacement_type = original_type == /turf/open/floor/plating ? /turf/open/floor/iron : /turf/open/floor/plating
	var/list/original_active = SSair.active_turfs
	var/original_can_fire = SSair.can_fire
	var/original_target_excited = target.excited
	var/original_other_excited = other.excited
	var/failure
	var/restored = FALSE
	SSair.can_fire = FALSE
	try
		target.excited = TRUE
		other.excited = TRUE
		SSair.dogmos_replace_active_frontier(list(target, other))
		if(!dogmos_sync_fixture_frontier())
			failure = "The real replacement fixture could not publish its initial frontier."
		else
			var/list/old_pair = SSair.dogmos_committed_frontier[target].Copy()
			SSair.dogmos_pending_frontier_epoch = null
			target = target.ChangeTurf(replacement_type, flags = CHANGETURF_INHERIT_AIR | CHANGETURF_RECALC_ADJACENT)
			if(length(SSair.active_turfs) != 2 || SSair.active_turfs[1] != other || SSair.active_turfs[2] != target)
				failure = "ChangeTurf did not preserve the other member and append the replacement."
			if(!dogmos_sync_fixture_frontier() || !SSair.dogmos_frontier_pair_is_current(target, SSair.dogmos_committed_frontier[target]) || json_encode(old_pair) == json_encode(SSair.dogmos_committed_frontier[target]))
				failure = "Real replacement publication did not retire the acknowledged old handle."
		SSair.dogmos_pending_frontier_epoch = null
		target = target.ChangeTurf(original_type, flags = CHANGETURF_INHERIT_AIR | CHANGETURF_RECALC_ADJACENT)
		SSair.dogmos_replace_active_frontier(original_active)
		restored = dogmos_sync_fixture_frontier()
		SSair.dogmos_pending_frontier_epoch = null
	catch(var/exception/error)
		failure = "Native frontier replacement fixture raised [error.name]."
	target.excited = original_target_excited
	other.excited = original_other_excited
	SSair.dogmos_replace_active_frontier(original_active)
	SSair.can_fire = original_can_fire
	if(!restored)
		return dogmos_abort_fixture(failure || "Native replacement fixture failed to restore the service frontier.")
	if(failure)
		return Fail(failure, __FILE__, __LINE__)

/** The 513th distinct change falls back to bounded reconciliation with exact last-add order. */
/datum/unit_test/dogmos_runtime_frontier_journal/overflow/Run()
	var/datum/controller/subsystem/air/recovery_test_copy/frontier_journal_probe/probe = allocate(/datum/controller/subsystem/air/recovery_test_copy/frontier_journal_probe)
	var/failure
	try
		var/list/turfs = block(locate(1, 1, 1), locate(23, 23, 1))
		probe.dogmos_committed_frontier = list()
		probe.dogmos_frontier_source = probe.active_turfs
		probe.dogmos_frontier_needs_rescan = FALSE
		for(var/index in 1 to 513)
			var/turf/entry = turfs[index]
			probe.fixture_pairs[entry] = list(index, 1)
			probe.dogmos_add_frontier_member(entry)
		if(!probe.dogmos_frontier_needs_rescan || length(probe.dogmos_frontier_journal) != 512)
			failure = "513 changes did not retain at most 512 journal records and schedule reconciliation."
		if(!failure && (!probe.sync_dogmos_frontier() || !probe.dogmos_frontier_sync_pending || length(probe.service_order) || probe.dogmos_pending_frontier_epoch))
			failure = "Starting an upload exposed an incomplete frontier to simulation."
		var/list/abandoned_epoch = probe.dogmos_frontier_upload_epoch.Copy()
		if(!failure && (!probe.sync_dogmos_frontier() || probe.dogmos_frontier_scan_cursor != 512 || length(probe.service_order) || probe.native_calls))
			failure = "Reconciliation did not stop at its 512-member slice before publication."
		// Change between collection slices, before declaring the unique wire count.
		var/turf/first = turfs[1]
		probe.dogmos_remove_frontier_member(first)
		probe.fixture_pairs[first] = list(1, 2)
		probe.dogmos_add_frontier_member(first)
		if(!failure && (!probe.sync_dogmos_frontier() || length(probe.dogmos_frontier_candidate) || length(probe.service_order)))
			failure = "A membership change between slices did not invalidate the unpublished upload."
		var/retired_before = length(probe.dogmos_frontier_retired)
		if(!failure && (probe.dogmos_reconcile_frontier_chunk(32) != FALSE || length(probe.dogmos_frontier_retired) != retired_before - 32))
			failure = "Retired snapshot cleanup did not respect its 32-entry slice."
		var/complete = FALSE
		for(var/chunk in 1 to 64)
			if(failure || !probe.sync_dogmos_frontier())
				break
			if(!probe.dogmos_frontier_sync_pending)
				complete = TRUE
				break
		var/list/expected = list()
		for(var/index in 2 to 513)
			expected += "[index]:1"
		expected += "1:2"
		if(!failure && (!complete || probe.max_prepared > 512 || json_encode(probe.service_order) != json_encode(expected) || SSdogmos.equal_u64_words(probe.dogmos_frontier_epoch, abandoned_epoch)))
			failure = "Restarted reconciliation lost canonical order, reused an upload epoch, or exceeded its preparation bound."
		probe.dogmos_pending_frontier_epoch = null
		var/calls_before = probe.native_calls
		probe.pair_checks = 0
		if(!failure && (!probe.sync_dogmos_frontier() || probe.pair_checks || probe.native_calls != calls_before))
			failure = "The first unchanged cycle after overflow performed discovery or publication."
	catch(var/exception/error)
		failure = "Frontier overflow fixture raised [error.name]."
	qdel(probe)
	if(failure)
		return Fail(failure, __FILE__, __LINE__)

/** Legacy lists can contain duplicate turfs within a slice or across the 512-entry boundary. */
/datum/unit_test/dogmos_runtime_frontier_journal/duplicate_members/Run()
	for(var/unique_count in list(0, 1, 513))
		var/datum/controller/subsystem/air/recovery_test_copy/frontier_journal_probe/probe = allocate(/datum/controller/subsystem/air/recovery_test_copy/frontier_journal_probe)
		var/list/turfs = block(locate(1, 1, 1), locate(23, 23, 1))
		var/list/expected = list()
		for(var/index in 1 to unique_count)
			var/turf/entry = turfs[index]
			probe.fixture_pairs[entry] = list(index, 1)
			probe.dogmos_add_frontier_member(entry)
			expected += "[index]:1"
		if(unique_count)
			probe.dogmos_add_frontier_member(turfs[1])
		var/original_length = length(probe.active_turfs)
		var/failure
		var/complete = FALSE
		try
			for(var/chunk in 1 to 32)
				if(!probe.sync_dogmos_frontier())
					failure = "Reconciliation rejected [unique_count] unique turfs plus a duplicate; source entries were used as wire offsets or count."
					break
				if(!probe.dogmos_frontier_sync_pending)
					complete = TRUE
					break
			if(!failure && (!complete || json_encode(probe.service_order) != json_encode(expected) || probe.max_prepared > 512 || length(probe.active_turfs) != original_length))
				failure = "Duplicate reconciliation changed canonical first-occurrence order, the input list, or its work bound."
		catch(var/exception/error)
			failure = "Duplicate frontier fixture raised [error.name]."
		qdel(probe)
		if(failure)
			return Fail(failure, __FILE__, __LINE__)

/** A mutation after an accepted wire slice must abandon it and use a new epoch. */
/datum/unit_test/dogmos_runtime_frontier_journal/upload_mutation/Run()
	var/datum/controller/subsystem/air/recovery_test_copy/frontier_journal_probe/probe = allocate(/datum/controller/subsystem/air/recovery_test_copy/frontier_journal_probe)
	var/list/turfs = block(locate(1, 1, 1), locate(23, 23, 1))
	for(var/index in 1 to 513)
		var/turf/entry = turfs[index]
		probe.fixture_pairs[entry] = list(index, 1)
		probe.dogmos_add_frontier_member(entry)
	var/failure
	try
		for(var/chunk in 1 to 16)
			if(!probe.sync_dogmos_frontier())
				failure = "Upload mutation fixture could not prepare its first slice."
				break
			if(length(probe.upload_order) == 512)
				break
		if(!failure && (length(probe.upload_order) != 512 || length(probe.service_order)))
			failure = "Upload did not expose a bounded, unpublished first wire slice."
		var/list/abandoned_epoch = probe.dogmos_frontier_upload_epoch.Copy()
		var/turf/first = turfs[1]
		probe.dogmos_remove_frontier_member(first)
		probe.fixture_pairs[first] = list(1, 2)
		probe.dogmos_add_frontier_member(first)
		if(!failure && (!probe.sync_dogmos_frontier() || !isnull(probe.dogmos_frontier_candidate) || length(probe.service_order)))
			failure = "A change after the first accepted slice did not invalidate the candidate."
		var/complete = FALSE
		for(var/chunk in 1 to 32)
			if(failure || !probe.sync_dogmos_frontier())
				break
			if(!probe.dogmos_frontier_sync_pending)
				complete = TRUE
				break
		var/list/expected = list()
		for(var/index in 2 to 513)
			expected += "[index]:1"
		expected += "1:2"
		if(!failure && (!complete || json_encode(probe.service_order) != json_encode(expected) || SSdogmos.equal_u64_words(abandoned_epoch, probe.dogmos_frontier_epoch)))
			failure = "Restart after an accepted slice lost generation/order or reused its epoch."
	catch(var/exception/error)
		failure = "Upload mutation fixture raised [error.name]."
	qdel(probe)
	if(failure)
		return Fail(failure, __FILE__, __LINE__)

/** Exercise duplicate collapse through the real shim and service, including a second source slice. */
/datum/unit_test/dogmos_runtime_frontier_journal/native_duplicates/Run()
	if(!dogmos_wait_for_stage_boundary())
		return
	var/list/turfs = allocate_turf_pair()
	var/list/original_active = SSair.active_turfs
	var/original_can_fire = SSair.can_fire
	var/list/repeated = list()
	for(var/index in 1 to 513)
		repeated += turfs[1]
	repeated += turfs[2]
	var/failure
	var/restored = FALSE
	SSair.can_fire = FALSE
	try
		SSair.dogmos_replace_active_frontier(repeated)
		if(!dogmos_sync_fixture_frontier())
			failure = "The real service rejected a frontier containing repeated source turfs."
		else if(length(SSair.dogmos_committed_frontier) != 2 || SSair.dogmos_committed_frontier[1] != turfs[1] || SSair.dogmos_committed_frontier[2] != turfs[2] || length(repeated) != 514)
			failure = "Native duplicate publication changed first-occurrence order or the legacy input list."
		SSair.dogmos_pending_frontier_epoch = null
		SSair.dogmos_replace_active_frontier(original_active)
		restored = dogmos_sync_fixture_frontier()
		SSair.dogmos_pending_frontier_epoch = null
	catch(var/exception/error)
		failure = "Native duplicate frontier fixture raised [error.name]."
	SSair.dogmos_replace_active_frontier(original_active)
	SSair.can_fire = original_can_fire
	if(!restored)
		return dogmos_abort_fixture(failure || "Native duplicate fixture failed to restore the service frontier.")
	if(failure)
		return Fail(failure, __FILE__, __LINE__)

/** Rejected upload receipts must never publish a candidate epoch or membership. */
/datum/unit_test/dogmos_runtime_frontier_journal/rejected_upload/Run()
	var/failure
	for(var/phase in list("begin", "append", "commit"))
		var/datum/controller/subsystem/air/recovery_test_copy/frontier_journal_probe/probe = allocate(/datum/controller/subsystem/air/recovery_test_copy/frontier_journal_probe)
		var/turf/entry = run_loc_floor_bottom_left
		probe.fixture_pairs[entry] = list(1, 1)
		probe.dogmos_add_frontier_member(entry)
		probe.reject_upload_phase = phase
		var/rejected = FALSE
		try
			for(var/chunk in 1 to 8)
				if(!probe.sync_dogmos_frontier())
					rejected = TRUE
					break
			if(!rejected || length(probe.service_order) || length(probe.dogmos_committed_frontier) || probe.dogmos_pending_frontier_epoch || !SSdogmos.equal_u64_words(probe.dogmos_frontier_epoch, list(0, 0, 0, 0)))
				failure = "Rejected [phase] published or acknowledged an incomplete frontier."
		catch(var/exception/error)
			failure = "Rejected frontier [phase] fixture raised [error.name]."
		qdel(probe)
		if(failure)
			return Fail(failure, __FILE__, __LINE__)

/** Verifies a queued turf heat write is readable before its deferred service flush. */
/datum/unit_test/dogmos_service_pending_turf_heat_read_after_write

/datum/unit_test/dogmos_service_pending_turf_heat_read_after_write/Run()
	var/turf/open/target = run_loc_floor_bottom_left
	var/slot = target.dogmos_service_slot()
	var/generation = target.dogmos_service_generation()
	var/slot_key = "[slot]"
	var/list/original_pending_heat = SSdogmos.dogmos_pending_turf_heat[slot_key]
	SSdogmos.dogmos_pending_turf_heat[slot_key] = list(slot, generation, TRUE, 777, target.thermal_conductivity, target.heat_capacity, FALSE)
	var/observed_temperature = target.return_temperature()
	if(original_pending_heat)
		SSdogmos.dogmos_pending_turf_heat[slot_key] = original_pending_heat
	else
		SSdogmos.dogmos_pending_turf_heat.Remove(slot_key)
	if(observed_temperature != 777)
		return Fail("Dogmos returned [observed_temperature]K instead of the queued 777K turf heat write.", __FILE__, __LINE__)

/** Verifies an explicit breath-sized removal preserves the requested amount. */
/datum/unit_test/dogmos_service_breath_sized_removal

/datum/unit_test/dogmos_service_breath_sized_removal/Run()
	var/obj/item/tank/internals/emergency_oxygen/tank = allocate(/obj/item/tank/internals/emergency_oxygen)
	var/source_moles = tank.air_contents.total_moles()
	var/source_pressure = tank.air_contents.return_pressure()
	var/source_temperature = tank.air_contents.return_temperature()
	var/requested_moles = tank.distribute_pressure * BREATH_VOLUME / (R_IDEAL_GAS_EQUATION * tank.air_contents.return_temperature())
	var/datum/gas_mixture/removed = tank.remove_air_volume(BREATH_VOLUME)
	var/observed_moles = removed?.get_moles(/datum/gas/oxygen)
	if(abs(observed_moles - QUANTIZE(requested_moles)) > MOLAR_ACCURACY)
		return Fail("Dogmos removed [observed_moles] mol instead of the requested [requested_moles] mol breath from [source_moles] mol at [source_pressure] kPa and [source_temperature]K.", __FILE__, __LINE__)

/** Verifies a stage request defers while another service stage remains pending. */
/datum/unit_test/dogmos_service_foreign_pending_stage_defers

/datum/unit_test/dogmos_service_foreign_pending_stage_defers/Run()
	var/original_pending_stage = SSair.dogmos_pending_stage
	var/list/original_pending_frontier = SSair.dogmos_pending_frontier_epoch
	var/list/sentinel_frontier = list(41, 0, 0, 0)
	SSair.dogmos_pending_stage = DOGMOS_TEST_STAGE_EXCITED_GROUPS
	SSair.dogmos_pending_frontier_epoch = sentinel_frontier.Copy()
	var/deferred = SSair.dogmos_run_stage(DOGMOS_TEST_STAGE_TURF_HEAT, 1)
	var/stage_changed = SSair.dogmos_pending_stage != DOGMOS_TEST_STAGE_EXCITED_GROUPS
	var/frontier_changed = !SSdogmos.equal_u64_words(SSair.dogmos_pending_frontier_epoch, sentinel_frontier)
	SSair.dogmos_pending_stage = original_pending_stage
	SSair.dogmos_pending_frontier_epoch = original_pending_frontier
	if(!deferred || stage_changed || frontier_changed)
		return Fail("Dogmos did not defer a foreign stage without changing the active stage identity.", __FILE__, __LINE__)

/** Verifies frontier preparation repairs an active turf whose normal registration was missed. */
/datum/unit_test/dogmos_service_frontier_registration_catchup

/datum/unit_test/dogmos_service_frontier_registration_catchup/Run()
	var/reached_stage_boundary = FALSE
	for(var/attempt in 1 to DOGMOS_TEST_STAGE_BOUNDARY_ATTEMPTS)
		if(isnull(SSair.dogmos_pending_stage) && !SSair.dogmos_pending_frontier_epoch && SSdogmos.flush_turf_registration_batch())
			reached_stage_boundary = TRUE
			break
		sleep(SSair.wait)
	if(!reached_stage_boundary)
		return Fail("Dogmos did not reach a safe stage boundary before the frontier registration catch-up test.", __FILE__, __LINE__)

	var/turf/open/target = run_loc_floor_bottom_left
	if(!istype(target) || !target.air)
		return Fail("The Dogmos frontier registration catch-up test requires an atmosphere-enabled open turf.", __FILE__, __LINE__)
	var/list/original_epoch = SSair.dogmos_frontier_epoch.Copy()
	var/list/original_committed_frontier = SSair.dogmos_committed_frontier
	target.dogmos_registration_generation = null
	target.dogmos_registered_mixture_slot = null
	target.dogmos_registered_mixture_generation = null
	var/list/prepared = SSair.dogmos_prepare_frontier_pairs(list(target))
	var/list/pair = prepared?[target]
	if(!SSair.dogmos_frontier_pair_is_valid(pair))
		return Fail("Dogmos did not repair the active turf's missing service generation before frontier publication.", __FILE__, __LINE__)
	if(pair[2] != target.dogmos_registration_generation || !target.dogmos_air_registration_is_current())
		return Fail("Dogmos prepared a frontier pair that did not match the repaired turf registration.", __FILE__, __LINE__)
	if(!SSdogmos.equal_u64_words(SSair.dogmos_frontier_epoch, original_epoch) || SSair.dogmos_committed_frontier != original_committed_frontier)
		return Fail("Dogmos published frontier state during registration catch-up.", __FILE__, __LINE__)


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
