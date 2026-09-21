/** Verifies bounded Kennel event overlays and refresh behavior. */
/datum/unit_test/dogmos_kennel_overlays
	var/list/original_tracker
	var/list/marked_turfs

/datum/unit_test/dogmos_kennel_overlays/Run()
	var/turf/open/base = run_loc_floor_bottom_left
	TEST_ASSERT(istype(base), "run_loc_floor_bottom_left is not an open turf - this test needs one.")

	original_tracker = SSair.kennel_overlay_breach_turfs
	SSair.kennel_overlay_breach_turfs = list()
	marked_turfs = list()

	// Mark exactly KENNEL_OVERLAY_RECENT_CAP distinct turfs from the shared test room's Z_TURFS - real
	// turfs, not synthetic stand-ins, since vis_contents is what's actually being asserted on.
	var/list/room_turfs = list()
	for(var/turf/open/candidate in Z_TURFS(base.z))
		room_turfs += candidate
		if(length(room_turfs) >= KENNEL_OVERLAY_RECENT_CAP + 1)
			break
	TEST_ASSERT(length(room_turfs) >= KENNEL_OVERLAY_RECENT_CAP + 1, \
		"The shared test room has only [length(room_turfs)] open turfs - this test needs at least [KENNEL_OVERLAY_RECENT_CAP + 1] to exercise real eviction.")

	for(var/i in 1 to KENNEL_OVERLAY_RECENT_CAP)
		var/turf/open/T = room_turfs[i]
		SSair.kennel_mark_overlay_recent(SSair.kennel_overlay_breach_turfs, KENNEL_OVERLAY_BREACH, T)
		marked_turfs += T // tracked here (not just at Run()'s end) so Destroy() can always clean up whatever was actually touched, even on an early TEST_ASSERT abort

	TEST_ASSERT_EQUAL(length(SSair.kennel_overlay_breach_turfs), KENNEL_OVERLAY_RECENT_CAP, \
		"After marking exactly KENNEL_OVERLAY_RECENT_CAP ([KENNEL_OVERLAY_RECENT_CAP]) distinct turfs, the tracker holds [length(SSair.kennel_overlay_breach_turfs)] - none should have been evicted yet.")

	var/turf/open/first_marked = marked_turfs[1]
	var/list/first_slots = GLOB.kennel_overlay_turfs[KENNEL_OVERLAY_BREACH]
	var/first_offset = GET_Z_PLANE_OFFSET(first_marked.z) + 1
	TEST_ASSERT(first_marked.vis_contents.Find(first_slots[first_offset]), \
		"The first-marked turf is not showing the breach overlay before any eviction has happened - kennel_show_overlay() is not adding to vis_contents correctly.")

	// One more distinct turf: the FIRST marked turf (oldest, never re-marked) must be evicted - both
	// from the tracker list and, more importantly, its actual vis_contents overlay.
	var/turf/open/overflow_turf = room_turfs[KENNEL_OVERLAY_RECENT_CAP + 1]
	SSair.kennel_mark_overlay_recent(SSair.kennel_overlay_breach_turfs, KENNEL_OVERLAY_BREACH, overflow_turf)
	marked_turfs += overflow_turf

	TEST_ASSERT_EQUAL(length(SSair.kennel_overlay_breach_turfs), KENNEL_OVERLAY_RECENT_CAP, \
		"After exceeding the cap by one, the tracker holds [length(SSair.kennel_overlay_breach_turfs)], expected it to stay at KENNEL_OVERLAY_RECENT_CAP ([KENNEL_OVERLAY_RECENT_CAP]) via eviction.")
	TEST_ASSERT(!first_marked.vis_contents.Find(first_slots[first_offset]), \
		"The oldest turf still shows the breach overlay after the tracker exceeded its cap - kennel_mark_overlay_recent() is not hiding the evicted turf's overlay.")
	TEST_ASSERT(!(first_marked in SSair.kennel_overlay_breach_turfs), \
		"The oldest turf is still present in the tracker list after eviction.")
	TEST_ASSERT((overflow_turf in SSair.kennel_overlay_breach_turfs), \
		"The newly-marked turf that triggered eviction is not itself present in the tracker.")

	// Re-marking an already-tracked turf must move it to the front, not duplicate it - the tracker
	// should still be at the cap, not the cap+1.
	var/turf/open/second_marked = marked_turfs[2]
	SSair.kennel_mark_overlay_recent(SSair.kennel_overlay_breach_turfs, KENNEL_OVERLAY_BREACH, second_marked)
	TEST_ASSERT_EQUAL(length(SSair.kennel_overlay_breach_turfs), KENNEL_OVERLAY_RECENT_CAP, \
		"Re-marking an already-tracked turf changed the tracker size to [length(SSair.kennel_overlay_breach_turfs)] - it should be moved to the front, not duplicated.")

	// Cleanup: hide every overlay this test turned on, restore the real tracker. (Destroy() does this
	// same cleanup unconditionally too, for the early-abort case - this just makes a clean run tidy up
	// immediately rather than waiting for teardown.)
	for(var/turf/open/T in marked_turfs)
		SSair.kennel_hide_overlay(T, KENNEL_OVERLAY_BREACH)
	SSair.kennel_overlay_breach_turfs = original_tracker

/datum/unit_test/dogmos_kennel_overlays/Destroy()
	// Unconditional, not just on success: a TEST_ASSERT abort in Run() skips its own cleanup above and
	// would otherwise leave a real, visible overlay lit on shared test-room turfs and SSair's real
	// tracker replaced with this test's empty one for the rest of the suite.
	if(marked_turfs)
		for(var/turf/open/T in marked_turfs)
			SSair.kennel_hide_overlay(T, KENNEL_OVERLAY_BREACH)
	if(!isnull(original_tracker))
		SSair.kennel_overlay_breach_turfs = original_tracker
	return ..()
