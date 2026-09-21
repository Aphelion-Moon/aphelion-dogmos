#if defined(UNIT_TESTS) || defined(SPACEMAN_DMM)


#include "../shift_start_performance_test.dm"

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

/** Returns a malformed frontier response without touching the production service. */
/proc/dogmos_test_reject_frontier_chunk(list/fields)
	return null

/** Checks fixed-width observation decoding without depending on wall-clock timing. */
/datum/unit_test/dogmos_job_observations/Run()
	var/list/words = new/list(236)
	for(var/index in 1 to 236)
		words[index] = 0
	words[183] = 4660
	words[184] = 22136
	words[185] = 39612
	words[186] = 65535
	words[187] = 3
	words[189] = 16960
	words[190] = 15 // Exactly one millisecond in nanoseconds.
	for(var/index in 193 to 196)
		words[index] = 65535
	words[197] = 33920
	words[198] = 30 // Exactly two milliseconds.
	words[228] = 65535 // Retry high word must survive export.
	var/list/decoded = SSdogmos.decode_job_observations(words)
	if(!decoded || decoded["status"] != 3 || decoded["age_ms"] != 1 || decoded["prepare_total_ms"] != 2)
		return Fail("Job observation positions or display durations changed.", __FILE__, __LINE__)
	if(!SSdogmos.equal_u64_words(decoded["job_words"], list(4660, 22136, 39612, 65535)) || !SSdogmos.equal_u64_words(decoded["prepare_calls_words"], list(65535, 65535, 65535, 65535)))
		return Fail("Job identity or cumulative counters lost exact high words.", __FILE__, __LINE__)
	if(!SSdogmos.equal_u64_words(decoded["publication_retries_words"], list(0, 0, 0, 65535)) || length(decoded["raw_words"]) != 54)
		return Fail("The observation export lost raw retry or timing words.", __FILE__, __LINE__)
	words[183] = 0
	if(!SSdogmos.equal_u64_words(decoded["job_words"], list(4660, 22136, 39612, 65535)))
		return Fail("The returned observation aliases its source buffer.", __FILE__, __LINE__)
	if(SSdogmos.decode_job_observations(null))
		return Fail("A missing observation was accepted.", __FILE__, __LINE__)
	for(var/list/bad in list(words.Copy(1, 236), words + list(0)))
		if(SSdogmos.decode_job_observations(bad))
			return Fail("A wrong-length observation was accepted.", __FILE__, __LINE__)
	for(var/invalid_word in list(null, "1", -1, 0.5, 65536))
		var/list/bad = words.Copy()
		bad[236] = invalid_word
		if(SSdogmos.decode_job_observations(bad))
			return Fail("An invalid exact observation word was accepted.", __FILE__, __LINE__)
	for(var/invalid_status in list(0, 7, 65535))
		var/list/bad = words.Copy()
		bad[187] = invalid_status
		if(SSdogmos.decode_job_observations(bad))
			return Fail("An unknown or inconsistent job status was accepted.", __FILE__, __LINE__)
	var/list/bad_high_status = words.Copy()
	bad_high_status[188] = 1
	if(SSdogmos.decode_job_observations(bad_high_status))
		return Fail("An unknown high status word was accepted.", __FILE__, __LINE__)
	for(var/index in 183 to 188)
		words[index] = 0
	if(SSdogmos.decode_job_observations(words))
		return Fail("Age without an admitted job was accepted.", __FILE__, __LINE__)
	for(var/index in 189 to 192)
		words[index] = 0
	if(!SSdogmos.decode_job_observations(words))
		return Fail("An idle observation with cumulative counters was rejected.", __FILE__, __LINE__)
	words[187] = 1
	if(SSdogmos.decode_job_observations(words))
		return Fail("Status without job identity was accepted.", __FILE__, __LINE__)
	var/list/live = dogmos_job_observations_snapshot()
	if(!live || length(live["raw_words"]) != 54)
		return Fail("The loaded native pair did not supply the complete observation block.", __FILE__, __LINE__)

/** Verifies startup identity mismatches report exact expected and actual values. */
/datum/unit_test/dogmos_service_contract_identity

/datum/unit_test/dogmos_service_contract_identity/Run()
	var/abi_error = dogmos_contract_identity_error(DOGMOS_CONTRACT_ABI_VERSION + 1, DOGMOS_CONTRACT_PROTOCOL_VERSION, DOGMOS_CONTRACT_SOURCE_REVISION, DOGMOS_CONTRACT_FEATURE_FINGERPRINT)
	if(abi_error != "Dogmos ABI mismatch: expected [DOGMOS_CONTRACT_ABI_VERSION], actual [DOGMOS_CONTRACT_ABI_VERSION + 1].")
		return Fail("Dogmos startup did not report the exact ABI mismatch: [abi_error]", __FILE__, __LINE__)
	var/protocol_error = dogmos_contract_identity_error(DOGMOS_CONTRACT_ABI_VERSION, DOGMOS_CONTRACT_PROTOCOL_VERSION + 1, DOGMOS_CONTRACT_SOURCE_REVISION, DOGMOS_CONTRACT_FEATURE_FINGERPRINT)
	if(protocol_error != "Dogmos protocol mismatch: expected [DOGMOS_CONTRACT_PROTOCOL_VERSION], actual [DOGMOS_CONTRACT_PROTOCOL_VERSION + 1].")
		return Fail("Dogmos startup did not report the exact protocol mismatch: [protocol_error]", __FILE__, __LINE__)
	var/mismatched_revision = "[DOGMOS_CONTRACT_SOURCE_REVISION]-mismatch"
	var/revision_error = dogmos_contract_identity_error(DOGMOS_CONTRACT_ABI_VERSION, DOGMOS_CONTRACT_PROTOCOL_VERSION, mismatched_revision, DOGMOS_CONTRACT_FEATURE_FINGERPRINT)
	if(revision_error != "Dogmos source revision mismatch: expected [DOGMOS_CONTRACT_SOURCE_REVISION], actual [mismatched_revision].")
		return Fail("Dogmos startup did not report the exact source-revision mismatch: [revision_error]", __FILE__, __LINE__)
	var/mismatched_fingerprint = "[DOGMOS_CONTRACT_FEATURE_FINGERPRINT]-mismatch"
	var/fingerprint_error = dogmos_contract_identity_error(DOGMOS_CONTRACT_ABI_VERSION, DOGMOS_CONTRACT_PROTOCOL_VERSION, DOGMOS_CONTRACT_SOURCE_REVISION, mismatched_fingerprint)
	if(fingerprint_error != "Dogmos feature fingerprint mismatch: expected [DOGMOS_CONTRACT_FEATURE_FINGERPRINT], actual [mismatched_fingerprint].")
		return Fail("Dogmos startup did not report the exact feature-fingerprint mismatch: [fingerprint_error]", __FILE__, __LINE__)
	var/matching_error = dogmos_contract_identity_error(DOGMOS_CONTRACT_ABI_VERSION, DOGMOS_CONTRACT_PROTOCOL_VERSION, DOGMOS_CONTRACT_SOURCE_REVISION, DOGMOS_CONTRACT_FEATURE_FINGERPRINT)
	if(!isnull(matching_error))
		return Fail("Dogmos startup reported an identity mismatch for the synchronized contract: [matching_error]", __FILE__, __LINE__)

/** Verifies the production service reports its identity and preserves a sentinel mixture. */
/datum/unit_test/dogmos_service_lifecycle
	/// Sentinel mixture released during test teardown.
	var/datum/gas_mixture/sentinel

/datum/unit_test/dogmos_service_lifecycle/Run()
	if(!SSdogmos.service_ready || !dogmos_service_health())
		return Fail("dogmosd did not pass startup identity and health checks.", __FILE__, __LINE__)

	var/service_pid = dogmos_service_pid()
	if(!isnum(service_pid) || service_pid <= 0 || round(service_pid) != service_pid)
		return Fail("dogmosd reported invalid service PID [service_pid].", __FILE__, __LINE__)

	var/list/world_generation_words = dogmos_service_world_generation()
	if(!islist(world_generation_words) || length(world_generation_words) != 2)
		return Fail("dogmosd reported malformed world-generation words.", __FILE__, __LINE__)
	for(var/world_generation_word in world_generation_words)
		if(!isnum(world_generation_word) || world_generation_word < 0 || world_generation_word > DOGMOS_WORLD_GENERATION_WORD_MAX || round(world_generation_word) != world_generation_word)
			return Fail("dogmosd reported invalid world-generation word [world_generation_word].", __FILE__, __LINE__)
	if(!world_generation_words[1] && !world_generation_words[2])
		return Fail("dogmosd reported a zero world generation.", __FILE__, __LINE__)

	var/expected_temperature = 321.5
	var/expected_oxygen_moles = 7.25
	sentinel = new(CELL_VOLUME)
	sentinel.set_temperature(expected_temperature)
	sentinel.set_moles(/datum/gas/oxygen, expected_oxygen_moles)
	var/sentinel_temperature = sentinel.return_temperature()
	var/sentinel_oxygen_moles = sentinel.get_moles(/datum/gas/oxygen)
	if(sentinel.dogmos_slot <= 0 || sentinel.dogmos_generation <= 0)
		return Fail("Dogmos assigned an invalid identity to the lifecycle sentinel mixture.", __FILE__, __LINE__)
	if(sentinel_temperature != expected_temperature || sentinel_oxygen_moles != expected_oxygen_moles)
		return Fail("dogmosd did not preserve the lifecycle sentinel mixture state.", __FILE__, __LINE__)

	log_world("DOGMOS SERVICE LIFECYCLE: pid=[service_pid] world_generation_words=[world_generation_words[1]]:[world_generation_words[2]] sentinel=[sentinel.dogmos_slot]:[sentinel.dogmos_generation] temperature=[sentinel_temperature] oxygen_moles=[sentinel_oxygen_moles]")

/datum/unit_test/dogmos_service_lifecycle/Destroy()
	QDEL_NULL(sentinel)
	return ..()

/** Verifies service-backed mixture identities are live, bounded, and generational. */
/datum/unit_test/dogmos_service_mixture_identity

/** Exercises slot reuse while base teardown owns both mixture datums on early failure. */
/datum/unit_test/dogmos_service_mixture_identity/Run()
	if(!SSdogmos.service_ready)
		return Fail("dogmosd did not pass startup identity and health checks.", __FILE__, __LINE__)
	if(!dogmos_wait_for_stage_boundary())
		return
	var/datum/gas_mixture/first = allocate(/datum/gas_mixture, CELL_VOLUME)
	var/first_slot = first.dogmos_slot
	var/first_generation = first.dogmos_generation
	if(first_slot <= 0 || first_slot > 16777216)
		return Fail("Dogmos assigned an invalid mixture slot [first_slot].", __FILE__, __LINE__)
	if(first_generation <= 0 || first_generation > 16777216)
		return Fail("Dogmos assigned an invalid mixture generation [first_generation].", __FILE__, __LINE__)
	var/list/retired_snapshot = new/list(42)
	SSdogmos.store_mixture_snapshot_cache(first_slot, first_generation, retired_snapshot)
	first.__gasmixture_unregister()
	if(SSdogmos.lookup_mixture_snapshot_cache(first_slot, first_generation))
		return Fail("Unregistering a mixture retained its cached snapshot.", __FILE__, __LINE__)
	qdel(first)

	// The first datum has relinquished its token before this slot is reused. Base teardown
	// owns the datums, never a saved slot/generation that could unregister the replacement.
	var/datum/gas_mixture/second = allocate(/datum/gas_mixture, CELL_VOLUME)
	if(second.dogmos_slot != first_slot)
		return Fail("Dogmos did not reuse the released bounded mixture slot.", __FILE__, __LINE__)
	if(second.dogmos_generation <= first_generation)
		return Fail("Dogmos reused a mixture slot without advancing its generation.", __FILE__, __LINE__)
	if(SSdogmos.lookup_mixture_snapshot_cache(first_slot, first_generation))
		return Fail("A reused mixture slot resolved the retired generation's cached snapshot.", __FILE__, __LINE__)
	qdel(second)


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
