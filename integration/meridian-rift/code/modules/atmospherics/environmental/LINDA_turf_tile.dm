/turf
	///used for temperature calculations in superconduction
	var/thermal_conductivity = 0.05
	///Amount of heat necessary to activate some atmos processes (there is a weird usage of this var because is compared directly to the temperature instead of heat energy)
	var/heat_capacity = INFINITY //This should be opt in rather then opt out

	///list of turfs adjacent to us that air can flow onto
	var/list/atmos_adjacent_turfs
	///bitfield of dirs in which we are superconducitng
	var/atmos_supeconductivity = NONE

	///used to determine whether we should archive
	var/archived_cycle = 0
	var/current_cycle = 0

	/**
	 * used for mapping and for breathing while in walls (because that's a thing that needs to be accounted for...)
	 * string parsed by /datum/gas/proc/copy_from_turf
	 * approximation of MOLES_O2STANDARD and MOLES_N2STANDARD pending byond allowing constant expressions to be embedded in constant strings
	 * If someone will place 0 of some gas there, SHIT WILL BREAK. Do not do that.
	**/
	var/initial_gas_mix = OPENTURF_DEFAULT_ATMOS

/turf/open
	//used for spacewind
	///Pressure difference between two turfs
	var/pressure_difference = 0
	///Where the difference come from (from higher pressure to lower pressure)
	var/pressure_direction = 0
	/// Scratch target written by Dogmos while tracing a hull breach's path to space.
	var/turf/pressure_specific_target

	///Excited group we are part of
	var/datum/excited_group/excited_group
	///Are we active?
	var/excited = FALSE
	///Our gas mix
	var/datum/gas_mixture/air

	///If there is an active hotspot on us store a reference to it here
	var/obj/effect/hotspot/active_hotspot
	/// air will slowly revert to initial_gas_mix
	var/planetary_atmos = FALSE
	/// once our paired turfs are finished with all other shares, do one 100% share
	/// exists so things like space can ask to take 100% of a tile's gas
	var/run_later = FALSE

	///gas IDs of current active gas overlays
	var/list/atmos_overlay_types
	var/significant_share_ticker = 0
	///the cooldown on playing a fire starting sound each time a tile is ignited
	COOLDOWN_DECLARE(fire_puff_cooldown)
	#ifdef TRACK_MAX_SHARE
	var/max_share = 0
	#endif

/turf/open/Initialize(mapload)
	if(!blocks_air)
		air = create_gas_mixture()
		if(planetary_atmos)
			if(!SSair.planetary[initial_gas_mix])
				var/datum/gas_mixture/immutable/planetary/mix = new
				mix.parse_string_immutable(initial_gas_mix)
				SSair.planetary[initial_gas_mix] = mix
	return ..()

/turf/open/Destroy()
	if(active_hotspot)
		QDEL_NULL(active_hotspot)
	// Adds the adjacent turfs to the current atmos processing
	for(var/near_turf in atmos_adjacent_turfs)
		SSair.add_to_active(near_turf)
	return ..()

/////////////////GAS MIXTURE PROCS///////////////////

///Copies all gas info from the turf into a new gas_mixture, along with our temperature
///Returns the created gas_mixture
/turf/proc/create_gas_mixture()
	var/datum/gas_mixture/mix = SSair.parse_gas_string(initial_gas_mix, /datum/gas_mixture/turf)

	//acounts for changes in temperature
	var/turf/parent = parent_type
	if(temperature != initial(temperature) || temperature != initial(parent.temperature))
		mix.set_temperature(temperature)

	return mix

/turf/open/assume_air(datum/gas_mixture/giver) //use this for machines to adjust air
	if(!giver)
		return FALSE
	air.merge(giver)
	update_visuals()
	air_update_turf(FALSE, FALSE)
	return TRUE

/turf/open/remove_air(amount)
	var/datum/gas_mixture/ours = return_air()
	var/datum/gas_mixture/removed = ours.remove(amount)
	update_visuals()
	air_update_turf(FALSE, FALSE)
	return removed

/turf/open/proc/copy_air_with_tile(turf/open/target_turf)
	if(istype(target_turf))
		air.copy_from(target_turf.air)

/turf/open/proc/copy_air(datum/gas_mixture/copy)
	if(copy)
		air.copy_from(copy)

/turf/return_air()
	RETURN_TYPE(/datum/gas_mixture)
	var/datum/gas_mixture/copied_mixture = create_gas_mixture()
	return copied_mixture

/turf/open/return_air()
	RETURN_TYPE(/datum/gas_mixture)
	return air

/turf/open/return_analyzable_air()
	return return_air()

/turf/should_atmos_process(datum/gas_mixture/air, exposed_temperature)
	return (exposed_temperature >= heat_capacity || to_be_destroyed)

/turf/atmos_expose(datum/gas_mixture/air, exposed_temperature)
	if(exposed_temperature >= heat_capacity)
		to_be_destroyed = TRUE
	if(to_be_destroyed && exposed_temperature >= max_fire_temperature_sustained)
		max_fire_temperature_sustained = min(exposed_temperature, max_fire_temperature_sustained + heat_capacity / 4) //Ramp up to 100% yeah?
	if(to_be_destroyed && !changing_turf)
		burn_turf()

/turf/proc/burn_turf()
	burn_tile()
	var/chance_of_deletion
	if (heat_capacity) //beware of division by zero
		chance_of_deletion = max_fire_temperature_sustained / heat_capacity * 8 //there is no problem with prob(23456), min() was redundant --rastaf0
	else
		chance_of_deletion = 100
	if(prob(chance_of_deletion))
		Melt()
		max_fire_temperature_sustained = 0
	else
		to_be_destroyed = FALSE

/turf/temperature_expose(datum/gas_mixture/air, exposed_temperature)
	atmos_expose(air, exposed_temperature)

/turf/open/temperature_expose(datum/gas_mixture/air, exposed_temperature)
	SEND_SIGNAL(src, COMSIG_TURF_EXPOSE, air, exposed_temperature)
	check_atmos_process(src, air, exposed_temperature) //Manually do this to avoid needing to use elements, don't want 200 second atom init times

/turf/open/proc/archive()
	LINDA_CYCLE_ARCHIVE(src)

/////////////////////////GAS OVERLAYS//////////////////////////////


/turf/open/proc/update_visuals()
	if(!air) // 2019-05-14: was not able to get this path to fire in testing. Consider removing/looking at callers -Naksu
		apply_visual_overlays(null)
		return

	apply_visual_overlays(air.return_visuals(src))

/** Applies the gas-overlay diff produced by DM or Dogmos and caches the result. */
/turf/open/proc/apply_visual_overlays(list/new_overlay_types)
	var/list/atmos_overlay_types = src.atmos_overlay_types // Cache for free performance

	if(isnull(new_overlay_types))
		if(atmos_overlay_types)
			for(var/overlay in atmos_overlay_types)
				vis_contents -= overlay
			src.atmos_overlay_types = null
		return

	if (atmos_overlay_types)
		for(var/overlay in atmos_overlay_types-new_overlay_types) //doesn't remove overlays that would only be added
			vis_contents -= overlay

	if (length(new_overlay_types))
		if (atmos_overlay_types)
			vis_contents += new_overlay_types - atmos_overlay_types //don't add overlays that already exist
		else
			vis_contents += new_overlay_types

	UNSETEMPTY(new_overlay_types)
	src.atmos_overlay_types = new_overlay_types

/// Receives the overlay list computed by Dogmos' gas-processing callback.
/turf/open/proc/set_visuals(list/new_overlay_types)
	apply_visual_overlays(new_overlay_types)

/proc/typecache_of_gases_with_no_overlays()
	. = list()
	for (var/gastype in subtypesof(/datum/gas))
		var/datum/gas/gasvar = gastype
		if (!initial(gasvar.gas_overlay))
			.[gastype] = TRUE

//////////////////////////SPACEWIND/////////////////////////////

/turf/open/proc/consider_pressure_difference(turf/target_turf, difference)
	SSair.high_pressure_delta |= src
	if(difference > pressure_difference)
		pressure_direction = get_dir(src, target_turf)
		pressure_difference = difference

/turf/open/proc/high_pressure_movements()
	var/atom/movable/moving_atom
	for(var/thing in src)
		moving_atom = thing
		if (moving_atom.last_high_pressure_movement_air_cycle < SSair.times_fired)
			if (!moving_atom.anchored && !moving_atom.pulledby)
				moving_atom.experience_pressure_difference(pressure_difference, pressure_direction)
			else
				SEND_SIGNAL(moving_atom, COMSIG_MOVABLE_RESISTED_SPACEWIND, pressure_difference, pressure_direction)

/atom/movable
	///How much delta pressure is needed for us to move
	var/pressure_resistance = 10
	var/last_high_pressure_movement_air_cycle = 0

/atom/movable/proc/experience_pressure_difference(pressure_difference, direction, pressure_resistance_prob_delta = 0)
	set waitfor = FALSE
	if(SEND_SIGNAL(src, COMSIG_ATOM_PRE_PRESSURE_PUSH) & COMSIG_ATOM_BLOCKS_PRESSURE)
		return
	var/const/PROBABILITY_OFFSET = 25
	var/const/PROBABILITY_BASE_PRECENT = 75
	var/max_force = sqrt(pressure_difference) * (MOVE_FORCE_DEFAULT / 5)
	var/move_prob = 100
	if (pressure_resistance > 0)
		move_prob = (pressure_difference / pressure_resistance * PROBABILITY_BASE_PRECENT) - PROBABILITY_OFFSET
	move_prob += pressure_resistance_prob_delta
	if (move_prob > PROBABILITY_OFFSET && prob(move_prob) && (move_resist != INFINITY) && (!anchored && (max_force >= (move_resist * MOVE_FORCE_PUSH_RATIO))) || (anchored && (max_force >= (move_resist * MOVE_FORCE_FORCEPUSH_RATIO))))
		step(src, direction)
		last_high_pressure_movement_air_cycle = SSair.times_fired

/// Minimum moles a neighbor turf had before a hull breach sucked it dry for handle_decompression_floor_rip()
/// to consider the loss violent enough to tear up the floor, rather than a minor pressure settle.
#define DECOMPRESSION_FLOOR_RIP_MIN_MOLES (MOLES_CELLSTANDARD * 0.25)

/**
 * Called by Dogmos' katmos equalizer (explosively_depressurize(), aphelion-dogmos
 * src/turfs/katmos.rs) when flood-filling a hull breach finds a firelock-flagged edge
 * (DOGMOS_ADJACENT_FIRELOCK, see atmos_adjacency_flags_with()) between src and adjacent - a chance to
 * slam the firelock shut immediately rather than waiting for its own reactive alarm check
 * (/obj/machinery/door/firedoor/proc/process_results(), signal-driven off COMSIG_TURF_EXPOSE) to
 * catch up, which could let a tick's worth of extra air escape first during an active breach.
 */
/turf/proc/consider_firelocks(turf/adjacent)
	var/obj/machinery/door/firedoor/lock = locate(/obj/machinery/door/firedoor) in src
	if(!lock)
		lock = locate(/obj/machinery/door/firedoor) in adjacent
	lock?.start_activation_process(FIRELOCK_ALARM_TYPE_GENERIC)

/* // APHELION EDIT REMOVAL START - DOGMOS
 * Called by Dogmos' katmos equalizer when a hull breach's flood-fill actually drained air
 * from (aphelion-dogmos src/turfs/katmos.rs explosively_depressurize(), amount = the neighbor's moles
 * just before it was pulled toward space). This codebase has no prior "decompression damages the floor"
 * mechanic - ScrapeAway() (baseturfs.dm) is the existing general-purpose "strip this turf down to its
 * next baseturf" proc already used by explosions and similar forceful events, reused here rather than
 * inventing a parallel one. Gated on amount so an ordinary, minor pressure settle doesn't rip up every
 * floor tile it touches - only a turf that actually lost a meaningful fraction of a standard cell's
 * worth of gas counts as violent enough.
*/ // APHELION EDIT REMOVAL END
// APHELION EDIT ADDITION START - DOGMOS
/** Damages a breach-mouth floor when Dogmos reports a meaningful gas loss. */
// APHELION EDIT ADDITION END
/turf/proc/handle_decompression_floor_rip(amount)
	if(amount < DECOMPRESSION_FLOOR_RIP_MIN_MOLES || !isfloorturf(src) || decompression_floor_rip_resistant) // APHELION EDIT CHANGE - ORIGINAL: if(amount < DECOMPRESSION_FLOOR_RIP_MIN_MOLES)
		return
	var/area/breach_area = get_area(src)
	SSair.record_kennel_event(SSair.recent_breaches, list(
		"time" = round_timestamp(),
		"jump_to" = REF(src),
		"area" = breach_area ? breach_area.name : null,
		"moles_lost" = round(amount, 0.1),
	), src)
	for(var/obj/machinery/breach_adjacent_machine in src)
		SSair.kennel_pin_structure(breach_adjacent_machine, "breach-adjacent", SSair.kennel_auto_pin_duration)
	SSair.kennel_mark_overlay_recent(SSair.kennel_overlay_breach_turfs, KENNEL_OVERLAY_BREACH, src)
	// APHELION EDIT ADDITION START - DOGMOS
	if(SSair.kennel_decompression_feedback_available(src))
		visible_message(
			span_danger("The hull tears open as pressure rips away the floor!"),
			span_userdanger("The floor tears open under the pressure!"),
			span_hear("You hear a violent rush of escaping air!"),
		)
		playsound(src, 'sound/effects/space_wind.ogg', 50, TRUE)
	// APHELION EDIT ADDITION END
	ScrapeAway(1, flags = CHANGETURF_INHERIT_AIR)

#undef DECOMPRESSION_FLOOR_RIP_MIN_MOLES

///////////////////////////EXCITED GROUPS/////////////////////////////

/datum/excited_group
	///Stores a reference to the turfs we are controlling
	var/list/turf_list = list()
	///If this is over EXCITED_GROUP_BREAKDOWN_CYCLES we call self_breakdown()
	var/breakdown_cooldown = 0
	///If this is over EXCITED_GROUP_DISMANTLE_CYCLES we call dismantle()
	var/dismantle_cooldown = 0
	///Used for debug to show the excited groups active and their turfs
	var/should_display = FALSE
	///Id of the index color of the displayed group
	var/display_id = 0
	///Wrapping loop of the index colors
	var/static/wrapping_id = 0
	///All turf reaction flags we have received.
	var/turf_reactions = NONE

/datum/excited_group/New()
	SSair.excited_groups += src

/datum/excited_group/proc/add_turf(turf/open/target_turf)
	turf_list += target_turf
	target_turf.excited_group = src
	dismantle_cooldown = 0
	if(should_display || SSair.display_all_groups)
		display_turf(target_turf)

/datum/excited_group/proc/merge_groups(datum/excited_group/target_group)
	if(turf_list.len > target_group.turf_list.len)
		SSair.excited_groups -= target_group
		for(var/turf/open/group_member as anything in target_group.turf_list)
			group_member.excited_group = src
			turf_list += group_member
		should_display = target_group.should_display | should_display
		if(should_display || SSair.display_all_groups)
			target_group.hide_turfs()
			display_turfs()
		breakdown_cooldown = min(breakdown_cooldown, target_group.breakdown_cooldown) //Take the smaller of the two options
		dismantle_cooldown = 0
	else
		SSair.excited_groups -= src
		for(var/turf/open/group_member as anything in turf_list)
			group_member.excited_group = target_group
			target_group.turf_list += group_member
		target_group.should_display = target_group.should_display | should_display
		if(target_group.should_display || SSair.display_all_groups)
			hide_turfs()
			target_group.display_turfs()
		target_group.breakdown_cooldown = min(breakdown_cooldown, target_group.breakdown_cooldown)
		target_group.dismantle_cooldown = 0

/datum/excited_group/proc/reset_cooldowns()
	breakdown_cooldown = 0
	dismantle_cooldown = 0

/datum/excited_group/proc/self_breakdown(roundstart = FALSE, poke_turfs = FALSE)
	var/datum/gas_mixture/shared_mix = new

	var/list/turf_list = src.turf_list
	var/turflen = turf_list.len
	var/imumutable_in_group = FALSE
	var/energy = 0
	var/heat_cap = 0

	for(var/turf/open/group_member as anything in turf_list)
		//Cache?
		var/datum/gas_mixture/turf/mix = group_member.air
		if (roundstart)
			if(istype(group_member.air, /datum/gas_mixture/immutable))
				imumutable_in_group = TRUE
				shared_mix.copy_from(group_member.air) //This had better be immutable young man
				break
			// If we're planetary use THAT mix, and stop here
			if(group_member.planetary_atmos)
				imumutable_in_group = TRUE
				var/datum/gas_mixture/planetary_mix = SSair.planetary[group_member.initial_gas_mix]
				shared_mix.copy_from(planetary_mix)
				break
		//"borrowing" this code from merge(), I need to play with the temp portion. Lets expand it out
		//temperature = (giver.temperature * giver_heat_capacity + temperature * self_heat_capacity) / combined_heat_capacity
		var/capacity = mix.heat_capacity()
		energy += mix.return_temperature() * capacity
		heat_cap += capacity

		for(var/gas_id in mix.get_gases())
			shared_mix.adjust_moles(gas_id, mix.get_moles(gas_id))

	if(!imumutable_in_group)
		shared_mix.set_temperature(energy / heat_cap)
		for(var/gas_id in shared_mix.get_gases())
			shared_mix.set_moles(gas_id, shared_mix.get_moles(gas_id) / turflen)

	for(var/turf/open/group_member as anything in turf_list)
		if(group_member.planetary_atmos) //We do this as a hack to try and minimize unneeded excited group spread over planetary turfs
			group_member.air.copy_from(SSair.planetary[group_member.initial_gas_mix]) //Comes with a cost of "slower" drains, but it's worth it
		else
			group_member.air.copy_from(shared_mix) //Otherwise just set the mix to a copy of our equalized mix
		group_member.update_visuals()
		if(poke_turfs) //Because we only activate all these once every breakdown, in event of lag due to this code and slow space + vent things, increase the wait time for breakdowns
			SSair.add_to_active(group_member)
			group_member.significant_share_ticker = EXCITED_GROUP_DISMANTLE_CYCLES //Max out the ticker, if they don't share next tick, nuke em

	breakdown_cooldown = 0

///Dismantles the excited group, puts allll the turfs to sleep
/datum/excited_group/proc/dismantle()
	for(var/turf/open/current_turf as anything in turf_list)
		current_turf.excited = FALSE
		current_turf.significant_share_ticker = 0
		SSair.dogmos_remove_frontier_member(current_turf)
		#ifdef VISUALIZE_ACTIVE_TURFS //Use this when you want details about how the turfs are moving, display_all_groups should work for normal operation
		current_turf.remove_atom_colour(TEMPORARY_COLOUR_PRIORITY, COLOR_VIBRANT_LIME)
		#endif
	garbage_collect()

//Breaks down the excited group, this doesn't sleep the turfs mind, just removes them from the group
/datum/excited_group/proc/garbage_collect()
	if(display_id) //If we ever did make those changes
		hide_turfs()
	for(var/turf/open/current_turf as anything in turf_list)
		current_turf.excited_group = null
	turf_list.Cut()
	SSair.excited_groups -= src
	if(SSair.currentpart == SSAIR_EXCITEDGROUPS)
		SSair.currentrun -= src

/datum/excited_group/proc/display_turfs()
	if(display_id == 0) //Hasn't been shown before
		wrapping_id = wrapping_id % GLOB.colored_turfs.len
		wrapping_id++ //We do this after because lists index at 1
		display_id = wrapping_id
	for(var/thing in turf_list)
		var/turf/display = thing
		var/offset = GET_Z_PLANE_OFFSET(display.z) + 1
		display.vis_contents += GLOB.colored_turfs[display_id][offset]

/datum/excited_group/proc/hide_turfs()
	for(var/thing in turf_list)
		var/turf/display = thing
		var/offset = GET_Z_PLANE_OFFSET(display.z) + 1
		display.vis_contents -= GLOB.colored_turfs[display_id][offset]
	display_id = 0

/datum/excited_group/proc/display_turf(turf/thing)
	if(display_id == 0) //Hasn't been shown before
		wrapping_id = wrapping_id % GLOB.colored_turfs.len
		wrapping_id++ //We do this after because lists index at 1
		display_id = wrapping_id
	var/offset = GET_Z_PLANE_OFFSET(thing.z) + 1
	thing.vis_contents += GLOB.colored_turfs[display_id][offset]

////////////////////////SUPERCONDUCTIVITY (Dogmos, aphelion-dogmos src/turfs/superconduct.rs)/////////////////////////////
/**
 * The DM-side heat-conduction walk (super_conduct(), neighbor_conduct_with_src(), radiate_to_spess(),
 * consider_superconductivity(), etc.) is deleted - Rust owns turf-to-turf heat conduction now
 * (process_turf_heat, SSair.process_super_conductivity(), controllers/subsystem/air.dm). What remains
 * here are the two procs Rust still calls into directly and can't do without:
 */

///Returns a set of directions that we should be conducting in, NOTE, atmos_supeconductivity is ACTUALLY inversed, don't worrry about it
/turf/proc/conductivity_directions()
	return ALL_CARDINALS

/turf/open/conductivity_directions()
	if(blocks_air)
		return ..()
	for(var/direction in GLOB.cardinals)
		var/turf/checked_turf = get_step(src, direction)
		if(!(checked_turf in atmos_adjacent_turfs) && !(atmos_supeconductivity & direction))
			. |= direction

/**
 * Answers Dogmos' `should_conduct_to_space` FFI call (aphelion-dogmos src/turfs/superconduct.rs,
 * supercond_update_ref) - "is this turf directly adjacent to space", read once at registration into
 * ThermalInfo.adjacent_to_space, and called synchronously with errors propagating, so this proc must
 * always exist. Pure adjacency check, not a radiation calculation - Rust does its own space-radiation
 * math entirely on its side now.
 */
/turf/proc/should_conduct_to_space()
	for(var/direction in GLOB.cardinals)
		if(isspaceturf(get_step(src, direction)))
			return TRUE
	return FALSE
