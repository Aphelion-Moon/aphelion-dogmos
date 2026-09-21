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

/** Verifies the bounded direct-mapped mixture snapshot cache and mutation invalidation. */
/datum/unit_test/dogmos_service_mixture_snapshot_cache
	/// First service-backed mixture released during teardown.
	var/datum/gas_mixture/first
	/// Second service-backed mixture released during teardown.
	var/datum/gas_mixture/second

/datum/unit_test/dogmos_service_mixture_snapshot_cache/Run()
	if(!SSdogmos.service_ready)
		return Fail("dogmosd did not pass startup identity and health checks.", __FILE__, __LINE__)

	SSdogmos.reset_mixture_snapshot_cache()
	first = new(CELL_VOLUME)
	second = new(CELL_VOLUME)
	first.set_temperature(312.5)
	first.set_moles(/datum/gas/oxygen, 4)
	second.set_temperature(290)

	var/misses_before = SSdogmos.dogmos_mixture_cache_misses
	var/hits_before = SSdogmos.dogmos_mixture_cache_hits
	if(first.return_temperature() != 312.5)
		return Fail("The mixture snapshot cache changed the returned temperature.", __FILE__, __LINE__)
	if(first.total_moles() != 4)
		return Fail("The mixture snapshot cache changed the returned total moles.", __FILE__, __LINE__)
	if(SSdogmos.dogmos_mixture_cache_misses != misses_before + 1 || SSdogmos.dogmos_mixture_cache_hits != hits_before + 1)
		return Fail("Repeated same-revision getters did not produce one cache miss followed by one hit.", __FILE__, __LINE__)

	first.set_temperature(315)
	first.return_temperature()
	if(SSdogmos.dogmos_mixture_cache_misses != misses_before + 2)
		return Fail("A primary mixture mutation did not evict its cached snapshot.", __FILE__, __LINE__)

	var/misses_before_multi = SSdogmos.dogmos_mixture_cache_misses
	first.adjust_multi(/datum/gas/oxygen, 1, /datum/gas/nitrogen, 2)
	first.return_temperature()
	if(SSdogmos.dogmos_mixture_cache_misses != misses_before_multi + 1)
		return Fail("A multi-gas mutation did not evict its cached snapshot.", __FILE__, __LINE__)

	second.return_temperature()
	var/misses_after_warm = SSdogmos.dogmos_mixture_cache_misses
	var/hits_after_warm = SSdogmos.dogmos_mixture_cache_hits
	first.equalize_with(second)
	first.return_temperature()
	second.return_temperature()
	if(SSdogmos.dogmos_mixture_cache_misses != misses_after_warm + 1 || SSdogmos.dogmos_mixture_cache_hits != hits_after_warm + 1)
		return Fail("Equalizing from a mixture did not preserve its read-only source snapshot.", __FILE__, __LINE__)

	second.return_temperature()
	misses_after_warm = SSdogmos.dogmos_mixture_cache_misses
	hits_after_warm = SSdogmos.dogmos_mixture_cache_hits
	first.copy_from(second)
	first.return_temperature()
	second.return_temperature()
	if(SSdogmos.dogmos_mixture_cache_misses != misses_after_warm + 1 || SSdogmos.dogmos_mixture_cache_hits != hits_after_warm + 1)
		return Fail("Copying from a mixture did not preserve its read-only source snapshot.", __FILE__, __LINE__)

	second.return_temperature()
	misses_after_warm = SSdogmos.dogmos_mixture_cache_misses
	hits_after_warm = SSdogmos.dogmos_mixture_cache_hits
	first.merge(second)
	first.return_temperature()
	second.return_temperature()
	if(SSdogmos.dogmos_mixture_cache_misses != misses_after_warm + 1 || SSdogmos.dogmos_mixture_cache_hits != hits_after_warm + 1)
		return Fail("Merging a mixture did not preserve its read-only source snapshot.", __FILE__, __LINE__)

	first.return_temperature()
	second.return_temperature()
	misses_after_warm = SSdogmos.dogmos_mixture_cache_misses
	first.transfer_to(second, 0.1)
	first.return_temperature()
	second.return_temperature()
	if(SSdogmos.dogmos_mixture_cache_misses != misses_after_warm + 2)
		return Fail("Transferring gas did not evict both mutated mixture snapshots.", __FILE__, __LINE__)

	var/list/fake_snapshot = new/list(42)
	SSdogmos.store_mixture_snapshot_cache(1, 7, fake_snapshot)
	var/collisions_before = SSdogmos.dogmos_mixture_cache_collisions
	// The current 2048-bucket cache maps these distinct slots to the same bucket.
	SSdogmos.store_mixture_snapshot_cache(2049, 9, fake_snapshot)
	if(SSdogmos.dogmos_mixture_cache_collisions != collisions_before + 1)
		return Fail("Direct-mapped cache collisions were not counted.", __FILE__, __LINE__)
	if(!isnull(SSdogmos.lookup_mixture_snapshot_cache(1, 7)))
		return Fail("A colliding slot retained the displaced cache entry.", __FILE__, __LINE__)
	if(SSdogmos.lookup_mixture_snapshot_cache(2049, 8))
		return Fail("The mixture snapshot cache accepted a mismatched generation.", __FILE__, __LINE__)

	var/invalidations_before = SSdogmos.dogmos_mixture_cache_epoch_invalidations
	SSdogmos.invalidate_mixture_snapshot_epoch()
	if(SSdogmos.dogmos_mixture_cache_epoch_invalidations != invalidations_before + 1 || SSdogmos.lookup_mixture_snapshot_cache(2049, 9))
		return Fail("Stage-wide epoch invalidation retained an old snapshot.", __FILE__, __LINE__)
	SSdogmos.dogmos_mixture_cache_epoch = 16777216
	SSdogmos.store_mixture_snapshot_cache(1, 1, fake_snapshot)
	SSdogmos.invalidate_mixture_snapshot_epoch()
	if(SSdogmos.dogmos_mixture_cache_epoch != 1 || SSdogmos.lookup_mixture_snapshot_cache(1, 1))
		return Fail("Exact-integer cache epoch rollover did not clear and reset the bounded cache.", __FILE__, __LINE__)

	first.return_temperature()
	var/misses_before_immutable = SSdogmos.dogmos_mixture_cache_misses
	first.mark_immutable()
	first.return_temperature()
	if(SSdogmos.dogmos_mixture_cache_misses != misses_before_immutable + 1)
		return Fail("Marking a mixture immutable did not evict its cached snapshot.", __FILE__, __LINE__)
	SSdogmos.evict_mixture_snapshot_cache(first.dogmos_slot, first.dogmos_generation)
	var/misses_before_local_immutable_check = SSdogmos.dogmos_mixture_cache_misses
	if(!first.is_immutable())
		return Fail("Dogmos did not retain the mixture's immutable state.", __FILE__, __LINE__)
	if(SSdogmos.dogmos_mixture_cache_misses != misses_before_local_immutable_check)
		return Fail("Checking a finalized mixture's immutable state fetched a service snapshot.", __FILE__, __LINE__)
	first.set_temperature(320)
	if(first.return_temperature() != 290)
		return Fail("Dogmos accepted a mutation after immutable finalization.", __FILE__, __LINE__)

/datum/unit_test/dogmos_service_mixture_snapshot_cache/Destroy()
	QDEL_NULL(first)
	QDEL_NULL(second)
	SSdogmos.reset_mixture_snapshot_cache()
	return ..()

/** Verifies pipeline rebuild storage preserves state without repeatedly fetching its source. */
/datum/unit_test/dogmos_service_pipeline_temporary_air
	/// Pipeline released during teardown.
	var/datum/pipeline/test_pipeline
	/// Pipeline-owned mixture released during teardown.
	var/datum/gas_mixture/pipeline_air
	/// First pipe detached before pipeline teardown.
	var/obj/machinery/atmospherics/pipe/first_pipe
	/// Second pipe detached before pipeline teardown.
	var/obj/machinery/atmospherics/pipe/second_pipe

/datum/unit_test/dogmos_service_pipeline_temporary_air/Run()
	if(!SSdogmos.service_ready)
		return Fail("dogmosd did not pass startup identity and health checks.", __FILE__, __LINE__)

	test_pipeline = new
	pipeline_air = new(300)
	pipeline_air.set_temperature(350)
	pipeline_air.set_moles(/datum/gas/oxygen, 30)
	pipeline_air.set_moles(/datum/gas/nitrogen, 15)
	test_pipeline.set_air(pipeline_air)

	first_pipe = allocate(/obj/machinery/atmospherics/pipe/smart/simple)
	second_pipe = allocate(/obj/machinery/atmospherics/pipe/smart/simple)
	first_pipe.volume = 100
	second_pipe.volume = 200
	test_pipeline.members = list(first_pipe, second_pipe)

	SSdogmos.reset_mixture_snapshot_cache()
	var/misses_before = SSdogmos.dogmos_mixture_cache_misses
	test_pipeline.temporarily_store_air()
	var/expected_snapshot_misses = 0
	var/actual_snapshot_misses = SSdogmos.dogmos_mixture_cache_misses - misses_before
	if(actual_snapshot_misses != expected_snapshot_misses)
		return Fail("Pipeline temporary storage used [actual_snapshot_misses] snapshots; expected direct native equalization without snapshots.", __FILE__, __LINE__)

	var/list/first_snapshot = first_pipe.air_temporary.dogmos_snapshot()
	var/list/second_snapshot = second_pipe.air_temporary.dogmos_snapshot()
	var/first_revision = SSdogmos.join_u32_words(first_snapshot[DOGMOS_TEST_SNAPSHOT_REVISION_LOW], first_snapshot[DOGMOS_TEST_SNAPSHOT_REVISION_HIGH])
	var/second_revision = SSdogmos.join_u32_words(second_snapshot[DOGMOS_TEST_SNAPSHOT_REVISION_LOW], second_snapshot[DOGMOS_TEST_SNAPSHOT_REVISION_HIGH])
	if(first_revision != 2 || second_revision != 2)
		return Fail("Pipeline temporary storage produced revisions [first_revision] and [second_revision]; expected constructor initialization plus one equalization command.", __FILE__, __LINE__)

	if(abs(first_pipe.air_temporary.return_volume() - 100) > DOGMOS_PIPELINE_TEST_EPSILON || abs(second_pipe.air_temporary.return_volume() - 200) > DOGMOS_PIPELINE_TEST_EPSILON)
		return Fail("Pipeline temporary storage did not preserve member volumes.", __FILE__, __LINE__)
	if(abs(first_pipe.air_temporary.return_temperature() - 350) > DOGMOS_PIPELINE_TEST_EPSILON || abs(second_pipe.air_temporary.return_temperature() - 350) > DOGMOS_PIPELINE_TEST_EPSILON)
		return Fail("Pipeline temporary storage did not preserve the source temperature.", __FILE__, __LINE__)
	if(abs(first_pipe.air_temporary.get_moles(/datum/gas/oxygen) - 10) > DOGMOS_PIPELINE_TEST_EPSILON || abs(second_pipe.air_temporary.get_moles(/datum/gas/oxygen) - 20) > DOGMOS_PIPELINE_TEST_EPSILON)
		return Fail("Pipeline temporary storage did not distribute oxygen by member volume.", __FILE__, __LINE__)
	if(abs(first_pipe.air_temporary.get_moles(/datum/gas/nitrogen) - 5) > DOGMOS_PIPELINE_TEST_EPSILON || abs(second_pipe.air_temporary.get_moles(/datum/gas/nitrogen) - 10) > DOGMOS_PIPELINE_TEST_EPSILON)
		return Fail("Pipeline temporary storage did not distribute nitrogen by member volume.", __FILE__, __LINE__)
	if(abs(first_pipe.air_temporary.get_moles(/datum/gas/oxygen) + second_pipe.air_temporary.get_moles(/datum/gas/oxygen) - 30) > DOGMOS_PIPELINE_TEST_EPSILON)
		return Fail("Pipeline temporary storage did not conserve total oxygen.", __FILE__, __LINE__)
	if(abs(first_pipe.air_temporary.get_moles(/datum/gas/nitrogen) + second_pipe.air_temporary.get_moles(/datum/gas/nitrogen) - 15) > DOGMOS_PIPELINE_TEST_EPSILON)
		return Fail("Pipeline temporary storage did not conserve total nitrogen.", __FILE__, __LINE__)

/datum/unit_test/dogmos_service_pipeline_temporary_air/Destroy()
	test_pipeline?.members.Cut()
	if(first_pipe)
		QDEL_NULL(first_pipe.air_temporary)
		first_pipe.parent = null
	if(second_pipe)
		QDEL_NULL(second_pipe.air_temporary)
		second_pipe.parent = null
	QDEL_NULL(test_pipeline)
	QDEL_NULL(pipeline_air)
	SSdogmos.reset_mixture_snapshot_cache()
	return ..()

/** Verifies one yielded pipeline expansion publishes its accumulated volume once. */
/datum/unit_test/dogmos_service_pipeline_expansion_volume_batch
	/// Pipeline released during teardown.
	var/datum/pipeline/test_pipeline
	/// Pipeline mixture released during teardown.
	var/datum/gas_mixture/pipeline_air
	/// Allocated pipes detached from the pipeline and each other during teardown.
	var/list/obj/machinery/atmospherics/pipe/test_pipes

/datum/unit_test/dogmos_service_pipeline_expansion_volume_batch/Run()
	if(!SSdogmos.service_ready)
		return Fail("dogmosd did not pass startup identity and health checks.", __FILE__, __LINE__)

	test_pipeline = new
	pipeline_air = new(10)
	test_pipeline.set_air(pipeline_air)
	test_pipes = list()
	for(var/pipe_index in 1 to 4)
		var/obj/machinery/atmospherics/pipe/smart/simple/test_pipe = allocate(/obj/machinery/atmospherics/pipe/smart/simple)
		test_pipe.has_gas_visuals = FALSE
		test_pipe.volume = pipe_index * 10
		test_pipe.nodes = list()
		test_pipes += test_pipe

	var/obj/machinery/atmospherics/pipe/first_pipe = test_pipes[1]
	for(var/pipe_index in 2 to length(test_pipes))
		var/obj/machinery/atmospherics/pipe/connected_pipe = test_pipes[pipe_index]
		first_pipe.nodes += connected_pipe
		connected_pipe.nodes += first_pipe

	first_pipe.parent = test_pipeline
	test_pipeline.members = list(first_pipe)
	var/list/revision_before_snapshot = pipeline_air.dogmos_snapshot()
	var/revision_before = SSdogmos.join_u32_words(revision_before_snapshot[DOGMOS_TEST_SNAPSHOT_REVISION_LOW], revision_before_snapshot[DOGMOS_TEST_SNAPSHOT_REVISION_HIGH])

	SSdogmos.reset_mixture_snapshot_cache()
	var/misses_before = SSdogmos.dogmos_mixture_cache_misses
	var/list/border = list(first_pipe)
	SSair.expand_pipeline(test_pipeline, border)
	for(var/obj/machinery/atmospherics/pipe/test_pipe as anything in test_pipes)
		if(test_pipe.parent != test_pipeline || !(test_pipe in test_pipeline.members))
			return Fail("Pipeline expansion did not attach every discovered pipe.", __FILE__, __LINE__)

	var/list/final_snapshot = pipeline_air.dogmos_snapshot()
	var/final_revision = SSdogmos.join_u32_words(final_snapshot[DOGMOS_TEST_SNAPSHOT_REVISION_LOW], final_snapshot[DOGMOS_TEST_SNAPSHOT_REVISION_HIGH])
	if(final_revision != revision_before + 1)
		return Fail("Pipeline expansion advanced mixture revision from [revision_before] to [final_revision]; expected one accumulated volume mutation.", __FILE__, __LINE__)
	if(abs(pipeline_air.return_volume() - 100) > DOGMOS_PIPELINE_TEST_EPSILON)
		return Fail("Pipeline expansion did not publish the summed member volume.", __FILE__, __LINE__)
	var/actual_snapshot_misses = SSdogmos.dogmos_mixture_cache_misses - misses_before
	if(actual_snapshot_misses != 2)
		return Fail("Pipeline expansion used [actual_snapshot_misses] snapshots; expected one initial volume read and one final verification snapshot.", __FILE__, __LINE__)

	SSdogmos.reset_mixture_snapshot_cache()
	var/empty_misses_before = SSdogmos.dogmos_mixture_cache_misses
	SSair.expand_pipeline(test_pipeline, list())
	if(SSdogmos.dogmos_mixture_cache_misses != empty_misses_before)
		return Fail("An empty pipeline expansion fetched mixture state.", __FILE__, __LINE__)

/datum/unit_test/dogmos_service_pipeline_expansion_volume_batch/Destroy()
	test_pipeline?.members.Cut()
	for(var/obj/machinery/atmospherics/pipe/test_pipe as anything in test_pipes)
		test_pipe.parent = null
		test_pipe.nodes = new(test_pipe.device_type)
	QDEL_NULL(test_pipeline)
	QDEL_NULL(pipeline_air)
	SSdogmos.reset_mixture_snapshot_cache()
	return ..()

/** Verifies pipenet reconciliation caches one native response while conserving mixture state. */
/datum/unit_test/dogmos_service_pipeline_batch_reconcile
	/// Pipeline released during teardown.
	var/datum/pipeline/test_pipeline
	/// First service-backed mixture released during teardown.
	var/datum/gas_mixture/first
	/// Second service-backed mixture released during teardown.
	var/datum/gas_mixture/second

/datum/unit_test/dogmos_service_pipeline_batch_reconcile/Run()
	if(!SSdogmos.service_ready)
		return Fail("dogmosd did not pass startup identity and health checks.", __FILE__, __LINE__)

	first = new(100)
	second = new(300)
	first.set_volume(100)
	second.set_volume(300)
	first.set_temperature(300)
	second.set_temperature(600)
	first.set_moles(/datum/gas/oxygen, 4)
	second.set_moles(/datum/gas/nitrogen, 12)
	var/expected_temperature = (first.return_temperature() * first.heat_capacity() + second.return_temperature() * second.heat_capacity()) / (first.heat_capacity() + second.heat_capacity())

	test_pipeline = new
	test_pipeline.set_air(first)
	test_pipeline.other_airs = list(second)
	var/invalidations_before = SSdogmos.dogmos_mixture_cache_epoch_invalidations
	test_pipeline.reconcile_air()

	if(SSdogmos.dogmos_mixture_cache_epoch_invalidations != invalidations_before)
		return Fail("Pipenet reconciliation invalidated the entire mixture snapshot cache.", __FILE__, __LINE__)
	if(!SSdogmos.lookup_mixture_snapshot_cache(first.dogmos_slot, first.dogmos_generation) || !SSdogmos.lookup_mixture_snapshot_cache(second.dogmos_slot, second.dogmos_generation))
		return Fail("Pipenet reconciliation did not cache both returned service snapshots.", __FILE__, __LINE__)
	var/first_oxygen = first.get_moles(/datum/gas/oxygen)
	var/second_oxygen = second.get_moles(/datum/gas/oxygen)
	if(abs(first_oxygen - 1) > DOGMOS_PIPELINE_TEST_EPSILON || abs(second_oxygen - 3) > DOGMOS_PIPELINE_TEST_EPSILON)
		return Fail("Pipenet reconciliation did not distribute oxygen by volume ratio: [first_oxygen] / [second_oxygen].", __FILE__, __LINE__)
	var/first_nitrogen = first.get_moles(/datum/gas/nitrogen)
	var/second_nitrogen = second.get_moles(/datum/gas/nitrogen)
	if(abs(first_nitrogen - 3) > DOGMOS_PIPELINE_TEST_EPSILON || abs(second_nitrogen - 9) > DOGMOS_PIPELINE_TEST_EPSILON)
		return Fail("Pipenet reconciliation did not distribute nitrogen by volume ratio: [first_nitrogen] / [second_nitrogen].", __FILE__, __LINE__)
	if(abs(first.return_temperature() - expected_temperature) > DOGMOS_PIPELINE_TEST_EPSILON || abs(second.return_temperature() - expected_temperature) > DOGMOS_PIPELINE_TEST_EPSILON)
		return Fail("Pipenet reconciliation did not conserve thermal energy.", __FILE__, __LINE__)

/datum/unit_test/dogmos_service_pipeline_batch_reconcile/Destroy()
	QDEL_NULL(test_pipeline)
	QDEL_NULL(first)
	QDEL_NULL(second)
	return ..()

/** Verifies pipenet reconciliation remains atomic beyond one control-frame payload. */
/datum/unit_test/dogmos_service_oversized_pipeline_batch_reconcile
	/// Pipeline released during teardown.
	var/datum/pipeline/test_pipeline
	/// Service-backed mixtures released during teardown.
	var/list/test_mixtures

/** Registers each fixture before mutation so a rejected native call cannot leak its mixture. */
/datum/unit_test/dogmos_service_oversized_pipeline_batch_reconcile/Run()
	if(!SSdogmos.service_ready)
		return Fail("dogmosd did not pass startup identity and health checks.", __FILE__, __LINE__)

	test_mixtures = list()
	for(var/mixture_index in 1 to DOGMOS_TEST_OVERSIZED_PIPELINE_MIXTURES)
		var/datum/gas_mixture/mixture = new(100)
		test_mixtures += mixture
		mixture.set_temperature(300)
		mixture.set_moles(/datum/gas/oxygen, 1)

	test_pipeline = new
	test_pipeline.set_air(test_mixtures[1])
	test_pipeline.other_airs = test_mixtures.Copy(2)
	test_pipeline.reconcile_air()

	if(!SSdogmos.service_ready || !dogmos_service_health())
		return Fail("dogmosd became unavailable while reconciling an oversized pipeline batch.", __FILE__, __LINE__)
	for(var/datum/gas_mixture/mixture as anything in test_mixtures)
		if(abs(mixture.get_moles(/datum/gas/oxygen) - 1) > DOGMOS_PIPELINE_TEST_EPSILON || abs(mixture.return_temperature() - 300) > DOGMOS_PIPELINE_TEST_EPSILON)
			return Fail("Oversized pipenet reconciliation changed an equivalent mixture's conserved state.", __FILE__, __LINE__)

/datum/unit_test/dogmos_service_oversized_pipeline_batch_reconcile/Destroy()
	QDEL_NULL(test_pipeline)
	QDEL_LIST(test_mixtures)
	return ..()


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
