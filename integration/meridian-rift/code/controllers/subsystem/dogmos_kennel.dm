/** Shared admin panel for Dogmos telemetry and controls. State remains on SSair so all viewers see the
 * same values while this facade stays independent from AtmosControlPanel. */
GLOBAL_DATUM_INIT(dogmos_kennel, /datum/dogmos_kennel, new())

#define KENNEL_BROWSE_PAGE_SIZE 250
#define KENNEL_BROWSE_SEARCH_MAX_LENGTH 64

/** Per-session state for the bounded Kennel machinery browser. */
/datum/tgui/dogmos_kennel
	/// One-indexed machinery browse page requested by this UI session.
	var/browse_page = 1
	/// Bounded machinery browse search requested by this UI session.
	var/browse_search = ""

/datum/dogmos_kennel
	// APHELION EDIT ADDITION START - DOGMOS
	/// Number of process-metric snapshots requested by Kennel UI production.
	var/producer_process_metric_samples = 0
	/// Number of machinery candidates inspected by Kennel browse production.
	var/producer_machinery_candidates_inspected = 0
	/// Number of machinery browse pages built by Kennel UI production.
	var/producer_browse_pages_built = 0
	/// Number of open Kennel UI sessions at the latest data request.
	var/producer_active_viewers = 0
	// APHELION EDIT ADDITION END

/datum/dogmos_kennel/ui_state(mob/user)
	return ADMIN_STATE(R_DEBUG)

/datum/dogmos_kennel/ui_interact(mob/user, datum/tgui/ui)
	ui = SStgui.try_update_ui(user, src, ui)
	if(!ui)
		ui = new /datum/tgui/dogmos_kennel(user, src, "DogmosKennel")
		ui.set_autoupdate(FALSE)
		ui.open()

/** Returns Kennel limits which remain constant for the lifetime of an open UI. */
/datum/dogmos_kennel/ui_static_data(mob/user)
	return list(
		"kennel_browse_page_size" = KENNEL_BROWSE_PAGE_SIZE,
		"kennel_browse_search_max_length" = KENNEL_BROWSE_SEARCH_MAX_LENGTH,
	)

/** Returns a valid finite Kennel threshold or null for malformed input. */
/datum/dogmos_kennel/proc/normalize_threshold(threshold, raw_value)
	var/value = raw_value
	if(istext(value))
		value = text2num(value)
	if(!isnum(value) || value != value || value == INFINITY || value == -INFINITY)
		return null

	switch(threshold)
		if("fire_group_notable_size")
			return clamp(value, 1, SHORT_REAL_LIMIT)
		if("reaction_magnitude_threshold", "machine_cost_ms_threshold", "high_cost_ms_threshold")
			return clamp(value, 0, SHORT_REAL_LIMIT)
	return null

/** Returns a machinery search string within the per-session input limit. */
/datum/dogmos_kennel/proc/normalize_browse_search(raw_search)
	if(!istext(raw_search))
		return ""
	return copytext_char(raw_search, 1, KENNEL_BROWSE_SEARCH_MAX_LENGTH + 1)

/** Builds one bounded machinery browse page without retaining or materializing the full result set. */
/datum/dogmos_kennel/proc/build_machinery_browse_page(list/candidates, raw_search, raw_page)
	// APHELION EDIT ADDITION START - DOGMOS
	producer_browse_pages_built = min(producer_browse_pages_built + 1, SHORT_REAL_LIMIT)
	var/candidates_inspected = 0
	// APHELION EDIT ADDITION END
	var/search = normalize_browse_search(raw_search)
	var/requested_page = raw_page
	if(istext(requested_page))
		requested_page = text2num(requested_page)
	if(!isnum(requested_page) || requested_page != requested_page || requested_page == INFINITY || requested_page == -INFINITY)
		requested_page = 1

	var/total = 0
	for(var/datum/candidate as anything in candidates)
		// APHELION EDIT ADDITION START - DOGMOS
		candidates_inspected++
		// APHELION EDIT ADDITION END
		if(!ismachinery(candidate))
			continue
		var/obj/machinery/machine = candidate
		var/area/candidate_area = get_area(machine)
		if(length(search) && !findtext("[machine.name] [candidate_area?.name]", search))
			continue
		total++

	var/total_pages = max(1, CEILING(total / KENNEL_BROWSE_PAGE_SIZE, 1))
	var/page = clamp(round(requested_page), 1, total_pages)
	var/first_row = (page - 1) * KENNEL_BROWSE_PAGE_SIZE + 1
	var/last_row = min(first_row + KENNEL_BROWSE_PAGE_SIZE - 1, total)
	var/matched_row = 0
	var/list/rows = list()
	for(var/datum/candidate as anything in candidates)
		// APHELION EDIT ADDITION START - DOGMOS
		candidates_inspected++
		// APHELION EDIT ADDITION END
		if(!ismachinery(candidate))
			continue
		var/obj/machinery/machine = candidate
		var/area/candidate_area = get_area(machine)
		if(length(search) && !findtext("[machine.name] [candidate_area?.name]", search))
			continue
		matched_row++
		if(matched_row < first_row)
			continue
		if(matched_row > last_row)
			break
		rows += list(list(
			"ref" = REF(machine),
			"name" = machine.name,
			"area" = candidate_area?.name,
		))

	// APHELION EDIT ADDITION START - DOGMOS
	producer_machinery_candidates_inspected = min(producer_machinery_candidates_inspected + candidates_inspected, SHORT_REAL_LIMIT)
	// APHELION EDIT ADDITION END
	return list(
		"rows" = rows,
		"page" = page,
		"pages" = total_pages,
		"total" = total,
		"search" = search,
	)

/** Returns live Dogmos telemetry and bounded Kennel histories for the Overview tab. */
/datum/dogmos_kennel/ui_data(mob/user)
	// APHELION EDIT ADDITION START - DOGMOS
	producer_active_viewers = length(open_uis)
	producer_process_metric_samples = min(producer_process_metric_samples + 1, SHORT_REAL_LIMIT)
	// APHELION EDIT ADDITION END
	var/list/data = list()
	data["active_size"] = SSair.active_turfs.len
	data["hotspots_size"] = SSair.hotspots.len
	data["conducting_size"] = dogmos_heat_graph_count()
	data["low_pressure_turfs"] = SSair.low_pressure_turfs
	data["high_pressure_turfs"] = SSair.high_pressure_turfs
	data["group_turfs_processed"] = SSair.num_group_turfs_processed
	data["equalize_processed"] = SSair.num_equalize_processed
	data["space_boundary_size"] = dogmos_space_boundary_count()
	data["heat_telemetry"] = list(
		"graph_nodes" = SSair.dogmos_heat_graph_nodes,
		"edge_attempts" = SSair.dogmos_heat_edge_attempts,
		"edges_applied" = SSair.dogmos_heat_edges_applied,
		"lock_contention" = SSair.dogmos_heat_lock_contention,
		"registration_changes" = SSair.dogmos_heat_registration_changes,
		"callback_enqueue_failures" = dogmos_callback_enqueue_failures(),
	)
	data["dogmos_costs"] = list(
		"turfs" = SSair.cost_turfs,
		"groups" = SSair.cost_groups,
		"highpressure" = SSair.cost_highpressure,
		"equalize" = SSair.cost_equalize,
		"superconductivity" = SSair.cost_superconductivity,
		// APHELION EDIT ADDITION START - DOGMOS
		"pipenets" = SSair.cost_pipenets,
		// APHELION EDIT ADDITION END
		"post_process" = SSair.cost_post_process,
	)
	data["frozen"] = SSair.can_fire
	data["realistic_space_radiation"] = SSair.realistic_space_radiation
	data["equalize_enabled"] = SSair.equalize_enabled
	data["fire_count"] = SSair.times_fired
	data["showing_user"] = user.hud_used.atmos_debug_overlays
	data["kennel_slow_mode"] = SSair.kennel_slow_mode
	// APHELION EDIT ADDITION START - DOGMOS
	data["flamethrower_directional_spread"] = SSair.flamethrower_directional_spread
	data["process_metrics"] = dogmos_process_metrics_snapshot()
	data["event_counts"] = list(
		"fire_groups" = length(SSair.recent_fire_groups),
		"high_cost_zones" = length(SSair.recent_high_cost_zones),
		"explosions" = length(SSair.recent_explosions),
		"reactions_of_interest" = length(SSair.recent_reactions_of_interest),
		"breaches" = length(SSair.recent_breaches),
	)
	// APHELION EDIT ADDITION END

	// Slow mode gates only the potentially large machinery browse.
	SSair.kennel_prune_expired_pins()
	data["recent_fire_groups"] = SSair.recent_fire_groups
	data["recent_explosions"] = SSair.recent_explosions
	data["recent_high_cost_zones"] = SSair.recent_high_cost_zones
	data["recent_reactions_of_interest"] = SSair.recent_reactions_of_interest
	data["recent_breaches"] = SSair.recent_breaches
	data["structures_of_interest"] = SSair.structures_of_interest

	if(!SSair.kennel_slow_mode)
		var/datum/tgui/dogmos_kennel/kennel_ui = SStgui.get_open_ui(user, src)
		var/list/browse_page = build_machinery_browse_page(
			SSair.atmos_machinery,
			kennel_ui?.browse_search,
			kennel_ui?.browse_page,
		)
		if(kennel_ui)
			kennel_ui.browse_search = browse_page["search"]
			kennel_ui.browse_page = browse_page["page"]
		data["atmos_machinery_browse"] = browse_page["rows"]
		data["atmos_machinery_browse_page"] = browse_page["page"]
		data["atmos_machinery_browse_pages"] = browse_page["pages"]
		data["atmos_machinery_browse_total"] = browse_page["total"]
		data["atmos_machinery_browse_search"] = browse_page["search"]

	// APHELION EDIT ADDITION START - DOGMOS
	data["producer_telemetry"] = list(
		"process_metric_samples" = producer_process_metric_samples,
		"machinery_candidates_inspected" = producer_machinery_candidates_inspected,
		"browse_pages_built" = producer_browse_pages_built,
		"active_viewers" = producer_active_viewers,
	)
	// APHELION EDIT ADDITION END

	data["kennel_fire_group_notable_size"] = SSair.kennel_fire_group_notable_size
	data["kennel_reaction_magnitude_threshold"] = SSair.kennel_reaction_magnitude_threshold
	data["kennel_machine_cost_ms_threshold"] = SSair.kennel_machine_cost_ms_threshold
	data["kennel_profile_reactions"] = SSair.kennel_profile_reactions
	data["kennel_high_cost_ms_threshold"] = SSair.kennel_high_cost_ms_threshold
	return data

/datum/dogmos_kennel/ui_act(action, list/params, datum/tgui/ui, datum/ui_state/state)
	. = ..()
	var/mob/user = ui?.user
	if(. || !user?.client || !check_rights_for(user.client, R_DEBUG))
		return
	var/datum/tgui/dogmos_kennel/kennel_ui = ui
	switch(action)
		if("move-to-target")
			var/turf/target = SSair.resolve_kennel_jump_target(params["spot"])
			if(!target || !user)
				return
			user.forceMove(target)
		if("toggle-freeze")
			SSair.can_fire = !SSair.can_fire
			return TRUE
		if("toggle_realistic_space_radiation")
			SSair.realistic_space_radiation = !SSair.realistic_space_radiation
			return TRUE
		if("toggle_equalize_enabled")
			SSair.equalize_enabled = !SSair.equalize_enabled
			return TRUE
		// APHELION EDIT ADDITION START - DOGMOS
		if("toggle_flamethrower_directional_spread")
			SSair.flamethrower_directional_spread = !SSair.flamethrower_directional_spread
			return TRUE
		// APHELION EDIT ADDITION END
		if("toggle_kennel_slow_mode")
			SSair.kennel_slow_mode = !SSair.kennel_slow_mode
			return TRUE
		if("toggle_kennel_profile_reactions")
			SSair.kennel_profile_reactions = !SSair.kennel_profile_reactions
			return TRUE
		if("toggle_user_display")
			user.hud_used.atmos_debug_overlays = !user.hud_used.atmos_debug_overlays
			if(user.hud_used.atmos_debug_overlays)
				user.client.images += GLOB.colored_images
				user.client.images += GLOB.kennel_overlay_images
			else
				user.client.images -= GLOB.colored_images
				user.client.images -= GLOB.kennel_overlay_images
				// APHELION EDIT ADDITION START - DOGMOS
				if(ishuman(user))
					var/mob/living/carbon/human/human_user = user
					var/obj/item/clothing/glasses/meson/engine/dogmos/dogmos_goggles = human_user.glasses
					if(istype(dogmos_goggles))
						user.client.images |= dogmos_goggles.dogmos_overlay_images()
				// APHELION EDIT ADDITION END
			return TRUE
		if("kennel_pin")
			var/obj/machinery/target = locate(params["ref"]) in SSair.atmos_machinery
			if(!target)
				return
			SSair.kennel_pin_structure(target, "manually leashed", null)
			return TRUE
		if("kennel_unpin")
			SSair.kennel_unpin_structure(params["ref"])
			return TRUE
		if("kennel_set_browse_search")
			if(!istype(kennel_ui))
				return
			kennel_ui.browse_search = normalize_browse_search(params["search"])
			kennel_ui.browse_page = 1
			return TRUE
		if("kennel_set_browse_page")
			if(!istype(kennel_ui))
				return
			var/page = text2num(params["page"])
			if(!isnum(page) || page != page || page == INFINITY || page == -INFINITY)
				return
			kennel_ui.browse_page = max(1, round(page))
			return TRUE
		if("kennel_set_threshold")
			var/value = normalize_threshold(params["threshold"], params["value"])
			if(isnull(value))
				return
			switch(params["threshold"])
				if("fire_group_notable_size")
					SSair.kennel_fire_group_notable_size = value
				if("reaction_magnitude_threshold")
					SSair.kennel_reaction_magnitude_threshold = value
				if("machine_cost_ms_threshold")
					SSair.kennel_machine_cost_ms_threshold = value
				if("high_cost_ms_threshold")
					SSair.kennel_high_cost_ms_threshold = value
				else
					return
			return TRUE

#undef KENNEL_BROWSE_PAGE_SIZE
#undef KENNEL_BROWSE_SEARCH_MAX_LENGTH
