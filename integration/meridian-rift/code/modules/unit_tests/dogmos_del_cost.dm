/** Bounds gas-mixture teardown cost, including arena unregistration. */
/datum/unit_test/dogmos_del_cost

/datum/unit_test/dogmos_del_cost/Run()
	var/n = 2000

	var/list/mixtures = new(n)
	for(var/i in 1 to n)
		var/datum/gas_mixture/mix = new
		mix.set_volume(CELL_VOLUME)
		mix.set_moles(/datum/gas/oxygen, 5)
		mixtures[i] = mix

	var/gm_start_tick = TICK_USAGE
	for(var/datum/gas_mixture/mix as anything in mixtures)
		del(mix)
	var/gm_total_ms = TICK_USAGE_TO_MS(gm_start_tick)

	var/list/dummies = new(n)
	for(var/i in 1 to n)
		dummies[i] = new /datum/dogmos_del_cost_baseline()

	var/base_start_tick = TICK_USAGE
	for(var/datum/dummy as anything in dummies)
		del(dummy)
	var/base_total_ms = TICK_USAGE_TO_MS(base_start_tick)

	var/gm_ms_per_instance = gm_total_ms / n
	var/base_ms_per_instance = base_total_ms / n

	log_world("DOGMOS DEL() COST: [n] gas_mixture Del() calls = [gm_total_ms]ms total ([gm_ms_per_instance]ms/instance). [n] plain-datum Del() calls (baseline) = [base_total_ms]ms total ([base_ms_per_instance]ms/instance).")

	// Relative to the baseline, not an absolute ms bound - CIBUILDING runs with REFERENCE_TRACKING
	// enabled, which puts a real per-del() floor cost on EVERY datum (observed ~19-20ms/instance for
	// a plain, feature-less datum in this build), completely unrelated to Dogmos. An absolute bound
	// would just be measuring that floor. The +1ms keeps this sane if a release build ever makes the
	// baseline itself near-zero. This is a guard against a pathologically expensive FFI teardown
	// (a leaked lock, a blocking syscall), not a tight performance gate - the real numbers are in the
	// log line above for an actual read.
	TEST_ASSERT(gm_ms_per_instance < (base_ms_per_instance * 3) + 1, "gas_mixture Del() averaged [gm_ms_per_instance]ms per instance across [n] deletes, well above the [base_ms_per_instance]ms/instance plain-datum baseline - the Dogmos FFI teardown may be pathologically expensive.")

/// Deliberately empty - exists only as a same-call-path del() baseline for dogmos_del_cost to compare
/// gas_mixture's Del() cost against. No Del() override on purpose: this is the floor cost of deleting
/// a plain, feature-less datum.
/datum/dogmos_del_cost_baseline
