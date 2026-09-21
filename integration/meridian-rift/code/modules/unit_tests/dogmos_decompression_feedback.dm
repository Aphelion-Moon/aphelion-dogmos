/** Verifies per-area rate limiting for decompression feedback. */
/datum/unit_test/dogmos_decompression_feedback
	/// Original per-area feedback timestamps restored during teardown.
	var/list/original_feedback_times

/datum/unit_test/dogmos_decompression_feedback/Run()
	var/turf/open/breach_turf = run_loc_floor_bottom_left
	TEST_ASSERT(istype(breach_turf), "run_loc_floor_bottom_left is not an open turf - this test needs one.")

	original_feedback_times = SSair.kennel_breach_feedback_times
	SSair.kennel_breach_feedback_times = list()

	TEST_ASSERT(SSair.kennel_decompression_feedback_available(breach_turf), \
		"The first decompression feedback event in an area was suppressed.")
	TEST_ASSERT(!SSair.kennel_decompression_feedback_available(breach_turf), \
		"Repeated decompression feedback in the same area was not rate-limited.")

	SSair.kennel_breach_feedback_times = list()
	for(var/index in 1 to 200)
		SSair.kennel_breach_feedback_times["bounded-test-[index]"] = world.time
	TEST_ASSERT(SSair.kennel_decompression_feedback_available(breach_turf), \
		"A new decompression feedback area was suppressed at the bounded-index limit.")
	TEST_ASSERT_EQUAL(length(SSair.kennel_breach_feedback_times), 200, \
		"Decompression feedback retained more than 200 area timestamps.")

	SSair.kennel_breach_feedback_times = original_feedback_times

/datum/unit_test/dogmos_decompression_feedback/Destroy()
	if(!isnull(original_feedback_times))
		SSair.kennel_breach_feedback_times = original_feedback_times
	return ..()
