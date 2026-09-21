/turf
	/// Monotonic identity for queued Dogmos callbacks; changes when ChangeTurf() replaces this turf ref.
	var/dogmos_registration_generation
	/// Shared counter used to distinguish a turf replacement from routine re-registration.
	var/static/next_dogmos_registration_generation = 0
	/// Initial temperature used when Dogmos first registers the turf's heat node.
	var/initial_temperature
	/// Mixture slot last queued for this turf's current Dogmos registration.
	var/dogmos_registered_mixture_slot
	/// Mixture generation last queued for this turf's current Dogmos registration.
	var/dogmos_registered_mixture_generation
	/// Directions blocked for Dogmos heat conduction.
	var/conductivity_blocked_directions = NONE
	/// Whether decompression may strip this turf's floor surface.
	var/decompression_floor_rip_resistant = FALSE

/** Advances callback identity and records replacement order, even after ChangeTurf resets fields.
 * initial_registration skips membership changes unless an acknowledged old handle needs repair.
 */
/turf/proc/mark_dogmos_turf_replacement(initial_registration = FALSE)
	// Keep generation replacement in canonical last-add order without repeating activation effects.
	// First registration has no retired identity and must not restart a bootstrap scan.
#ifdef DOGMOS_IN_PROCESS
	if(!initial_registration && SSair?.dogmos_remove_frontier_member(src))
#else
	if((!initial_registration || SSair?.dogmos_committed_frontier?[src]) && SSair?.dogmos_remove_frontier_member(src))
#endif
		SSair.dogmos_add_frontier_member(src)
	dogmos_registration_generation = ++next_dogmos_registration_generation
	dogmos_registered_mixture_slot = null
	dogmos_registered_mixture_generation = null

/**
 * Returns whether startup registration already reflects the turf's current gas mixture.
 *
 * Arguments:
 * * register_space_boundary - Whether an open space turf registers its shared boundary mixture.
 */
/turf/proc/dogmos_air_registration_is_current(register_space_boundary = FALSE)
	if(isnull(dogmos_registration_generation))
		return FALSE
	var/turf/open/open_turf = isopenturf(src) ? src : null
	var/datum/gas_mixture/expected_mixture = (open_turf?.air && (register_space_boundary || !blocks_air)) ? open_turf.air : null
#ifdef DOGMOS_IN_PROCESS
	return !isnull(dogmos_registered_mixture_generation) && dogmos_registered_mixture_generation == dogmos_registration_generation && dogmos_registered_mixture_slot == expected_mixture?._extools_pointer_gasmixture

#else
	return (dogmos_registered_mixture_slot || 0) == (expected_mixture?.dogmos_slot || 0) \
		&& (dogmos_registered_mixture_generation || 0) == (expected_mixture?.dogmos_generation || 0)
#endif

/turf/Initalize_Atmos(time)
	register_dogmos_air()
	return ..()

/**
 * Registers or re-registers this turf in Dogmos' gas and heat graphs.
 *
 * Arguments:
 * * remove_uninitialized - Whether a newly replaced non-atmos turf must invalidate the previous service generation.
 */
/turf/proc/register_dogmos_air(remove_uninitialized = FALSE)
	if(!DOGMOS)
		return
	if(!init_air)
		if(remove_uninitialized)
			update_air_ref(DOGMOS_SIMULATION_REMOVE)
		return
	if(isnull(dogmos_registration_generation))
		mark_dogmos_turf_replacement(initial_registration = TRUE)
	if(isnull(initial_temperature))
		initial_temperature = temperature
	// Map-load turfs without air use heat-only registration until their gas datum exists.
	var/turf/open/as_open = isopenturf(src) ? src : null
	update_air_ref((as_open?.air && !blocks_air) ? DOGMOS_SIMULATION_ALL : DOGMOS_SIMULATION_NONE)
#ifdef DOGMOS_IN_PROCESS
	dogmos_registered_mixture_slot = (as_open?.air && !blocks_air) ? as_open.air._extools_pointer_gasmixture : null
	dogmos_registered_mixture_generation = dogmos_registration_generation
#endif

/** Writes the DM and Dogmos temperatures. */
/turf/proc/set_temperature(new_temp)
	temperature = new_temp
	if(DOGMOS && init_air)
		__set_temperature(new_temp)

/** Returns the registered Dogmos heat temperature, if available. */
/turf/proc/dogmos_heat_temperature()
	return __dogmos_heat_temperature()

/** Returns this turf's service-owned heat temperature. */
#ifndef DOGMOS_IN_PROCESS
/turf/return_temperature()
	var/dogmos_temperature = dogmos_heat_temperature()
	return isnull(dogmos_temperature) ? temperature : dogmos_temperature

#endif
/** Returns the configured temperature authority for blocked turfs. */
/turf/proc/get_dogmos_blocked_temperature()
	if(DOGMOS && SSair.dogmos_blocked_turf_temperature_authority == DOGMOS_TEMPERATURE_AUTHORITY_RUST)
		var/rust_temperature = dogmos_heat_temperature()
		if(!isnull(rust_temperature))
			return rust_temperature
	return temperature
