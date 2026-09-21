#if defined(UNIT_TESTS) || defined(SPACEMAN_DMM)

/** Registration must not allocate a reverse weak reference before any callback needs it. */
/datum/unit_test/dogmos_mixture_registration_without_weakref

/** Checks registration without giving the fixture an extra weak reference. */
/datum/unit_test/dogmos_mixture_registration_without_weakref/Run()
	var/datum/gas_mixture/mixture = allocate(/datum/gas_mixture, CELL_VOLUME)
	var/allocated_weakref = !isnull(mixture.weak_reference)
	qdel(mixture)
	if(allocated_weakref)
		return Fail("Mixture registration allocated an eager reverse weak reference.", __FILE__, __LINE__)

/** Returns an ownership token after dropping the only reference to its mixture. */
/datum/unit_test/dogmos_identity_token_gc/proc/drop_temporary_mixture()
	var/datum/gas_mixture/temporary = new(CELL_VOLUME)
	var/list/result = list(temporary.dogmos_slot, temporary.dogmos_generation, temporary.dogmos_identity_token)
	temporary = null
	return result

/** Token retention must not prevent ordinary BYOND collection and native unregistration. */
/datum/unit_test/dogmos_identity_token_gc

/** Leaves the GC subject unowned and tracks only the replacement for failure-safe teardown. */
/datum/unit_test/dogmos_identity_token_gc/Run()
	if(!dogmos_wait_for_stage_boundary())
		return
	var/list/identity = drop_temporary_mixture()
	var/slot = identity[1]
	if(!islist(identity[3]) || length(identity[3]))
		return Fail("Registration did not create an opaque empty ownership token.", __FILE__, __LINE__)
	if(!isnull(SSdogmos.dogmos_mixture_slots[slot]) || !(slot in SSdogmos.dogmos_free_mixture_slots))
		return Fail("The retained ownership token prevented mixture GC and native unregistration.", __FILE__, __LINE__)
	var/datum/gas_mixture/reused = allocate(/datum/gas_mixture, CELL_VOLUME)
	var/failure
	if(reused.dogmos_slot != slot || reused.dogmos_generation != identity[2] + 1 || reused.dogmos_identity_token == identity[3])
		failure = "Collected mixture reuse did not advance generation and replace its ownership token."
	qdel(reused)
	if(failure)
		return Fail(failure, __FILE__, __LINE__)

/** Matching numeric handles cannot impersonate a different mixture's ownership token. */
/datum/unit_test/dogmos_identity_token_foreign

/** Restores forged identity fields before base teardown can release either real mixture. */
/datum/unit_test/dogmos_identity_token_foreign/Run()
	var/datum/gas_mixture/first = allocate(/datum/gas_mixture, CELL_VOLUME)
	var/datum/gas_mixture/second = allocate(/datum/gas_mixture, CELL_VOLUME / 2)
	var/second_slot = second.dogmos_slot
	var/second_generation = second.dogmos_generation
	var/failure
	try
		if(!SSdogmos.mixture_identity_matches(first, first.dogmos_slot, first.dogmos_generation) || second.return_volume() != CELL_VOLUME / 2)
			failure = "Registration changed live identity or non-default volume initialization."
		second.dogmos_slot = first.dogmos_slot
		second.dogmos_generation = first.dogmos_generation
		if(SSdogmos.mixture_identity_matches(second, first.dogmos_slot, first.dogmos_generation))
			failure = "A foreign token impersonated a registered mixture."
		if(SSdogmos.mixture_identity_matches(first, first.dogmos_slot, first.dogmos_generation + 1) || SSdogmos.mixture_identity_matches(first, 0, 0) || SSdogmos.mixture_identity_matches(first, length(SSdogmos.dogmos_mixture_slots) + 1, 1))
			failure = "An invalid slot or stale generation passed mixture validation."
	catch(var/exception/error)
		failure = "Identity validation raised [error.name]."
	second.dogmos_slot = second_slot
	second.dogmos_generation = second_generation
	qdel(first)
	qdel(second)
	if(failure)
		return Fail(failure, __FILE__, __LINE__)

/** Encodes only identity fields consumed by the real general-reaction decoder. */
/datum/unit_test/dogmos_identity_token_turf_context/proc/encode_subject(datum/gas_mixture/mixture, turf/target)
	var/list/batch = new/list(48)
	// Event offset 13; subject slot/generation at +11/+13, target at +15/+17.
	var/list/handles = list(mixture.dogmos_slot, mixture.dogmos_generation, target.dogmos_service_slot(), target.dogmos_registration_generation)
	for(var/index in 1 to 4)
		var/field = 24 + (index - 1) * 2
		batch[field] = handles[index] % 65536
		batch[field + 1] = floor(handles[index] / 65536)
	return batch

/** General callbacks must resolve the exact turf and its current mixture together. */
/datum/unit_test/dogmos_identity_token_turf_context

/** Restores turf ownership before releasing the callback fixture's replacement mixture. */
/datum/unit_test/dogmos_identity_token_turf_context/Run()
	var/turf/open/target = run_loc_floor_bottom_left
	var/datum/gas_mixture/original = target.air
	var/datum/gas_mixture/replacement = allocate(/datum/gas_mixture, CELL_VOLUME)
	var/list/callback = encode_subject(original, target)
	var/failure
	try
		var/list/live = SSdogmos.decode_general_reaction_subject(callback, 13)
		if(live[1] != original)
			failure = "The callback decoder rejected the current turf and mixture."
		callback[30]++ // Stale target generation, leaving the live mixture handle unchanged.
		var/list/stale_target = SSdogmos.decode_general_reaction_subject(callback, 13)
		if(stale_target[1])
			failure = "The callback decoder accepted a stale turf generation."
		callback[30]--
		target.air = replacement
		var/list/changed_air = SSdogmos.decode_general_reaction_subject(callback, 13)
		if(changed_air[1])
			failure = "The callback decoder accepted air no longer owned by its target turf."
	catch(var/exception/error)
		failure = "The callback identity decoder raised [error.name]."
	target.air = original
	qdel(replacement)
	if(failure)
		return Fail(failure, __FILE__, __LINE__)


#endif
