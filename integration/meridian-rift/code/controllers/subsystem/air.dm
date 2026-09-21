/// Maximum turfs prefetched by one maintenance or visual chunk.
#define ACTIVE_TURFS_WALK_BATCH_SIZE 100 // NOVA EDIT CHANGE - DOGMOS - ORIGINAL: #define ACTIVE_TURFS_WALK_BATCH_SIZE 400

/// Fire cycles between shared Dogmos Kennel UI updates while slow mode is enabled.
#define KENNEL_SLOW_MODE_PUSH_INTERVAL 4

// APHELION EDIT ADDITION START - DOGMOS
/// Initial maximum service work items requested by one resumable atmosphere chunk.
#define DOGMOS_STAGE_INITIAL_WORK_LIMIT 256
/// Maximum processing entries covered by one machinery prefetch range.
#define DOGMOS_MACHINE_PREFETCH_ENTRIES 32
/// Bound input visits and retained mixture references below the 381-record wire limit.
#define DOGMOS_MACHINE_PREFETCH_MIXTURES 256
/// Service stage id for pressure equalization.
#define DOGMOS_SIMULATION_TURF_EQUALIZE 2
/// Service stage id for active-turf diffusion.
#define DOGMOS_SIMULATION_TURFS 4
/// Service stage id for active-turf reactions.
#define DOGMOS_SIMULATION_REACTIONS 5
/// Largest exactly representable bounded health-preflight counter.
#define DOGMOS_HEALTH_COUNTER_MAX 16777216
// APHELION EDIT ADDITION END

SUBSYSTEM_DEF(air)
	name = "Atmospherics"
	dependencies = list(
		/datum/controller/subsystem/dogmos,
		/datum/controller/subsystem/mapping,
		/datum/controller/subsystem/atoms,
	)
	priority = FIRE_PRIORITY_AIR
	wait = 0.5 SECONDS
	ss_flags = SS_BACKGROUND
	runlevels = RUNLEVEL_GAME | RUNLEVEL_POSTGAME

	var/cached_cost = 0

	var/cost_atoms = 0
	var/cost_turfs = 0
	var/cost_hotspots = 0
	var/cost_groups = 0
	var/cost_highpressure = 0
	var/cost_superconductivity = 0
	var/cost_pipenets = 0
	var/cost_atmos_machinery = 0
	var/cost_rebuilds = 0
	var/cost_adjacent = 0
	/// Cost of Dogmos' post_process() pass.
	var/cost_post_process = 0
	/// Cost of Dogmos' Katmos equalization pass.
	var/cost_equalize = 0
	// APHELION EDIT ADDITION START - DOGMOS
	/// Pipenets that performed reconciliation during the most recently started pipenet pass.
	var/dogmos_pipenets_reconciled = 0
	/// Candidate mixture references visited by those pipenet reconciliations.
	var/dogmos_pipenet_mixtures_reconciled = 0
	// APHELION EDIT ADDITION END

	/// Maximum FDM iterations per Dogmos processing call.
	var/share_max_steps = 4
	/// Whether the Katmos pressure equalizer runs after FDM.
	var/equalize_enabled = TRUE
	/// Whether space-adjacent heat loss uses blackbody radiation instead of the gameplay sink.
	var/realistic_space_radiation = TRUE
	// APHELION EDIT ADDITION START - DOGMOS
	/// Whether flamethrowers use directional ignition spread.
	var/flamethrower_directional_spread = TRUE
	// APHELION EDIT ADDITION END
	/// Whether the Kennel UI uses its reduced payload and update cadence.
	var/kennel_slow_mode = TRUE
	/// Round-robin cursor for Kennel UI updates.
	var/kennel_push_cursor = 0
	/// Recent notable fire groups, newest first.
	var/list/recent_fire_groups = list()
	/// Recent high-cost reaction samples.
	var/list/recent_high_cost_zones = list()
	/// Whether reaction calls are timed for high-cost Kennel entries.
	var/kennel_profile_reactions = FALSE
	/// Minimum reaction duration, in milliseconds, for a high-cost entry.
	var/kennel_high_cost_ms_threshold = 0.5
	/// Recent explosions.
	var/list/recent_explosions = list()
	/// Recent reactions above the configured magnitude.
	var/list/recent_reactions_of_interest = list()
	/// Recent turfs showing breach overlays.
	var/list/kennel_overlay_breach_turfs = list()
	/// Recent turfs showing high-cost overlays.
	var/list/kennel_overlay_high_cost_turfs = list()
	/// Recent turfs showing reaction overlays.
	var/list/kennel_overlay_reaction_turfs = list()
	/// Recent hull breaches.
	var/list/recent_breaches = list()
	// APHELION EDIT ADDITION START - DOGMOS
	/// Last player-facing decompression feedback time, keyed by area REF or z-level fallback.
	var/list/kennel_breach_feedback_times = list()
	// APHELION EDIT ADDITION END
	/// Atmos machinery pinned for inspection; automatic pins expire, manual pins do not.
	var/list/structures_of_interest = list()
	/// REF(turf) -> weakref for recent Kennel event jump targets.
	var/list/kennel_jump_targets = list()
	/// Number of retained event rows using each jump target ref.
	var/list/kennel_jump_target_counts = list()
	/// REF(machine) -> weakref to the turf used for its structure overlay.
	var/list/kennel_pinned_turfs = list()
	/// Per-machine process cost EWMA, keyed by REF(machine).
	var/list/kennel_machine_cost_ewma = list()
	/// Minimum peak fire-group size to record.
	var/kennel_fire_group_notable_size = 5
	/// Minimum reaction magnitude to record.
	var/kennel_reaction_magnitude_threshold = 20
	/// Minimum process_atmos() cost, in milliseconds, for auto-pinning.
	var/kennel_machine_cost_ms_threshold = 2
	/// Lifetime of automatic structure pins.
	var/kennel_auto_pin_duration = 10 MINUTES
	/// Fraction shared with planetary atmosphere per FDM cycle.
	var/planet_share_ratio = 0.125
	/// Turfs last flagged as low pressure by Dogmos.
	var/low_pressure_turfs = 0
	/// Turfs last flagged as high pressure by Dogmos.
	var/high_pressure_turfs = 0
	/// Pressure delta at which Dogmos considers a group converged.
	var/excited_group_pressure_goal = 0.5
	/// Turfs processed by the last excited-group pass.
	var/num_group_turfs_processed = 0
	/// Maximum turfs touched by one Katmos equalization pass.
	var/equalize_hard_turf_limit = 2000
	/// Turfs processed by the last Katmos equalization pass.
	var/num_equalize_processed = 0

	var/list/excited_groups = list()
	var/list/active_turfs = list()
	/// Number of initial snapshot entries visited by this cycle's resumable maintenance walk.
	var/active_turfs_walk_cursor = 0
	// APHELION EDIT ADDITION START - DOGMOS
#ifndef DOGMOS_IN_PROCESS
	/// Four exact little-endian words identifying the latest published active frontier.
	var/list/dogmos_frontier_epoch = list(0, 0, 0, 0)
	/// Four exact little-endian words identifying the latest started service stage.
	var/list/dogmos_stage_epoch = list(0, 0, 0, 0)
	/// Service stage retained across SSair fires, or null between chunks.
	var/dogmos_pending_stage
	/// Boot-selected preparation jobs; kept off until controlled qualification.
	var/dogmos_async_stages = FALSE
	/// Fixed-size identity and publication receipt for the one admitted service job.
	var/datum/dogmos_stage_job/dogmos_job
	/// Last submit/poll game tick, retained across MC recovery and stage boundaries.
	var/dogmos_job_last_poll_tick = -1
	/// Exact frontier epoch retained while any service stage remains in this cycle.
	var/list/dogmos_pending_frontier_epoch
	/// Turf -> exact acknowledged (slot, generation); null before the first publication.
	var/list/dogmos_committed_frontier
	/// Ordered turf -> (acknowledged old pair, desired membership, reinsert) journal, capped at 512.
	var/list/dogmos_frontier_journal = list()
	/// Reset/overflow/recovery requires bounded publication of the canonical active list.
	var/dogmos_frontier_needs_rescan = TRUE
	/// List identity whose membership changes are owned by the journal helpers.
	var/list/dogmos_frontier_source
	/// Exact membership revision, advanced even when an overflowed journal stops retaining entries.
	var/list/dogmos_frontier_revision = list(0, 0, 0, 0)
	/// Latest attempted upload epoch, including abandoned uploads that cannot reuse an epoch.
	var/list/dogmos_frontier_upload_epoch = list(0, 0, 0, 0)
	/// Unpublished reconciliation snapshot and its captured revision.
	var/list/dogmos_frontier_candidate
	/// Membership revision captured before the current upload began.
	var/list/dogmos_frontier_scan_revision
	/// Number of source entries visited while collecting the unique candidate.
	var/dogmos_frontier_scan_cursor = 0
	/// Source length captured before candidate collection began; may include duplicates.
	var/dogmos_frontier_scan_total = 0
	/// Unique entries accepted by Append, or null while collecting/before an accepted Begin.
	var/dogmos_frontier_upload_cursor
	/// Retired snapshot released from the tail in bounded batches before further reconciliation.
	var/list/dogmos_frontier_retired
	/// A successful sync call still needs another MC slice before a simulation stage may start.
	var/dogmos_frontier_sync_pending = FALSE
	/// Service estimate of work items remaining in the pending stage.
	var/dogmos_stage_remaining_estimate = 0
	/// Maximum service work items requested by the next stage chunk.
	var/dogmos_stage_work_limit = DOGMOS_STAGE_INITIAL_WORK_LIMIT
#endif
	/// Whether native simulation completed before a callback-drain resume.
	var/dogmos_active_turf_stages_complete = FALSE
	/// Whether equalization finished before a pressure-queue continuation.
	var/dogmos_equalize_stage_complete = FALSE
	/// Number of FDM passes completed in the current active-turf service cycle.
	var/dogmos_fdm_steps_completed = 0
	/// Whether this cycle's complete maintenance walk has published its frontier.
	var/dogmos_active_walk_complete = FALSE
	/// Number of initial snapshot entries whose post-simulation visuals have been refreshed.
	var/dogmos_visual_refresh_cursor = 0
	/// End of the already-prefetched maintenance chunk, retained across budget pauses.
	var/dogmos_walk_prefetch_end = 0
	/// End of the already-prefetched settlement chunk, retained across budget pauses.
	var/dogmos_visual_prefetch_end = 0
	/// Upper index captured for the selected range, adjusted for removals; zero when absent.
	var/dogmos_machine_prefetch_start = 0
	/// Lowest remaining index included in that range.
	var/dogmos_machine_prefetch_end = 0
	/// Next entry to collect, descending through the retained machinery range.
	var/dogmos_machine_prefetch_cursor = 0
	/// Next component mixture position, retained when one component spans collection slices.
	var/dogmos_machine_prefetch_air_cursor = 1
	/// Whether collection and bounded snapshot requests completed for the current range.
	var/dogmos_machine_prefetch_ready = FALSE
	/// At most DOGMOS_MACHINE_PREFETCH_MIXTURES references, retained only until their request completes.
	var/list/datum/gas_mixture/dogmos_machine_prefetch_mixtures = list()
	/// One-use continuation override after the Master replaces this subsystem and rebuilds its queue.
	var/dogmos_resume_recovered_cycle = FALSE
	/// Turfs that reacted during this active phase and must remain active for another evaluation.
	var/list/dogmos_reacted_turfs = list()
	/// Fixed initial active set, retained through maintenance, native stages and visual refresh.
	var/list/dogmos_visual_refresh_batch = list()
	// APHELION EDIT ADDITION END
	var/list/hotspots = list()
	var/list/networks = list()
	var/list/rebuild_queue = list()
	//Subservient to rebuild queue
	var/list/expansion_queue = list()
	/// List of turfs to recalculate adjacent turfs on before processing
	var/list/adjacent_rebuild = list()
	/// A list of machines that will be processed when currentpart == SSAIR_ATMOSMACHINERY. Use SSair.begin_processing_machine and SSair.stop_processing_machine to add and remove machines.
	var/list/obj/machinery/atmos_machinery = list()

	var/list/pipe_init_dirs_cache = list()
	//atmos singletons
	var/list/gas_reactions = list()
	/// Flat, uniquely-prioritised view of gas_reactions. Read by Dogmos; see init_dogmos_reactions().
	var/list/dogmos_reactions = list()
	var/list/atmos_gen
	var/list/planetary = list() //Lets cache static planetary mixes
	/// List of gas string -> canonical gas mixture
	var/list/strings_to_mix = list()


	//Special functions lists
	var/list/turf/open/high_pressure_delta = list()
	var/list/atom_process = list()
	/// Reactions which will contribute to a hotspot's size.
	var/list/hotspot_reactions

	/// A cache of objects that perisists between processing runs when resumed == TRUE. Dangerous, qdel'd objects not cleared from this may cause runtimes on processing.
	var/list/currentrun = list()
	var/currentpart = SSAIR_PIPENETS

	var/map_loading = TRUE
	var/list/queued_for_activation
	var/display_all_groups = FALSE

	var/list/reaction_handbook
	var/list/gas_handbook


/datum/controller/subsystem/air/stat_entry(msg)
	msg += "\n  Cost:{"
	msg += "AT:[round(cost_turfs,1)]|"
	msg += "HS:[round(cost_hotspots,1)]|"
	msg += "EG:[round(cost_groups,1)]|"
	msg += "HP:[round(cost_highpressure,1)]|"
	msg += "SC:[round(cost_superconductivity,1)]|"
	msg += "PN:[round(cost_pipenets,1)]|"
	msg += "AM:[round(cost_atmos_machinery,1)]|"
	msg += "AO:[round(cost_atoms, 1)]|"
	msg += "RB:[round(cost_rebuilds,1)]|"
	msg += "AJ:[round(cost_adjacent,1)]|"
	msg += "} "
	msg += "\n  Count:{AT:[active_turfs.len]|"
	msg += "HS:[hotspots.len]|"
	msg += "EG:[excited_groups.len]|"
	msg += "HP:[high_pressure_delta.len]|"
	msg += "SC:[dogmos_heat_graph_count()]|"
	msg += "PN:[networks.len]|"
	msg += "AM:[atmos_machinery.len]|"
	msg += "AO:[atom_process.len]|"
	msg += "RB:[rebuild_queue.len]|"
	msg += "EP:[expansion_queue.len]|"
	msg += "AJ:[adjacent_rebuild.len]|"
	msg += "AT/MS:[round((cost ? active_turfs.len/cost : 0),0.1)]"
	msg += "}"
	return ..()


/datum/controller/subsystem/air/Initialize()
	map_loading = FALSE
	// APHELION EDIT ADDITION START - DOGMOS
#ifndef DOGMOS_IN_PROCESS
	dogmos_async_stages = CONFIG_GET(flag/dogmos_async_stages)
#endif
	// APHELION EDIT ADDITION END
	// gas_reactions, dogmos_reactions and the Dogmos gas registry are built by SSdogmos at
	// INITSTAGE_EARLY - they have to exist before the first turf builds its air. See dogmos.dm.
	hotspot_reactions = init_hotspot_reactions()

	setup_allturfs()
	setup_atmos_machinery()
	setup_pipenets()
	setup_turf_visuals()
	setup_kennel_overlays()
	process_adjacent_rebuild()
	atmos_handbooks_init()
	RegisterSignal(SSdcs, COMSIG_GLOB_EXPLOSION, PROC_REF(on_kennel_explosion))
	return SS_INIT_SUCCESS


// APHELION EDIT ADDITION START - DOGMOS
/** Returns whether this invocation begins a new SSair cycle health preflight. */
/datum/controller/subsystem/air/proc/dogmos_health_preflight_required(resumed)
	return !resumed
// APHELION EDIT ADDITION END

/datum/controller/subsystem/air/fire(resumed = FALSE)
	// APHELION EDIT ADDITION START - DOGMOS
	if(dogmos_resume_recovered_cycle)
		resumed = TRUE
		dogmos_resume_recovered_cycle = FALSE
#ifndef DOGMOS_IN_PROCESS
	if(dogmos_health_preflight_required(resumed))
		SSdogmos.dogmos_health_preflight_count = min(SSdogmos.dogmos_health_preflight_count + 1, DOGMOS_HEALTH_COUNTER_MAX)
		if(!SSdogmos.service_ready || !dogmos_service_health())
			dogmos_fail_closed_stage("health preflight")
			return
#endif
	// APHELION EDIT ADDITION END
	var/timer = TICK_USAGE_REAL

	//Rebuilds can happen at any time, so this needs to be done outside of the normal system
	cost_rebuilds = 0
	cost_adjacent = 0

	// We need to have a solid setup for turfs before fire, otherwise we'll get massive runtimes and strange behavior
	if(length(adjacent_rebuild))
		timer = TICK_USAGE_REAL
		process_adjacent_rebuild()
		//This does mean that the apperent rebuild costs fluctuate very quickly, this is just the cost of having them always process, no matter what
		cost_adjacent = TICK_USAGE_REAL - timer
		if(state != SS_RUNNING)
			return

	// Every time we fire, we want to make sure pipenets are rebuilt. The game state could have changed between each fire() proc call
	// and anything missing a pipenet can lead to unintended behaviour at worse and various runtimes at best.
	if(length(rebuild_queue) || length(expansion_queue))
		timer = TICK_USAGE_REAL
		process_rebuilds()
		//This does mean that the apperent rebuild costs fluctuate very quickly, this is just the cost of having them always process, no matter what
		cost_rebuilds = TICK_USAGE_REAL - timer
		if(state != SS_RUNNING)
			return

	if(currentpart == SSAIR_PIPENETS || !resumed)
		timer = TICK_USAGE_REAL
		if(!resumed)
			cached_cost = 0
		process_pipenets(resumed)
		cached_cost += TICK_USAGE_REAL - timer
		if(state != SS_RUNNING)
			return
		cost_pipenets = MC_AVERAGE(cost_pipenets, TICK_DELTA_TO_MS(cached_cost))
		resumed = FALSE
		currentpart = SSAIR_ATMOSMACHINERY

	if(currentpart == SSAIR_ATMOSMACHINERY)
		timer = TICK_USAGE_REAL
		if(!resumed)
			cached_cost = 0
		process_atmos_machinery(resumed)
		cached_cost += TICK_USAGE_REAL - timer
		if(state != SS_RUNNING)
			return
		cost_atmos_machinery = MC_AVERAGE(cost_atmos_machinery, TICK_DELTA_TO_MS(cached_cost))
		resumed = FALSE
		currentpart = SSAIR_ACTIVETURFS

	if(currentpart == SSAIR_ACTIVETURFS)
		timer = TICK_USAGE_REAL
		if(!resumed)
			cached_cost = 0
		process_active_turfs(resumed)
		cached_cost += TICK_USAGE_REAL - timer
		if(state != SS_RUNNING)
			return
		cost_turfs = MC_AVERAGE(cost_turfs, TICK_DELTA_TO_MS(cached_cost))
		resumed = FALSE
		currentpart = SSAIR_HOTSPOTS

	if(currentpart == SSAIR_HOTSPOTS) //We do this before excited groups to allow breakdowns to be independent of adding turfs while still *mostly preventing mass fires
		timer = TICK_USAGE_REAL
		if(!resumed)
			cached_cost = 0
		process_hotspots(resumed)
		cached_cost += TICK_USAGE_REAL - timer
		if(state != SS_RUNNING)
			return
		cost_hotspots = MC_AVERAGE(cost_hotspots, TICK_DELTA_TO_MS(cached_cost))
		resumed = FALSE
		currentpart = SSAIR_EXCITEDGROUPS

	if(currentpart == SSAIR_EXCITEDGROUPS)
		timer = TICK_USAGE_REAL
		if(!resumed)
			cached_cost = 0
		process_excited_groups(resumed)
		cached_cost += TICK_USAGE_REAL - timer
		if(state != SS_RUNNING)
			return
		cost_groups = MC_AVERAGE(cost_groups, TICK_DELTA_TO_MS(cached_cost))
		resumed = FALSE
		currentpart = SSAIR_HIGHPRESSURE

	if(currentpart == SSAIR_HIGHPRESSURE)
		timer = TICK_USAGE_REAL
		if(!resumed)
			cached_cost = 0
		process_high_pressure_delta(resumed)
		cached_cost += TICK_USAGE_REAL - timer
		if(state != SS_RUNNING)
			return
		cost_highpressure = MC_AVERAGE(cost_highpressure, TICK_DELTA_TO_MS(cached_cost))
		resumed = FALSE
		currentpart = SSAIR_SUPERCONDUCTIVITY

	if(currentpart == SSAIR_SUPERCONDUCTIVITY)
		// Was never actually measured: the removed comment here claimed a Rust background thread
		// wrote cost_superconductivity asynchronously (superconduct.rs), but that describes the
		// legacy in-process DLL path (docs/agent/architecture-and-ownership.md puts turf heat
		// there) - nothing in the current out-of-process service pipeline produces that write, so
		// Kennel showed a permanent 0 regardless of whether this stage was running. Measured the
		// same way as every other stage now.
		timer = TICK_USAGE_REAL
		if(!resumed)
			cached_cost = 0
		process_super_conductivity(resumed)
		cached_cost += TICK_USAGE_REAL - timer
		if(state != SS_RUNNING)
			return
#ifndef DOGMOS_IN_PROCESS
		cost_superconductivity = MC_AVERAGE(cost_superconductivity, TICK_DELTA_TO_MS(cached_cost))
#endif
		resumed = FALSE
		currentpart = SSAIR_PROCESS_ATOMS

	if(currentpart == SSAIR_PROCESS_ATOMS)
		timer = TICK_USAGE_REAL
		if(!resumed)
			cached_cost = 0
		process_atoms(resumed)
		cached_cost += TICK_USAGE_REAL - timer
		if(state != SS_RUNNING)
			return
		cost_atoms = MC_AVERAGE(cost_atoms, TICK_DELTA_TO_MS(cached_cost))
		resumed = FALSE


	currentpart = SSAIR_PIPENETS
	SStgui.update_uis(SSair) //Lightning fast debugging motherfucker

	// Cadence half of Kennel slow mode (payload half is in /datum/dogmos_kennel/ui_data()): pushed every
	// cycle when off, every KENNEL_SLOW_MODE_PUSH_INTERVAL-th cycle when on (~2s at wait = 0.5s) via a
	// small round-robin cursor, so multiple simultaneous viewers don't multiply real per-cycle push cost.
	if(!kennel_slow_mode)
		SStgui.update_uis(GLOB.dogmos_kennel)
	else
		kennel_push_cursor = (kennel_push_cursor + 1) % KENNEL_SLOW_MODE_PUSH_INTERVAL
		if(!kennel_push_cursor)
			SStgui.update_uis(GLOB.dogmos_kennel)

/datum/controller/subsystem/air/Recover()
	initialized = SSair.initialized
	excited_groups = SSair.excited_groups
	active_turfs = SSair.active_turfs
	hotspots = SSair.hotspots
	networks = SSair.networks
	rebuild_queue = SSair.rebuild_queue
	expansion_queue = SSair.expansion_queue
	adjacent_rebuild = SSair.adjacent_rebuild
	atmos_machinery = SSair.atmos_machinery
	pipe_init_dirs_cache = SSair.pipe_init_dirs_cache
	gas_reactions = SSair.gas_reactions
	atmos_gen = SSair.atmos_gen
	planetary = SSair.planetary
	high_pressure_delta = SSair.high_pressure_delta
	atom_process = SSair.atom_process
	currentrun = SSair.currentrun
	queued_for_activation = SSair.queued_for_activation

	// APHELION EDIT ADDITION START - DOGMOS
	// The Master owns state and queue links and resets them after replacement.
	// Preserve the phase and cycle separately so its first fire(FALSE) can resume.
	currentpart = SSair.currentpart
	times_fired = SSair.times_fired
#ifdef DOGMOS_IN_PROCESS
	dogmos_resume_recovered_cycle = initialized && (SSair.dogmos_resume_recovered_cycle || SSair.state == SS_RUNNING || SSair.state == SS_PAUSED || length(SSair.dogmos_visual_refresh_batch))
#else
	dogmos_resume_recovered_cycle = initialized && (SSair.dogmos_resume_recovered_cycle \
		|| SSair.state == SS_RUNNING || SSair.state == SS_PAUSED \
		|| ((SSair.state == SS_IDLE || SSair.state == SS_QUEUED) \
			&& (!isnull(SSair.dogmos_pending_stage) || SSair.dogmos_pending_frontier_epoch || length(SSair.dogmos_visual_refresh_batch))))
#endif
	share_max_steps = SSair.share_max_steps
	equalize_enabled = SSair.equalize_enabled
	realistic_space_radiation = SSair.realistic_space_radiation
	flamethrower_directional_spread = SSair.flamethrower_directional_spread
	planet_share_ratio = SSair.planet_share_ratio
	excited_group_pressure_goal = SSair.excited_group_pressure_goal
	equalize_hard_turf_limit = SSair.equalize_hard_turf_limit
	dogmos_blocked_turf_temperature_authority = SSair.dogmos_blocked_turf_temperature_authority
	dogmos_equalize_performance_profile = SSair.dogmos_equalize_performance_profile
#ifndef DOGMOS_IN_PROCESS
	dogmos_frontier_epoch = SSair.dogmos_frontier_epoch.Copy()
	dogmos_stage_epoch = SSair.dogmos_stage_epoch.Copy()
	dogmos_pending_stage = SSair.dogmos_pending_stage
	dogmos_async_stages = SSair.dogmos_async_stages
	// The job holds only fixed-width words. Transfer its receipt and ready token
	// together; SSdogmos retains the callback cursor and authoritative service.
	dogmos_job = SSair.dogmos_job
	dogmos_job_last_poll_tick = SSair.dogmos_job_last_poll_tick
	dogmos_pending_frontier_epoch = SSair.dogmos_pending_frontier_epoch?.Copy()
	// Transfer frontier ownership without copying a world-sized map in Recover().
	dogmos_committed_frontier = SSair.dogmos_committed_frontier
	dogmos_frontier_candidate = SSair.dogmos_frontier_candidate
	dogmos_frontier_retired = SSair.dogmos_frontier_retired
	dogmos_frontier_upload_epoch = SSair.dogmos_frontier_upload_epoch.Copy()
	dogmos_frontier_revision = SSair.dogmos_frontier_revision.Copy()
	dogmos_note_frontier_reset()
	dogmos_stage_remaining_estimate = SSair.dogmos_stage_remaining_estimate
	dogmos_stage_work_limit = SSair.dogmos_stage_work_limit
#endif
	dogmos_active_turf_stages_complete = SSair.dogmos_active_turf_stages_complete
	dogmos_equalize_stage_complete = SSair.dogmos_equalize_stage_complete
	dogmos_fdm_steps_completed = SSair.dogmos_fdm_steps_completed
	dogmos_visual_refresh_batch = SSair.dogmos_visual_refresh_batch?.Copy() || list()
	dogmos_active_walk_complete = SSair.dogmos_active_walk_complete
	dogmos_visual_refresh_cursor = SSair.dogmos_visual_refresh_cursor
	dogmos_walk_prefetch_end = SSair.dogmos_walk_prefetch_end
	dogmos_visual_prefetch_end = SSair.dogmos_visual_prefetch_end
	dogmos_machine_prefetch_start = SSair.dogmos_machine_prefetch_start
	dogmos_machine_prefetch_end = SSair.dogmos_machine_prefetch_end
	dogmos_machine_prefetch_cursor = SSair.dogmos_machine_prefetch_cursor
	dogmos_machine_prefetch_air_cursor = SSair.dogmos_machine_prefetch_air_cursor
	dogmos_machine_prefetch_ready = SSair.dogmos_machine_prefetch_ready
	dogmos_machine_prefetch_mixtures = SSair.dogmos_machine_prefetch_mixtures.Copy()
	dogmos_reacted_turfs = SSair.dogmos_reacted_turfs.Copy()

	kennel_slow_mode = SSair.kennel_slow_mode
	kennel_profile_reactions = SSair.kennel_profile_reactions
	kennel_high_cost_ms_threshold = SSair.kennel_high_cost_ms_threshold
	kennel_fire_group_notable_size = SSair.kennel_fire_group_notable_size
	kennel_reaction_magnitude_threshold = SSair.kennel_reaction_magnitude_threshold
	kennel_machine_cost_ms_threshold = SSair.kennel_machine_cost_ms_threshold
	kennel_auto_pin_duration = SSair.kennel_auto_pin_duration
	kennel_push_cursor = 0
	active_turfs_walk_cursor = SSair.active_turfs_walk_cursor

	recent_fire_groups = SSair.recent_fire_groups
	recent_high_cost_zones = SSair.recent_high_cost_zones
	recent_explosions = SSair.recent_explosions
	recent_reactions_of_interest = SSair.recent_reactions_of_interest
	recent_breaches = SSair.recent_breaches
	structures_of_interest = SSair.structures_of_interest

	cached_cost = SSair.cached_cost
	cost_atoms = SSair.cost_atoms
	cost_turfs = SSair.cost_turfs
	cost_hotspots = SSair.cost_hotspots
	cost_groups = SSair.cost_groups
	cost_highpressure = SSair.cost_highpressure
	cost_superconductivity = SSair.cost_superconductivity
	cost_pipenets = SSair.cost_pipenets
	cost_atmos_machinery = SSair.cost_atmos_machinery
	cost_rebuilds = SSair.cost_rebuilds
	cost_adjacent = SSair.cost_adjacent
	cost_post_process = SSair.cost_post_process
	cost_equalize = SSair.cost_equalize
	low_pressure_turfs = SSair.low_pressure_turfs
	high_pressure_turfs = SSair.high_pressure_turfs
	num_group_turfs_processed = SSair.num_group_turfs_processed
	num_equalize_processed = SSair.num_equalize_processed
	dogmos_heat_graph_nodes = SSair.dogmos_heat_graph_nodes
	dogmos_heat_edge_attempts = SSair.dogmos_heat_edge_attempts
	dogmos_heat_edges_applied = SSair.dogmos_heat_edges_applied
	dogmos_heat_lock_contention = SSair.dogmos_heat_lock_contention
	dogmos_heat_registration_changes = SSair.dogmos_heat_registration_changes

	dogmos_reactions = init_dogmos_reactions(gas_reactions)
	recover_kennel_derived_state(SSair)
	RegisterSignal(SSdcs, COMSIG_GLOB_EXPLOSION, PROC_REF(on_kennel_explosion))
	// SSdogmos owns the service session and all atmosphere state; recovery must not copy or restart it.
	// APHELION EDIT ADDITION END

/datum/controller/subsystem/air/proc/process_adjacent_rebuild(init = FALSE)
	var/list/queue = adjacent_rebuild
	// APHELION EDIT ADDITION START - DOGMOS
#ifndef DOGMOS_IN_PROCESS
	SSdogmos.runtime_topology_batching = TRUE
#endif
	// APHELION EDIT ADDITION END

	while (length(queue))
		var/turf/currT = queue[1]
		var/goal = queue[currT]
		queue.Cut(1,2)

		currT.immediate_calculate_adjacent_turfs()
		if(goal == MAKE_ACTIVE)
			add_to_active(currT)
		else if(goal == KILL_EXCITED)
			add_to_active(currT, TRUE)

		if(init)
			CHECK_TICK
		else
			if(MC_TICK_CHECK)
				break
	// APHELION EDIT ADDITION START - DOGMOS
#ifndef DOGMOS_IN_PROCESS
	SSdogmos.runtime_topology_batching = FALSE
	SSdogmos.flush_turf_registration_batch()
#endif
	// APHELION EDIT ADDITION END

/datum/controller/subsystem/air/proc/process_pipenets(resumed = FALSE)
	if (!resumed)
		src.currentrun = networks.Copy()
		// APHELION EDIT ADDITION START - DOGMOS
		dogmos_pipenets_reconciled = 0
		dogmos_pipenet_mixtures_reconciled = 0
		// APHELION EDIT ADDITION END
	//cache for sanic speed (lists are references anyways)
	var/list/currentrun = src.currentrun
	while(currentrun.len)
		var/datum/thing = currentrun[currentrun.len]
		currentrun.len--
		if(thing)
			// APHELION EDIT ADDITION START - DOGMOS
			var/datum/pipeline/network = thing
			if(network.update && !network.building)
				dogmos_pipenets_reconciled++
				dogmos_pipenet_mixtures_reconciled += length(network.other_airs) + 1
			// APHELION EDIT ADDITION END
			thing.process()
		else
			networks.Remove(thing)
		if(MC_TICK_CHECK)
			return

/datum/controller/subsystem/air/proc/add_to_rebuild_queue(obj/machinery/atmospherics/atmos_machine)
	if(istype(atmos_machine, /obj/machinery/atmospherics) && !atmos_machine.rebuilding)
		rebuild_queue += atmos_machine
		atmos_machine.rebuilding = TRUE

/datum/controller/subsystem/air/proc/add_to_expansion(datum/pipeline/line, starting_point)
	var/list/new_packet = new(SSAIR_REBUILD_QUEUE)
	new_packet[SSAIR_REBUILD_PIPELINE] = line
	new_packet[SSAIR_REBUILD_QUEUE] = list(starting_point)
	expansion_queue += list(new_packet)

/datum/controller/subsystem/air/proc/remove_from_expansion(datum/pipeline/line)
	for(var/list/packet in expansion_queue)
		if(packet[SSAIR_REBUILD_PIPELINE] == line)
			expansion_queue -= packet
			return

/datum/controller/subsystem/air/proc/process_atoms(resumed = FALSE)
	if(!resumed)
		src.currentrun = atom_process.Copy()
	//cache for sanic speed (lists are references anyways)
	var/list/currentrun = src.currentrun
	while(currentrun.len)
		var/atom/talk_to = currentrun[currentrun.len]
		currentrun.len--
		if(!talk_to)
			return
		talk_to.process_exposure()
		if(MC_TICK_CHECK)
			return

/// Prefetches bounded reverse ranges before invoking the unchanged atmosphere-processing API. // APHELION EDIT ADDITION - DOGMOS
/datum/controller/subsystem/air/proc/process_atmos_machinery(resumed = FALSE)
	if (!resumed)
		src.currentrun = atmos_machinery.Copy()
		// APHELION EDIT ADDITION START - DOGMOS
		dogmos_clear_machinery_prefetch()
		// APHELION EDIT ADDITION END
	//cache for sanic speed (lists are references anyways)
	var/list/currentrun = src.currentrun
	while(currentrun.len)
		// APHELION EDIT ADDITION START - DOGMOS
		if(MC_TICK_CHECK)
			return
#ifndef DOGMOS_IN_PROCESS
		if(!dogmos_machine_prefetch_ready)
			dogmos_machine_prefetch_ready = dogmos_prefetch_machinery_snapshots(currentrun)
			if(!dogmos_machine_prefetch_ready)
				pause()
				return
#endif
		// The request itself can consume the remaining budget. Preserve the range on yield.
		if(MC_TICK_CHECK)
			return
		var/datum/processing_entry = currentrun[currentrun.len]
		// APHELION EDIT ADDITION END
		currentrun.len--
		// APHELION EDIT ADDITION START - DOGMOS
		if(currentrun.len < dogmos_machine_prefetch_end)
			dogmos_clear_machinery_prefetch()
		if(!istype(processing_entry, /obj/machinery) && !istype(processing_entry, /datum/component/gas_leaker))
			atmos_machinery -= processing_entry
			continue
		var/kennel_tick_start = TICK_USAGE
		var/process_result
		if(ismachinery(processing_entry))
			var/obj/machinery/machine = processing_entry
			process_result = machine.process_atmos(wait * 0.1)
		else
			var/datum/component/gas_leaker/gas_leaker = processing_entry
			process_result = gas_leaker.process_atmos(wait * 0.1)
		if(process_result == PROCESS_KILL)
			stop_processing_machine(processing_entry, currentrun_entry_removed = TRUE)
		if(ismachinery(processing_entry))
			var/obj/machinery/profiled_machine = processing_entry
			check_kennel_machine_cost(profiled_machine, TICK_USAGE_TO_MS(kennel_tick_start))
		// APHELION EDIT ADDITION END
		if(MC_TICK_CHECK)
			return


/** Requests native heat work; only the service backend reports a resumable synchronous stage. */ // APHELION EDIT CHANGE - DOGMOS
/datum/controller/subsystem/air/proc/process_super_conductivity(resumed = FALSE)
	// APHELION EDIT ADDITION START - DOGMOS
#ifdef DOGMOS_IN_PROCESS
	process_turf_heat()
#else
	if(process_turf_heat())
		pause()
#endif
	// APHELION EDIT ADDITION END

/datum/controller/subsystem/air/proc/process_hotspots(resumed = FALSE)
	if (!resumed)
		src.currentrun = hotspots.Copy()
	//cache for sanic speed (lists are references anyways)
	var/list/currentrun = src.currentrun
	while(currentrun.len)
		var/obj/effect/hotspot/H = currentrun[currentrun.len]
		currentrun.len--
		if (H)
			H.process()
		else
			hotspots -= H
		if(MC_TICK_CHECK)
			return

/** Runs Rust's pressure equalizer, then drains any queued DM pressure movements. */
/datum/controller/subsystem/air/proc/process_high_pressure_delta(resumed = FALSE)
	// APHELION EDIT ADDITION START - DOGMOS
	if(!resumed)
		dogmos_equalize_stage_complete = FALSE
	// A budget deferral can happen before a native cursor exists. Only successful
	// completion permits pressure-only resumes to skip the service stage.
	if(!dogmos_equalize_stage_complete)
		var/remaining_ms = TICK_DELTA_TO_MS(Master.current_ticklimit - TICK_USAGE)
		if(process_turf_equalize_auxtools(remaining_ms))
			pause() // ran out of budget mid-equalize - resume next fire()
			return
		dogmos_equalize_stage_complete = TRUE
	// APHELION EDIT ADDITION END

	while (high_pressure_delta.len)
		var/turf/open/T = high_pressure_delta[high_pressure_delta.len]
		high_pressure_delta.len--
		// APHELION EDIT ADDITION START - DOGMOS
		if(!T)
			continue
		// APHELION EDIT ADDITION END
		T.high_pressure_movements()
		T.pressure_difference = 0
		if(MC_TICK_CHECK)
			return

/** Runs native gas and reactions between resumable exposure and settlement passes.
 * New activations join the published frontier; their exposure waits until the next cycle.
 */
/datum/controller/subsystem/air/proc/process_active_turfs(resumed = FALSE)
	// APHELION EDIT ADDITION START - DOGMOS
#ifndef DOGMOS_IN_PROCESS
	if(!SSdogmos.service_ready)
		pause()
		return
#endif
	// APHELION EDIT ADDITION END
	if(!resumed)
		// APHELION EDIT ADDITION START - DOGMOS
		dogmos_active_turf_stages_complete = FALSE
		dogmos_fdm_steps_completed = 0
		dogmos_active_walk_complete = FALSE
		active_turfs_walk_cursor = 0
		dogmos_visual_refresh_cursor = 0
		dogmos_walk_prefetch_end = 0
		dogmos_visual_prefetch_end = 0
		dogmos_visual_refresh_batch = active_turfs.Copy()
		dogmos_reacted_turfs = list()
		// APHELION EDIT ADDITION END

	// APHELION EDIT ADDITION START - DOGMOS
	if(!dogmos_active_walk_complete)
		while(walk_active_turfs_batch())
			if(state != SS_RUNNING)
				return
		if(MC_TICK_CHECK)
			return
#ifndef DOGMOS_IN_PROCESS
		if(!sync_dogmos_frontier())
			dogmos_fail_closed_stage(DOGMOS_SIMULATION_TURFS)
			return
		if(dogmos_frontier_sync_pending)
			pause()
			return
#endif
		dogmos_active_walk_complete = TRUE
	// APHELION EDIT ADDITION END

	// APHELION EDIT ADDITION START - DOGMOS
	if(!dogmos_active_turf_stages_complete)
#ifdef DOGMOS_IN_PROCESS
		// Native diffusion queues reactions and callbacks in the same stage.
		process_turfs_auxtools(TICK_DELTA_TO_MS(Master.current_ticklimit - TICK_USAGE))
#else
		if(isnull(dogmos_pending_stage) || dogmos_pending_stage == DOGMOS_SIMULATION_TURFS)
			if(process_turfs_auxtools(TICK_DELTA_TO_MS(Master.current_ticklimit - TICK_USAGE)))
				pause()
				return
		if(isnull(dogmos_pending_stage) || dogmos_pending_stage == DOGMOS_SIMULATION_REACTIONS)
			if(process_reactions_auxtools(TICK_DELTA_TO_MS(Master.current_ticklimit - TICK_USAGE)))
				pause()
				return
#endif
		dogmos_active_turf_stages_complete = TRUE
	// APHELION EDIT ADDITION END

	if(finish_turf_processing_auxtools(TICK_DELTA_TO_MS(Master.current_ticklimit - TICK_USAGE)))
		pause() // still draining queued reactions/visuals/pressure-difference callbacks - resume next fire()
		return
	refresh_dogmos_visuals()

/** Processes a bounded round-robin batch without iterating the live list while removing entries. */
/* // APHELION EDIT REMOVAL START - DOGMOS - superseded by the fixed per-cycle snapshot below
/datum/controller/subsystem/air/proc/walk_active_turfs_batch()
	var/list/turfs = active_turfs
	var/turf_count = length(turfs)
	if(!turf_count)
		active_turfs_walk_cursor = 0
		return

	if(active_turfs_walk_cursor >= turf_count)
		active_turfs_walk_cursor = 0

	var/batch_end = min(active_turfs_walk_cursor + ACTIVE_TURFS_WALK_BATCH_SIZE, turf_count)
	var/list/batch = turfs.Copy(active_turfs_walk_cursor + 1, batch_end + 1)
	dogmos_visual_refresh_batch = batch

	// APHELION EDIT ADDITION START - DOGMOS
	dogmos_prefetch_walk_snapshots(batch)
	var/removed_count = 0
	// APHELION EDIT ADDITION END

	for(var/turf/open/T as anything in batch)
		if(!T || !T.air)
			continue
		if(T.archived_cycle < times_fired)
			LINDA_CYCLE_ARCHIVE(T)
		T.current_cycle = times_fired
		T.temperature_expose(T.air, T.air.return_temperature())
		if(turf_settled(T))
			// APHELION EDIT ADDITION START - DOGMOS
			var/count_before_removal = length(turfs)
			// APHELION EDIT ADDITION END
			remove_from_active(T)
			// APHELION EDIT ADDITION START - DOGMOS
			removed_count += count_before_removal - length(turfs)
			// APHELION EDIT ADDITION END

	// Removals may have shortened the list since batch_end was computed.
	// APHELION EDIT ADDITION START - DOGMOS
	// Count removals directly: waking neighbors can append entries during the same walk.
	var/next_cursor = max(0, batch_end - removed_count)
	// APHELION EDIT ADDITION END
	active_turfs_walk_cursor = (next_cursor >= length(active_turfs)) ? 0 : next_cursor // APHELION EDIT CHANGE - DOGMOS - ORIGINAL: active_turfs_walk_cursor = (batch_end >= length(active_turfs)) ? 0 : batch_end
*/ // APHELION EDIT REMOVAL END

// APHELION EDIT ADDITION START - DOGMOS
/** Visits at most one snapshot chunk, returning TRUE while maintenance remains.
 * The cursor advances before exposure callbacks, so resuming never repeats an emitted exposure.
 * Settling and reactivation mutate only the live queue, never this fixed snapshot.
 */
/datum/controller/subsystem/air/proc/walk_active_turfs_batch()
	var/list/snapshot = dogmos_visual_refresh_batch
#ifndef DOGMOS_IN_PROCESS
	if(!SSdogmos.service_ready)
		pause()
		return TRUE
#endif
	var/turf_count = length(snapshot)
	if(active_turfs_walk_cursor >= turf_count)
		return FALSE
	if(MC_TICK_CHECK)
		return TRUE
	if(active_turfs_walk_cursor >= dogmos_walk_prefetch_end)
		dogmos_walk_prefetch_end = min(active_turfs_walk_cursor + ACTIVE_TURFS_WALK_BATCH_SIZE, turf_count)
#ifndef DOGMOS_IN_PROCESS
		dogmos_prefetch_walk_snapshots(snapshot.Copy(active_turfs_walk_cursor + 1, dogmos_walk_prefetch_end + 1))
#endif
#ifndef DOGMOS_IN_PROCESS
		if(!SSdogmos.service_ready)
			pause()
			return TRUE
#endif
		// Retain the prefetched end even if this request consumed the entire budget.
		if(MC_TICK_CHECK)
			return TRUE
	var/batch_end = dogmos_walk_prefetch_end
	while(active_turfs_walk_cursor < batch_end)
		var/turf/open/active_turf = snapshot[++active_turfs_walk_cursor]
		if(QDELETED(active_turf) || !isopenturf(active_turf) || !active_turf.air)
			remove_from_active(active_turf)
		else if(active_turf.excited)
			if(active_turf.archived_cycle < times_fired)
				LINDA_CYCLE_ARCHIVE(active_turf)
			active_turf.current_cycle = times_fired
			active_turf.temperature_expose(active_turf.air, active_turf.air.return_temperature())
#ifndef DOGMOS_IN_PROCESS
			if(!SSdogmos.service_ready)
				pause()
				return TRUE
#endif
			if(!QDELETED(active_turf) && isopenturf(active_turf) && active_turf.air)
				// Wake differing neighbors before publication, but matching gas may
				// still react. Retirement belongs after native reactions and callbacks.
				turf_settled(active_turf)
		if(MC_TICK_CHECK)
			return TRUE
	return active_turfs_walk_cursor < turf_count

/** Batch-fetches turf air snapshots for the active-turf walk batch and their neighbors.
 * compare() reads both the turf and each adjacent turf's air; prefetching them in one IPC call
 * replaces one per unique mixture the walk will access.
 */
#ifndef DOGMOS_IN_PROCESS
/datum/controller/subsystem/air/proc/dogmos_prefetch_walk_snapshots(list/batch)
	var/list/datum/gas_mixture/prefetch = list()
	for(var/turf/open/T as anything in batch)
		if(QDELETED(T) || !isopenturf(T))
			continue
		if(T?.air)
			prefetch += T.air
		for(var/turf/neighbor as anything in T.atmos_adjacent_turfs)
			if(QDELETED(neighbor) || !isopenturf(neighbor))
				continue
			var/turf/open/open_neighbor = neighbor
			if(open_neighbor.air)
				prefetch += open_neighbor.air
	if(length(prefetch))
		SSdogmos.prefetch_mixture_snapshots(prefetch)

#endif

/** Releases bounded preparation state at a range boundary, new run or fatal shutdown. */
/datum/controller/subsystem/air/proc/dogmos_clear_machinery_prefetch()
	dogmos_machine_prefetch_start = 0
	dogmos_machine_prefetch_end = 0
	dogmos_machine_prefetch_cursor = 0
	dogmos_machine_prefetch_air_cursor = 1
	dogmos_machine_prefetch_ready = FALSE
	dogmos_machine_prefetch_mixtures.Cut()

/** Resumes collection in processing order, including within oversized component air lists.
 * Returns TRUE once the selected range has completed its bounded snapshot requests.
 * Snapshot caching remains advisory: normal gas writes invalidate it and getters fetch current state.
 */
#ifndef DOGMOS_IN_PROCESS
/datum/controller/subsystem/air/proc/dogmos_prefetch_machinery_snapshots(list/machines)
	if(!dogmos_machine_prefetch_start)
		dogmos_machine_prefetch_start = length(machines)
		dogmos_machine_prefetch_end = max(1, length(machines) - DOGMOS_MACHINE_PREFETCH_ENTRIES + 1)
		dogmos_machine_prefetch_cursor = length(machines)
	var/list/datum/gas_mixture/prefetch = dogmos_machine_prefetch_mixtures
	var/visited = 0
	while(dogmos_machine_prefetch_cursor >= dogmos_machine_prefetch_end \
		&& visited < DOGMOS_MACHINE_PREFETCH_MIXTURES && length(prefetch) < DOGMOS_MACHINE_PREFETCH_MIXTURES)
		if(MC_TICK_CHECK)
			return FALSE
		visited++
		var/obj/machinery/atmospherics/components/component = machines[dogmos_machine_prefetch_cursor]
		if(istype(component) && !QDELETED(component))
			if(dogmos_machine_prefetch_air_cursor <= length(component.airs))
				var/datum/gas_mixture/mix = component.airs[dogmos_machine_prefetch_air_cursor++]
				if(mix)
					prefetch += mix
				continue
			var/turf/open/component_turf = component.loc
			if(istype(component_turf) && component_turf.air)
				prefetch += component_turf.air
		dogmos_machine_prefetch_cursor--
		dogmos_machine_prefetch_air_cursor = 1
	if(MC_TICK_CHECK)
		return FALSE
	if(length(prefetch))
		SSdogmos.prefetch_mixture_snapshots(prefetch)
		prefetch.Cut()
	return dogmos_machine_prefetch_cursor < dogmos_machine_prefetch_end
#endif

// APHELION EDIT ADDITION END

/** Refreshes the walked turfs after their gas diffusion, reactions, and callbacks are complete. */
/* // APHELION EDIT REMOVAL START - DOGMOS - visual work must retain the same bounded continuation
/datum/controller/subsystem/air/proc/refresh_dogmos_visuals()
	for(var/turf/open/active_turf as anything in dogmos_visual_refresh_batch)
		if(!active_turf?.air)
			continue
		active_turf.update_visuals()
		check_kennel_reaction_of_interest(active_turf)
	dogmos_visual_refresh_batch.Cut()
*/ // APHELION EDIT REMOVAL END

// APHELION EDIT ADDITION START - DOGMOS
/** Resumes post-simulation visuals without repeating native stages or completed refreshes. */
/datum/controller/subsystem/air/proc/refresh_dogmos_visuals()
	var/list/snapshot = dogmos_visual_refresh_batch
#ifndef DOGMOS_IN_PROCESS
	if(!SSdogmos.service_ready)
		pause()
		return
#endif
	while(dogmos_visual_refresh_cursor < length(snapshot))
		if(MC_TICK_CHECK)
			return
		if(dogmos_visual_refresh_cursor >= dogmos_visual_prefetch_end)
			dogmos_visual_prefetch_end = min(dogmos_visual_refresh_cursor + ACTIVE_TURFS_WALK_BATCH_SIZE, length(snapshot))
#ifndef DOGMOS_IN_PROCESS
			dogmos_prefetch_walk_snapshots(snapshot.Copy(dogmos_visual_refresh_cursor + 1, dogmos_visual_prefetch_end + 1))
#endif
#ifndef DOGMOS_IN_PROCESS
			if(!SSdogmos.service_ready)
				pause()
				return
#endif
			if(MC_TICK_CHECK)
				return
		var/batch_end = dogmos_visual_prefetch_end
		while(dogmos_visual_refresh_cursor < batch_end)
			var/turf/open/active_turf = snapshot[++dogmos_visual_refresh_cursor]
			if(!QDELETED(active_turf) && isopenturf(active_turf) && active_turf.air)
				if(active_turf.excited && turf_settled(active_turf) && !dogmos_reacted_turfs[active_turf])
					remove_from_active(active_turf)
				active_turf.update_visuals()
#ifndef DOGMOS_IN_PROCESS
				if(!SSdogmos.service_ready)
					pause()
					return
#endif
				check_kennel_reaction_of_interest(active_turf)
			if(MC_TICK_CHECK)
				return
	dogmos_visual_refresh_batch.Cut()
	dogmos_reacted_turfs.Cut()
	active_turfs_walk_cursor = 0
	dogmos_visual_refresh_cursor = 0
	dogmos_walk_prefetch_end = 0
	dogmos_visual_prefetch_end = 0
// APHELION EDIT ADDITION END

/** Returns TRUE when a turf has no active hotspot and matches its open neighbors.
 * Mutable neighbors with different air are activated before this cycle's frontier publication.
 * Immutable sources settle after waking mutable neighbors. Immutable boundaries remain fixed, but
 * keep a mutable source active until it converges within the normal comparison tolerance.
 */
/datum/controller/subsystem/air/proc/turf_settled(turf/open/T)
	// APHELION EDIT ADDITION START - DOGMOS
#ifdef DOGMOS_IN_PROCESS
	// One bounded native query replaces per-neighbor compare/immutability crossings.
	// Neither this result nor the wake decision survives the current call.
	var/list/neighbors = list()
	var/list/mixtures = list()
	for(var/turf/open/neighbor as anything in T.atmos_adjacent_turfs)
		if(isopenturf(neighbor))
			neighbors += neighbor
			mixtures += neighbor.air
	var/list/settlement = T.air.__settlement_batch(mixtures)
	if(length(settlement) != length(neighbors) + 1)
		CRASH("Dogmos returned an invalid settlement batch.")
	var/source_is_immutable = settlement[1]
	var/settled = source_is_immutable || !T.active_hotspot
	for(var/index in 1 to length(neighbors))
		var/neighbor_state = settlement[index + 1]
		if(neighbor_state)
			settled = source_is_immutable
			// State 1 is a differing fixed boundary; state 2 is a mutable neighbor.
			if(neighbor_state == 2)
				add_to_active(neighbors[index])
	return settled
#else
	// APHELION EDIT ADDITION START - DOGMOS
	var/source_is_immutable = T.air.is_immutable()
	// APHELION EDIT ADDITION END
	var/settled = source_is_immutable || !T.active_hotspot // APHELION EDIT CHANGE - DOGMOS - ORIGINAL: var/settled = !T.active_hotspot
	for(var/turf/neighbor as anything in T.atmos_adjacent_turfs)
		if(!isopenturf(neighbor))
			continue
		var/turf/open/open_neighbor = neighbor
		var/differs = T.air.compare(open_neighbor.air)
		if(differs)
			settled = source_is_immutable // APHELION EDIT CHANGE - DOGMOS - ORIGINAL: settled = FALSE
			if(!open_neighbor.air.is_immutable())
				add_to_active(open_neighbor)
	return settled
#endif
	// APHELION EDIT ADDITION END

/** Runs Rust's low-pressure equalizer within the current tick budget. */
/datum/controller/subsystem/air/proc/process_excited_groups(resumed = FALSE)
	var/remaining_ms = TICK_DELTA_TO_MS(Master.current_ticklimit - TICK_USAGE)
	if(process_excited_groups_auxtools(remaining_ms))
		pause() // ran out of budget mid-batch - resume next fire(), see doc comment above

/datum/controller/subsystem/air/proc/process_rebuilds()
	//Yes this does mean rebuilding pipenets can freeze up the subsystem forever, but if we're in that situation something else is very wrong
	var/list/currentrun = rebuild_queue
	while(currentrun.len || length(expansion_queue))
		while(currentrun.len && !length(expansion_queue)) //If we found anything, process that first
			var/obj/machinery/atmospherics/remake = currentrun[currentrun.len]
			currentrun.len--
			if (!remake)
				continue
			remake.rebuild_pipes()
			if (MC_TICK_CHECK)
				return

		var/list/queue = expansion_queue
		while(queue.len)
			var/list/pack = queue[queue.len]
			//We operate directly with the pipeline like this because we can trust any rebuilds to remake it properly
			var/datum/pipeline/linepipe = pack[SSAIR_REBUILD_PIPELINE]
			var/list/border = pack[SSAIR_REBUILD_QUEUE]
			expand_pipeline(linepipe, border)
			if(state != SS_RUNNING) //expand_pipeline can fail a tick check, we shouldn't let things get too fucky here
				return

			linepipe.building = FALSE
			queue.len--
			if (MC_TICK_CHECK)
				return

///Rebuilds a pipeline by expanding outwards, while yielding when sane
/datum/controller/subsystem/air/proc/expand_pipeline(datum/pipeline/net, list/border)
	// APHELION EDIT ADDITION START - DOGMOS
	var/expanded_volume
	// APHELION EDIT ADDITION END
	while(border.len)
		var/obj/machinery/atmospherics/borderline = border[border.len]
		border.len--

		var/list/result = borderline.pipeline_expansion(net)
		if(!length(result))
			continue
		for(var/obj/machinery/atmospherics/considered_device in result)
			if(!istype(considered_device, /obj/machinery/atmospherics/pipe))
				considered_device.set_pipenet(net, borderline)
				net.add_machinery_member(considered_device)
				continue
			var/obj/machinery/atmospherics/pipe/item = considered_device
			if(item.parent == net) // APHELION EDIT CHANGE - DOGMOS - ORIGINAL: if(net.members.Find(item))
				continue
			if(item.parent)
				var/static/pipenetwarnings = 10
				if(pipenetwarnings > 0)
					log_mapping("build_pipeline(): [item.type] added to a pipenet while still having one. (pipes leading to the same spot stacking in one turf) around [AREACOORD(item)].")
					pipenetwarnings--
					if(pipenetwarnings == 0)
						log_mapping("build_pipeline(): further messages about pipenets will be suppressed")

			net.members += item
			border += item

			/* // APHELION EDIT REMOVAL START - DOGMOS
			net.air.set_volume(net.air.return_volume() + item.volume)
			*/ // APHELION EDIT REMOVAL END
			// APHELION EDIT ADDITION START - DOGMOS
			if(isnull(expanded_volume))
				expanded_volume = net.air.return_volume()
			expanded_volume += item.volume
			// APHELION EDIT ADDITION END
			item.replace_pipenet(item.parent, net)

			if(item.air_temporary)
				net.air.merge(item.air_temporary)
				item.air_temporary = null

		if (MC_TICK_CHECK)
			// APHELION EDIT ADDITION START - DOGMOS
			if(!isnull(expanded_volume))
				net.air.set_volume(expanded_volume)
			// APHELION EDIT ADDITION END
			return
	// APHELION EDIT ADDITION START - DOGMOS
	if(!isnull(expanded_volume))
		net.air.set_volume(expanded_volume)
	// APHELION EDIT ADDITION END

///Removes a turf from processing, and causes its excited group to clean up so things properly adapt to the change
/datum/controller/subsystem/air/proc/remove_from_active(turf/open/T)
	dogmos_remove_frontier_member(T) // APHELION EDIT CHANGE - DOGMOS - ORIGINAL: active_turfs -= T
	if(currentpart == SSAIR_ACTIVETURFS)
		currentrun -= T
	#ifdef VISUALIZE_ACTIVE_TURFS //Use this when you want details about how the turfs are moving, display_all_groups should work for normal operation
	T.remove_atom_colour(TEMPORARY_COLOUR_PRIORITY, COLOR_VIBRANT_LIME)
	#endif
	if(istype(T))
		T.excited = FALSE
		if(T.excited_group)
			//If this fires during active turfs it'll cause a slight removal of active turfs, as they breakdown if they have no excited group
			//The group also expands by a tile per rebuild on each edge, suffering
			T.excited_group.garbage_collect() //Kill the excited group, it'll reform on its own later

///Puts an active turf to sleep so it doesn't process. Do this without cleaning up its excited group.
/datum/controller/subsystem/air/proc/sleep_active_turf(turf/open/T)
	dogmos_remove_frontier_member(T) // APHELION EDIT CHANGE - DOGMOS - ORIGINAL: active_turfs -= T
	if(currentpart == SSAIR_ACTIVETURFS)
		currentrun -= T
	#ifdef VISUALIZE_ACTIVE_TURFS
	T.remove_atom_colour(TEMPORARY_COLOUR_PRIORITY, COLOR_VIBRANT_LIME)
	#endif
	if(istype(T))
		T.excited = FALSE

///Adds a turf to active processing, handles duplicates. Call this with blockchanges == TRUE if you want to nuke the assoc excited group
/datum/controller/subsystem/air/proc/add_to_active(turf/open/activate, blockchanges = FALSE)
	if(istype(activate) && activate.air)
		// NOVA EDIT ADDITION START - DOGMOS
		for(var/obj/machinery/atmospherics/atmos_machine in activate)
			if(atmos_machine.wake_on_turf_atmos && !atmos_machine.atmos_processing) // APHELION EDIT CHANGE - DOGMOS - ORIGINAL: if(atmos_machine.wake_on_turf_atmos)
				start_processing_machine(atmos_machine)
		// NOVA EDIT ADDITION END
		activate.significant_share_ticker = 0
		if(blockchanges && activate.excited_group) //This is used almost exclusivly for shuttles, so the excited group doesn't stay behind
			activate.excited_group.garbage_collect() //Nuke it
		if(activate.excited) //Don't keep doing it if there's no point
			return
		#ifdef VISUALIZE_ACTIVE_TURFS
		activate.add_atom_colour(COLOR_VIBRANT_LIME, TEMPORARY_COLOUR_PRIORITY)
		#endif
		activate.excited = TRUE
		dogmos_add_frontier_member(activate) // APHELION EDIT CHANGE - DOGMOS - ORIGINAL: active_turfs += activate
	else if(activate.flags_1 & INITIALIZED_1)
		for(var/turf/neighbor as anything in activate.atmos_adjacent_turfs)
			add_to_active(neighbor, TRUE)
	else if(map_loading)
		if(queued_for_activation)
			queued_for_activation[activate] = activate
	else
		activate.requires_activation = TRUE

/datum/controller/subsystem/air/StartLoadingMap()
	LAZYINITLIST(queued_for_activation)
	map_loading = TRUE

/datum/controller/subsystem/air/StopLoadingMap()
	map_loading = FALSE
	for(var/turf/T in queued_for_activation)
		// Late-map-loaded turfs (ruins, away missions) never went through setup_allturfs()'s bulk
		// Initalize_Atmos() pass, so they've never registered with Dogmos - do it now, alongside the
		// existing add_to_active() catch-up this loop already does for the same reason.
		T.register_dogmos_air()
		add_to_active(T, TRUE)
	queued_for_activation.Cut()

// APHELION EDIT ADDITION START - DOGMOS
/** Prefetches own gas before initialization reads its visuals, preserving turf order and cycle stamps. */
/datum/controller/subsystem/air/proc/dogmos_initialize_turf_batch(list/batch, list/difference_check, time)
#ifndef DOGMOS_IN_PROCESS
	var/list/mixtures = list()
	for(var/turf/open/setup as anything in batch)
		if(!QDELETED(setup) && isopenturf(setup) && setup.init_air && setup.air)
			mixtures += setup.air
	SSdogmos.prefetch_mixture_snapshots(mixtures)
#endif
	for(var/turf/setup as anything in batch)
		if(QDELETED(setup) || !setup.init_air)
			continue
		setup.Initalize_Atmos(time)
		difference_check += setup
		if(CHECK_TICK)
			time--
	return time
// APHELION EDIT ADDITION END

/datum/controller/subsystem/air/proc/setup_allturfs()
	var/list/active_turfs = src.active_turfs
	times_fired++
	// APHELION EDIT ADDITION START - DOGMOS
#ifndef DOGMOS_IN_PROCESS
	if(DOGMOS)
		SSdogmos.begin_turf_registration_batch()
#endif
	// APHELION EDIT ADDITION END

	// Clear active turfs - faster than removing every single turf in the world
	// one-by-one, and Initalize_Atmos only ever adds `src` back in.
	#ifdef VISUALIZE_ACTIVE_TURFS
	for(var/jumpy in active_turfs)
		var/turf/active = jumpy
		active.remove_atom_colour(TEMPORARY_COLOUR_PRIORITY, COLOR_VIBRANT_LIME)
	#endif
	dogmos_clear_active_frontier() // APHELION EDIT CHANGE - DOGMOS - ORIGINAL: active_turfs.Cut()
	// We compare this against turf.current cycle using <= to ensure O(n)
	// It defaults to 0, so we start at -1
	var/time = -1

	var/list/turf/open/difference_check = list()
	// APHELION EDIT ADDITION START - DOGMOS
	var/list/initialization_batch = list()
	// APHELION EDIT ADDITION END
	for(var/turf/setup as anything in ALL_TURFS())
		if (!setup.init_air)
			continue
		// APHELION EDIT ADDITION START - DOGMOS
		if(DOGMOS)
			initialization_batch += setup
			if(length(initialization_batch) >= ACTIVE_TURFS_WALK_BATCH_SIZE)
				time = dogmos_initialize_turf_batch(initialization_batch, difference_check, time)
				initialization_batch.Cut()
			continue
		// APHELION EDIT ADDITION END
		// We pass the tick as the current step so if we sleep the step changes
		// This way we can make setting up adjacent turfs O(n) rather then O(n^2)
		setup.Initalize_Atmos(time)
		// We assert that we'll only get open turfs here
		difference_check += setup
		if(CHECK_TICK)
			time--
	// APHELION EDIT ADDITION START - DOGMOS
	if(DOGMOS)
		if(length(initialization_batch))
			time = dogmos_initialize_turf_batch(initialization_batch, difference_check, time)
#ifdef DOGMOS_IN_PROCESS
		// Rebuild edges after every endpoint has registered, independent of map order.
		for(var/turf/registered_turf as anything in difference_check)
			registered_turf.__update_auxtools_turf_adjacency_info(world.maxx, world.maxy)
			CHECK_TICK
#else
		SSdogmos.retry_startup_turf_adjacencies()
		SSdogmos.finish_turf_registration_batch()
#endif
	// APHELION EDIT ADDITION END

	// Now we're gonna compare for differences
	// Taking advantage of current cycle being set to negative before this run to do A->B B->A prevention
	// APHELION EDIT ADDITION START - DOGMOS
#ifndef DOGMOS_IN_PROCESS
	var/difference_index = 0
#endif
	// Startup comparisons need the same bounded snapshot prefetch as the runtime walk.
	// Fetching each mixture on demand otherwise turns map setup into one IPC per cache miss.
	// APHELION EDIT ADDITION END
	for(var/turf/open/potential_diff as anything in difference_check)
		// APHELION EDIT ADDITION START - DOGMOS
#ifndef DOGMOS_IN_PROCESS
		difference_index++
		if(DOGMOS && (difference_index - 1) % ACTIVE_TURFS_WALK_BATCH_SIZE == 0)
			dogmos_prefetch_walk_snapshots(difference_check.Copy(difference_index, min(difference_index + ACTIVE_TURFS_WALK_BATCH_SIZE, length(difference_check) + 1)))
#endif
		// APHELION EDIT ADDITION END
		// I can't use 0 here, so we're gonna do this instead. If it ever breaks I'll eat my shoe
		potential_diff.current_cycle = -INFINITY
		for(var/turf/open/enemy_tile as anything in potential_diff.atmos_adjacent_turfs)
			// If it's already been processed, then it's already talked to us
			if(enemy_tile.current_cycle == -INFINITY)
				continue
			// .air instead of .return_air() because we can guarantee that the proc won't do anything
			if(potential_diff.air.compare(enemy_tile.air, FALSE))
				if(!potential_diff.excited)
					potential_diff.excited = TRUE
					SSair.dogmos_add_frontier_member(potential_diff) // APHELION EDIT CHANGE - DOGMOS - ORIGINAL: SSair.active_turfs += potential_diff
				if(!enemy_tile.excited)
					enemy_tile.excited = TRUE
					SSair.dogmos_add_frontier_member(enemy_tile) // APHELION EDIT CHANGE - DOGMOS - ORIGINAL: SSair.active_turfs += enemy_tile
				// No sense continuing to iterate
				break
		CHECK_TICK

	if(active_turfs.len)
		var/starting_ats = active_turfs.len
		sleep(world.tick_lag)
		var/timer = world.timeofday

		log_mapping("There are [starting_ats] active turfs at roundstart caused by a difference of the air between the adjacent turfs. \
		To locate these active turfs, go into the \"Debug\" tab of your stat-panel. Then hit the verb that says \"Mapping Verbs - Enable\". \
		Now, you can see all of the associated coordinates using \"Mapping -> Show roundstart AT list\" verb.")

		for(var/turf/T in active_turfs)
			GLOB.active_turfs_startlist += T

		//now lets clear out these active turfs
		var/list/turfs_to_check = active_turfs.Copy()
		do
			var/list/new_turfs_to_check = list()
			for(var/turf/open/T in turfs_to_check)
				new_turfs_to_check += T.resolve_active_graph()
			CHECK_TICK

			/* // APHELION EDIT REMOVAL START - DOGMOS
			active_turfs += new_turfs_to_check
			*/ // APHELION EDIT REMOVAL END
			// APHELION EDIT ADDITION START - DOGMOS
			for(var/turf/open/new_active as anything in new_turfs_to_check)
				dogmos_add_frontier_member(new_active)
			// APHELION EDIT ADDITION END
			turfs_to_check = new_turfs_to_check
		while (turfs_to_check.len)

		var/ending_ats = active_turfs.len
		for(var/thing in excited_groups)
			var/datum/excited_group/EG = thing
			EG.self_breakdown(roundstart = TRUE)
			EG.dismantle()
			CHECK_TICK

		log_active_turfs() // invoke this here so we can count the time it takes to run this proc as "wasted time", quite simple honestly.

		var/msg = "HEY! LISTEN! [DisplayTimeText(world.timeofday - timer, 0.00001)] were wasted processing [starting_ats] turf(s) (connected to [ending_ats - starting_ats] other turfs) with atmos differences at round start."
		to_chat(world, span_boldannounce("[msg]"))
		warning(msg)

/// Logs all active turfs at roundstart to the mapping log so it can be readily accessed.
/datum/controller/subsystem/air/proc/log_active_turfs()
// sadly this has to be here because we can't realistically expect that all active turfs will be resolved in every possible situation when running through CI.
// In an ideal world, we would have absolutely zero active turfs 99.99% of the time, but that's not the case. `log_mapping()` during world initialize triggers a CI fail.
#ifdef UNIT_TESTS
	return
#else
	// Associated lists, left-hand-side is the z-level or z-trait, right-hand-side is the number of active turfs associated with that.
	var/list/tally_by_level = list()
	// Discriminate for certain z-traits, stuff like "Linkage" is not helpful.
	var/list/tally_by_level_trait = list(
		ZTRAIT_AWAY = 0,
		ZTRAIT_CENTCOM = 0,
		ZTRAIT_ICE_RUINS = 0,
		ZTRAIT_ICE_RUINS_UNDERGROUND  = 0,
		ZTRAIT_ISOLATED_RUINS = 0,
		ZTRAIT_LAVA_RUINS = 0,
		ZTRAIT_MINING = 0,
		ZTRAIT_RESERVED = 0,
		ZTRAIT_SPACE_RUINS = 0,
		ZTRAIT_STATION = 0,
	)

	var/list/message_to_log = list()

	message_to_log += "\nAll that follows is a turf with an active air difference at roundstart. To clear this, make sure that all of the turfs listed below are connected to a turf with the same air contents.\n\
		In an ideal world, this list should have enough information to help you locate the active turf(s) in question. Unfortunately, this might not be an ideal world.\n\
		If the round is still ongoing, you can use the \"Mapping -> Show roundstart AT list\" verb to see exactly what active turfs were detected. Otherwise, good luck."

	for(var/turf/active_turf as anything in GLOB.active_turfs_startlist)
		var/turf_z = active_turf.z
		var/datum/space_level/level = SSmapping.z_list[turf_z]
		var/list/level_traits = list()
		for(var/trait in level.traits)
			if(!isnull(tally_by_level_trait[trait]))
				level_traits += trait
				tally_by_level_trait[trait]++

		// so we can pass along the area type for the log, making it much easier to locate the active turf for a mapper assuming all area types are unique. This is only really a problem for stuff like ruin areas.
		var/area/turf_area = get_area(active_turf)
		message_to_log += "Active turf: [AREACOORD(active_turf)] ([turf_area.type]). Turf type: [active_turf.type]. Relevant Z-Trait(s): [english_list(level_traits)]."

		tally_by_level["[turf_z]"]++

	// Following is so we can detect which rounds were "problematic" as far as active turfs go.
	SSblackbox.record_feedback("amount", "overall_roundstart_active_turfs", length(GLOB.active_turfs_startlist))

	for(var/z_level in tally_by_level)
		var/level_turf_count = tally_by_level[z_level]
		if(level_turf_count == 0) // no point logging it
			continue
		message_to_log += "Z-Level [z_level] has [level_turf_count] active turf(s)."
		SSblackbox.record_feedback("tally", "roundstart_active_turfs_per_z", level_turf_count, z_level)

	for(var/z_trait in tally_by_level_trait)
		var/trait_turf_count = tally_by_level_trait[z_trait]
		if(trait_turf_count == 0)
			continue
		message_to_log += "Z-Level trait [z_trait] has [trait_turf_count] active turf(s)."
		SSblackbox.record_feedback("amount", "roundstart_active_turfs_for_trait_[z_trait]", trait_turf_count)

	message_to_log += "End of active turf list."
	log_mapping(message_to_log.Join("\n"))
#endif

/turf/open/proc/resolve_active_graph()
	. = list()
	var/datum/excited_group/EG = excited_group
	if (blocks_air || !air)
		return
	if (!EG)
		EG = new
		EG.add_turf(src)

	for (var/turf/open/ET in atmos_adjacent_turfs)
		if (ET.blocks_air || !ET.air)
			continue

		var/ET_EG = ET.excited_group
		if (ET_EG)
			if (ET_EG != EG)
				EG.merge_groups(ET_EG)
				EG = excited_group //merge_groups() may decide to replace our current EG
		else
			EG.add_turf(ET)
		if (!ET.excited)
			ET.excited = TRUE
			. += ET

/turf/open/space/resolve_active_graph()
	return list()

/datum/controller/subsystem/air/proc/setup_atmos_machinery()
	for (var/obj/machinery/atmospherics/AM in atmos_machinery)
		AM.atmos_init()
		CHECK_TICK

//this can't be done with setup_atmos_machinery() because
// all atmos machinery has to initialize before the first
// pipenet can be built.
/datum/controller/subsystem/air/proc/setup_pipenets()
	for (var/obj/machinery/atmospherics/AM in atmos_machinery)
		var/list/targets = AM.get_rebuild_targets()
		for(var/datum/pipeline/build_off as anything in targets)
			build_off.build_pipeline_blocking(AM)
		CHECK_TICK

GLOBAL_LIST_EMPTY(colored_turfs)
GLOBAL_LIST_EMPTY(colored_images)
/datum/controller/subsystem/air/proc/setup_turf_visuals()
	for(var/sharp_color in GLOB.contrast_colors)
		var/list/add_to = list()
		GLOB.colored_turfs += list(add_to)
		for(var/offset in 0 to SSmapping.max_plane_offset)
			var/obj/effect/overlay/atmos_excited/suger_high = new()
			SET_PLANE_W_SCALAR(suger_high, HIGH_GAME_PLANE, offset)
			add_to += suger_high
			var/image/shiny = new('icons/effects/effects.dmi', suger_high, "atmos_top")
			SET_PLANE_W_SCALAR(shiny, HIGH_GAME_PLANE, offset)
			shiny.color = sharp_color
			GLOB.colored_images += shiny

/datum/controller/subsystem/air/proc/setup_template_machinery(list/atmos_machines)
	var/obj/machinery/atmospherics/AM
	for(var/A in 1 to atmos_machines.len)
		AM = atmos_machines[A]
		AM.atmos_init()
		CHECK_TICK

	for(var/A in 1 to atmos_machines.len)
		AM = atmos_machines[A]
		var/list/targets = AM.get_rebuild_targets()
		for(var/datum/pipeline/build_off as anything in targets)
			build_off.build_pipeline_blocking(AM)
		CHECK_TICK


/datum/controller/subsystem/air/proc/get_init_dirs(type, dir, init_dir)

	if(!pipe_init_dirs_cache[type])
		pipe_init_dirs_cache[type] = list()

	if(!pipe_init_dirs_cache[type]["[init_dir]"])
		pipe_init_dirs_cache[type]["[init_dir]"] = list()

	if(!pipe_init_dirs_cache[type]["[init_dir]"]["[dir]"])
		var/obj/machinery/atmospherics/temp = new type(null, FALSE, dir, init_dir)
		pipe_init_dirs_cache[type]["[init_dir]"]["[dir]"] = temp.get_init_directions()
		qdel(temp)

	return pipe_init_dirs_cache[type]["[init_dir]"]["[dir]"]

/datum/controller/subsystem/air/proc/generate_atmos()
	atmos_gen = list()
	for(var/T in subtypesof(/datum/atmosphere))
		var/datum/atmosphere/atmostype = T
		atmos_gen[initial(atmostype.id)] = new atmostype

/// Takes a gas string, returns the matching mutable gas_mixture
/datum/controller/subsystem/air/proc/parse_gas_string(gas_string, gastype = /datum/gas_mixture)
	var/datum/gas_mixture/cached = strings_to_mix["[gas_string]-[gastype]"]

	if(cached)
		if(istype(cached, /datum/gas_mixture/immutable))
			return cached
		return cached.copy()

	var/datum/gas_mixture/canonical_mix = new gastype()
	// We set here so any future key changes don't fuck us
	strings_to_mix["[gas_string]-[gastype]"] = canonical_mix
	gas_string = preprocess_gas_string(gas_string)

	var/list/gas = params2list(gas_string)
	if(gas["TEMP"])
		canonical_mix.set_temperature(text2num(gas["TEMP"]))
		gas -= "TEMP"
	else // if we do not have a temp in the new gas mix lets assume room temp.
		canonical_mix.set_temperature(T20C)
	for(var/id in gas)
		canonical_mix.set_moles(id, text2num(gas[id]))

	if(istype(canonical_mix, /datum/gas_mixture/immutable))
		canonical_mix.mark_immutable() //content is final now; New() deliberately did not do this
		return canonical_mix
	return canonical_mix.copy()

/datum/controller/subsystem/air/proc/preprocess_gas_string(gas_string)
	if(!atmos_gen)
		generate_atmos()
	if(!atmos_gen[gas_string])
		return gas_string
	var/datum/atmosphere/mix = atmos_gen[gas_string]
	return mix.gas_string

#undef ACTIVE_TURFS_WALK_BATCH_SIZE

/**
 * Adds a given machine to the processing system for SSAIR_ATMOSMACHINERY processing.
 *
 * Arguments:
 * * machine - An atmosphere-processing machine or gas-leaker component.
 */
/datum/controller/subsystem/air/proc/start_processing_machine(datum/machine) // APHELION EDIT CHANGE - DOGMOS - ORIGINAL: /datum/controller/subsystem/air/proc/start_processing_machine(obj/machinery/machine)
	// APHELION EDIT ADDITION START - DOGMOS
	if(!istype(machine, /obj/machinery) && !istype(machine, /datum/component/gas_leaker))
		stack_trace("Attempted to add unsupported [machine?.type] to SSair atmosphere machinery processing.")
		return
	// APHELION EDIT ADDITION END
	var/already_processing
	if(ismachinery(machine))
		var/obj/machinery/atmos_machine = machine
		already_processing = atmos_machine.atmos_processing
	else
		var/datum/component/gas_leaker/gas_leaker = machine
		already_processing = gas_leaker.atmos_processing
	if(already_processing)
		return
	if(QDELETED(machine))
		stack_trace("We tried to add a garbage collecting machine to SSair. Don't")
		return
	if(ismachinery(machine))
		var/obj/machinery/atmos_machine = machine
		atmos_machine.atmos_processing = TRUE
	else
		var/datum/component/gas_leaker/gas_leaker = machine
		gas_leaker.atmos_processing = TRUE
	atmos_machinery += machine

/**
 * Removes a given machine to the processing system for SSAIR_ATMOSMACHINERY processing.
 *
 * Arguments:
 * * machine - The atmosphere-processing machine or gas-leaker component to stop.
 * * currentrun_entry_removed - The processing loop has already popped this entry; other callers leave FALSE.
 */
/datum/controller/subsystem/air/proc/stop_processing_machine(datum/machine, currentrun_entry_removed = FALSE) // APHELION EDIT CHANGE - DOGMOS - ORIGINAL: /datum/controller/subsystem/air/proc/stop_processing_machine(obj/machinery/machine)
	// APHELION EDIT ADDITION START - DOGMOS
	if(!istype(machine, /obj/machinery) && !istype(machine, /datum/component/gas_leaker))
		return
	// APHELION EDIT ADDITION END
	var/is_processing
	if(ismachinery(machine))
		var/obj/machinery/atmos_machine = machine
		is_processing = atmos_machine.atmos_processing
	else
		var/datum/component/gas_leaker/gas_leaker = machine
		is_processing = gas_leaker.atmos_processing
	if(!is_processing)
		return
	if(ismachinery(machine))
		var/obj/machinery/atmos_machine = machine
		atmos_machine.atmos_processing = FALSE
	else
		var/datum/component/gas_leaker/gas_leaker = machine
		gas_leaker.atmos_processing = FALSE
	atmos_machinery -= machine
	// APHELION EDIT ADDITION START - DOGMOS
	kennel_machine_cost_ewma -= REF(machine)
	// APHELION EDIT ADDITION END

	// If we're currently processing atmos machines, there's a chance this machine is in
	// the currentrun list, which is a cache of atmos_machinery. Remove it from that list
	// as well to prevent processing qdeleted objects in the cache.
	if(currentpart == SSAIR_ATMOSMACHINERY && !currentrun_entry_removed) // APHELION EDIT CHANGE - DOGMOS - ORIGINAL: if(currentpart == SSAIR_ATMOSMACHINERY)
		// APHELION EDIT ADDITION START - DOGMOS
		// Removal shifts lower ranges and a partially collected component's index.
		var/removed_index = currentrun.Find(machine)
		if(removed_index && dogmos_machine_prefetch_start)
			if(removed_index <= dogmos_machine_prefetch_start)
				dogmos_machine_prefetch_start--
			if(removed_index < dogmos_machine_prefetch_end)
				dogmos_machine_prefetch_end--
			if(removed_index == dogmos_machine_prefetch_cursor)
				dogmos_machine_prefetch_air_cursor = 1
			if(removed_index <= dogmos_machine_prefetch_cursor)
				dogmos_machine_prefetch_cursor--
		// APHELION EDIT ADDITION END
		/* // APHELION EDIT REMOVAL START - DOGMOS
		currentrun -= machine
		*/ // APHELION EDIT REMOVAL END
		// APHELION EDIT ADDITION START - DOGMOS
		// Reuse the lookup above instead of scanning this continuation a second time.
		if(removed_index)
			currentrun.Cut(removed_index, removed_index + 1)
		if(length(currentrun) < dogmos_machine_prefetch_end)
			dogmos_clear_machinery_prefetch()
		// APHELION EDIT ADDITION END

/datum/controller/subsystem/air/ui_state(mob/user)
	return ADMIN_STATE(R_DEBUG)

/datum/controller/subsystem/air/ui_interact(mob/user, datum/tgui/ui)
	ui = SStgui.try_update_ui(user, src, ui)
	if(!ui)
		ui = new(user, src, "AtmosControlPanel")
		ui.set_autoupdate(FALSE)
		ui.open()

/datum/controller/subsystem/air/ui_data(mob/user)
	var/list/data = list()
	data["excited_groups"] = list()
	for(var/datum/excited_group/group in excited_groups)
		var/turf/T = group.turf_list[1]
		var/area/target = get_area(T)
		var/max = 0
		#ifdef TRACK_MAX_SHARE
		for(var/who in group.turf_list)
			var/turf/open/lad = who
			max = max(lad.max_share, max)
		#endif
		data["excited_groups"] += list(list(
			"jump_to" = REF(T), //Just go to the first turf
			"group" = REF(group),
			"area" = target.name,
			"breakdown" = group.breakdown_cooldown,
			"dismantle" = group.dismantle_cooldown,
			"size" = group.turf_list.len,
			"should_show" = group.should_display,
			"max_share" = max
		))
	data["active_size"] = active_turfs.len
	data["hotspots_size"] = hotspots.len
	data["excited_size"] = excited_groups.len
	data["conducting_size"] = dogmos_heat_graph_count()
	// The legacy excited_groups snapshot is not updated by Rust; expose live counters below instead.
	data["low_pressure_turfs"] = low_pressure_turfs
	data["high_pressure_turfs"] = high_pressure_turfs
	data["group_turfs_processed"] = num_group_turfs_processed
	data["equalize_processed"] = num_equalize_processed
	data["space_boundary_size"] = dogmos_space_boundary_count()
	data["dogmos_costs"] = list(
		"turfs" = cost_turfs,
		"groups" = cost_groups,
		"highpressure" = cost_highpressure,
		"equalize" = cost_equalize,
		"superconductivity" = cost_superconductivity,
		"post_process" = cost_post_process,
	)
	data["frozen"] = can_fire
	data["show_all"] = display_all_groups
	data["realistic_space_radiation"] = realistic_space_radiation
	data["fire_count"] = times_fired
	#ifdef TRACK_MAX_SHARE
	data["display_max"] = TRUE
	#else
	data["display_max"] = FALSE
	#endif
	data["showing_user"] = user.hud_used.atmos_debug_overlays
	return data

/datum/controller/subsystem/air/ui_act(action, list/params, datum/tgui/ui, datum/ui_state/state)
	. = ..()
	var/mob/user = usr
	if(. || !user?.client || !check_rights_for(user.client, R_DEBUG))
		return
	switch(action)
		if("move-to-target")
			var/turf/target
			for(var/datum/excited_group/group as anything in excited_groups)
				if(!length(group.turf_list))
					continue
				target = locate(params["spot"]) in group.turf_list
				if(target)
					break
			if(!target || !user)
				return
			user.forceMove(target)
		if("toggle-freeze")
			can_fire = !can_fire
			return TRUE
		if("toggle_realistic_space_radiation")
			realistic_space_radiation = !realistic_space_radiation
			return TRUE
		if("toggle_show_group")
			var/datum/excited_group/group = locate(params["group"])
			if(!group)
				return
			group.should_display = !group.should_display
			if(display_all_groups)
				return TRUE
			if(group.should_display)
				group.display_turfs()
			else
				group.hide_turfs()
			return TRUE
		if("toggle_show_all")
			display_all_groups = !display_all_groups
			for(var/datum/excited_group/group in excited_groups)
				if(display_all_groups)
					group.display_turfs()
				else if(!group.should_display) //Don't flicker yeah?
					group.hide_turfs()
			return TRUE
		if("toggle_user_display")
			user = ui.user
			user.hud_used.atmos_debug_overlays = !user.hud_used.atmos_debug_overlays
			if(user.hud_used.atmos_debug_overlays)
				user.client.images += GLOB.colored_images
			else
				user.client.images -= GLOB.colored_images
			return TRUE

#undef KENNEL_SLOW_MODE_PUSH_INTERVAL
#undef DOGMOS_STAGE_INITIAL_WORK_LIMIT
#undef DOGMOS_MACHINE_PREFETCH_ENTRIES
#undef DOGMOS_MACHINE_PREFETCH_MIXTURES
#undef DOGMOS_SIMULATION_TURF_EQUALIZE
#undef DOGMOS_SIMULATION_TURFS
#undef DOGMOS_SIMULATION_REACTIONS
#undef DOGMOS_HEALTH_COUNTER_MAX
