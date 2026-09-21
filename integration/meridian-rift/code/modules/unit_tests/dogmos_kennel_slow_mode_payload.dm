/** Slow mode keeps bounded event history visible while gating the large machinery browse. */
/datum/unit_test/dogmos_kennel_slow_mode_payload
	var/original_slow_mode
	var/list/original_bucket
	var/list/original_explosion_bucket
	var/list/original_reaction_bucket
	var/list/original_high_cost_bucket
	var/list/original_breach_bucket
	var/list/original_structures

/datum/unit_test/dogmos_kennel_slow_mode_payload/Run()
	var/mob/living/carbon/human/observer = allocate(/mob/living/carbon/human/consistent)
	// create_mob_hud() no-ops without a real client (this test mob has none) - build the HUD directly,
	// the same way create_mob_hud() does internally, since ui_data() unconditionally reads
	// user.hud_used.atmos_debug_overlays regardless of what this test is actually checking.
	observer.set_hud_used(new observer.hud_type(observer))

	original_slow_mode = SSair.kennel_slow_mode
	original_bucket = SSair.recent_fire_groups
	original_explosion_bucket = SSair.recent_explosions
	original_reaction_bucket = SSair.recent_reactions_of_interest
	original_high_cost_bucket = SSair.recent_high_cost_zones
	original_breach_bucket = SSair.recent_breaches
	original_structures = SSair.structures_of_interest
	SSair.recent_fire_groups = list(list(
		"time" = "00:00:00",
		"jump_to" = null,
		"area" = "Test",
		"peak_size" = 99,
	))
	SSair.recent_explosions = list(list(
		"time" = "00:00:00",
		"jump_to" = null,
		"area" = "Test",
		"devastation_range" = 1,
		"heavy_impact_range" = 2,
		"light_impact_range" = 3,
		"cause" = "Test",
		"index" = 1,
	))
	SSair.recent_reactions_of_interest = list(list(
		"time" = "00:00:00",
		"jump_to" = null,
		"area" = "Test",
		"reaction" = "plasmafire",
		"amount" = 99,
	))
	SSair.recent_high_cost_zones = list(list(
		"time" = "00:00:00",
		"jump_to" = null,
		"area" = "Test",
		"reaction" = "plasmafire",
		"cost_ms" = 1,
	))
	SSair.recent_breaches = list(list(
		"time" = "00:00:00",
		"jump_to" = null,
		"area" = "Test",
		"moles_lost" = 99,
	))
	SSair.structures_of_interest = list(list(
		"ref" = "[0x1]",
		"name" = "Test machine",
		"area" = "Test",
		"reason" = "test",
		"pinned_at" = "00:00:00",
	))

	SSair.kennel_slow_mode = TRUE
	var/list/data_slow = GLOB.dogmos_kennel.ui_data(observer)
	TEST_ASSERT(islist(data_slow["recent_fire_groups"]), \
		"ui_data()'s recent_fire_groups is not a list at all while slow mode is on - the frontend has nothing safe to render.")
	TEST_ASSERT_EQUAL(length(data_slow["recent_fire_groups"]), 1, \
		"ui_data() did not preserve recent_fire_groups while kennel_slow_mode is TRUE - fire-group diagnostics must remain available in slow mode.")
	TEST_ASSERT_EQUAL(data_slow["recent_fire_groups"][1]["peak_size"], 99, \
		"ui_data()'s slow-mode recent_fire_groups entry does not match SSair's real data.")
	TEST_ASSERT_EQUAL(length(data_slow["recent_explosions"]), 1, \
		"ui_data() did not preserve recent_explosions while kennel_slow_mode is TRUE - explosion diagnostics must remain available in slow mode.")
	TEST_ASSERT_EQUAL(data_slow["recent_explosions"][1]["index"], 1, \
		"ui_data()'s slow-mode recent_explosions entry does not match SSair's real data.")
	TEST_ASSERT_EQUAL(data_slow["event_counts"]["reactions_of_interest"], 1, \
		"ui_data() did not expose the stored reaction count while slow mode was on - the frontend cannot distinguish an empty history from a hidden history.")
	TEST_ASSERT_EQUAL(length(data_slow["recent_reactions_of_interest"]), 1, \
		"ui_data() hid stored reaction history while kennel_slow_mode is TRUE - bounded event histories must remain visible.")
	TEST_ASSERT_EQUAL(length(data_slow["recent_high_cost_zones"]), 1, \
		"ui_data() hid stored high-cost history while kennel_slow_mode is TRUE - bounded event histories must remain visible.")
	TEST_ASSERT_EQUAL(length(data_slow["recent_breaches"]), 1, \
		"ui_data() hid stored breach history while kennel_slow_mode is TRUE - bounded event histories must remain visible.")
	TEST_ASSERT_EQUAL(length(data_slow["structures_of_interest"]), 1, \
		"ui_data() hid stored structures of interest while kennel_slow_mode is TRUE - the small stored pin list must remain visible.")
	TEST_ASSERT_NULL(data_slow["atmos_machinery_browse"], \
		"ui_data() sent atmos_machinery_browse while kennel_slow_mode is TRUE - that key should be entirely absent, not just empty, matching its optional frontend type.")

	SSair.kennel_slow_mode = FALSE
	var/list/data_live = GLOB.dogmos_kennel.ui_data(observer)
	TEST_ASSERT_NULL(data_live["equalize_performance_profile"], \
		"ui_data() still exposes the round-static Equalize performance profile - it does not belong on the live Kennel page.")
	TEST_ASSERT_EQUAL(length(data_live["recent_fire_groups"]), 1, \
		"ui_data() did not send the real recent_fire_groups entry while kennel_slow_mode is FALSE - got [length(data_live["recent_fire_groups"])] entries.")
	TEST_ASSERT_EQUAL(data_live["recent_fire_groups"][1]["peak_size"], 99, \
		"ui_data()'s recent_fire_groups entry does not match SSair's real data while slow mode is off.")
	TEST_ASSERT_EQUAL(length(data_live["recent_explosions"]), 1, \
		"ui_data() did not send the real recent_explosions entry while kennel_slow_mode is FALSE.")
	TEST_ASSERT_EQUAL(length(data_live["recent_reactions_of_interest"]), 1, \
		"ui_data() did not send the real reaction history while kennel_slow_mode is FALSE.")
	TEST_ASSERT_EQUAL(data_live["event_counts"]["reactions_of_interest"], 1, \
		"ui_data()'s reaction count does not match the real reaction history while kennel_slow_mode is FALSE.")

	SSair.kennel_slow_mode = original_slow_mode
	SSair.recent_fire_groups = original_bucket
	SSair.recent_explosions = original_explosion_bucket
	SSair.recent_reactions_of_interest = original_reaction_bucket
	SSair.recent_high_cost_zones = original_high_cost_bucket
	SSair.recent_breaches = original_breach_bucket
	SSair.structures_of_interest = original_structures

/datum/unit_test/dogmos_kennel_slow_mode_payload/Destroy()
	// Unconditional, not just on success: a TEST_ASSERT abort in Run() skips its own restore above and
	// would otherwise leave SSair's real slow-mode toggle/bucket dirty for the rest of the suite.
	if(!isnull(original_slow_mode))
		SSair.kennel_slow_mode = original_slow_mode
	if(!isnull(original_bucket))
		SSair.recent_fire_groups = original_bucket
	if(!isnull(original_explosion_bucket))
		SSair.recent_explosions = original_explosion_bucket
	if(!isnull(original_reaction_bucket))
		SSair.recent_reactions_of_interest = original_reaction_bucket
	if(!isnull(original_high_cost_bucket))
		SSair.recent_high_cost_zones = original_high_cost_bucket
	if(!isnull(original_breach_bucket))
		SSair.recent_breaches = original_breach_bucket
	if(!isnull(original_structures))
		SSair.structures_of_interest = original_structures
	return ..()
