/** Verifies directional flamethrower ignition uses the active hotspot path. */
/obj/item/flamethrower/dogmos_projection_test
	/// Turfs recorded by the test igniter.
	var/list/ignited_turfs = list()

/// Records an ignition without creating a hotspot.
/obj/item/flamethrower/dogmos_projection_test/default_ignite(turf/target, release_amount = 0.05)
	ignited_turfs += target

/datum/unit_test/dogmos_flamethrower_projection
	/// Restores the subsystem setting after the test completes.
	var/original_directional_spread

/datum/unit_test/dogmos_flamethrower_projection/Run()
	original_directional_spread = SSair.flamethrower_directional_spread
	SSair.flamethrower_directional_spread = TRUE

	var/turf/source_turf = run_loc_floor_bottom_left
	var/turf/first_projection_turf = get_step(source_turf, EAST)
	var/turf/second_projection_turf = get_step(first_projection_turf, EAST)
	var/turf/target_turf = get_step(second_projection_turf, EAST)
	source_turf.immediate_calculate_adjacent_turfs()
	first_projection_turf.immediate_calculate_adjacent_turfs()
	var/list/projection_line = get_line(source_turf, target_turf)
	TEST_ASSERT_EQUAL(projection_line[1], source_turf, \
		"Flamethrower projection setup returned a line that does not start at the source turf.")
	TEST_ASSERT_EQUAL(projection_line[2], first_projection_turf, \
		"Flamethrower projection setup returned an unexpected first step.")
	TEST_ASSERT_EQUAL(projection_line[3], second_projection_turf, \
		"Flamethrower projection setup returned an unexpected second step.")
	TEST_ASSERT_EQUAL(projection_line[4], target_turf, \
		"Flamethrower projection setup returned an unexpected target step.")
	TEST_ASSERT(first_projection_turf in source_turf.get_atmos_adjacent_turfs(alldir = TRUE), \
		"Flamethrower projection setup lost atmospheric adjacency between the source and first projection turfs.")
	var/obj/item/flamethrower/dogmos_projection_test/test_flamethrower = allocate(
		/obj/item/flamethrower/dogmos_projection_test,
		source_turf,
	)
	test_flamethrower.lit = TRUE
	TEST_ASSERT_EQUAL(get_turf(test_flamethrower), source_turf, \
		"Flamethrower projection setup did not place the test item on the source turf.")
	test_flamethrower.flame_turf(projection_line)

	TEST_ASSERT_EQUAL(test_flamethrower.ignited_turfs[1], second_projection_turf, \
		"Directional flamethrower projection ignited the turf adjacent to the user instead of starting one tile farther away.")
	TEST_ASSERT(!test_flamethrower.operating, \
		"Directional flamethrower projection did not clear its operating state before the legacy projection check.")

	test_flamethrower.ignited_turfs.Cut()
	SSair.flamethrower_directional_spread = FALSE
	test_flamethrower.flame_turf(projection_line)
	var/turf/legacy_first_ignition = test_flamethrower.ignited_turfs[1]
	TEST_ASSERT(legacy_first_ignition, "Legacy flamethrower projection did not ignite any turf.")
	TEST_ASSERT(legacy_first_ignition.x == first_projection_turf.x && legacy_first_ignition.y == first_projection_turf.y, \
		"Legacy flamethrower projection ignited ([legacy_first_ignition.x], [legacy_first_ignition.y]) instead of ([first_projection_turf.x], [first_projection_turf.y]).")

	TEST_ASSERT(DOGMOS_FLAMETHROWER_HOTSPOT_EXPOSURE_VOLUME * 25 < CELL_VOLUME * 0.95, \
		"The flamethrower hotspot exposure volume reaches LINDA's bypass threshold and can spread backward into adjacent turfs.")

/datum/unit_test/dogmos_flamethrower_projection/Destroy()
	SSair.flamethrower_directional_spread = original_directional_spread
	return ..()
