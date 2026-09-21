/// Maximum entries retained in each recent-event buffer.
#define KENNEL_EVENT_HISTORY_CAP 200
/// Maximum machinery entries retained for Kennel inspection.
#define KENNEL_STRUCTURE_INTEREST_CAP 250

// APHELION EDIT ADDITION START - DOGMOS
/// Minimum time between player-facing decompression messages in the same area.
#define DOGMOS_DECOMPRESSION_FEEDBACK_COOLDOWN (5 SECONDS)
// APHELION EDIT ADDITION END

/// Overlay objects by category and plane; images are kept in kennel_overlay_images for client toggles.
GLOBAL_LIST_EMPTY(kennel_overlay_turfs)
GLOBAL_LIST_EMPTY(kennel_overlay_images)
/// Category-specific overlay images used by Dogmos goggles.
GLOBAL_LIST_EMPTY(kennel_overlay_images_by_category)

/** Builds the dedicated overlay objects once during SSair initialization. */
/datum/controller/subsystem/air/proc/setup_kennel_overlays()
	var/static/list/category_colors = list(
		"[KENNEL_OVERLAY_BREACH]" = COLOR_RED,
		"[KENNEL_OVERLAY_HIGH_COST]" = COLOR_ORANGE,
		"[KENNEL_OVERLAY_REACTION]" = COLOR_PURPLE,
		"[KENNEL_OVERLAY_STRUCTURE]" = COLOR_CYAN,
	)
	for(var/category in category_colors)
		var/list/add_to = list()
		var/list/category_images = list()
		GLOB.kennel_overlay_turfs[category] = add_to
		GLOB.kennel_overlay_images_by_category[category] = category_images
		for(var/offset in 0 to SSmapping.max_plane_offset)
			var/obj/effect/overlay/atmos_excited/marker = new()
			SET_PLANE_W_SCALAR(marker, HIGH_GAME_PLANE, offset)
			add_to += marker
			var/image/shiny = new('icons/effects/effects.dmi', marker, "atmos_top")
			SET_PLANE_W_SCALAR(shiny, HIGH_GAME_PLANE, offset)
			shiny.color = category_colors[category]
			category_images += shiny
			GLOB.kennel_overlay_images += shiny

/** Rebuilds bounded Kennel indexes and overlay trackers after SSair replacement. */
/datum/controller/subsystem/air/proc/recover_kennel_derived_state(datum/controller/subsystem/air/old_air)
	kennel_jump_targets = list()
	kennel_jump_target_counts = list()
	var/list/history_buckets = list(
		recent_fire_groups,
		recent_high_cost_zones,
		recent_explosions,
		recent_reactions_of_interest,
		recent_breaches,
	)
	for(var/list/history as anything in history_buckets)
		for(var/list/entry as anything in history)
			var/jump_key = entry["jump_to"]
			if(!istext(jump_key))
				continue
			var/datum/weakref/old_target_ref = old_air.kennel_jump_targets[jump_key]
			var/atom/target = old_target_ref?.resolve()
			if(!target || QDELETED(target))
				continue
			kennel_jump_targets[jump_key] = WEAKREF(target)
			kennel_jump_target_counts[jump_key] = (kennel_jump_target_counts[jump_key] || 0) + 1

	if(length(structures_of_interest) > KENNEL_STRUCTURE_INTEREST_CAP)
		for(var/index in (KENNEL_STRUCTURE_INTEREST_CAP + 1) to length(structures_of_interest))
			var/list/evicted = structures_of_interest[index]
			var/datum/weakref/evicted_turf_ref = old_air.kennel_pinned_turfs[evicted["ref"]]
			kennel_hide_overlay(evicted_turf_ref?.resolve(), KENNEL_OVERLAY_STRUCTURE)
		structures_of_interest.Cut(KENNEL_STRUCTURE_INTEREST_CAP + 1, length(structures_of_interest) + 1)

	kennel_pinned_turfs = list()
	for(var/list/entry as anything in structures_of_interest) // APHELION EDIT CHANGE - ORIGINAL: for(var/list/entry in structures_of_interest)
		var/pinned_key = entry["ref"]
		var/datum/weakref/old_turf_ref = old_air.kennel_pinned_turfs[pinned_key]
		var/turf/pinned_turf = old_turf_ref?.resolve()
		if(!pinned_turf || QDELETED(pinned_turf))
			continue
		kennel_pinned_turfs[pinned_key] = WEAKREF(pinned_turf)
		kennel_show_overlay(pinned_turf, KENNEL_OVERLAY_STRUCTURE)

	kennel_overlay_breach_turfs = recover_kennel_overlay_tracker(old_air.kennel_overlay_breach_turfs, KENNEL_OVERLAY_BREACH)
	kennel_overlay_high_cost_turfs = recover_kennel_overlay_tracker(old_air.kennel_overlay_high_cost_turfs, KENNEL_OVERLAY_HIGH_COST)
	kennel_overlay_reaction_turfs = recover_kennel_overlay_tracker(old_air.kennel_overlay_reaction_turfs, KENNEL_OVERLAY_REACTION)
	kennel_breach_feedback_times = list()

	kennel_machine_cost_ewma = list()
	for(var/obj/machinery/machine as anything in atmos_machinery)
		var/key = REF(machine)
		var/old_cost = old_air.kennel_machine_cost_ewma[key]
		if(!isnull(old_cost))
			kennel_machine_cost_ewma[key] = old_cost

/** Returns a live, bounded overlay tracker rebuilt from the previous SSair instance. */
/datum/controller/subsystem/air/proc/recover_kennel_overlay_tracker(list/old_tracker, category)
	var/list/recovered = list()
	for(var/turf/target as anything in old_tracker)
		if(QDELETED(target))
			continue
		recovered += target
		kennel_show_overlay(target, category)
		if(length(recovered) >= KENNEL_OVERLAY_RECENT_CAP)
			break
	return recovered

/datum/controller/subsystem/air/proc/kennel_show_overlay(turf/target, category)
	if(!istype(target))
		return
	var/list/slots = GLOB.kennel_overlay_turfs[category]
	if(!slots)
		return
	var/offset = GET_Z_PLANE_OFFSET(target.z) + 1
	target.vis_contents |= slots[offset]

/datum/controller/subsystem/air/proc/kennel_hide_overlay(turf/target, category)
	if(!istype(target))
		return
	var/list/slots = GLOB.kennel_overlay_turfs[category]
	if(!slots)
		return
	var/offset = GET_Z_PLANE_OFFSET(target.z) + 1
	target.vis_contents -= slots[offset]

/** Shows a recent-event overlay and evicts the oldest turf when its cap is exceeded. */
/datum/controller/subsystem/air/proc/kennel_mark_overlay_recent(list/tracker, category, turf/target)
	if(!istype(target))
		return
	if(target in tracker)
		tracker -= target
	tracker += target
	kennel_show_overlay(target, category)
	if(length(tracker) > KENNEL_OVERLAY_RECENT_CAP)
		var/turf/evicted = tracker[1]
		tracker.Cut(1, 2)
		kennel_hide_overlay(evicted, category)

// APHELION EDIT ADDITION START - DOGMOS
/** Returns whether decompression feedback is available for this turf's area. */
/datum/controller/subsystem/air/proc/kennel_decompression_feedback_available(turf/breach_turf)
	if(!istype(breach_turf))
		return FALSE
	var/area/breach_area = get_area(breach_turf)
	var/feedback_key = breach_area ? REF(breach_area) : "z[breach_turf.z]"
	for(var/retained_key in kennel_breach_feedback_times)
		if(world.time >= kennel_breach_feedback_times[retained_key] + DOGMOS_DECOMPRESSION_FEEDBACK_COOLDOWN)
			kennel_breach_feedback_times -= retained_key
	var/last_feedback = kennel_breach_feedback_times[feedback_key]
	if(!isnull(last_feedback))
		return FALSE
	if(length(kennel_breach_feedback_times) >= KENNEL_EVENT_HISTORY_CAP)
		var/oldest_key
		var/oldest_time = INFINITY
		for(var/retained_key in kennel_breach_feedback_times)
			var/retained_time = kennel_breach_feedback_times[retained_key]
			if(retained_time >= oldest_time)
				continue
			oldest_key = retained_key
			oldest_time = retained_time
		kennel_breach_feedback_times -= oldest_key
	kennel_breach_feedback_times[feedback_key] = world.time
	return TRUE
// APHELION EDIT ADDITION END

/** Records a bounded Kennel event and its optional server-owned jump target. */
/datum/controller/subsystem/air/proc/record_kennel_event(list/bucket, list/entry, atom/jump_target)
	var/jump_key = entry["jump_to"]
	bucket.Insert(1, list(entry))
	if(length(bucket) > KENNEL_EVENT_HISTORY_CAP)
		var/list/evicted = bucket[KENNEL_EVENT_HISTORY_CAP + 1]
		if(islist(evicted) && evicted["jump_to"])
			var/evicted_ref = evicted["jump_to"]
			var/remaining_refs = (kennel_jump_target_counts[evicted_ref] || 1) - 1
			if(remaining_refs > 0)
				kennel_jump_target_counts[evicted_ref] = remaining_refs
			else
				kennel_jump_target_counts -= evicted_ref
				kennel_jump_targets -= evicted_ref
		bucket.Cut(KENNEL_EVENT_HISTORY_CAP + 1, length(bucket) + 1)
	if(jump_target && jump_key)
		var/datum/weakref/target_ref = WEAKREF(jump_target)
		if(target_ref)
			kennel_jump_targets[jump_key] = target_ref
			kennel_jump_target_counts[jump_key] = (kennel_jump_target_counts[jump_key] || 0) + 1
	kennel_append_log(entry)

/// Resolves a recent event's server-owned turf reference.
/datum/controller/subsystem/air/proc/resolve_kennel_jump_target(ref)
	if(!istext(ref))
		return null
	var/datum/weakref/jump_ref = kennel_jump_targets[ref]
	if(!jump_ref)
		jump_ref = kennel_pinned_turfs[ref]
	if(!jump_ref)
		return null
	var/turf/target = jump_ref.resolve()
	if(!target || QDELETED(target))
		kennel_jump_targets -= ref
		kennel_pinned_turfs -= ref
		return null
	return target

/// Appends one JSON event to the round's Kennel log.
/datum/controller/subsystem/air/proc/kennel_append_log(list/entry)
	WRITE_LOG(GLOB.dogmos_kennel_log, json_encode(entry))

/** Records a reaction call that exceeds the configured Kennel threshold. */
/datum/controller/subsystem/air/proc/kennel_record_reaction_cost(reaction_name, atom/holder, cost_ms)
	var/turf/holder_turf = isturf(holder) ? holder : null
	var/area/holder_area = holder_turf ? get_area(holder_turf) : null
	record_kennel_event(recent_high_cost_zones, list(
		"time" = round_timestamp(),
		"jump_to" = holder_turf ? REF(holder_turf) : null,
		"area" = holder_area ? holder_area.name : (holder ? "[holder]" : "unknown"),
		"reaction" = reaction_name,
		"cost_ms" = round(cost_ms, 0.01),
	), holder_turf)
	if(holder_turf)
		kennel_mark_overlay_recent(kennel_overlay_high_cost_turfs, KENNEL_OVERLAY_HIGH_COST, holder_turf)

/** Records explosions and auto-pins an atmos machinery cause. */
/datum/controller/subsystem/air/proc/on_kennel_explosion(datum/source, turf/epicenter, devastation_range, heavy_impact_range, light_impact_range, took, orig_dev_range, orig_heavy_range, orig_light_range, explosion_cause, explosion_index)
	SIGNAL_HANDLER
	var/area/epicenter_area = epicenter ? get_area(epicenter) : null
	record_kennel_event(recent_explosions, list(
		"time" = round_timestamp(),
		"jump_to" = epicenter ? REF(epicenter) : null,
		"area" = epicenter_area ? epicenter_area.name : null,
		"devastation_range" = devastation_range,
		"heavy_impact_range" = heavy_impact_range,
		"light_impact_range" = light_impact_range,
		"cause" = explosion_cause ? "[explosion_cause]" : "unknown",
		"index" = explosion_index,
	), epicenter)
	if(istype(explosion_cause, /obj/machinery))
		kennel_pin_structure(explosion_cause, "explosion cause", kennel_auto_pin_duration)

/** Records only new reaction-result values that exceed the configured magnitude. */
/datum/controller/subsystem/air/proc/check_kennel_reaction_of_interest(turf/open/T)
	var/list/results = T.air.reaction_results
	if(!length(results))
		return
	for(var/reaction_type in results)
		var/amount = results[reaction_type]
		var/cached = LAZYACCESS(T.kennel_last_reaction_results, reaction_type)
		if(cached == amount)
			continue
		LAZYSET(T.kennel_last_reaction_results, reaction_type, amount)
		if(abs(amount) < kennel_reaction_magnitude_threshold)
			continue
		var/area/reaction_area = get_area(T)
		record_kennel_event(recent_reactions_of_interest, list(
			"time" = round_timestamp(),
			"jump_to" = REF(T),
			"area" = reaction_area ? reaction_area.name : null,
			"reaction" = "[reaction_type]",
			"amount" = round(amount, 0.1),
		), T)
		kennel_mark_overlay_recent(kennel_overlay_reaction_turfs, KENNEL_OVERLAY_REACTION, T)

/** Updates a per-machine process-cost EWMA and auto-pins expensive machines. */
/datum/controller/subsystem/air/proc/check_kennel_machine_cost(obj/machinery/M, cost_ms)
	if(!M)
		return
	var/key = REF(M)
	var/previous = kennel_machine_cost_ewma[key]
	var/ewma = isnull(previous) ? cost_ms : MC_AVERAGE(previous, cost_ms)
	kennel_machine_cost_ewma[key] = ewma
	if(ewma >= kennel_machine_cost_ms_threshold)
		kennel_pin_structure(M, "high cost ([round(ewma, 0.01)]ms EWMA)", kennel_auto_pin_duration)

/** Adds or refreshes a structure pin and its overlay. */
/datum/controller/subsystem/air/proc/kennel_pin_structure(obj/machinery/target, reason, expires_in)
	if(QDELETED(target))
		return
	var/key = REF(target)
	for(var/list/entry as anything in structures_of_interest)
		if(entry["ref"] == key)
			entry["reason"] = reason
			entry["expires"] = expires_in ? world.time + expires_in : null
			// APHELION EDIT ADDITION START - DOGMOS
			var/datum/weakref/old_turf_ref = kennel_pinned_turfs[key]
			var/turf/old_turf = old_turf_ref?.resolve()
			var/turf/current_turf = get_turf(target)
			if(old_turf != current_turf)
				kennel_hide_overlay(old_turf, KENNEL_OVERLAY_STRUCTURE)
				if(current_turf)
					kennel_pinned_turfs[key] = WEAKREF(current_turf)
					kennel_show_overlay(current_turf, KENNEL_OVERLAY_STRUCTURE)
				else
					kennel_pinned_turfs -= key
			// APHELION EDIT ADDITION END
			return
	var/area/target_area = get_area(target)
	structures_of_interest.Insert(1, list(list(
		"ref" = key,
		"name" = target.name,
		"area" = target_area ? target_area.name : null,
		"reason" = reason,
		"pinned_at" = round_timestamp(),
		"expires" = expires_in ? world.time + expires_in : null,
	)))
	var/turf/target_turf = get_turf(target)
	if(target_turf)
		kennel_pinned_turfs[key] = WEAKREF(target_turf)
		kennel_show_overlay(target_turf, KENNEL_OVERLAY_STRUCTURE)
	if(length(structures_of_interest) > KENNEL_STRUCTURE_INTEREST_CAP)
		var/list/evicted = structures_of_interest[KENNEL_STRUCTURE_INTEREST_CAP + 1]
		structures_of_interest.Cut(KENNEL_STRUCTURE_INTEREST_CAP + 1, length(structures_of_interest) + 1)
		kennel_hide_pinned_overlay(evicted["ref"])

/// Hides and clears a structure's weakly-referenced overlay turf.
/datum/controller/subsystem/air/proc/kennel_hide_pinned_overlay(ref)
	var/datum/weakref/pinned_ref = kennel_pinned_turfs[ref]
	var/turf/pinned_turf = pinned_ref?.resolve()
	kennel_hide_overlay(pinned_turf, KENNEL_OVERLAY_STRUCTURE)
	kennel_pinned_turfs -= ref

/// Removes a structure pin by reference.
/datum/controller/subsystem/air/proc/kennel_unpin_structure(ref)
	for(var/list/entry in structures_of_interest)
		if(entry["ref"] == ref)
			structures_of_interest -= list(entry)
			kennel_hide_pinned_overlay(ref)
			return

/// Removes expired automatic pins.
/datum/controller/subsystem/air/proc/kennel_prune_expired_pins()
	for(var/list/entry in structures_of_interest)
		var/expires = entry["expires"]
		if(expires && world.time >= expires)
			var/ref = entry["ref"]
			structures_of_interest -= list(entry)
			kennel_hide_pinned_overlay(ref)

// APHELION EDIT ADDITION START - DOGMOS
#undef DOGMOS_DECOMPRESSION_FEEDBACK_COOLDOWN
// APHELION EDIT ADDITION END
#undef KENNEL_EVENT_HISTORY_CAP
#undef KENNEL_STRUCTURE_INTEREST_CAP
