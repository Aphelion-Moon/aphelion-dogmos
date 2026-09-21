/// Returns whether dogmosd remains healthy.
/datum/controller/subsystem/air/proc/thread_running()
	return SSdogmos.service_ready && dogmos_service_health()

/// Refreshes reaction metadata only during initialization in the service backend.
/datum/controller/subsystem/air/proc/auxtools_update_reactions()
	CRASH("Mid-round Dogmos reaction metadata replacement is unsupported.")

/// Legacy gas registration is replaced by the atomic metadata install.
/proc/_auxtools_register_gas(gas)
	CRASH("Per-gas Dogmos registration is unsupported; use atomic metadata install.")

/// Legacy gas reference finalization is replaced by the atomic metadata install.
/proc/finalize_gas_refs()
	return TRUE

/// Parsing gas strings remains blocked until its service command is added.
/datum/gas_mixture/proc/__auxtools_parse_gas_string(string)
	CRASH("Dogmos service gas-string parsing is not implemented.")

/// Heat graph cardinality is not yet exposed by protocol v6 telemetry.
/proc/dogmos_heat_graph_count()
	return 0

/// Heat graph registration totals are not yet exposed by protocol v6 telemetry.
/proc/dogmos_heat_registration_total()
	return 0

/// Space-boundary cardinality is not yet exposed by protocol v6 telemetry.
/proc/dogmos_space_boundary_count()
	return 0
