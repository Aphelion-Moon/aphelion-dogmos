#define DOGMOS_GOGGLE_MODE_NONE ""
#define DOGMOS_GOGGLE_MODE_MESON "meson"
#define DOGMOS_GOGGLE_MODE_TRAY "t-ray"
#define DOGMOS_GOGGLE_MODE_PIPE_CONNECTABLE "connectable"
#define DOGMOS_GOGGLE_MODE_ATMOS_THERMAL "atmospheric-thermal"
#define DOGMOS_GOGGLE_MODE_AREA_BLUEPRINTS "area-blueprints"

/** Station-safe atmospheric imaging goggles for Dogmos work. */
/obj/item/clothing/glasses/meson/engine/dogmos
	name = "Dogmos atmospheric imaging goggles"
	desc = "Engineering goggles with meson, T-ray, pipe-connection, thermal, breach-alert, and reaction-profile modes."
	range = 3
	modes = list(
		DOGMOS_GOGGLE_MODE_NONE,
		DOGMOS_GOGGLE_MODE_MESON,
		DOGMOS_GOGGLE_MODE_TRAY,
		DOGMOS_GOGGLE_MODE_PIPE_CONNECTABLE,
		DOGMOS_GOGGLE_MODE_ATMOS_THERMAL,
		DOGMOS_GOGGLE_MODE_BREACHES,
		DOGMOS_GOGGLE_MODE_REACTIONS,
	)

/** Returns the Kennel overlay categories represented by the current mode. */
/obj/item/clothing/glasses/meson/engine/dogmos/proc/dogmos_overlay_categories()
	switch(mode)
		if(DOGMOS_GOGGLE_MODE_BREACHES)
			return list(KENNEL_OVERLAY_BREACH)
		if(DOGMOS_GOGGLE_MODE_REACTIONS)
			return list(KENNEL_OVERLAY_REACTION)
		if(DOGMOS_GOGGLE_MODE_HIGH_COST)
			return list(KENNEL_OVERLAY_HIGH_COST)
		if(DOGMOS_GOGGLE_MODE_STRUCTURES)
			return list(KENNEL_OVERLAY_STRUCTURE)
		if(DOGMOS_GOGGLE_MODE_ALL)
			return list(
				KENNEL_OVERLAY_BREACH,
				KENNEL_OVERLAY_HIGH_COST,
				KENNEL_OVERLAY_REACTION,
				KENNEL_OVERLAY_STRUCTURE,
			)
	return list()

/** Returns all category images selected by the current goggles mode. */
/obj/item/clothing/glasses/meson/engine/dogmos/proc/dogmos_overlay_images()
	var/list/selected_images = list()
	for(var/category in dogmos_overlay_categories())
		selected_images += GLOB.kennel_overlay_images_by_category[category]
	return selected_images

/** Synchronizes the selected Kennel overlay images with the current wearer. */
/obj/item/clothing/glasses/meson/engine/dogmos/proc/update_dogmos_overlay_images()
	var/mob/living/carbon/human/wearer = loc
	if(!istype(wearer) || wearer.glasses != src || !wearer.client)
		return
	if(!wearer.hud_used?.atmos_debug_overlays)
		wearer.client.images -= GLOB.kennel_overlay_images
	wearer.client.images |= dogmos_overlay_images()

/// Shows the selected Kennel overlays when these goggles enter the eye slot.
/obj/item/clothing/glasses/meson/engine/dogmos/equipped(mob/living/user, slot)
	. = ..()
	if(slot & ITEM_SLOT_EYES)
		update_dogmos_overlay_images()

/// Removes goggles-owned Kennel overlays when the wearer drops them.
/obj/item/clothing/glasses/meson/engine/dogmos/dropped(mob/living/user)
	if(user?.client && !user.hud_used?.atmos_debug_overlays)
		user.client.images -= GLOB.kennel_overlay_images
	return ..()

/// Removes goggles-owned Kennel overlays before the item is deleted.
/obj/item/clothing/glasses/meson/engine/dogmos/Destroy()
	var/mob/living/carbon/human/wearer = loc
	if(istype(wearer) && wearer.client && !wearer.hud_used?.atmos_debug_overlays)
		wearer.client.images -= GLOB.kennel_overlay_images
	return ..()

/// Refreshes the selected Kennel overlays after the inherited mode switch.
/obj/item/clothing/glasses/meson/engine/dogmos/toggle_mode(mob/user, voluntary)
	var/mob/living/carbon/human/wearer = loc
	if(istype(wearer) && wearer.client && !wearer.hud_used?.atmos_debug_overlays)
		wearer.client.images -= GLOB.kennel_overlay_images
	. = ..()
	update_dogmos_overlay_images()

/obj/item/clothing/glasses/meson/engine/dogmos/update_icon_state()
	. = ..()
	switch(mode)
		if(DOGMOS_GOGGLE_MODE_BREACHES, DOGMOS_GOGGLE_MODE_REACTIONS, DOGMOS_GOGGLE_MODE_HIGH_COST, DOGMOS_GOGGLE_MODE_STRUCTURES, DOGMOS_GOGGLE_MODE_ALL)
			icon_state = inhand_icon_state = worn_icon_state = "trayson-atmospheric-thermal"

/** Administrative atmospheric imaging goggles with the complete Dogmos debugging set. */
/obj/item/clothing/glasses/meson/engine/dogmos/admin
	name = "Dogmos administrative imaging goggles"
	desc = "Administrative goggles with the complete engineering and Kennel overlay set, including area-blueprint imaging."
	range = 7
	modes = list(
		DOGMOS_GOGGLE_MODE_NONE,
		DOGMOS_GOGGLE_MODE_MESON,
		DOGMOS_GOGGLE_MODE_TRAY,
		DOGMOS_GOGGLE_MODE_PIPE_CONNECTABLE,
		DOGMOS_GOGGLE_MODE_ATMOS_THERMAL,
		DOGMOS_GOGGLE_MODE_BREACHES,
		DOGMOS_GOGGLE_MODE_REACTIONS,
		DOGMOS_GOGGLE_MODE_HIGH_COST,
		DOGMOS_GOGGLE_MODE_STRUCTURES,
		DOGMOS_GOGGLE_MODE_ALL,
		DOGMOS_GOGGLE_MODE_AREA_BLUEPRINTS,
	)

/datum/design/dogmos_goggles
	name = "Dogmos Atmospheric Imaging Goggles"
	desc = "Engineering goggles tuned for Dogmos troubleshooting without administrative area-blueprint access."
	build_type = PROTOLATHE | AWAY_LATHE
	materials = list(
		/datum/material/iron = SMALL_MATERIAL_AMOUNT * 5,
		/datum/material/glass = SMALL_MATERIAL_AMOUNT * 5,
		/datum/material/plasma = SMALL_MATERIAL_AMOUNT,
	)
	build_path = /obj/item/clothing/glasses/meson/engine/dogmos
	category = list(
		RND_CATEGORY_EQUIPMENT + RND_SUBCATEGORY_EQUIPMENT_ENGINEERING,
	)
	departmental_flags = DEPARTMENT_BITFLAG_ENGINEERING

#undef DOGMOS_GOGGLE_MODE_NONE
#undef DOGMOS_GOGGLE_MODE_MESON
#undef DOGMOS_GOGGLE_MODE_TRAY
#undef DOGMOS_GOGGLE_MODE_PIPE_CONNECTABLE
#undef DOGMOS_GOGGLE_MODE_ATMOS_THERMAL
#undef DOGMOS_GOGGLE_MODE_AREA_BLUEPRINTS
