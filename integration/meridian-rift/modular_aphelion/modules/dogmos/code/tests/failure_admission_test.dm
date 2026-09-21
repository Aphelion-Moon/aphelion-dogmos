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

/**
 * Owns the local state overrides used by synchronous, closed-admission fixtures.
 * Restore before the framework restores turf gas, including when Run() aborts.
 * The explicit field inventories below are test state, not a production copy contract.
 */
/datum/unit_test/dogmos_admission_fixture
	abstract_type = /datum/unit_test/dogmos_admission_fixture
	/// Exact controllers whose local state the fixture temporarily overrides.
	var/datum/controller/subsystem/dogmos/admission_service_owner
	var/datum/controller/subsystem/air/admission_air_owner
	/// Original values and list identities; null means restoration already completed.
	var/list/admission_service_state
	var/list/admission_air_state
	/// Optional local heat fallback changed by the heat-admission fixture.
	var/turf/open/admission_heat_turf
	var/admission_heat_temperature

/** Capture all overrides before the first mutation, with no native work or yields. */
/datum/unit_test/dogmos_admission_fixture/proc/save_admission_fixture(list/service_fields, list/air_fields, turf/open/heat_turf)
	admission_service_owner = SSdogmos
	admission_air_owner = SSair
	admission_service_state = list()
	admission_air_state = list()
	for(var/field in service_fields)
		admission_service_state[field] = admission_service_owner.vars[field]
	for(var/field in air_fields)
		admission_air_state[field] = admission_air_owner.vars[field]
	// Shutdown cuts this list in place; rejection deletes the current job. Both belong
	// to the live controller and must survive this test's local admission failure.
	if("dogmos_machine_prefetch_mixtures" in air_fields)
		admission_air_owner.dogmos_machine_prefetch_mixtures = admission_air_owner.dogmos_machine_prefetch_mixtures.Copy()
	if("dogmos_job" in air_fields)
		admission_air_owner.dogmos_job = null
	admission_heat_turf = heat_turf
	if(admission_heat_turf)
		admission_heat_temperature = admission_heat_turf.temperature

/** Restore once; never install an old controller's references into a replacement owner. */
/datum/unit_test/dogmos_admission_fixture/proc/restore_admission_fixture()
	if(!admission_service_state)
		return
	if(admission_service_owner == SSdogmos && admission_air_owner == SSair)
		for(var/field in admission_service_state)
			admission_service_owner.vars[field] = admission_service_state[field]
		for(var/field in admission_air_state)
			admission_air_owner.vars[field] = admission_air_state[field]
		if(admission_heat_turf)
			admission_heat_turf.temperature = admission_heat_temperature
	else
		dogmos_abort_fixture("A synchronous admission fixture unexpectedly replaced its subsystem owner.")
	admission_service_state = null
	admission_air_state = null
	admission_service_owner = null
	admission_air_owner = null
	admission_heat_turf = null

/datum/unit_test/dogmos_admission_fixture/restore_atmos()
	restore_admission_fixture()
	return ..()

/datum/unit_test/dogmos_admission_fixture/Destroy()
	restore_admission_fixture()
	return ..()

/** Own every local value cleared by dogmos_fail_closed_stage(), protecting the live job. */
/datum/unit_test/dogmos_admission_fixture/proc/save_rejected_admission_fixture()
	save_admission_fixture(
		list("service_ready", "service_failure_latched", "service_shutdown_requested"),
		list(
			"can_fire", "dogmos_job", "dogmos_pending_stage", "dogmos_pending_frontier_epoch", "dogmos_stage_remaining_estimate",
			"dogmos_active_turf_stages_complete", "dogmos_equalize_stage_complete", "dogmos_fdm_steps_completed", "dogmos_active_walk_complete",
			"active_turfs_walk_cursor", "dogmos_visual_refresh_cursor", "dogmos_visual_refresh_batch", "dogmos_walk_prefetch_end", "dogmos_visual_prefetch_end",
			"dogmos_resume_recovered_cycle", "dogmos_reacted_turfs", "dogmos_machine_prefetch_start", "dogmos_machine_prefetch_end",
			"dogmos_machine_prefetch_cursor", "dogmos_machine_prefetch_air_cursor", "dogmos_machine_prefetch_ready", "dogmos_machine_prefetch_mixtures",
		),
	)

/** A caught exceptional exit restores seeded owners and list identities exactly once. */
/datum/unit_test/dogmos_admission_fixture_exception_cleanup
	parent_type = /datum/unit_test/dogmos_admission_fixture

/datum/unit_test/dogmos_admission_fixture_exception_cleanup/Run()
	var/turf/open/target = run_loc_floor_bottom_left
	var/datum/unit_test/dogmos_admission_fixture/probe = allocate(/datum/unit_test/dogmos_admission_fixture)
	var/datum/dogmos_stage_job/fixture_job = allocate(/datum/dogmos_stage_job, DOGMOS_TEST_STAGE_TURFS)
	save_rejected_admission_fixture()
	var/caught_expected = FALSE
	var/restored = FALSE
	var/restored_twice = FALSE
	var/failure
	try
		SSdogmos.service_ready = FALSE
		SSdogmos.service_failure_latched = TRUE
		SSdogmos.service_shutdown_requested = TRUE
		SSair.can_fire = FALSE
		SSair.dogmos_job = fixture_job
		SSair.dogmos_machine_prefetch_start = 91
		SSair.dogmos_machine_prefetch_end = 73
		SSair.dogmos_machine_prefetch_cursor = 89
		SSair.dogmos_machine_prefetch_air_cursor = 4
		SSair.dogmos_machine_prefetch_ready = TRUE
		var/list/seeded_prefetch = list(target.air)
		SSair.dogmos_machine_prefetch_mixtures = seeded_prefetch
		var/list/seeded_reacted = list(run_loc_floor_bottom_left)
		SSair.dogmos_reacted_turfs = seeded_reacted
		probe.save_rejected_admission_fixture()
		try
			SSdogmos.service_ready = TRUE
			SSdogmos.service_failure_latched = FALSE
			SSdogmos.service_shutdown_requested = FALSE
			SSair.can_fire = TRUE
			SSair.dogmos_clear_machinery_prefetch()
			SSair.dogmos_reacted_turfs = list()
			throw "admission fixture cleanup sentinel"
		catch(var/error)
			caught_expected = error == "admission fixture cleanup sentinel"
		// This is the same idempotent hook called before restore_atmos() and Destroy().
		probe.restore_admission_fixture()
		restored = !SSdogmos.service_ready && SSdogmos.service_failure_latched && SSdogmos.service_shutdown_requested && !SSair.can_fire \
			&& SSair.dogmos_job == fixture_job && !QDELETED(fixture_job) \
			&& SSair.dogmos_machine_prefetch_start == 91 && SSair.dogmos_machine_prefetch_end == 73 \
			&& SSair.dogmos_machine_prefetch_cursor == 89 && SSair.dogmos_machine_prefetch_air_cursor == 4 \
			&& SSair.dogmos_machine_prefetch_ready && SSair.dogmos_machine_prefetch_mixtures == seeded_prefetch \
			&& length(seeded_prefetch) == 1 && SSair.dogmos_reacted_turfs == seeded_reacted
		SSair.dogmos_machine_prefetch_cursor = 88
		probe.restore_admission_fixture()
		restored_twice = SSair.dogmos_machine_prefetch_cursor == 88 && SSair.dogmos_job == fixture_job \
			&& SSair.dogmos_machine_prefetch_mixtures == seeded_prefetch && SSair.dogmos_reacted_turfs == seeded_reacted
	catch(var/error)
		failure = "The exceptional admission fixture raised [error]."
	// Nested test state must be released before restoring the real world and asserting.
	probe.restore_admission_fixture()
	restore_admission_fixture()
	if(failure)
		return Fail(failure, __FILE__, __LINE__)
	if(!caught_expected)
		return Fail("The fixture did not catch its exact exceptional-exit sentinel.", __FILE__, __LINE__)
	if(!restored)
		return Fail("The exceptional fixture lost admission flags, prefetch values, list identity or its live job.", __FILE__, __LINE__)
	if(!restored_twice)
		return Fail("Repeated fixture cleanup overwrote state after releasing ownership.", __FILE__, __LINE__)

/** Verifies a latched service failure stops stage work without another FFI attempt. */
/datum/unit_test/dogmos_service_failure_latch_stops_stage
	parent_type = /datum/unit_test/dogmos_admission_fixture

/datum/unit_test/dogmos_service_failure_latch_stops_stage/Run()
	var/original_service_ready = SSdogmos.service_ready
	var/original_failure_latched = SSdogmos.service_failure_latched
	var/original_pending_stage = SSair.dogmos_pending_stage
	var/list/original_pending_frontier = SSair.dogmos_pending_frontier_epoch
	var/turf/open/target = run_loc_floor_bottom_left
	if(!target?.init_air || target.thermal_conductivity <= 0 || target.heat_capacity <= 0 || isnull(target.dogmos_registration_generation) || !target.dogmos_air_registration_is_current(FALSE))
		return Fail("The failure-latch heat admission test requires a current registered heat turf.", __FILE__, __LINE__)
	var/datum/gas_mixture/mixture = target.air
	var/mixture_slot = mixture.dogmos_slot
	var/mixture_generation = mixture.dogmos_generation
	var/mixture_slot_count = length(SSdogmos.dogmos_mixture_slots)
	var/turf_slot = target.dogmos_service_slot()
	var/turf_key = "[turf_slot]"
	var/list/original_turf_lifecycle = SSdogmos.dogmos_pending_turf_lifecycle[turf_key]
	var/turf_generation = target.dogmos_service_generation()
	var/registered_mixture_slot = target.dogmos_registered_mixture_slot
	var/registered_mixture_generation = target.dogmos_registered_mixture_generation
	var/list/original_pending_heat = SSdogmos.dogmos_pending_turf_heat
	var/list/original_pending_heat_entry = original_pending_heat[turf_key]
	var/had_pending_heat_entry = islist(original_pending_heat_entry)
	var/original_pending_heat_length = length(original_pending_heat)
	var/list/isolated_pending_heat = original_pending_heat.Copy()
	var/original_temperature = target.temperature
	var/local_fallback_temperature = original_temperature + 17
	var/original_temperature_authority = SSair.dogmos_blocked_turf_temperature_authority
	var/raw_heat_temperature
	var/public_heat_temperature
	var/blocked_heat_temperature
	var/heat_read_error
	var/heat_queue_isolated
	var/heat_entry_absent
	var/heat_queue_length_unchanged
	save_admission_fixture(
		list("service_ready", "service_failure_latched", "dogmos_pending_turf_heat"),
		list("dogmos_blocked_turf_temperature_authority"),
		target,
	)
	SSdogmos.service_ready = FALSE
	SSdogmos.service_failure_latched = TRUE
	var/stage_stopped = SSair.dogmos_run_stage(DOGMOS_TEST_STAGE_EQUALIZE, 1)
	var/list/failed_response = SSdogmos.mixture_command(list(), DOGMOS_TEST_RESPONSE_APPLIED)
	SSdogmos.evict_mixture_snapshot_cache(mixture_slot, mixture_generation)
	var/list/failed_gases = mixture.__get_gases()
	try
		// Isolate only this registered turf's pending value so the raw getter must choose its FFI path.
		SSdogmos.dogmos_pending_turf_heat = isolated_pending_heat
		isolated_pending_heat.Remove(turf_key)
		target.temperature = local_fallback_temperature
		SSair.dogmos_blocked_turf_temperature_authority = DOGMOS_TEMPERATURE_AUTHORITY_RUST
		raw_heat_temperature = target.__dogmos_heat_temperature()
		public_heat_temperature = target.return_temperature()
		blocked_heat_temperature = target.get_dogmos_blocked_temperature()
		heat_queue_isolated = SSdogmos.dogmos_pending_turf_heat == isolated_pending_heat
		heat_entry_absent = isnull(SSdogmos.dogmos_pending_turf_heat[turf_key])
		heat_queue_length_unchanged = length(SSdogmos.dogmos_pending_turf_heat) == original_pending_heat_length - (had_pending_heat_entry ? 1 : 0)
	catch(var/exception/heat_read_exception)
		heat_read_error = heat_read_exception.name
	SSdogmos.dogmos_pending_turf_heat = original_pending_heat
	SSdogmos.register_mixture(mixture)
	target.update_air_ref(DOGMOS_SIMULATION_ALL)
	var/stage_changed = SSair.dogmos_pending_stage != original_pending_stage || SSair.dogmos_pending_frontier_epoch != original_pending_frontier
	var/mixture_changed = mixture.dogmos_slot != mixture_slot || mixture.dogmos_generation != mixture_generation || length(SSdogmos.dogmos_mixture_slots) != mixture_slot_count
	var/turf_changed = SSdogmos.dogmos_pending_turf_lifecycle[turf_key] != original_turf_lifecycle
	SSdogmos.service_ready = original_service_ready
	SSdogmos.service_failure_latched = original_failure_latched
	SSair.dogmos_blocked_turf_temperature_authority = original_temperature_authority
	target.temperature = original_temperature
	var/heat_identity_unchanged = target.dogmos_service_slot() == turf_slot && target.dogmos_service_generation() == turf_generation \
		&& target.dogmos_registered_mixture_slot == registered_mixture_slot && target.dogmos_registered_mixture_generation == registered_mixture_generation
	var/heat_entry_restored = had_pending_heat_entry ? SSdogmos.dogmos_pending_turf_heat[turf_key] == original_pending_heat_entry : isnull(SSdogmos.dogmos_pending_turf_heat[turf_key])
	var/heat_queue_restored = SSdogmos.dogmos_pending_turf_heat == original_pending_heat && length(SSdogmos.dogmos_pending_turf_heat) == original_pending_heat_length && heat_entry_restored
	restore_admission_fixture()
	if(!stage_stopped)
		return Fail("Dogmos reported a failed service stage as complete.", __FILE__, __LINE__)
	if(stage_changed)
		return Fail("Dogmos mutated stage state after the service failure latch was set.", __FILE__, __LINE__)
	if(!islist(failed_response) || length(failed_response) != 4 || failed_response[1] != DOGMOS_TEST_RESPONSE_APPLIED)
		return Fail("Dogmos returned a malformed inert mixture response after the service failure latch was set.", __FILE__, __LINE__)
	if(!islist(failed_gases) || length(failed_gases))
		return Fail("Dogmos failed gas enumeration did not return an empty list without a runtime.", __FILE__, __LINE__)
	if(mixture_changed)
		return Fail("Dogmos mutated mixture registration after the service failure latch was set.", __FILE__, __LINE__)
	if(turf_changed)
		return Fail("Dogmos queued a turf lifecycle mutation after the service failure latch was set.", __FILE__, __LINE__)
	if(heat_read_error)
		return Fail("Dogmos failure-latch heat admission read raised [heat_read_error].", __FILE__, __LINE__)
	if(!isnull(raw_heat_temperature))
		return Fail("Dogmos failure-latch heat admission reached the raw TurfHeat snapshot path.", __FILE__, __LINE__)
	if(public_heat_temperature != local_fallback_temperature || blocked_heat_temperature != local_fallback_temperature)
		return Fail("Dogmos failure-latch heat admission did not return local-temperature fallbacks.", __FILE__, __LINE__)
	if(!heat_queue_isolated || !heat_entry_absent || !heat_queue_length_unchanged || !heat_queue_restored)
		return Fail("Dogmos failure-latch heat admission changed pending heat outside its isolated entry.", __FILE__, __LINE__)
	if(!heat_identity_unchanged)
		return Fail("Dogmos failure-latch heat admission changed the registered turf identity.", __FILE__, __LINE__)

/** Late map-loading producers must not submit native work after intentional shutdown begins. */
/datum/unit_test/dogmos_service_shutdown_stops_producers
	parent_type = /datum/unit_test/dogmos_admission_fixture

/datum/unit_test/dogmos_service_shutdown_stops_producers/Run()
	var/original_service_ready = SSdogmos.service_ready
	var/original_shutdown_requested = SSdogmos.service_shutdown_requested
	var/original_failure_latched = SSdogmos.service_failure_latched
	var/slot_count = length(SSdogmos.dogmos_mixture_slots)
	var/turf/open/target = run_loc_floor_bottom_left
	var/datum/gas_mixture/source = target.air
	save_admission_fixture(
		list("service_ready", "service_shutdown_requested", "service_failure_latched"),
		list("dogmos_machine_prefetch_start", "dogmos_machine_prefetch_end", "dogmos_machine_prefetch_cursor", "dogmos_machine_prefetch_air_cursor", "dogmos_machine_prefetch_ready", "dogmos_machine_prefetch_mixtures"),
	)
	SSdogmos.begin_service_shutdown()
	var/datum/gas_mixture/late_copy = source.copy()
	allocated += late_copy
	var/list/gases = late_copy.__get_gases()
	var/stage_stopped = SSair.dogmos_run_stage(DOGMOS_TEST_STAGE_EQUALIZE, 1)
	target.update_air_ref(DOGMOS_SIMULATION_ALL)
	var/registration_blocked = !late_copy.dogmos_slot && length(SSdogmos.dogmos_mixture_slots) == slot_count
	var/admission_closed = SSdogmos.service_shutdown_requested && !SSdogmos.service_ready
	var/failure_unchanged = SSdogmos.service_failure_latched == original_failure_latched
	SSdogmos.service_ready = original_service_ready
	SSdogmos.service_shutdown_requested = original_shutdown_requested
	SSdogmos.service_failure_latched = original_failure_latched
	restore_admission_fixture()
	if(!admission_closed || !registration_blocked || !stage_stopped || !failure_unchanged)
		return Fail("Intentional shutdown did not close native admission independently of service failure.", __FILE__, __LINE__)
	if(!islist(gases) || length(gases))
		return Fail("A late shutdown producer did not receive an inert gas snapshot.", __FILE__, __LINE__)

/** Verifies failure blocks queued topology before any lifecycle or adjacency FFI call. */
/datum/unit_test/dogmos_service_failure_latch_stops_topology
	parent_type = /datum/unit_test/dogmos_admission_fixture

/datum/unit_test/dogmos_service_failure_latch_stops_topology/Run()
	var/original_service_ready = SSdogmos.service_ready
	var/original_failure_latched = SSdogmos.service_failure_latched
	var/list/original_pending_frontier = SSair.dogmos_pending_frontier_epoch
	var/list/queue_names = list("dogmos_pending_mixture_unregistrations", "dogmos_pending_turf_lifecycle", "dogmos_pending_turf_heat", "dogmos_pending_turf_adjacency", "dogmos_pending_turf_heat_adjacency", "dogmos_pending_adjacency_retry")
	save_admission_fixture(queue_names + list("service_ready", "service_failure_latched"), list("dogmos_pending_frontier_epoch"))
	var/list/saved_queues = list()
	for(var/queue_name in queue_names)
		saved_queues[queue_name] = SSdogmos.vars[queue_name]
		SSdogmos.vars[queue_name] = list()
	// An invalid sentinel must never reach dogmosd after the failure latch is set.
	var/list/sentinel = list(0, 0, 0, 0, TRUE)
	SSdogmos.dogmos_pending_turf_adjacency["failed-service-sentinel"] = sentinel
	SSdogmos.service_ready = FALSE
	SSdogmos.service_failure_latched = TRUE
	SSair.dogmos_pending_frontier_epoch = null
	var/flushed = SSdogmos.flush_turf_registration_batch()
	var/sentinel_preserved = SSdogmos.dogmos_pending_turf_adjacency["failed-service-sentinel"] == sentinel
	SSair.dogmos_pending_frontier_epoch = original_pending_frontier
	SSdogmos.service_ready = original_service_ready
	SSdogmos.service_failure_latched = original_failure_latched
	for(var/queue_name in queue_names)
		SSdogmos.vars[queue_name] = saved_queues[queue_name]
	restore_admission_fixture()
	if(flushed || !sentinel_preserved)
		return Fail("Dogmos consumed pending topology after the service failure latch was set.", __FILE__, __LINE__)

/** Verifies rejected mixture registration fails closed without publishing an invalid identity. */
/datum/unit_test/dogmos_service_rejected_mixture_registration_fails_closed
	parent_type = /datum/unit_test/dogmos_admission_fixture

/datum/unit_test/dogmos_service_rejected_mixture_registration_fails_closed/Run()
	save_rejected_admission_fixture()
	var/list/original_walk_state = list()
	for(var/field in list("dogmos_active_walk_complete", "active_turfs_walk_cursor", "dogmos_visual_refresh_cursor", "dogmos_visual_refresh_batch"))
		original_walk_state[field] = SSair.vars[field]
	var/original_service_ready = SSdogmos.service_ready
	var/original_failure_latched = SSdogmos.service_failure_latched
	var/original_can_fire = SSair.can_fire
	var/original_pending_stage = SSair.dogmos_pending_stage
	var/list/original_pending_frontier = SSair.dogmos_pending_frontier_epoch
	var/original_remaining_estimate = SSair.dogmos_stage_remaining_estimate
	var/original_active_complete = SSair.dogmos_active_turf_stages_complete
	var/original_equalize_complete = SSair.dogmos_equalize_stage_complete
	var/original_fdm_steps = SSair.dogmos_fdm_steps_completed
	var/turf/open/target = run_loc_floor_bottom_left
	var/datum/gas_mixture/mixture = target.air
	var/original_slot = mixture.dogmos_slot
	var/original_generation = mixture.dogmos_generation
	var/original_pointer = mixture._extools_pointer_gasmixture
	var/accepted = SSdogmos.finalize_mixture_registration(
		mixture,
		length(SSdogmos.dogmos_mixture_slots) + 1,
		1,
		null,
		FALSE,
	)
	var/identity_changed = mixture.dogmos_slot != original_slot || mixture.dogmos_generation != original_generation || mixture._extools_pointer_gasmixture != original_pointer
	var/failed_closed = !SSair.can_fire && !SSdogmos.service_ready && SSdogmos.service_failure_latched
	SSdogmos.service_ready = original_service_ready
	SSdogmos.service_failure_latched = original_failure_latched
	SSair.can_fire = original_can_fire
	SSair.dogmos_pending_stage = original_pending_stage
	SSair.dogmos_pending_frontier_epoch = original_pending_frontier
	SSair.dogmos_stage_remaining_estimate = original_remaining_estimate
	SSair.dogmos_active_turf_stages_complete = original_active_complete
	SSair.dogmos_equalize_stage_complete = original_equalize_complete
	SSair.dogmos_fdm_steps_completed = original_fdm_steps
	for(var/field in original_walk_state)
		SSair.vars[field] = original_walk_state[field]
	restore_admission_fixture()
	if(accepted)
		return Fail("Dogmos accepted a rejected mixture lifecycle response.", __FILE__, __LINE__)
	if(identity_changed)
		return Fail("Dogmos published a mixture identity after the service rejected it.", __FILE__, __LINE__)
	if(!failed_closed)
		return Fail("Dogmos did not fail closed after the service rejected a mixture registration.", __FILE__, __LINE__)


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
