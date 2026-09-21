/**
 * Bare bookkeeping-only stand-in for /obj/effect/hotspot, used ONLY by dogmos_kennel_fire_groups to
 * drive /datum/hot_group's add_to_group()/remove_from_group() directly. Deliberately NOT an
 * /obj/effect/hotspot subtype: the real type's Initialize() does a lot of unrelated heavy lifting
 * (auto-grouping via adjacent turfs, gas exposure/reaction, igniting everything on the turf, a looping
 * fire sound) that this test doesn't want and can't safely control - letting it run for real risks
 * genuinely igniting the shared unit-test room. add_to_group()/remove_from_group()/merge_hot_groups()
 * only ever read target.loc and read/write target.our_hot_group, so this only needs to declare that
 * one var to be a valid stand-in.
 */
/obj/effect/dogmos_kennel_fire_group_probe
	var/datum/hot_group/our_hot_group

/**
 * Covers /datum/hot_group's peak_size tracking (add_to_group() bumps it) and the recording gate in
 * remove_from_group() - a group's peak_size is recorded into SSair.recent_fire_groups exactly once,
 * right before the group is deleted, only if peak_size >= kennel_fire_group_notable_size. A group that
 * never reaches the notable size must not be recorded, even though it still goes through the exact same
 * "spot_list emptied -> qdel" path as one that does.
 */
/datum/unit_test/dogmos_kennel_fire_groups
	var/list/original_bucket
	var/original_notable_size

/datum/unit_test/dogmos_kennel_fire_groups/Run()
	var/turf/open/T = run_loc_floor_bottom_left
	TEST_ASSERT(istype(T), "run_loc_floor_bottom_left is not an open turf - this test needs one.")

	original_bucket = SSair.recent_fire_groups
	original_notable_size = SSair.kennel_fire_group_notable_size
	SSair.recent_fire_groups = list()
	// Kept at/under MIN_SIZE_SOUND (2, LINDA_fire.dm) deliberately: add_to_group() itself calls
	// update_sound() - a real, unrelated side effect (instantiates /datum/looping_sound/fire) - once
	// spot_list exceeds that. This test only needs to check peak_size/the recording gate, not exercise
	// that subsystem, so notable_size is set to 2 rather than 3 to keep every group in this test at or
	// below the sound threshold.
	SSair.kennel_fire_group_notable_size = 2

	// Below-notable-size group: one probe, added then removed. Must never be recorded.
	var/datum/hot_group/small_group = allocate(/datum/hot_group) // APHELION EDIT CHANGE - DOGMOS - ORIGINAL: var/datum/hot_group/small_group = new
	var/obj/effect/dogmos_kennel_fire_group_probe/small_a = allocate(/obj/effect/dogmos_kennel_fire_group_probe)
	small_group.add_to_group(small_a)
	TEST_ASSERT_EQUAL(small_group.peak_size, 1, \
		"peak_size ([small_group.peak_size]) did not track add_to_group() calls - expected 1 after adding 1 probe.")
	small_group.remove_from_group(small_a) // spot_list now empty -> qdel(src), the recording gate
	TEST_ASSERT_EQUAL(length(SSair.recent_fire_groups), 0, \
		"A fire group with peak_size 1, below kennel_fire_group_notable_size (2), was recorded anyway.")

	// At-notable-size group: two probes. Must be recorded exactly once.
	var/datum/hot_group/big_group = allocate(/datum/hot_group) // APHELION EDIT CHANGE - DOGMOS - ORIGINAL: var/datum/hot_group/big_group = new
	var/obj/effect/dogmos_kennel_fire_group_probe/big_a = allocate(/obj/effect/dogmos_kennel_fire_group_probe)
	var/obj/effect/dogmos_kennel_fire_group_probe/big_b = allocate(/obj/effect/dogmos_kennel_fire_group_probe)
	big_group.add_to_group(big_a)
	big_group.add_to_group(big_b)
	TEST_ASSERT_EQUAL(big_group.peak_size, 2, \
		"peak_size ([big_group.peak_size]) did not track add_to_group() calls - expected 2 after adding 2 probes.")
	big_group.remove_from_group(big_a)
	big_group.remove_from_group(big_b) // spot_list now empty -> qdel(src)
	TEST_ASSERT_EQUAL(length(SSair.recent_fire_groups), 1, \
		"A fire group with peak_size 2, at kennel_fire_group_notable_size (2), was not recorded - expected 1 entry, got [length(SSair.recent_fire_groups)].")
	TEST_ASSERT_EQUAL(SSair.recent_fire_groups[1]["peak_size"], 2, \
		"The recorded entry's peak_size ([SSair.recent_fire_groups[1]["peak_size"]]) does not match the group's real peak (2).")

	SSair.recent_fire_groups = original_bucket
	SSair.kennel_fire_group_notable_size = original_notable_size

/datum/unit_test/dogmos_kennel_fire_groups/Destroy()
	// Unconditional, not just on success: a TEST_ASSERT abort in Run() skips its own restore above and
	// would otherwise leave SSair's real bucket/threshold dirty for the rest of the suite.
	if(!isnull(original_bucket))
		SSair.recent_fire_groups = original_bucket
	if(!isnull(original_notable_size))
		SSair.kennel_fire_group_notable_size = original_notable_size
	return ..()
