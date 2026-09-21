/** Adopts the existing native arena; controller recovery must not initialize it twice. */
/datum/controller/subsystem/dogmos/Recover()
	ss_flags |= SS_NO_INIT
	initialized = SSdogmos.initialized
	gases_registered = SSdogmos.gases_registered
	SSdogmos.gases_registered = FALSE
	populate_gas_data_overlays()

/** Native state is shared in-process; the DM list only schedules exposures and visuals. */
/datum/controller/subsystem/air/proc/dogmos_add_frontier_member(turf/active_turf)
	active_turfs += active_turf

/datum/controller/subsystem/air/proc/dogmos_remove_frontier_member(turf/active_turf)
	var/previous_count = length(active_turfs)
	active_turfs -= active_turf
	return length(active_turfs) != previous_count

/datum/controller/subsystem/air/proc/dogmos_clear_active_frontier()
	active_turfs.Cut()

/datum/controller/subsystem/air/proc/dogmos_replace_active_frontier(list/replacement)
	active_turfs = replacement

/** Main-thread reaction callback, including public mixture signals and retirement protection. */
/turf/open/proc/dogmos_react()
	if(QDELETED(src) || !air)
		return
	. = air.react(src)
	if(. && !QDELETED(src))
		SSair.dogmos_reacted_turfs[src] = TRUE

/** Preserves the shuttle's destination-before-source atmosphere update ordering. */
/datum/controller/subsystem/dogmos/proc/block_shuttle_turfs(turf/source_turf, turf/destination_turf)
	SHOULD_NOT_SLEEP(TRUE)
	destination_turf.blocks_air = TRUE
	destination_turf.air_update_turf(TRUE, FALSE)
	source_turf.blocks_air = TRUE
	source_turf.air_update_turf(TRUE, TRUE)

/** Template initialization has completed before publishing its final border adjacency. */
/datum/controller/subsystem/dogmos/proc/update_template_border(list/turfs)
	SHOULD_NOT_SLEEP(TRUE)
	for(var/turf/affected_turf as anything in turfs)
		affected_turf.air_update_turf(TRUE, TRUE)
		affected_turf.levelupdate()

/** Samples the DreamDaemon host; there is no dogmosd process in this backend. */
/proc/dogmos_process_metrics_snapshot()
	return json_decode(dogmos_in_process_metrics())

/** Reconciles unique native mixtures in one call, preserving gas, energy and member volumes. */
/proc/dogmos_reconcile_pipeline_mixtures(list/datum/gas_mixture/gas_mixture_list)
	equalize_all_gases_in_list(gas_mixture_list)
