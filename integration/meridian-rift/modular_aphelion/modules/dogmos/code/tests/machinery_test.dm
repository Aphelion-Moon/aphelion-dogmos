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

/** Verifies a dirty pipeline wakes an attached dormant atmosphere machine. */
/datum/unit_test/dogmos_idle_machinery_pipeline_wake
	/// Pipeline released during teardown.
	var/datum/pipeline/test_pipeline
	/// Pipeline-owned mixture released during teardown.
	var/datum/gas_mixture/pipeline_air

/datum/unit_test/dogmos_idle_machinery_pipeline_wake/Run()
	var/obj/machinery/atmospherics/components/binary/pump/test_pump = allocate(/obj/machinery/atmospherics/components/binary/pump)
	SSair.stop_processing_machine(test_pump)
	test_pipeline = new
	pipeline_air = new(200)
	test_pipeline.set_air(pipeline_air)
	test_pipeline.other_atmos_machines |= test_pump
	test_pipeline.update = TRUE
	test_pipeline.process()
	if(!(test_pump in SSair.atmos_machinery))
		return Fail("A dirty pipeline did not wake its attached dormant atmosphere machine.", __FILE__, __LINE__)

/datum/unit_test/dogmos_idle_machinery_pipeline_wake/Destroy()
	test_pipeline?.other_atmos_machines.Cut()
	QDEL_NULL(test_pipeline)
	QDEL_NULL(pipeline_air)
	return ..()

/** Verifies component gas is preserved when its node outlives its destroyed pipenet. */
/datum/unit_test/dogmos_component_relocates_air_without_parent
	/// Destination mixture released during teardown.
	var/datum/gas_mixture/released_air

/datum/unit_test/dogmos_component_relocates_air_without_parent/Run()
	var/obj/machinery/atmospherics/components/unary/vent_pump/test_component = allocate(/obj/machinery/atmospherics/components/unary/vent_pump, run_loc_floor_bottom_left)
	released_air = new(200)
	test_component.nodes[1] = test_component
	test_component.parents[1] = null
	test_component.airs[1].set_moles(GAS_O2, 10)

	test_component.relocate_airs(released_air)

	if(released_air.get_moles(GAS_O2) != 10)
		return Fail("Component gas was not relocated after its node outlived the parent pipenet.", __FILE__, __LINE__)

/datum/unit_test/dogmos_component_relocates_air_without_parent/Destroy()
	QDEL_NULL(released_air)
	return ..()

/** Verifies a pump sleeps when its current gas state cannot produce a transfer. */
/datum/unit_test/dogmos_idle_machinery_pump_sleeps
	/// Input pipeline released during teardown.
	var/datum/pipeline/input_pipeline
	/// Output pipeline released during teardown.
	var/datum/pipeline/output_pipeline
	/// Input pipeline mixture released during teardown.
	var/datum/gas_mixture/input_pipeline_air
	/// Output pipeline mixture released during teardown.
	var/datum/gas_mixture/output_pipeline_air

/datum/unit_test/dogmos_idle_machinery_pump_sleeps/Run()
	var/obj/machinery/atmospherics/components/binary/pump/test_pump = allocate(/obj/machinery/atmospherics/components/binary/pump)
	input_pipeline = new
	output_pipeline = new
	input_pipeline_air = new(200)
	output_pipeline_air = new(200)
	input_pipeline.set_air(input_pipeline_air)
	output_pipeline.set_air(output_pipeline_air)
	test_pump.parents[1] = input_pipeline
	test_pump.parents[2] = output_pipeline
	test_pump.on = TRUE
	if(test_pump.process_atmos(SSair.wait * 0.1) != PROCESS_KILL)
		return Fail("A gas pump with no transferable gas did not return PROCESS_KILL.", __FILE__, __LINE__)

/datum/unit_test/dogmos_idle_machinery_pump_sleeps/Destroy()
	QDEL_NULL(input_pipeline)
	QDEL_NULL(output_pipeline)
	QDEL_NULL(input_pipeline_air)
	QDEL_NULL(output_pipeline_air)
	return ..()

/** Verifies turning on dormant atmosphere machinery wakes it immediately. */
/datum/unit_test/dogmos_idle_machinery_control_wake

/datum/unit_test/dogmos_idle_machinery_control_wake/Run()
	var/obj/machinery/atmospherics/components/binary/pump/test_pump = allocate(/obj/machinery/atmospherics/components/binary/pump)
	test_pump.set_on(FALSE)
	SSair.stop_processing_machine(test_pump)
	test_pump.set_on(TRUE)
	if(!(test_pump in SSair.atmos_machinery))
		return Fail("Turning on dormant atmosphere machinery did not wake it immediately.", __FILE__, __LINE__)

/** Verifies dormant enabled atmosphere machinery wakes when it becomes operational. */
/datum/unit_test/dogmos_idle_machinery_operational_wake

/datum/unit_test/dogmos_idle_machinery_operational_wake/Run()
	var/obj/machinery/atmospherics/components/binary/pump/test_pump = allocate(/obj/machinery/atmospherics/components/binary/pump)
	test_pump.on = TRUE
	test_pump.set_is_operational(FALSE)
	SSair.stop_processing_machine(test_pump)
	if(test_pump in SSair.atmos_machinery)
		return Fail("The operational wake test requires dormant machinery.", __FILE__, __LINE__)
	test_pump.set_is_operational(TRUE)
	if(!(test_pump in SSair.atmos_machinery))
		return Fail("Dormant enabled atmosphere machinery did not wake when it became operational.", __FILE__, __LINE__)

/** Verifies turf atmosphere activity wakes a dormant vent on that turf. */
/datum/unit_test/dogmos_idle_machinery_turf_wake

/datum/unit_test/dogmos_idle_machinery_turf_wake/Run()
	var/obj/machinery/atmospherics/components/unary/vent_pump/test_vent = allocate(/obj/machinery/atmospherics/components/unary/vent_pump)
	SSair.stop_processing_machine(test_vent)
	SSair.add_to_active(run_loc_floor_bottom_left)
	if(!(test_vent in SSair.atmos_machinery))
		return Fail("Turf atmosphere activity did not wake a dormant vent on that turf.", __FILE__, __LINE__)

/** Verifies turf meter deletion reaches parent cleanup without accessing pipe-only state. */
/datum/unit_test/dogmos_turf_meter_destroy

/datum/unit_test/dogmos_turf_meter_destroy/Run()
	var/obj/machinery/meter/turf/test_meter = allocate(/obj/machinery/meter/turf)
	if(test_meter.target != run_loc_floor_bottom_left)
		return Fail("The turf meter must attach to its turf.", __FILE__, __LINE__)
	qdel(test_meter, force = TRUE)
	if(!isnull(test_meter.target))
		return Fail("Deleting a turf meter must clear its target.", __FILE__, __LINE__)
	if(!isnull(test_meter.loc))
		return Fail("Deleting a turf meter must reach parent cleanup and leave the map.", __FILE__, __LINE__)
	if(test_meter in SSair.atmos_machinery)
		return Fail("Deleted turf meters must leave atmosphere processing.", __FILE__, __LINE__)

/** Verifies pipe meter deletion removes the pipeline's wakeup reference. */
/datum/unit_test/dogmos_pipe_meter_destroy

/datum/unit_test/dogmos_pipe_meter_destroy/Run()
	var/obj/machinery/atmospherics/pipe/test_pipe = allocate(/obj/machinery/atmospherics/pipe/smart/simple)
	var/obj/machinery/meter/test_meter = allocate(/obj/machinery/meter)
	if(test_meter.target != test_pipe)
		return Fail("The pipe meter must attach to the test pipe.", __FILE__, __LINE__)
	if(!(test_meter in test_pipe.dogmos_pipeline_meters))
		return Fail("The pipe must register the meter for pipeline wakeups.", __FILE__, __LINE__)
	qdel(test_meter, force = TRUE)
	if(test_meter in test_pipe.dogmos_pipeline_meters)
		return Fail("Deleting a pipe meter must remove its pipeline wakeup reference.", __FILE__, __LINE__)
	if(!isnull(test_meter.target))
		return Fail("Deleting a pipe meter must clear its target.", __FILE__, __LINE__)
	if(!isnull(test_meter.loc))
		return Fail("Deleting a pipe meter must reach parent cleanup and leave the map.", __FILE__, __LINE__)

/** Verifies a stable pipe meter sleeps and wakes on its pipeline's next change. */
/datum/unit_test/dogmos_idle_meter_scheduler
	/// Pipeline released during teardown.
	var/datum/pipeline/test_pipeline
	/// Pipeline-owned mixture released during teardown.
	var/datum/gas_mixture/pipeline_air
	/// Pipe detached before pipeline teardown.
	var/obj/machinery/atmospherics/pipe/test_pipe
	/// Meter detached from the pipe before teardown.
	var/obj/machinery/meter/test_meter

/datum/unit_test/dogmos_idle_meter_scheduler/Run()
	test_pipe = allocate(/obj/machinery/atmospherics/pipe/smart/simple)
	test_meter = allocate(/obj/machinery/meter)
	test_pipeline = new
	pipeline_air = new(200)
	test_pipeline.set_air(pipeline_air)
	test_pipeline.members |= test_pipe
	test_pipe.parent = test_pipeline
	test_meter.target = test_pipe
	test_pipe.dogmos_pipeline_meters |= test_meter
	if(test_meter.process_atmos() != PROCESS_KILL)
		return Fail("A stable pipe meter did not return PROCESS_KILL.", __FILE__, __LINE__)
	SSair.stop_processing_machine(test_meter)
	test_pipeline.update = TRUE
	test_pipeline.process()
	if(!(test_meter in SSair.atmos_machinery))
		return Fail("A dirty pipeline did not wake its dormant pipe meter.", __FILE__, __LINE__)

/datum/unit_test/dogmos_idle_meter_scheduler/Destroy()
	if(test_meter && test_pipe)
		test_pipe.dogmos_pipeline_meters -= test_meter
		test_meter.target = null
	if(test_pipe)
		test_pipe.parent = null
	test_pipeline?.members.Cut()
	QDEL_NULL(test_pipeline)
	QDEL_NULL(pipeline_air)
	return ..()

/** Verifies a vent sleeps after reaching its configured pressure bound. */
/datum/unit_test/dogmos_idle_machinery_vent_sleeps

/datum/unit_test/dogmos_idle_machinery_vent_sleeps/Run()
	var/obj/machinery/atmospherics/components/unary/vent_pump/test_vent = allocate(/obj/machinery/atmospherics/components/unary/vent_pump)
	test_vent.nodes[1] = test_vent
	test_vent.on = TRUE
	test_vent.external_pressure_bound = run_loc_floor_bottom_left.return_air().return_pressure()
	if(test_vent.process_atmos(SSair.wait * 0.1) != PROCESS_KILL)
		return Fail("A vent at its configured pressure bound did not return PROCESS_KILL.", __FILE__, __LINE__)

/** Verifies a stable pressure tank sleeps until its pipeline changes. */
/datum/unit_test/dogmos_idle_machinery_tank_sleeps

/datum/unit_test/dogmos_idle_machinery_tank_sleeps/Run()
	var/obj/machinery/atmospherics/components/tank/test_tank = allocate(/obj/machinery/atmospherics/components/tank)
	if(test_tank.process_atmos(SSair.wait * 0.1) != PROCESS_KILL)
		return Fail("A stable under-pressure tank did not return PROCESS_KILL.", __FILE__, __LINE__)

/** Verifies an enabled filter sleeps when its input contains no transferable gas. */
/datum/unit_test/dogmos_idle_machinery_filter_sleeps

/datum/unit_test/dogmos_idle_machinery_filter_sleeps/Run()
	var/obj/machinery/atmospherics/components/trinary/filter/test_filter = allocate(/obj/machinery/atmospherics/components/trinary/filter)
	test_filter.nodes[1] = test_filter
	test_filter.nodes[2] = test_filter
	test_filter.nodes[3] = test_filter
	test_filter.on = TRUE
	if(test_filter.process_atmos(SSair.wait * 0.1) != PROCESS_KILL)
		return Fail("An enabled filter with empty input did not return PROCESS_KILL.", __FILE__, __LINE__)

/** Verifies a stable heat pipe wakes on pipeline changes and sleeps after convergence. */
/datum/unit_test/dogmos_idle_heat_pipe_scheduler
	/// Pipeline released during teardown.
	var/datum/pipeline/test_pipeline
	/// Pipeline-owned mixture released during teardown.
	var/datum/gas_mixture/pipeline_air
	/// Heat pipe detached before pipeline teardown.
	var/obj/machinery/atmospherics/pipe/heat_exchanging/test_pipe

/datum/unit_test/dogmos_idle_heat_pipe_scheduler/Run()
	test_pipe = allocate(/obj/machinery/atmospherics/pipe/heat_exchanging/simple)
	test_pipeline = new
	pipeline_air = new(200)
	pipeline_air.set_temperature(run_loc_floor_bottom_left.GetTemperature())
	test_pipeline.set_air(pipeline_air)
	test_pipeline.members |= test_pipe
	test_pipe.parent = test_pipeline
	SSair.stop_processing_machine(test_pipe)
	test_pipeline.update = TRUE
	test_pipeline.process()
	if(!(test_pipe in SSair.atmos_machinery))
		return Fail("A dirty pipeline did not wake its dormant heat-exchange pipe.", __FILE__, __LINE__)
	pipeline_air.set_temperature(run_loc_floor_bottom_left.GetTemperature())
	if(test_pipe.process_atmos(SSair.wait * 0.1) != PROCESS_KILL)
		return Fail("A stable heat-exchange pipe did not return PROCESS_KILL.", __FILE__, __LINE__)
	SSair.stop_processing_machine(test_pipe)
	SSair.add_to_active(run_loc_floor_bottom_left)
	if(!(test_pipe in SSair.atmos_machinery))
		return Fail("Turf atmosphere activity did not wake its dormant heat-exchange pipe.", __FILE__, __LINE__)
	SSair.stop_processing_machine(test_pipe)
	var/mob/living/test_mob = allocate(/mob/living/carbon/human/consistent)
	test_pipe.post_buckle_mob(test_mob)
	if(!(test_pipe in SSair.atmos_machinery))
		return Fail("Buckling a mob did not wake its dormant heat-exchange pipe.", __FILE__, __LINE__)

/datum/unit_test/dogmos_idle_heat_pipe_scheduler/Destroy()
	if(test_pipe)
		test_pipe.parent = null
	test_pipeline?.members.Cut()
	QDEL_NULL(test_pipeline)
	QDEL_NULL(pipeline_air)
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
