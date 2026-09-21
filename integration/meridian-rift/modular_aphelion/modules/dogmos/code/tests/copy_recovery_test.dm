#if defined(UNIT_TESTS) || defined(SPACEMAN_DMM)

/** Test constructor whose extra state and copy hook must retain dynamic subtype dispatch. */
/datum/gas_mixture/dogmos_copy_constructor_test
	/// Number of arguments delivered to the custom constructor.
	var/constructor_arguments
	/// Calls through the subtype's normal copy hook.
	var/copy_calls = 0

/datum/gas_mixture/dogmos_copy_constructor_test/New(volume)
	constructor_arguments = length(args)
	. = ..()
	last_share = 7
	pipeline_cycle = 91
	reaction_results["constructor"] = 1
	set_min_heat_capacity(88)

/datum/gas_mixture/dogmos_copy_constructor_test/copy_from(datum/gas_mixture/sample)
	copy_calls++
	return ..()

/** Copy construction must preserve the old constructor sequence and independent mutable state. */
/datum/unit_test/dogmos_service_copy_construction

/datum/unit_test/dogmos_service_copy_construction/Run()
	for(var/mixture_type in list(/datum/gas_mixture, /datum/gas_mixture/turf))
		for(var/volume in list(CELL_VOLUME, 125))
			for(var/with_gas in list(FALSE, TRUE))
				var/datum/gas_mixture/source = allocate(mixture_type, volume)
				if(with_gas)
					source.set_temperature(321.5)
					source.set_moles(/datum/gas/oxygen, 7.25)
					source.set_moles(/datum/gas/nitrogen, 3)
				source.set_min_heat_capacity(17)
				source.last_share = 53
				source.pipeline_cycle = 9
				source.reaction_results["source"] = 7
				var/list/source_before = source.dogmos_snapshot()
				var/datum/gas_mixture/copied = source.copy()
				allocated += copied
				if((copied.type) != (mixture_type))
					return Fail("copy changed the exact mixture type", __FILE__, __LINE__)
				if((SSdogmos.lookup_mixture_snapshot_cache(source.dogmos_slot, source.dogmos_generation)) != (source_before))
					return Fail("read-only copy evicted the source snapshot", __FILE__, __LINE__)
				if((copied.initial_volume) != (volume))
					return Fail("copy lost constructor volume", __FILE__, __LINE__)
				if((copied.last_share) != (0))
					return Fail("copy inherited source share metadata", __FILE__, __LINE__)
				if((copied.pipeline_cycle) != (-1))
					return Fail("copy inherited source pipeline metadata", __FILE__, __LINE__)
				if((copied.reaction_results) == (source.reaction_results))
					return Fail("copy shares the reaction result list", __FILE__, __LINE__)
				if((length(copied.reaction_results)) != (0))
					return Fail("copy inherited reaction results", __FILE__, __LINE__)
				if(!(SSdogmos.mixture_identity_matches(copied, copied.dogmos_slot, copied.dogmos_generation)))
					return Fail("copy was returned before its identity became live", __FILE__, __LINE__)
				var/datum/gas_mixture/control = allocate(mixture_type, volume)
				control.copy_from(source)
				var/list/expected = control.dogmos_snapshot()
				var/list/actual = copied.dogmos_snapshot()
				if((length(actual)) != (length(expected)))
					return Fail("copy snapshot width changed", __FILE__, __LINE__)
				for(var/field in 1 to length(expected))
					if((actual[field]) != (expected[field]))
						return Fail("copy changed native snapshot field [field]", __FILE__, __LINE__)
				copied.set_moles(/datum/gas/oxygen, 99)
				var/list/source_after = source.dogmos_snapshot()
				for(var/field in 1 to length(source_before))
					if((source_after[field]) != (source_before[field]))
						return Fail("mutating copy changed source field [field]", __FILE__, __LINE__)
				source.set_temperature(700)
				if((copied.return_temperature()) != (with_gas ? 321.5 : TCMB))
					return Fail("mutating source changed copied temperature", __FILE__, __LINE__)

/** A copied mixture retires through the ordinary identity lifecycle before its slot is reused. */
/datum/unit_test/dogmos_service_copy_identity_reuse

/datum/unit_test/dogmos_service_copy_identity_reuse/Run()
	if(!dogmos_wait_for_stage_boundary())
		return
	var/datum/gas_mixture/source = allocate(/datum/gas_mixture, CELL_VOLUME)
	source.set_moles(/datum/gas/oxygen, 7.25)
	var/datum/gas_mixture/first = source.copy()
	allocated += first
	var/retired_slot = first.dogmos_slot
	var/retired_generation = first.dogmos_generation
	first.dogmos_snapshot()
	first.__gasmixture_unregister()
	if(!isnull(first._extools_pointer_gasmixture))
		return Fail("retired copy kept its native registration marker", __FILE__, __LINE__)
	if(!isnull(SSdogmos.lookup_mixture_snapshot_cache(retired_slot, retired_generation)))
		return Fail("retired copy kept its cached state", __FILE__, __LINE__)
	var/datum/gas_mixture/replacement = source.copy()
	allocated += replacement
	if((replacement.dogmos_slot) != (retired_slot))
		return Fail("copy did not reuse the released slot", __FILE__, __LINE__)
	if(!(replacement.dogmos_generation > retired_generation))
		return Fail("copy reused a retired generation", __FILE__, __LINE__)
	if((replacement.get_moles(/datum/gas/oxygen)) != (7.25))
		return Fail("reused copy lost source gas", __FILE__, __LINE__)
	if(!(SSdogmos.mixture_identity_matches(replacement, replacement.dogmos_slot, replacement.dogmos_generation)))
		return Fail("replacement copy identity is not live", __FILE__, __LINE__)
	if(!(!SSdogmos.mixture_identity_matches(first, retired_slot, retired_generation)))
		return Fail("retired copy identity resolved after slot reuse", __FILE__, __LINE__)

/** Custom and immutable constructors keep their old New and copy_from behavior. */
/datum/unit_test/dogmos_service_copy_subtypes

/datum/unit_test/dogmos_service_copy_subtypes/Run()
	var/datum/gas_mixture/dogmos_copy_constructor_test/custom = allocate(/datum/gas_mixture/dogmos_copy_constructor_test, 125)
	custom.set_temperature(321.5)
	custom.set_moles(/datum/gas/oxygen, 7.25)
	var/datum/gas_mixture/dogmos_copy_constructor_test/copied = custom.copy()
	allocated += copied
	if((copied.type) != (custom.type))
		return Fail("custom copy changed type", __FILE__, __LINE__)
	if((copied.constructor_arguments) != (1))
		return Fail("custom constructor received an internal copy argument", __FILE__, __LINE__)
	if((copied.copy_calls) != (1))
		return Fail("custom copy hook was skipped", __FILE__, __LINE__)
	if((copied.last_share) != (7))
		return Fail("custom constructor share state was lost", __FILE__, __LINE__)
	if((copied.pipeline_cycle) != (91))
		return Fail("custom constructor pipeline state was lost", __FILE__, __LINE__)
	if((copied.reaction_results["constructor"]) != (1))
		return Fail("custom constructor reaction result was lost", __FILE__, __LINE__)
	if((copied.reaction_results) == (custom.reaction_results))
		return Fail("custom copies share reaction results", __FILE__, __LINE__)
	if((copied.return_temperature()) != (321.5))
		return Fail("custom copy changed temperature", __FILE__, __LINE__)
	if((copied.get_moles(/datum/gas/oxygen)) != (7.25))
		return Fail("custom copy changed gas", __FILE__, __LINE__)
	for(var/mixture_type in list(/datum/gas_mixture/immutable/space, /datum/gas_mixture/immutable/planetary))
		var/datum/gas_mixture/immutable/source = allocate(mixture_type, 125)
		if(istype(source, /datum/gas_mixture/immutable/planetary))
			var/datum/gas_mixture/immutable/planetary/planetary = source
			planetary.parse_string_immutable("o2=7.25;TEMP=321.5")
		var/datum/gas_mixture/immutable/duplicate = source.copy()
		allocated += duplicate
		var/datum/gas_mixture/immutable/control = allocate(mixture_type, source.return_volume())
		control.copy_from(source)
		if((duplicate.type) != (mixture_type))
			return Fail("immutable subtype changed", __FILE__, __LINE__)
		var/list/actual = duplicate.dogmos_snapshot()
		var/list/expected = control.dogmos_snapshot()
		for(var/field in 1 to length(expected))
			if((actual[field]) != (expected[field]))
				return Fail("immutable fallback changed snapshot field [field]", __FILE__, __LINE__)

/** Real subsystem replacement must transfer state and retire the previous native-session owner. */
/datum/unit_test/dogmos_recovery_owner_transfer

/** Leaves the replacement registered with the Master; the service world is never reinitialized. */
/datum/unit_test/dogmos_recovery_owner_transfer/Run()
	if(!dogmos_wait_for_stage_boundary())
		return
	var/service_pid = dogmos_service_pid()
	var/list/world_generation = dogmos_service_world_generation()
	var/datum/gas_mixture/sentinel = allocate(/datum/gas_mixture, CELL_VOLUME)
	sentinel.set_temperature(321.5)
	sentinel.set_moles(/datum/gas/oxygen, 7.25)
	// Repeat the same bounded transfer without yielding or duplicating the service world.
	// Report process roles separately; allocator noise is not a performance pass threshold.
	for(var/batch in 1 to 3)
		var/list/before = dogmos_process_metrics_snapshot()
		var/start_tick_usage = world.tick_usage
		for(var/iteration in 1 to 20)
			var/datum/controller/subsystem/dogmos/previous_owner = SSdogmos
			var/master_index = Master.subsystems.Find(previous_owner)
			if(!master_index)
				return Fail("The current Dogmos owner is missing from the Master.", __FILE__, __LINE__)
			var/list/identities = previous_owner.dogmos_mixture_slots
			var/list/generations = previous_owner.dogmos_mixture_generations
			var/list/callback_sequence = previous_owner.dogmos_next_callback_sequence
			var/list/adjacency_queue = previous_owner.dogmos_pending_turf_adjacency
			var/list/adjacency_index = previous_owner.dogmos_pending_turf_adjacency_index
			var/list/snapshot_cache = previous_owner.dogmos_mixture_cache
			// NEW_SS_GLOBAL calls Recover, deletes the prior subsystem, then installs this one.
			// The Master owns the replacement; base fixture teardown must not delete it.
			var/datum/controller/subsystem/dogmos/replacement = new
			Master.subsystems.Insert(master_index, replacement)
			if(SSdogmos != replacement || !QDELETED(previous_owner) || replacement.dogmos_mixture_slots != identities || replacement.dogmos_mixture_generations != generations)
				return Fail("Subsystem replacement did not preserve identity ownership.", __FILE__, __LINE__)
			if(previous_owner.gases_registered || previous_owner.service_ready || previous_owner.dogmos_mixture_slots || previous_owner.dogmos_pending_callback_batch)
				return Fail("The retired Dogmos owner still retains native admission or transferred references.", __FILE__, __LINE__)
			previous_owner.Shutdown()
			if(replacement.dogmos_next_callback_sequence != callback_sequence || replacement.dogmos_pending_turf_adjacency != adjacency_queue || replacement.dogmos_pending_turf_adjacency_index != adjacency_index || replacement.dogmos_mixture_cache != snapshot_cache)
				return Fail("Old-owner shutdown changed transferred queues, indexes or cache identity.", __FILE__, __LINE__)
			var/list/current_generation = dogmos_service_world_generation()
			if(!dogmos_service_health() || dogmos_service_pid() != service_pid || current_generation[1] != world_generation[1] || current_generation[2] != world_generation[2])
				return Fail("Retiring the old owner replaced or stopped the authoritative service world.", __FILE__, __LINE__)
			if(sentinel.return_temperature() != 321.5 || sentinel.get_moles(/datum/gas/oxygen) != 7.25)
				return Fail("Owner transfer changed the sentinel mixture.", __FILE__, __LINE__)
		var/cost_ms = TICK_USAGE_TO_MS(start_tick_usage)
		var/list/after = dogmos_process_metrics_snapshot()
		log_test("Dogmos recovery batch [batch]: 20 replacements, [cost_ms]ms; DreamDaemon private [before["dreamdaemon"]["private_bytes"]] -> [after["dreamdaemon"]["private_bytes"]], virtual [before["dreamdaemon"]["virtual_bytes"]] -> [after["dreamdaemon"]["virtual_bytes"]]; deltas: DreamDaemon private [after["dreamdaemon"]["private_bytes"] - before["dreamdaemon"]["private_bytes"]], virtual [after["dreamdaemon"]["virtual_bytes"] - before["dreamdaemon"]["virtual_bytes"]]; dogmosd RSS [before["dogmosd"]["rss_bytes"]] -> [after["dogmosd"]["rss_bytes"]], delta [after["dogmosd"]["rss_bytes"] - before["dogmosd"]["rss_bytes"]].")



#define DOGMOS_FAILURE_FENCE_STAGE 4


#undef DOGMOS_FAILURE_FENCE_STAGE
#endif
