/** Verifies which turfs can be stripped by decompression. */
/datum/unit_test/dogmos_decompression_floor_rip
	/// Original neighbor type restored during teardown.
	var/original_neighbor_type
	/// Original test-floor type restored during teardown.
	var/original_floor_type

/datum/unit_test/dogmos_decompression_floor_rip/Run()
	var/turf/open/neighbor = run_loc_floor_top_right
	original_neighbor_type = neighbor.type
	neighbor.ChangeTurf(/turf/open/space, flags = CHANGETURF_INHERIT_AIR | CHANGETURF_RECALC_ADJACENT)
	neighbor.handle_decompression_floor_rip(MOLES_CELLSTANDARD)
	TEST_ASSERT_EQUAL(neighbor.type, /turf/open/space, \
		"A decompression floor-rip callback must not scrape a non-floor turf.")

	var/turf/open/floor/engine/engine_floor = run_loc_floor_bottom_left
	original_floor_type = engine_floor.type
	engine_floor = engine_floor.ChangeTurf(/turf/open/floor/engine, flags = CHANGETURF_INHERIT_AIR | CHANGETURF_RECALC_ADJACENT)
	engine_floor.handle_decompression_floor_rip(MOLES_CELLSTANDARD)
	TEST_ASSERT_EQUAL(engine_floor.type, /turf/open/floor/engine, \
		"Decompression must not strip an engine floor.")

	engine_floor = engine_floor.ChangeTurf(/turf/open/floor/plating/reinforced, flags = CHANGETURF_INHERIT_AIR | CHANGETURF_RECALC_ADJACENT)
	engine_floor.handle_decompression_floor_rip(MOLES_CELLSTANDARD)
	TEST_ASSERT_EQUAL(engine_floor.type, /turf/open/floor/plating/reinforced, \
		"Decompression must not strip reinforced plating.")

	engine_floor = engine_floor.ChangeTurf(/turf/open/floor, flags = CHANGETURF_INHERIT_AIR | CHANGETURF_RECALC_ADJACENT)
	engine_floor.handle_decompression_floor_rip(MOLES_CELLSTANDARD)
	TEST_ASSERT(!isfloorturf(engine_floor), "Ordinary floors should still be stripped by decompression.")

/datum/unit_test/dogmos_decompression_floor_rip/Destroy()
	if(original_neighbor_type && run_loc_floor_top_right.type != original_neighbor_type)
		run_loc_floor_top_right.ChangeTurf(original_neighbor_type, flags = CHANGETURF_INHERIT_AIR | CHANGETURF_RECALC_ADJACENT)
	if(original_floor_type && run_loc_floor_bottom_left.type != original_floor_type)
		run_loc_floor_bottom_left.ChangeTurf(original_floor_type, flags = CHANGETURF_INHERIT_AIR | CHANGETURF_RECALC_ADJACENT)
	return ..()
