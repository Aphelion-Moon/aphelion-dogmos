/// Runtime count captured after subsystem initialization.
GLOBAL_VAR_INIT(runtimes_at_init_complete, 0)

/datum/controller/subsystem/air
	/// Temperature source used by blocked-turf consumers.
	var/dogmos_blocked_turf_temperature_authority = DOGMOS_TEMPERATURE_AUTHORITY_RUST
	/// Pressure-processing profile used after FDM diffusion.
	var/dogmos_equalize_performance_profile = DOGMOS_EQUALIZE_PROFILE_FAST_ZONE
	/// Heat-graph nodes observed by the most recent completed cycle.
	var/dogmos_heat_graph_nodes = 0
	/// Unique heat edges considered by the most recent cycle.
	var/dogmos_heat_edge_attempts = 0
	/// Unique heat edges applied by the most recent cycle.
	var/dogmos_heat_edges_applied = 0
	/// Temperature writes that waited for a lock in the most recent cycle.
	var/dogmos_heat_lock_contention = 0
	/// Heat-graph insertions and removals since the previous completed cycle.
	var/dogmos_heat_registration_changes = 0

/** Initializes Dogmos' gas registry before turfs create gas mixtures. */
SUBSYSTEM_DEF(dogmos)
	name = "Dogmos"
	init_stage = INITSTAGE_EARLY
	ss_flags = SS_NO_FIRE
	/// Subsystems that must wait for Dogmos initialization.
	dependents = list(
		/datum/controller/subsystem/mapping,
		/datum/controller/subsystem/atoms,
	)

	/// TRUE after the Rust gas registry initializes successfully.
	var/gases_registered = FALSE

/datum/controller/subsystem/dogmos/Initialize()
#ifdef DOGMOS_IN_PROCESS
	var/native_identity = dogmos_in_process_identity()
	if(native_identity != DOGMOS_IN_PROCESS_IDENTITY)
		stack_trace("Dogmos native identity mismatch: expected [DOGMOS_IN_PROCESS_IDENTITY], got [native_identity].")
		return SS_INIT_FAILURE
#endif
	// Build the reaction table before the Rust registry starts.
	SSair.gas_reactions = init_gas_reactions()
	SSair.dogmos_reactions = init_dogmos_reactions(SSair.gas_reactions)

	if(!length(SSair.dogmos_reactions))
		stack_trace("init_dogmos_reactions() produced an empty list - Dogmos initialization failed.")
		return SS_INIT_FAILURE

	populate_gas_data_overlays()

	if(!auxtools_atmos_init(GLOB.gas_data))
		stack_trace("auxtools_atmos_init() did not report success - Dogmos may hold an incomplete gas registry.")
		return SS_INIT_FAILURE

	gases_registered = TRUE
	#if defined(UNIT_TESTS) && !defined(DOGMOS_IN_PROCESS)
	if(GLOB.focused_tests?.Find(/datum/unit_test/dogmos_shift_start_performance) \
		|| GLOB.focused_tests?.Find(/datum/unit_test/dogmos_shift_start_performance/profile))
		INVOKE_ASYNC(src, PROC_REF(record_shift_start_performance))
	#endif
	return SS_INIT_SUCCESS

/** Stops Dogmos workers and releases its Rust-side arenas. */
/datum/controller/subsystem/dogmos/Shutdown()
	if(src == SSdogmos && gases_registered)
		dogmos_shutdown()
	gases_registered = FALSE
	return ..()

/** Shares gas overlay lists with Dogmos' visual callback. */
/datum/controller/subsystem/dogmos/proc/populate_gas_data_overlays()
	var/list/meta_overlays = GLOB.meta_gas_info[META_GAS_OVERLAY]
	for(var/gas_path in GLOB.gas_data.datums)
		var/datum/gas/gas_instance = GLOB.gas_data.datums[gas_path]
		var/list/overlay_table = meta_overlays[gas_path]
		if(length(overlay_table))
			GLOB.gas_data.overlays[gas_instance.id] = overlay_table

/// Reinforced floors keep their surface during Dogmos decompression events.
/turf/open/floor/engine
	decompression_floor_rip_resistant = TRUE

/turf/open/floor/plating/reinforced
	decompression_floor_rip_resistant = TRUE
