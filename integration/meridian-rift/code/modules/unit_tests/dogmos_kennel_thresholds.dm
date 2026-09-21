/** Verifies Kennel threshold input rejects hostile values and applies documented bounds. */
/datum/unit_test/dogmos_kennel_thresholds

/datum/unit_test/dogmos_kennel_thresholds/Run()
	TEST_ASSERT_NULL(GLOB.dogmos_kennel.normalize_threshold("fire_group_notable_size", null), \
		"Kennel accepted a null threshold value.")
	TEST_ASSERT_NULL(GLOB.dogmos_kennel.normalize_threshold("fire_group_notable_size", "not-a-number"), \
		"Kennel accepted arbitrary threshold text.")
	TEST_ASSERT_NULL(GLOB.dogmos_kennel.normalize_threshold("reaction_magnitude_threshold", "NaN"), \
		"Kennel accepted NaN-like threshold input.")
	TEST_ASSERT_NULL(GLOB.dogmos_kennel.normalize_threshold("machine_cost_ms_threshold", "Infinity"), \
		"Kennel accepted infinity-like threshold input.")
	TEST_ASSERT_NULL(GLOB.dogmos_kennel.normalize_threshold("unknown", 1), \
		"Kennel accepted an unknown threshold name.")

	TEST_ASSERT_EQUAL(GLOB.dogmos_kennel.normalize_threshold("fire_group_notable_size", -1), 1, \
		"Kennel did not clamp a negative fire-group threshold to one.")
	TEST_ASSERT_EQUAL(GLOB.dogmos_kennel.normalize_threshold("fire_group_notable_size", 0), 1, \
		"Kennel did not clamp a zero fire-group threshold to one.")
	TEST_ASSERT_EQUAL(GLOB.dogmos_kennel.normalize_threshold("reaction_magnitude_threshold", -1), 0, \
		"Kennel did not clamp a negative reaction threshold to zero.")
	TEST_ASSERT_EQUAL(GLOB.dogmos_kennel.normalize_threshold("machine_cost_ms_threshold", 0), 0, \
		"Kennel did not preserve a zero machinery-cost threshold.")
	TEST_ASSERT_EQUAL(GLOB.dogmos_kennel.normalize_threshold("high_cost_ms_threshold", SHORT_REAL_LIMIT * 2), SHORT_REAL_LIMIT, \
		"Kennel did not clamp an above-maximum threshold to the exact-number ceiling.")

	TEST_ASSERT_EQUAL(GLOB.dogmos_kennel.normalize_browse_search(null), "", \
		"Kennel did not reject a null machinery search.")
	TEST_ASSERT_EQUAL(GLOB.dogmos_kennel.normalize_browse_search(1), "", \
		"Kennel did not reject a non-text machinery search.")
	TEST_ASSERT_EQUAL(length_char(GLOB.dogmos_kennel.normalize_browse_search(repeat_string(100, "x"))), 64, \
		"Kennel did not truncate a machinery search to its documented maximum length.")

	var/list/candidates = list()
	for(var/index in 1 to 251)
		var/obj/machinery/machine = allocate(/obj/machinery)
		machine.name = "Kennel paging test [index]"
		candidates += machine
	var/list/first_page = GLOB.dogmos_kennel.build_machinery_browse_page(candidates, "", 1)
	var/list/second_page = GLOB.dogmos_kennel.build_machinery_browse_page(candidates, "", 2)
	TEST_ASSERT_EQUAL(length(first_page["rows"]), 250, \
		"Kennel's first machinery page did not enforce the 250-row server maximum.")
	TEST_ASSERT_EQUAL(length(second_page["rows"]), 1, \
		"Kennel's second machinery page did not contain the one remaining row.")
	TEST_ASSERT_EQUAL(first_page["total"], 251, \
		"Kennel's machinery page did not report the complete matching-row count.")
