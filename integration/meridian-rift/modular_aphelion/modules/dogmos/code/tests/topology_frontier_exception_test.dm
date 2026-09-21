#if defined(UNIT_TESTS) || defined(SPACEMAN_DMM)

/** Fails inside preparation's scope before any native or world mutation. */
/datum/controller/subsystem/air/recovery_test_copy/frontier_exception/dogmos_frontier_turf_registration_is_current(turf/open/active_turf)
	throw "frontier preparation exception sentinel"

/** A preparation failure must restore both an unowned scope and a nested owner's scope. */
/datum/unit_test/dogmos_frontier_exception_scope/Run()
	var/datum/controller/subsystem/air/recovery_test_copy/frontier_exception/probe = allocate(/datum/controller/subsystem/air/recovery_test_copy/frontier_exception)
	var/original_batching = SSdogmos.runtime_topology_batching
	var/failure
	for(var/outer_owner in list(FALSE, TRUE))
		SSdogmos.runtime_topology_batching = outer_owner
		var/caught_expected = FALSE
		try
			probe.dogmos_prepare_frontier_pairs(list(run_loc_floor_bottom_left))
		catch(var/error)
			caught_expected = error == "frontier preparation exception sentinel"
		var/restored = SSdogmos.runtime_topology_batching == outer_owner
		SSdogmos.runtime_topology_batching = original_batching
		if(!caught_expected || !restored)
			failure = "Frontier preparation lost the exception or batching owner [outer_owner] (caught=[caught_expected], restored=[restored])."
	if(failure)
		return Fail(failure, __FILE__, __LINE__)

#endif
