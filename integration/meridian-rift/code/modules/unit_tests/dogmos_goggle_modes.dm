/** Verifies station-safe and administrative goggles expose the intended Kennel overlays. */
/datum/unit_test/dogmos_goggle_modes

/datum/unit_test/dogmos_goggle_modes/Run()
	var/obj/item/clothing/glasses/meson/engine/dogmos/station_goggles = allocate(/obj/item/clothing/glasses/meson/engine/dogmos)
	var/obj/item/clothing/glasses/meson/engine/dogmos/admin/admin_goggles = allocate(/obj/item/clothing/glasses/meson/engine/dogmos/admin)

	TEST_ASSERT(DOGMOS_GOGGLE_MODE_BREACHES in station_goggles.modes, \
		"Station-safe Dogmos goggles do not expose breach alerts.")
	TEST_ASSERT(DOGMOS_GOGGLE_MODE_REACTIONS in station_goggles.modes, \
		"Station-safe Dogmos goggles do not expose reaction profiling.")
	TEST_ASSERT(!(DOGMOS_GOGGLE_MODE_HIGH_COST in station_goggles.modes), \
		"Station-safe Dogmos goggles expose the administrative cost profile.")
	TEST_ASSERT(!(DOGMOS_GOGGLE_MODE_STRUCTURES in station_goggles.modes), \
		"Station-safe Dogmos goggles expose administrative structure pins.")

	TEST_ASSERT(DOGMOS_GOGGLE_MODE_HIGH_COST in admin_goggles.modes, \
		"Administrative Dogmos goggles do not expose the cost profile.")
	TEST_ASSERT(DOGMOS_GOGGLE_MODE_STRUCTURES in admin_goggles.modes, \
		"Administrative Dogmos goggles do not expose structure pins.")
	TEST_ASSERT(DOGMOS_GOGGLE_MODE_ALL in admin_goggles.modes, \
		"Administrative Dogmos goggles do not expose the full Kennel overlay mode.")

	station_goggles.mode = DOGMOS_GOGGLE_MODE_BREACHES
	var/list/station_categories = station_goggles.dogmos_overlay_categories()
	TEST_ASSERT_EQUAL(length(station_categories), 1, \
		"Station breach-alert mode exposes [length(station_categories)] categories instead of one.")
	TEST_ASSERT_EQUAL(station_categories[1], KENNEL_OVERLAY_BREACH, \
		"Station breach-alert mode is not mapped to the breach overlay category.")

	admin_goggles.mode = DOGMOS_GOGGLE_MODE_ALL
	var/list/admin_categories = admin_goggles.dogmos_overlay_categories()
	TEST_ASSERT_EQUAL(length(admin_categories), 4, \
		"Full Kennel mode exposes [length(admin_categories)] categories instead of all four.")
	for(var/category in admin_categories)
		TEST_ASSERT(length(GLOB.kennel_overlay_images_by_category[category]), \
			"Full Kennel mode has no initialized image table for category [category].")
