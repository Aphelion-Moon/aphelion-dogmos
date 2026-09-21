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


/datum/unit_test/dogmos_runtime_prefetch/Run()
	if(!dogmos_wait_for_stage_boundary())
		return
	var/original_tick_limit = Master.current_ticklimit
	var/datum/controller/subsystem/air/recovery_test_copy/machinery_prefetch_probe/probe = allocate(/datum/controller/subsystem/air/recovery_test_copy/machinery_prefetch_probe)
	var/list/obj/machinery/atmospherics/components/unary/vent_pump/dogmos_prefetch_probe/machines = list()
	var/failure
	try
		for(var/count in list(0, 1, 32, 33, 65))
			machines.Cut()
			var/list/processed = list()
			for(var/index = 1; index <= count; index++)
				var/obj/machinery/atmospherics/components/unary/vent_pump/dogmos_prefetch_probe/machine = allocate(/obj/machinery/atmospherics/components/unary/vent_pump/dogmos_prefetch_probe)
				SSair.stop_processing_machine(machine)
				machine.ordinal = index
				machine.processed = processed
				machines += machine
			probe.atmos_machinery = machines.Copy()
			probe.currentpart = SSAIR_ATMOSMACHINERY
			probe.state = SS_RUNNING
			probe.force_prefetch_yield = TRUE
			probe.prefetch_calls = 0
			Master.current_ticklimit = TICK_USAGE + 1000
			SSdogmos.reset_mixture_snapshot_cache()
			probe.process_atmos_machinery(FALSE)
			if(length(processed))
				failure = "Machinery processed an entry after prefetch exhausted its MC budget."
				break
			if(count == 33)
				var/obj/machinery/atmospherics/components/unary/vent_pump/dogmos_prefetch_probe/first = machines[1]
				var/datum/gas_mixture/first_mix = first.airs[1]
				if(SSdogmos.lookup_mixture_snapshot_cache(first_mix.dogmos_slot, first_mix.dogmos_generation))
					failure = "The first reverse prefetch chunk reached entry 1 instead of stopping at entry 2."
					break
				var/obj/machinery/atmospherics/components/unary/vent_pump/dogmos_prefetch_probe/last = machines[33]
				last.force_process_yield = TRUE
				Master.current_ticklimit = TICK_USAGE + 1000
				probe.state = SS_RUNNING
				probe.process_atmos_machinery(TRUE)
				if(json_encode(processed) != json_encode(list(33)) || probe.prefetch_calls != 1)
					failure = "The first resume did not process only entry 33 from its retained prefetch range."
					break
				var/datum/gas_mixture/changed_mix = last.airs[1]
				if(!SSdogmos.lookup_mixture_snapshot_cache(changed_mix.dogmos_slot, changed_mix.dogmos_generation))
					failure = "The write-invalidation oracle did not begin with a cached mixture."
					break
				changed_mix.set_moles(GAS_O2, 42)
				if(changed_mix.get_moles(GAS_O2) != 42)
					failure = "A write between machinery resumes returned stale cached gas state."
					break
				var/obj/machinery/atmospherics/components/unary/vent_pump/dogmos_prefetch_probe/removed = machines[32]
				removed.atmos_processing = TRUE
				probe.stop_processing_machine(removed)
				removed.processed = null
				qdel(removed)
			var/resumes = 0
			while(length(probe.currentrun) && resumes++ < 10)
				Master.current_ticklimit = TICK_USAGE + 1000
				probe.state = SS_RUNNING
				probe.process_atmos_machinery(TRUE)
			var/list/expected = list()
			for(var/index = count; index >= 1; index--)
				if(count == 33 && index == 32)
					continue
				expected += index
			if(json_encode(processed) != json_encode(expected))
				failure = "The machinery transcript was [json_encode(processed)], expected [json_encode(expected)]."
				break
			if(probe.prefetch_calls != CEILING(count / 32, 1))
				failure = "Ordinary machinery prefetch repeated a consumed range or crossed its 32-entry bound."
				break
			for(var/obj/machinery/atmospherics/components/unary/vent_pump/dogmos_prefetch_probe/machine as anything in machines)
				if(!QDELETED(machine))
					machine.processed = null
					qdel(machine)
	catch(var/exception/error)
		failure = "Machinery prefetch fixture raised [error.name]."
	Master.current_ticklimit = original_tick_limit
	probe.atmos_machinery = list()
	probe.currentrun = list()
	qdel(probe)
	for(var/obj/machinery/atmospherics/components/unary/vent_pump/dogmos_prefetch_probe/machine as anything in machines)
		if(!QDELETED(machine))
			machine.processed = null
	SSdogmos.reset_mixture_snapshot_cache()
	if(failure)
		return Fail(failure, __FILE__, __LINE__)

/** One component with repeated mixture references must still yield within its input visit limit. */
/datum/unit_test/dogmos_runtime_prefetch/oversized/Run()
	if(!dogmos_wait_for_stage_boundary())
		return
	var/original_tick_limit = Master.current_ticklimit
	var/datum/controller/subsystem/air/recovery_test_copy/machinery_prefetch_probe/probe = allocate(/datum/controller/subsystem/air/recovery_test_copy/machinery_prefetch_probe)
	var/obj/machinery/atmospherics/components/unary/vent_pump/dogmos_prefetch_probe/machine = allocate(/obj/machinery/atmospherics/components/unary/vent_pump/dogmos_prefetch_probe)
	SSair.stop_processing_machine(machine)
	var/list/original_airs = machine.airs
	var/datum/gas_mixture/tail = allocate(/datum/gas_mixture, CELL_VOLUME)
	var/list/processed = list()
	var/failure
	try
		machine.airs = list()
		for(var/index in 1 to 512)
			machine.airs += original_airs[1]
		machine.airs += tail
		machine.ordinal = 1
		machine.processed = processed
		probe.atmos_machinery = list(machine)
		probe.currentpart = SSAIR_ATMOSMACHINERY
		probe.state = SS_RUNNING
		Master.current_ticklimit = TICK_USAGE + 1000
		SSdogmos.reset_mixture_snapshot_cache()
		probe.process_atmos_machinery(FALSE)
		if(length(processed) || SSdogmos.lookup_mixture_snapshot_cache(tail.dogmos_slot, tail.dogmos_generation))
			failure = "Oversized component preparation crossed its first bounded input window."
		var/resumes = 0
		while(!failure && length(probe.currentrun) && resumes++ < 10)
			Master.current_ticklimit = TICK_USAGE + 1000
			probe.state = SS_RUNNING
			probe.process_atmos_machinery(TRUE)
		if(!failure && (json_encode(processed) != json_encode(list(1)) || probe.prefetch_calls != 3))
			failure = "The oversized component did not finish exactly once after three bounded input visits."
		if(!failure && !SSdogmos.lookup_mixture_snapshot_cache(tail.dogmos_slot, tail.dogmos_generation))
			failure = "Resuming inside an oversized component omitted its final distinct mixture."
	catch(var/exception/error)
		failure = "Oversized machinery fixture raised [error.name]."
	Master.current_ticklimit = original_tick_limit
	machine.airs = original_airs
	machine.processed = null
	probe.atmos_machinery = list()
	probe.currentrun = list()
	qdel(probe)
	SSdogmos.reset_mixture_snapshot_cache()
	if(failure)
		return Fail(failure, __FILE__, __LINE__)

/** Non-machine entries remain in the original processing order and retain PROCESS_KILL behavior. */
/datum/unit_test/dogmos_runtime_prefetch/leaker/Run()
	if(!dogmos_wait_for_stage_boundary())
		return
	var/original_tick_limit = Master.current_ticklimit
	var/datum/controller/subsystem/air/recovery_test_copy/machinery_prefetch_probe/probe = allocate(/datum/controller/subsystem/air/recovery_test_copy/machinery_prefetch_probe)
	var/obj/machinery/atmospherics/components/unary/vent_pump/dogmos_prefetch_probe/machine = allocate(/obj/machinery/atmospherics/components/unary/vent_pump/dogmos_prefetch_probe)
	SSair.stop_processing_machine(machine)
	var/datum/component/gas_leaker/dogmos_prefetch_probe/leaker = machine.AddComponent(/datum/component/gas_leaker/dogmos_prefetch_probe)
	var/list/processed = list()
	var/failure
	try
		machine.ordinal = 2
		machine.processed = processed
		leaker.processed = processed
		leaker.atmos_processing = TRUE
		probe.atmos_machinery = list(leaker, machine)
		probe.currentpart = SSAIR_ATMOSMACHINERY
		probe.state = SS_RUNNING
		Master.current_ticklimit = TICK_USAGE + 1000
		probe.process_atmos_machinery(FALSE)
		if(json_encode(processed) != json_encode(list(2, 1)) || leaker.atmos_processing || length(probe.currentrun))
			failure = "Machinery preparation dropped/reordered a gas leaker or lost its PROCESS_KILL result."
	catch(var/exception/error)
		failure = "Gas-leaker machinery fixture raised [error.name]."
	Master.current_ticklimit = original_tick_limit
	machine.processed = null
	leaker.processed = null
	leaker.atmos_processing = FALSE
	probe.atmos_machinery = list()
	probe.currentrun = list()
	qdel(probe)
	SSdogmos.reset_mixture_snapshot_cache()
	if(failure)
		return Fail(failure, __FILE__, __LINE__)

/** Records a visit, then exercises the real healthy-parent gas-leaker result. */
/datum/component/gas_leaker/dogmos_prefetch_probe
	/// Fixture-owned ordered transcript.
	var/list/processed

/datum/component/gas_leaker/dogmos_prefetch_probe/process_atmos()
	processed += 1
	return ..()

/** Inert test subsystem that exhausts the budget just after the real prefetch call. */
/datum/controller/subsystem/air/recovery_test_copy/machinery_prefetch_probe
	/// Exhaust exactly the first prefetch call's budget.
	var/force_prefetch_yield = FALSE
	/// Count collector calls to inspect resume behavior.
	var/prefetch_calls = 0

/datum/controller/subsystem/air/recovery_test_copy/machinery_prefetch_probe/dogmos_prefetch_machinery_snapshots(list/machines)
	. = ..()
	prefetch_calls++
	if(force_prefetch_yield)
		force_prefetch_yield = FALSE
		Master.current_ticklimit = 0

/** Records processing order without transferring gas into the loaded station. */
/obj/machinery/atmospherics/components/unary/vent_pump/dogmos_prefetch_probe
	/// Literal original position in the test run.
	var/ordinal
	/// Test-owned transcript, released before fixture teardown.
	var/list/processed
	/// Exhaust the MC budget after this entry to exercise mid-range pauses.
	var/force_process_yield = FALSE

/obj/machinery/atmospherics/components/unary/vent_pump/dogmos_prefetch_probe/process_atmos(seconds_per_tick)
	processed += ordinal
	var/datum/gas_mixture/mixture = airs[1]
	mixture.return_pressure()
	if(force_process_yield)
		force_process_yield = FALSE
		Master.current_ticklimit = 0
	return

/** Verifies that machinery prefetch populates the snapshot cache in one batch IPC call. */
/datum/unit_test/dogmos_service_machinery_prefetch
	var/list/obj/machinery/atmospherics/components/test_components = list()
	var/list/datum/gas_mixture/test_mixtures = list()

/datum/unit_test/dogmos_service_machinery_prefetch/Run()
	var/obj/machinery/atmospherics/components/unary/vent_pump/vent = allocate(/obj/machinery/atmospherics/components/unary/vent_pump)
	test_components += vent
	for(var/datum/gas_mixture/mix as anything in vent.airs)
		if(mix)
			test_mixtures += mix
	var/turf/open/vent_turf = vent.loc
	if(istype(vent_turf) && vent_turf.air)
		test_mixtures += vent_turf.air

	if(!length(test_mixtures))
		return Fail("No prefetchable mixtures from allocated vent pump.", __FILE__, __LINE__)

	SSdogmos.reset_mixture_snapshot_cache()
	var/misses_before = SSdogmos.dogmos_mixture_cache_misses
	SSdogmos.prefetch_mixture_snapshots(test_mixtures)
	var/misses_after_prefetch = SSdogmos.dogmos_mixture_cache_misses
	if(misses_after_prefetch != misses_before)
		return Fail("Prefetch should not increment cache misses, but misses went from [misses_before] to [misses_after_prefetch].", __FILE__, __LINE__)

	for(var/datum/gas_mixture/mix as anything in test_mixtures)
		if(!mix.dogmos_slot)
			continue
		var/list/cached = SSdogmos.lookup_mixture_snapshot_cache(mix.dogmos_slot, mix.dogmos_generation)
		if(!cached)
			return Fail("Prefetch did not populate cache for slot [mix.dogmos_slot].", __FILE__, __LINE__)

	var/reads_misses_before = SSdogmos.dogmos_mixture_cache_misses
	for(var/datum/gas_mixture/mix as anything in test_mixtures)
		mix.return_pressure()
		mix.return_temperature()
	if(SSdogmos.dogmos_mixture_cache_misses != reads_misses_before)
		return Fail("Getters after prefetch caused [SSdogmos.dogmos_mixture_cache_misses - reads_misses_before] cache misses; expected zero.", __FILE__, __LINE__)

/** Verifies a prefetch spans the 381-record wire boundary without losing or duplicating snapshots. */
/datum/unit_test/dogmos_service_prefetch_chunking

/datum/unit_test/dogmos_service_prefetch_chunking/Run()
	var/list/datum/gas_mixture/mixtures = list()
	var/list/buckets = list()
	// Free mixture slots need not be contiguous. Select distinct direct-cache buckets
	// so this test measures batching rather than legitimate cache collisions.
	for(var/attempt in 1 to 4096)
		var/datum/gas_mixture/mixture = allocate(/datum/gas_mixture, CELL_VOLUME)
		var/bucket_key = "[SSdogmos.mixture_snapshot_cache_bucket(mixture.dogmos_slot)]"
		if(buckets[bucket_key])
			continue
		buckets[bucket_key] = TRUE
		mixtures += mixture
		mixture.set_moles(/datum/gas/oxygen, length(mixtures))
		if(length(mixtures) == 382)
			break
	if(length(mixtures) != 382)
		return Fail("Could not construct 382 non-colliding snapshot handles.", __FILE__, __LINE__)

	for(var/count in list(381, 382))
		var/list/request = list()
		for(var/index in 1 to count)
			// Duplicate producer references must not consume reply capacity or hide
			// the final unique handle behind the prefetch limit.
			request += mixtures[index]
			request += mixtures[index]
			request += mixtures[index]
		SSdogmos.reset_mixture_snapshot_cache()
		if(SSdogmos.prefetch_mixture_snapshots(request) != count)
			return Fail("Prefetch did not cache each unique requested handle exactly once.", __FILE__, __LINE__)
		for(var/index in 1 to count)
			var/datum/gas_mixture/mixture = mixtures[index]
			var/list/snapshot = SSdogmos.lookup_mixture_snapshot_cache(mixture.dogmos_slot, mixture.dogmos_generation)
			if(!islist(snapshot) || length(snapshot) != 42)
				return Fail("Prefetch omitted or truncated snapshot [index] at the batch boundary.", __FILE__, __LINE__)
			// Field 7 is total moles, independent of the production field macro.
			if(snapshot[7] != index)
				return Fail("Prefetch associated snapshot [index] with the wrong gas state.", __FILE__, __LINE__)
		if(SSdogmos.dogmos_mixture_cache_misses != 0)
			return Fail("Prefetch used singular snapshot reads.", __FILE__, __LINE__)

/datum/unit_test/dogmos_service_prefetch_chunking/Destroy()
	SSdogmos.reset_mixture_snapshot_cache()
	return ..()

/datum/unit_test/dogmos_service_machinery_prefetch/Destroy()
	test_components.Cut()
	test_mixtures.Cut()
	SSdogmos.reset_mixture_snapshot_cache()
	return ..()

/// Measures native publications inside the two blocked-turf shuttle updates.
/turf/open/indestructible/plating/airless/dogmos_shuttle_probe
	/// Shared only for the synchronous test interval; contains numeric observations.
	var/static/list/dogmos_shuttle_samples

/turf/open/indestructible/plating/airless/dogmos_shuttle_probe/air_update_turf(update, remove)
	var/measuring = islist(dogmos_shuttle_samples) && blocks_air
	var/calls_before = SSdogmos.dogmos_runtime_topology_calls
	. = ..()
	if(measuring)
		dogmos_shuttle_samples += SSdogmos.dogmos_runtime_topology_calls - calls_before


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
