#include "manual_playtest_regressions.dm"
#include "pipenet_reconcile_regressions.dm"

/** Opt-in integration checks; never included in the production DME. */
SUBSYSTEM_DEF(settlement_regression)
	name = "Settlement regression"
	init_stage = INITSTAGE_LAST
	ss_flags = SS_NO_FIRE

/datum/controller/subsystem/settlement_regression/Initialize()
	Master.sleep_offline_after_initializations = FALSE
	INVOKE_ASYNC(src, PROC_REF(run_checks))
	return SS_INIT_SUCCESS

/** Runs after initialization in an isolated world, with no atmosphere stress workload. */
/datum/controller/subsystem/settlement_regression/proc/run_checks()
	while(Master.init_stage_completed < INITSTAGE_MAX)
		sleep(1)
	Master.processing = FALSE
	try
		verify_settlement_mixtures()
		verify_settlement_turfs()
		verify_settlement_scheduling()
		verify_manual_playtest_regressions()
		verify_pipenet_reconciliation()
		file("[GLOB.log_directory]/settlement-result.json") << json_encode(list("passed" = TRUE))
	catch(var/exception/error)
		file("[GLOB.log_directory]/settlement-result.json") << json_encode(list("passed" = FALSE, "error" = error.name))
	SSdogmos.Shutdown()
	file("[GLOB.log_directory]/settlement-shutdown.json") << json_encode(list("native_shutdown_complete" = TRUE))
	del(world)

/** Verifies the actual generated export against literal states and the public scalar API. */
/proc/verify_settlement_mixtures()
	var/datum/gas_mixture/source = new
	source.set_moles(GAS_O2, 10)
	source.set_temperature(300)
	var/datum/gas_mixture/hot = new(null, source)
	hot.set_temperature(1000)
	var/datum/gas_mixture/fixed = new(null, hot)
	fixed.mark_immutable()
	var/datum/gas_mixture/empty = new
	var/list/neighbors = list(source, hot, fixed, empty, hot, source)
	var/list/expected = list(0, 0, 2, 1, 2, 2, 0)
	var/list/actual = source.__settlement_batch(neighbors)
	for(var/index in 1 to length(expected))
		if(actual[index] != expected[index])
			CRASH("Settlement classification differs at [index].")
	hot.set_temperature(300)
	actual = source.__settlement_batch(list(hot))
	if(actual[2] != 0)
		CRASH("Settlement reused a stale temperature comparison.")
	actual = fixed.__settlement_batch(list(source, fixed))
	if(actual[1] != 1 || actual[2] != 2 || actual[3] != 0)
		CRASH("Immutable source or aliased neighbor classification changed.")
	actual = source.__settlement_batch(list())
	if(length(actual) != 1 || actual[1])
		CRASH("Empty adjacency did not preserve source immutability.")
	for(var/datum/gas_mixture/left in neighbors)
		actual = left.__settlement_batch(neighbors)
		for(var/index in 1 to length(neighbors))
			var/datum/gas_mixture/right = neighbors[index]
			var/expected_state = left.compare(right) ? (right.is_immutable() ? 1 : 2) : 0
			if(actual[index + 1] != expected_state)
				CRASH("Batch differs from the public directional comparison.")
	qdel(source)
	qdel(hot)
	qdel(fixed)
	qdel(empty)

/** Inert controller copy exercises real queue and activation procs without replacing SSair. */
/datum/controller/subsystem/air/settlement_probe
	ss_flags = SS_NO_INIT | SS_NO_FIRE
	can_fire = FALSE
	/// Counts admission attempts, including redundant starts that the repair avoids.
	var/start_calls = 0

/datum/controller/subsystem/air/settlement_probe/New()
	return

/datum/controller/subsystem/air/settlement_probe/start_processing_machine(datum/machine)
	start_calls++
	return ..()

/** Exercises the real DM retirement decision and neighbor activation on mutable/fixed air. */
/proc/verify_settlement_turfs()
	var/list/sites = list()
	for(var/turf/open/floor/site in world)
		if(locate(/obj/machinery) in site)
			continue
		if(site.active_hotspot)
			continue
		sites += site
		if(length(sites) == 2)
			break
	if(length(sites) != 2)
		CRASH("Missing quiet floors for settlement checks.")
	var/turf/open/source = sites[1]
	var/turf/open/neighbor = sites[2]
	var/datum/gas_mixture/old_source_air = source.air
	var/datum/gas_mixture/old_neighbor_air = neighbor.air
	var/list/old_adjacency = source.atmos_adjacent_turfs
	var/old_excited = neighbor.excited
	var/old_ticker = neighbor.significant_share_ticker
	var/datum/gas_mixture/left = new
	var/datum/gas_mixture/right = new
	left.set_moles(GAS_O2, 10)
	right.set_moles(GAS_O2, 10)
	left.set_temperature(300)
	right.set_temperature(300)
	source.air = left
	neighbor.air = right
	source.atmos_adjacent_turfs = list(neighbor)
	var/datum/controller/subsystem/air/settlement_probe/probe = new
	neighbor.excited = FALSE
	if(!probe.turf_settled(source) || neighbor.excited)
		CRASH("Matching air failed to settle or woke a neighbor.")
	right.set_temperature(1000)
	if(probe.turf_settled(source) || !neighbor.excited)
		CRASH("Differing mutable air did not remain active and wake its neighbor.")
	probe.active_turfs.Cut()
	neighbor.excited = FALSE
	right.mark_immutable()
	if(probe.turf_settled(source) || neighbor.excited)
		CRASH("A fixed boundary was activated or allowed different mutable air to settle.")
	source.air = right
	neighbor.air = left
	if(!probe.turf_settled(source) || !neighbor.excited)
		CRASH("Immutable source failed to settle and wake its mutable neighbor.")
	source.air = old_source_air
	neighbor.air = old_neighbor_air
	source.atmos_adjacent_turfs = old_adjacency
	neighbor.excited = old_excited
	neighbor.significant_share_ticker = old_ticker
	probe.active_turfs.Cut()
	qdel(probe)
	qdel(left)
	qdel(right)

/** Checks list order, prefetch cursor repair, duplicate activation, and wake-after-stop. */
/proc/verify_settlement_scheduling()
	var/turf/open/floor/site
	for(var/turf/open/floor/candidate in world)
		if(locate(/obj/machinery) in candidate)
			continue
		site = candidate
		break
	if(!site)
		CRASH("Missing floor for settlement scheduling probes.")
	var/datum/controller/subsystem/air/settlement_probe/probe = new
	var/obj/machinery/atmospherics/components/unary/vent_pump/first = new(site)
	var/obj/machinery/atmospherics/components/unary/vent_pump/second = new(site)
	SSair.stop_processing_machine(first)
	SSair.stop_processing_machine(second)
	var/was_excited = site.excited
	var/previous_ticker = site.significant_share_ticker
	site.excited = TRUE
	probe.add_to_active(site)
	var/first_calls = probe.start_calls
	probe.add_to_active(site)
	if(probe.start_calls != first_calls || !first.atmos_processing || !second.atmos_processing)
		CRASH("Duplicate activation repeated machine admission.")
	probe.stop_processing_machine(first)
	probe.add_to_active(site)
	if(!first.atmos_processing || probe.start_calls != first_calls + 1)
		CRASH("An already-active turf did not wake its newly dormant machine.")
	probe.currentpart = SSAIR_ATMOSMACHINERY
	probe.currentrun = list(first, second)
	probe.dogmos_machine_prefetch_start = 1
	probe.dogmos_machine_prefetch_end = 2
	probe.dogmos_machine_prefetch_cursor = 2
	probe.stop_processing_machine(first)
	if(length(probe.currentrun) != 1 || probe.currentrun[1] != second || probe.dogmos_machine_prefetch_end != 1 || probe.dogmos_machine_prefetch_cursor != 1)
		CRASH("Queued removal changed order or lost the prefetch continuation.")
	probe.currentrun.len--
	probe.stop_processing_machine(second, currentrun_entry_removed = TRUE)
	if(length(probe.currentrun) || first.atmos_processing || second.atmos_processing || length(probe.atmos_machinery))
		CRASH("Popped-entry removal left stale machinery membership.")
	probe.stop_processing_machine(second)
	probe.currentpart = SSAIR_PIPENETS
	site.excited = was_excited
	site.significant_share_ticker = previous_ticker
	qdel(first)
	qdel(second)
	qdel(probe)
