/** Verifies the multiz gas-overlay table consumed by Rust visual updates. */
/datum/unit_test/dogmos_gas_overlays

/datum/unit_test/dogmos_gas_overlays/Run()
	TEST_ASSERT(length(GLOB.gas_data.overlays), \
		"GLOB.gas_data.overlays is empty - Rust's set_visuals callback would never resolve any overlay, so no gas would ever render visually once SSAIR_ACTIVETURFS moves to Rust.")

	// Plasma is always visible (moles_visible is set) - a reliable known-good probe.
	var/plasma_id = initial(/datum/gas/plasma::id)
	var/list/plasma_overlays = GLOB.gas_data.overlays[plasma_id]
	TEST_ASSERT_NOTNULL(plasma_overlays, \
		"GLOB.gas_data.overlays has no entry for plasma (id [plasma_id]) despite plasma being a visible gas.")

	TEST_ASSERT(istype(plasma_overlays[1], /list), \
		"plasma's plane-offset-0 entry (index 1) is not a list - expected the per-visibility-state overlay table (the +1 is GET_TURF_PLANE_OFFSET()'s indexing convention, code/__HELPERS/_planes.dm).")
	var/list/state_table = plasma_overlays[1]
	TEST_ASSERT_EQUAL(length(state_table), TOTAL_VISIBLE_STATES, \
		"plasma's plane-offset-0 overlay table has [length(state_table)] entries, expected TOTAL_VISIBLE_STATES ([TOTAL_VISIBLE_STATES]).")
	TEST_ASSERT(istype(state_table[1], /obj/effect/overlay/gas), \
		"plasma's plane-offset-0, visibility-state-1 entry is not a /obj/effect/overlay/gas instance.")

	// Must be the SAME list object GLOB.meta_gas_info already owns, not a copy - otherwise SSmapping
	// growing z_level_to_plane_offset for a new z-level after roundstart (code/controllers/subsystem/mapping.dm)
	// would update meta_gas_info's table but silently leave gas_data's copy stale.
	TEST_ASSERT_EQUAL(plasma_overlays, GLOB.meta_gas_info[META_GAS_OVERLAY][/datum/gas/plasma], \
		"plasma's entry in GLOB.gas_data.overlays is not the same list object as GLOB.meta_gas_info[META_GAS_OVERLAY][/datum/gas/plasma] - a new plane offset added later would desync them.")

	// A gas with no moles_visible (e.g. nitrogen) should have no entry at all, not an empty/garbage one.
	var/nitrogen_id = initial(/datum/gas/nitrogen::id)
	TEST_ASSERT_NULL(GLOB.gas_data.overlays[nitrogen_id], \
		"GLOB.gas_data.overlays has an entry for nitrogen, which has no moles_visible and should never have generated any overlay objects to reference.")
