/** Verifies thresholded reaction history records only changed values. */
/datum/unit_test/dogmos_kennel_reactions_of_interest
	var/original_threshold
	var/list/original_bucket

/datum/unit_test/dogmos_kennel_reactions_of_interest/Run()
	var/turf/open/T = run_loc_floor_bottom_left
	TEST_ASSERT(istype(T), "run_loc_floor_bottom_left is not an open turf - this test needs one.")

	original_threshold = SSair.kennel_reaction_magnitude_threshold
	original_bucket = SSair.recent_reactions_of_interest
	SSair.kennel_reaction_magnitude_threshold = 100
	SSair.recent_reactions_of_interest = list()
	T.kennel_last_reaction_results = null

	var/fake_reaction = /datum/gas_reaction/standard/plasmafire

	// Below threshold: never recorded, but the cache still learns the value (so a later increase past
	// threshold is correctly seen as "changed", not swallowed).
	T.air.reaction_results[fake_reaction] = 50
	SSair.check_kennel_reaction_of_interest(T)
	TEST_ASSERT_EQUAL(length(SSair.recent_reactions_of_interest), 0, \
		"A reaction amount (50) below kennel_reaction_magnitude_threshold (100) was recorded anyway.")

	// Above threshold, first time seen at this value: recorded once.
	T.air.reaction_results[fake_reaction] = 500
	SSair.check_kennel_reaction_of_interest(T)
	TEST_ASSERT_EQUAL(length(SSair.recent_reactions_of_interest), 1, \
		"A reaction amount (500) above threshold, seen for the first time, was not recorded - expected 1 entry, got [length(SSair.recent_reactions_of_interest)].")

	// Same value again, unchanged: air.reaction_results is cumulative/never-cleared, so this call
	// simulates exactly the "still sitting there from an old reaction" case the cache exists for.
	SSair.check_kennel_reaction_of_interest(T)
	TEST_ASSERT_EQUAL(length(SSair.recent_reactions_of_interest), 1, \
		"An UNCHANGED reaction amount (500, same as last call) was re-recorded - expected the dedup cache to skip it, still got [length(SSair.recent_reactions_of_interest)] entries.")

	// Changed value, still above threshold: a real new reaction result, should record again.
	T.air.reaction_results[fake_reaction] = 700
	SSair.check_kennel_reaction_of_interest(T)
	TEST_ASSERT_EQUAL(length(SSair.recent_reactions_of_interest), 2, \
		"A genuinely CHANGED reaction amount (500 -> 700, still above threshold) was not recorded - expected 2 entries, got [length(SSair.recent_reactions_of_interest)].")

	SSair.kennel_reaction_magnitude_threshold = original_threshold
	SSair.recent_reactions_of_interest = original_bucket
	T.air.reaction_results.Cut()
	T.kennel_last_reaction_results = null
	restore_atmos()

/datum/unit_test/dogmos_kennel_reactions_of_interest/Destroy()
	// Unconditional, not just on success: a TEST_ASSERT abort in Run() skips its own restore above and
	// would otherwise leave SSair's real thresholds/bucket and the shared test turf's reaction cache
	// dirty for every test that runs after this one.
	if(!isnull(original_threshold))
		SSair.kennel_reaction_magnitude_threshold = original_threshold
	if(!isnull(original_bucket))
		SSair.recent_reactions_of_interest = original_bucket
	var/turf/open/T = run_loc_floor_bottom_left
	if(istype(T))
		T.air.reaction_results.Cut()
		T.kennel_last_reaction_results = null
	restore_atmos()
	return ..()
