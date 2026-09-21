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

/** Owns synthetic stale-callback state, restoring before assertions or atmospheric cleanup. */
/datum/unit_test/dogmos_callback_fixture
	abstract_type = /datum/unit_test/dogmos_callback_fixture
	parent_type = /datum/unit_test/dogmos_admission_fixture
	/// Optional world turf whose identity the synthetic callback fixture overrides.
	var/turf/callback_identity_turf
	var/callback_original_generation

/datum/unit_test/dogmos_callback_fixture/Run()
	save_admission_fixture(list("dogmos_next_callback_sequence", "dogmos_pending_callback_batch", "dogmos_pending_callback_index", "dogmos_pending_callback_count", "dogmos_pending_service_callbacks", "dogmos_stale_callback_count"), list())
	var/failure
	try
		run_callback_fixture()
	catch(var/error)
		failure = "Synthetic callback fixture [type] raised [error]."
	restore_callback_fixture()
	if(failure)
		return Fail(failure, __FILE__, __LINE__)

/** The existing stale-callback assertion body, with cleanup owned by its caller. */
/datum/unit_test/dogmos_callback_fixture/proc/run_callback_fixture()
	return

/** Restore turf identity and the exact original callback batch and sequence list owners once. */
/datum/unit_test/dogmos_callback_fixture/proc/restore_callback_fixture()
	if(callback_identity_turf)
		callback_identity_turf.dogmos_registration_generation = callback_original_generation
		callback_identity_turf = null
	restore_admission_fixture()

/datum/unit_test/dogmos_callback_fixture/restore_atmos()
	restore_callback_fixture()
	return ..()

/datum/unit_test/dogmos_callback_fixture/Destroy()
	restore_callback_fixture()
	return ..()

/** Verifies callback turf resolution rejects stale generations without invoking gameplay handlers. */
/datum/unit_test/dogmos_service_callback_identity
	parent_type = /datum/unit_test/dogmos_callback_fixture

/datum/unit_test/dogmos_service_callback_identity/run_callback_fixture()
	var/turf/target = run_loc_floor_bottom_left
	var/original_generation = target.dogmos_registration_generation
	callback_identity_turf = target
	callback_original_generation = original_generation
	var/list/original_sequence = SSdogmos.dogmos_next_callback_sequence.Copy()
	var/original_stale_callbacks = SSdogmos.dogmos_stale_callback_count
	target.dogmos_registration_generation = 41
	var/slot = target.dogmos_service_slot()
	if(SSdogmos.resolve_turf(slot, 41) != target)
		target.dogmos_registration_generation = original_generation
		return Fail("Dogmos did not resolve a current turf identity.", __FILE__, __LINE__)
	if(!isnull(SSdogmos.resolve_turf(slot, 42)))
		target.dogmos_registration_generation = original_generation
		return Fail("Dogmos accepted a stale turf generation.", __FILE__, __LINE__)

	SSdogmos.dogmos_next_callback_sequence = list(1, 0, 0, 0)
	var/list/stale_callback = new/list(48)
	stale_callback[13] = 1
	stale_callback[14] = 0
	stale_callback[15] = 0
	stale_callback[16] = 0
	stale_callback[21] = 1
	stale_callback[22] = 4
	stale_callback[24] = slot % 65536
	stale_callback[25] = floor(slot / 65536)
	stale_callback[26] = 42
	SSdogmos.dispatch_general_callback(stale_callback, 13)
	if(SSdogmos.dogmos_stale_callback_count != original_stale_callbacks + 1)
		target.dogmos_registration_generation = original_generation
		SSdogmos.dogmos_next_callback_sequence = original_sequence
		return Fail("Dogmos did not count a rejected stale callback.", __FILE__, __LINE__)

	target.dogmos_registration_generation = original_generation
	SSdogmos.dogmos_next_callback_sequence = original_sequence
	SSdogmos.dogmos_stale_callback_count = original_stale_callbacks

/** Verifies callback sequence mismatches are diagnosed without advancing the expected sequence. */
/datum/unit_test/dogmos_service_callback_sequence_mismatch

/datum/unit_test/dogmos_service_callback_sequence_mismatch/Run()
	if(!hascall(SSdogmos, "callback_sequence_error"))
		return Fail("Dogmos has no non-mutating callback sequence validator.", __FILE__, __LINE__)

	var/list/expected_sequence = list(1, 0, 0, 0)
	var/list/callback_batch = new/list(48)
	var/offset = 13
	callback_batch[offset] = 2
	var/error_message = call(SSdogmos, "callback_sequence_error")(callback_batch, offset, expected_sequence)
	if(error_message != "Dogmos callback sequence mismatch at offset 13: expected 1:0:0:0, received 2:0:0:0.")
		return Fail("Dogmos returned an incomplete callback sequence diagnostic: [error_message]", __FILE__, __LINE__)
	if(expected_sequence[1] != 1 || expected_sequence[2] || expected_sequence[3] || expected_sequence[4])
		return Fail("Dogmos mutated the expected sequence while diagnosing a mismatch.", __FILE__, __LINE__)

#define DOGMOS_TEST_CALLBACK_HEADER_FIELDS 12
#define DOGMOS_TEST_CALLBACK_EVENT_FIELDS 36
#define DOGMOS_TEST_CALLBACK_EVENT_START 13
#define DOGMOS_TEST_CALLBACK_SCOPE_GENERAL 1
#define DOGMOS_TEST_CALLBACK_SCOPE_FIELD 8
#define DOGMOS_TEST_CALLBACK_KIND_FIELD 9
#define DOGMOS_TEST_CALLBACK_SUBJECT_SLOT_FIELD 11
#define DOGMOS_TEST_CALLBACK_SUBJECT_GENERATION_FIELD 13
#define DOGMOS_TEST_CALLBACK_TURF_DESTRUCTION_REQUEST 4

/** Verifies exhausted SSair budget prevents the first retained callback from dispatching. */
/datum/unit_test/dogmos_service_callback_budget
	parent_type = /datum/unit_test/dogmos_callback_fixture

/datum/unit_test/dogmos_service_callback_budget/run_callback_fixture()
	var/list/original_sequence = SSdogmos.dogmos_next_callback_sequence
	var/list/original_pending_batch = SSdogmos.dogmos_pending_callback_batch
	var/original_pending_index = SSdogmos.dogmos_pending_callback_index
	var/original_pending_count = SSdogmos.dogmos_pending_callback_count
	var/original_pending_service_callbacks = SSdogmos.dogmos_pending_service_callbacks
	var/original_stale_callbacks = SSdogmos.dogmos_stale_callback_count
	var/list/test_sequence = list(1, 0, 0, 0)
	var/list/callback_batch = new/list(DOGMOS_TEST_CALLBACK_HEADER_FIELDS + DOGMOS_TEST_CALLBACK_EVENT_FIELDS)
	var/offset = DOGMOS_TEST_CALLBACK_EVENT_START
	for(var/word_index in 1 to 4)
		callback_batch[offset + word_index - 1] = test_sequence[word_index]
	callback_batch[offset + DOGMOS_TEST_CALLBACK_SCOPE_FIELD] = DOGMOS_TEST_CALLBACK_SCOPE_GENERAL
	callback_batch[offset + DOGMOS_TEST_CALLBACK_KIND_FIELD] = DOGMOS_TEST_CALLBACK_TURF_DESTRUCTION_REQUEST
	callback_batch[offset + DOGMOS_TEST_CALLBACK_SUBJECT_SLOT_FIELD] = 0
	callback_batch[offset + DOGMOS_TEST_CALLBACK_SUBJECT_SLOT_FIELD + 1] = 0
	callback_batch[offset + DOGMOS_TEST_CALLBACK_SUBJECT_GENERATION_FIELD] = 0
	callback_batch[offset + DOGMOS_TEST_CALLBACK_SUBJECT_GENERATION_FIELD + 1] = 0

	SSdogmos.dogmos_next_callback_sequence = test_sequence
	SSdogmos.dogmos_pending_callback_batch = callback_batch
	SSdogmos.dogmos_pending_callback_index = 0
	SSdogmos.dogmos_pending_callback_count = 1
	SSdogmos.dogmos_pending_service_callbacks = 0
	process_atmos_callbacks(0)

	var/failure_message
	if(SSdogmos.dogmos_pending_callback_batch != callback_batch)
		failure_message = "Dogmos discarded a retained callback batch without callback budget."
	else if(SSdogmos.dogmos_pending_callback_index != 0)
		failure_message = "Dogmos advanced the retained callback cursor without callback budget."
	else if(SSdogmos.dogmos_next_callback_sequence[1] != 1)
		failure_message = "Dogmos consumed a callback sequence without callback budget."
	else if(SSdogmos.dogmos_stale_callback_count != original_stale_callbacks)
		failure_message = "Dogmos dispatched a stale callback without callback budget."
	else
		process_atmos_callbacks(100)
		if(SSdogmos.dogmos_pending_callback_batch)
			failure_message = "Dogmos did not clear a retained callback batch after dispatch."
		else if(SSdogmos.dogmos_next_callback_sequence[1] != 2)
			failure_message = "Dogmos did not consume the retained callback in sequence."
		else if(SSdogmos.dogmos_stale_callback_count != original_stale_callbacks + 1)
			failure_message = "Dogmos did not dispatch the retained stale callback with positive budget."

	SSdogmos.dogmos_next_callback_sequence = original_sequence
	SSdogmos.dogmos_pending_callback_batch = original_pending_batch
	SSdogmos.dogmos_pending_callback_index = original_pending_index
	SSdogmos.dogmos_pending_callback_count = original_pending_count
	SSdogmos.dogmos_pending_service_callbacks = original_pending_service_callbacks
	SSdogmos.dogmos_stale_callback_count = original_stale_callbacks
	if(failure_message)
		return Fail(failure_message, __FILE__, __LINE__)

#undef DOGMOS_TEST_CALLBACK_HEADER_FIELDS
#undef DOGMOS_TEST_CALLBACK_EVENT_FIELDS
#undef DOGMOS_TEST_CALLBACK_EVENT_START
#undef DOGMOS_TEST_CALLBACK_SCOPE_GENERAL
#undef DOGMOS_TEST_CALLBACK_SCOPE_FIELD
#undef DOGMOS_TEST_CALLBACK_KIND_FIELD
#undef DOGMOS_TEST_CALLBACK_SUBJECT_SLOT_FIELD
#undef DOGMOS_TEST_CALLBACK_SUBJECT_GENERATION_FIELD
#undef DOGMOS_TEST_CALLBACK_TURF_DESTRUCTION_REQUEST

#define DOGMOS_TEST_REACTION_EVENT_OFFSET 13
#define DOGMOS_TEST_REACTION_SUBJECT_SLOT_FIELD 11
#define DOGMOS_TEST_REACTION_SUBJECT_GENERATION_FIELD 13
#define DOGMOS_TEST_CALLBACK_REACTION_FINISHED 2

/** Verifies general reaction callbacks reject stale mixture generations at the identity boundary. */
/datum/unit_test/dogmos_service_general_reaction_subject
	parent_type = /datum/unit_test/dogmos_callback_fixture

/datum/unit_test/dogmos_service_general_reaction_subject/run_callback_fixture()
	var/turf/open/target = run_loc_floor_bottom_left
	var/datum/gas_mixture/mixture = target.air
	var/list/callback = new/list(48)
	callback[DOGMOS_TEST_REACTION_EVENT_OFFSET + DOGMOS_TEST_REACTION_SUBJECT_SLOT_FIELD] = mixture.dogmos_slot % 65536
	callback[DOGMOS_TEST_REACTION_EVENT_OFFSET + DOGMOS_TEST_REACTION_SUBJECT_SLOT_FIELD + 1] = floor(mixture.dogmos_slot / 65536)
	callback[DOGMOS_TEST_REACTION_EVENT_OFFSET + DOGMOS_TEST_REACTION_SUBJECT_GENERATION_FIELD] = mixture.dogmos_generation % 65536
	callback[DOGMOS_TEST_REACTION_EVENT_OFFSET + DOGMOS_TEST_REACTION_SUBJECT_GENERATION_FIELD + 1] = floor(mixture.dogmos_generation / 65536)
	var/target_slot = target.dogmos_service_slot()
	callback[DOGMOS_TEST_REACTION_EVENT_OFFSET + 15] = target_slot % 65536
	callback[DOGMOS_TEST_REACTION_EVENT_OFFSET + 16] = floor(target_slot / 65536)
	callback[DOGMOS_TEST_REACTION_EVENT_OFFSET + 17] = target.dogmos_registration_generation % 65536
	callback[DOGMOS_TEST_REACTION_EVENT_OFFSET + 18] = floor(target.dogmos_registration_generation / 65536)
	var/list/live_subject = SSdogmos.decode_general_reaction_subject(callback, DOGMOS_TEST_REACTION_EVENT_OFFSET)
	var/failure_message
	if(live_subject[1] != mixture)
		failure_message = "Dogmos rejected a live general-reaction mixture identity."
	callback[DOGMOS_TEST_REACTION_EVENT_OFFSET + DOGMOS_TEST_REACTION_SUBJECT_GENERATION_FIELD]++
	var/list/stale_subject = SSdogmos.decode_general_reaction_subject(callback, DOGMOS_TEST_REACTION_EVENT_OFFSET)
	if(!failure_message && stale_subject[1])
		failure_message = "Dogmos accepted a stale general-reaction mixture generation."
	var/original_stale_callbacks = SSdogmos.dogmos_stale_callback_count
	var/stale_dispatch_result = SSdogmos.dispatch_general_reaction_callback(callback, DOGMOS_TEST_REACTION_EVENT_OFFSET, DOGMOS_TEST_CALLBACK_REACTION_FINISHED)
	if(!failure_message && (!isnum(stale_dispatch_result) || stale_dispatch_result != FALSE))
		failure_message = "Dogmos did not explicitly discard a stale finished-reaction callback."
	if(!failure_message && SSdogmos.dogmos_stale_callback_count != original_stale_callbacks + 1)
		failure_message = "Dogmos did not count a discarded stale finished-reaction callback."
	SSdogmos.dogmos_stale_callback_count = original_stale_callbacks
	if(failure_message)
		return Fail(failure_message, __FILE__, __LINE__)

#undef DOGMOS_TEST_REACTION_EVENT_OFFSET
#undef DOGMOS_TEST_REACTION_SUBJECT_SLOT_FIELD
#undef DOGMOS_TEST_REACTION_SUBJECT_GENERATION_FIELD
#undef DOGMOS_TEST_CALLBACK_REACTION_FINISHED


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
