/** Publishes an accepted mixture registration or fails the atmosphere subsystem closed.
 *
 * Arguments:
 * * mixture - Mixture receiving the accepted service identity.
 * * slot - Allocated service slot.
 * * generation - Allocated service generation.
 * * response - Accepted registration count from a lifecycle or create response.
 * * schedule_reboot - Whether rejection schedules the production reboot.
 */
/datum/controller/subsystem/dogmos/proc/finalize_mixture_registration(datum/gas_mixture/mixture, slot, generation, response, schedule_reboot = TRUE)
	if(response != 1)
		SSair.dogmos_fail_closed_stage("mixture registration", schedule_reboot)
		return FALSE
	mixture.dogmos_identity_token = list()
	dogmos_mixture_slots[slot] = mixture.dogmos_identity_token
	mixture.dogmos_slot = slot
	mixture.dogmos_generation = generation
	mixture._extools_pointer_gasmixture = TRUE
	return TRUE

/** Registers one gas mixture, optionally copying a source in the same native transaction.
 *
 * Arguments:
 * * mixture - Newly constructed datum receiving a fresh service identity.
 * * copy_source - Optional live source; only its gases and temperature are copied.
 */
/datum/controller/subsystem/dogmos/proc/register_mixture(datum/gas_mixture/mixture, datum/gas_mixture/copy_source)
	if(!service_ready)
		if(!service_failure_latched && !service_shutdown_requested)
			CRASH("Attempted to register a gas mixture while dogmosd is unavailable.")
		return

	if(!isnull(copy_source) && !mixture_identity_matches(copy_source, copy_source.dogmos_slot, copy_source.dogmos_generation))
		CRASH("Attempted to copy a stale Dogmos mixture identity before registration.")

	var/slot
	if(length(dogmos_free_mixture_slots))
		slot = pop(dogmos_free_mixture_slots)
		dogmos_mixture_generations[slot]++
	else
		slot = length(dogmos_mixture_slots) + 1
		if(slot > DOGMOS_MAX_EXACT_INTEGER)
			CRASH("Dogmos mixture identity capacity exhausted.")
		dogmos_mixture_generations += 1
		dogmos_mixture_slots.len = slot

	var/generation = dogmos_mixture_generations[slot]
	if(generation > DOGMOS_MAX_EXACT_INTEGER)
		CRASH("Dogmos mixture generation exhausted for slot [slot].")

	var/response
	if(copy_source)
		// Use the provisional destination directly. It must not become a DM identity until accepted.
		// A rejected or ambiguous create quarantines this slot through the same fail-closed path.
		var/list/created_response = dogmos_mixture_command(list(DOGMOS_COMMAND_CREATE_FROM_SOURCE, 0, slot, generation, copy_source.dogmos_slot, copy_source.dogmos_generation, mixture.initial_volume, 0, 0, 0, 0))
		if(islist(created_response) && length(created_response) == 4 && created_response[1] == DOGMOS_RESPONSE_APPLIED)
			response = created_response[2]
	else
		response = dogmos_mixture_lifecycle_batch(list(DOGMOS_LIFECYCLE_REGISTER, slot, generation))
	if(!finalize_mixture_registration(mixture, slot, generation, response))
		return
	if(copy_source)
		return
	// The service creates a mixture already at its own default volume, so sending that same value
	// back is a wasted round trip - and it is the common case, because every turf uses it.
	// Measured over initialization this removes about half of all mixture commands.
	if(mixture.initial_volume != DOGMOS_DEFAULT_MIXTURE_VOLUME)
		mixture.set_volume(mixture.initial_volume)

/** Unregisters one gas mixture and makes its slot eligible for generational reuse. */
/datum/controller/subsystem/dogmos/proc/unregister_mixture(datum/gas_mixture/mixture)
	var/slot = mixture.dogmos_slot
	var/generation = mixture.dogmos_generation
	if(!mixture_identity_matches(mixture, slot, generation, allow_deleting = TRUE))
		CRASH("Attempted to unregister stale Dogmos mixture identity [slot]:[generation].")

	if(service_ready)
		if(SSair?.dogmos_pending_frontier_epoch)
			dogmos_pending_mixture_unregistrations["[slot]"] = list(DOGMOS_LIFECYCLE_UNREGISTER, slot, generation)
		else
			if(dogmos_mixture_lifecycle_batch(list(DOGMOS_LIFECYCLE_UNREGISTER, slot, generation)) != 1)
				CRASH("dogmosd rejected mixture unregistration for [slot]:[generation].")
			dogmos_free_mixture_slots += slot

	evict_mixture_snapshot_cache(slot, generation)
	dogmos_mixture_slots[slot] = null
	mixture.dogmos_slot = null
	mixture.dogmos_generation = null
	mixture._extools_pointer_gasmixture = null
	mixture.dogmos_identity_token = null

/** Validates a caller-owned mixture without a reverse reference or a GC-retaining registry.
 * The deleting exception belongs only to unregister_mixture(), which runs from Del().
 */
/datum/controller/subsystem/dogmos/proc/mixture_identity_matches(datum/gas_mixture/mixture, slot, generation, allow_deleting = FALSE)
	if(!mixture || (!allow_deleting && QDELETED(mixture)))
		return FALSE
	if(!isnum(slot) || slot < 1 || slot > length(dogmos_mixture_slots) || slot != round(slot))
		return FALSE
	return mixture.dogmos_slot == slot && mixture.dogmos_generation == generation \
		&& dogmos_mixture_generations[slot] == generation && !isnull(mixture.dogmos_identity_token) \
		&& dogmos_mixture_slots[slot] == mixture.dogmos_identity_token

/** Allocates a bounded ephemeral identity for an arbitrary reaction holder. */
/datum/controller/subsystem/dogmos/proc/register_holder(datum/holder)
	if(isnull(holder))
		return list(0, 0)

	var/slot
	if(length(dogmos_free_holder_slots))
		slot = pop(dogmos_free_holder_slots)
		dogmos_holder_generations[slot]++
	else
		slot = length(dogmos_holder_slots) + 1
		if(slot > DOGMOS_MAX_EXACT_INTEGER)
			CRASH("Dogmos holder identity capacity exhausted.")
		dogmos_holder_generations += 1
		dogmos_holder_slots.len = slot

	var/generation = dogmos_holder_generations[slot]
	if(generation > DOGMOS_MAX_EXACT_INTEGER)
		CRASH("Dogmos holder generation exhausted for slot [slot].")
	dogmos_holder_slots[slot] = WEAKREF(holder)
	return list(slot, generation)

/** Releases an ephemeral holder identity after its synchronous reaction completes. */
/datum/controller/subsystem/dogmos/proc/unregister_holder(list/handle)
	var/slot = handle[1]
	if(!slot)
		return
	dogmos_holder_slots[slot] = null
	dogmos_free_holder_slots += slot

/** Resolves an arbitrary holder identity without accepting stale generations. */
/datum/controller/subsystem/dogmos/proc/resolve_holder(slot, generation)
	if(!slot)
		return null
	if(dogmos_holder_generations[slot] != generation)
		return null
	var/datum/weakref/reference = dogmos_holder_slots[slot]
	return reference?.resolve()

/** Resolves a coordinate-derived turf identity without accepting a stale generation. */
/datum/controller/subsystem/dogmos/proc/resolve_turf(slot, generation)
	if(slot <= 0 || slot > DOGMOS_MAX_EXACT_INTEGER || generation <= 0 || generation > DOGMOS_MAX_EXACT_INTEGER)
		return null
	var/zero_based_slot = slot - 1
	var/x_coordinate = (zero_based_slot % world.maxx) + 1
	zero_based_slot = floor(zero_based_slot / world.maxx)
	var/y_coordinate = (zero_based_slot % world.maxy) + 1
	var/z_coordinate = floor(zero_based_slot / world.maxy) + 1
	if(z_coordinate > world.maxz)
		return null
	var/turf/resolved = locate(x_coordinate, y_coordinate, z_coordinate)
	if(resolved?.dogmos_registration_generation != generation)
		return null
	return resolved
