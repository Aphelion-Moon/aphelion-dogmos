/** Verifies adjacency flags and heat-graph refresh on a real multi-turf layout. */
/datum/unit_test/dogmos_turf_adjacency_sync

/datum/unit_test/dogmos_turf_adjacency_sync/Run()
	var/turf/open/floor = run_loc_floor_bottom_left
	TEST_ASSERT(istype(floor), "The unit test run location is not an open turf - this test needs one.")

	floor.immediate_calculate_adjacent_turfs()

	TEST_ASSERT(islist(floor.atmos_adjacent_turfs) && length(floor.atmos_adjacent_turfs), \
		"A station floor has no atmos_adjacent_turfs after a rebuild - this test needs at least one real open neighbor to check anything.")

	for(var/turf/neighbor as anything in floor.atmos_adjacent_turfs)
		var/flag_value = floor.atmos_adjacent_turfs[neighbor]
		TEST_ASSERT_NOTEQUAL(flag_value, 1, \
			"atmos_adjacent_turfs entry for [neighbor] = 1 (bare TRUE) - Dogmos' AdjacentFlags::from_bits_truncate only recognizes bit 0b10 (DOGMOS_ADJACENT_FIRELOCK) and would silently drop this. Every entry must be a real flags value (NONE or DOGMOS_ADJACENT_FIRELOCK), never a bare boolean.")
		TEST_ASSERT(flag_value == NONE || flag_value == DOGMOS_ADJACENT_FIRELOCK, \
			"atmos_adjacent_turfs entry for [neighbor] = [flag_value], not a recognised AdjacentFlags value (NONE or DOGMOS_ADJACENT_FIRELOCK).")

	var/turf/open/middle = get_step(floor, EAST)
	var/turf/open/farther = get_step(middle, EAST)
	TEST_ASSERT(istype(middle) && istype(farther), "The room traversal regression needs three adjacent open turfs.")
	middle.immediate_calculate_adjacent_turfs()
	farther.immediate_calculate_adjacent_turfs()
	TEST_ASSERT(floor in middle.atmos_adjacent_turfs, "The traversal fixture needs a registered reverse edge.")
	TEST_ASSERT_EQUAL(middle.atmos_adjacent_turfs[floor], NONE, "The traversal fixture must exercise an ordinary zero-flag edge.")
	TEST_ASSERT(TURFS_CAN_SHARE(floor, middle), "A registered adjacent turf was treated as disconnected because its flags are zero.")
	var/list/room = detect_room(floor)
	TEST_ASSERT(farther in room, "Room detection did not traverse beyond the origin's immediate neighbors.")

	var/turf/open/north = get_step(floor, NORTH)
	var/turf/open/diagonal = get_step(floor, NORTHEAST)
	TEST_ASSERT(istype(north) && istype(diagonal), "The diagonal regression needs an open two-by-two square.")
	north.immediate_calculate_adjacent_turfs()
	diagonal.immediate_calculate_adjacent_turfs()
	TEST_ASSERT(north in floor.atmos_adjacent_turfs, "The diagonal fixture needs both cardinal routes from the origin.")
	TEST_ASSERT(middle in diagonal.atmos_adjacent_turfs, "The diagonal fixture needs a connected east route.")
	TEST_ASSERT(north in diagonal.atmos_adjacent_turfs, "The diagonal fixture needs a connected north route.")
	TEST_ASSERT_EQUAL(diagonal.atmos_adjacent_turfs[middle], NONE, "The first diagonal route must exercise a zero-flag edge.")
	TEST_ASSERT_EQUAL(diagonal.atmos_adjacent_turfs[north], NONE, "The second diagonal route must exercise a zero-flag edge.")
	TEST_ASSERT(!(diagonal in floor.get_atmos_adjacent_turfs()), "Cardinal-only adjacency unexpectedly included a diagonal.")
	TEST_ASSERT(diagonal in floor.get_atmos_adjacent_turfs(alldir = TRUE), "Diagonal adjacency discarded connected zero-flag edges.")

	// Remove one route only for this synchronous lookup, restoring the real graph before asserting.
	var/list/original_diagonal_adjacency = diagonal.atmos_adjacent_turfs
	diagonal.atmos_adjacent_turfs = original_diagonal_adjacency.Copy()
	diagonal.atmos_adjacent_turfs -= north
	var/list/one_diagonal_route = floor.get_atmos_adjacent_turfs(alldir = TRUE)
	diagonal.atmos_adjacent_turfs = original_diagonal_adjacency
	TEST_ASSERT(!(diagonal in one_diagonal_route), "Diagonal adjacency accepted only one route from the diagonal turf.")

	var/list/original_floor_adjacency = floor.atmos_adjacent_turfs
	floor.atmos_adjacent_turfs = original_floor_adjacency.Copy()
	floor.atmos_adjacent_turfs -= north
	var/list/one_origin_route = floor.get_atmos_adjacent_turfs(alldir = TRUE)
	floor.atmos_adjacent_turfs = original_floor_adjacency
	TEST_ASSERT(!(diagonal in one_origin_route), "Diagonal adjacency accepted only one route from the origin turf.")

	var/expected_blocked = ALL_CARDINALS & ~floor.conductivity_directions()
	TEST_ASSERT_EQUAL(floor.conductivity_blocked_directions, expected_blocked, \
		"conductivity_blocked_directions ([floor.conductivity_blocked_directions]) does not match ALL_CARDINALS & ~conductivity_directions() ([expected_blocked]) - it fell out of sync with the adjacency rebuild that just ran, which is exactly what sync_dogmos_adjacency() exists to prevent.")
