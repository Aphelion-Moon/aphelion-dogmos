/** Returns the loaded platform shim name for legacy diagnostics. */
/proc/__detect_dogmos()
	return world.system_type == UNIX ? "libdogmos" : "dogmos"

/** Returns the first exact mismatch between the loaded shim and generated contract.
 * Arguments:
 * * actual_abi_version - ABI reported by the loaded shim.
 * * actual_protocol_version - Protocol reported by the loaded shim.
 * * actual_source_revision - Source revision reported by the loaded shim.
 * * actual_feature_fingerprint - Feature fingerprint reported by the loaded shim.
 */
/proc/dogmos_contract_identity_error(actual_abi_version, actual_protocol_version, actual_source_revision, actual_feature_fingerprint)
	if(actual_abi_version != DOGMOS_CONTRACT_ABI_VERSION)
		return "Dogmos ABI mismatch: expected [DOGMOS_CONTRACT_ABI_VERSION], actual [actual_abi_version]."
	if(actual_protocol_version != DOGMOS_CONTRACT_PROTOCOL_VERSION)
		return "Dogmos protocol mismatch: expected [DOGMOS_CONTRACT_PROTOCOL_VERSION], actual [actual_protocol_version]."
	if(actual_source_revision != DOGMOS_CONTRACT_SOURCE_REVISION)
		return "Dogmos source revision mismatch: expected [DOGMOS_CONTRACT_SOURCE_REVISION], actual [actual_source_revision]."
	if(actual_feature_fingerprint != DOGMOS_CONTRACT_FEATURE_FINGERPRINT)
		return "Dogmos feature fingerprint mismatch: expected [DOGMOS_CONTRACT_FEATURE_FINGERPRINT], actual [actual_feature_fingerprint]."
	return null

/** Starts dogmosd, validates the generated contract, and installs metadata. */
/proc/auxtools_atmos_init(gas_data)
	SSdogmos.service_failure_latched = FALSE
	SSdogmos.service_shutdown_requested = FALSE
	var/contract_protocol_version = DOGMOS_CONTRACT_PROTOCOL_VERSION
	if(contract_protocol_version != DOGMOS_REQUIRED_PROTOCOL_VERSION)
		stack_trace("Dogmos contract protocol [DOGMOS_CONTRACT_PROTOCOL_VERSION] is stale; protocol [DOGMOS_REQUIRED_PROTOCOL_VERSION] is required.")
		return FALSE
	var/identity_error = dogmos_contract_identity_error(
		dogmos_abi_version(),
		dogmos_protocol_version(),
		dogmos_source_revision(),
		dogmos_feature_fingerprint(),
	)
	if(identity_error)
		stack_trace(identity_error)
		return FALSE

	var/service_path = world.system_type == UNIX ? "./dogmosd" : "./dogmosd.exe"
	if(!dogmos_service_start(service_path) || !dogmos_service_health())
		stack_trace("dogmosd failed its startup health check.")
		return FALSE

	SSdogmos.service_ready = TRUE
	SSdogmos.dogmos_next_callback_sequence = list(1, 0, 0, 0)
	SSdogmos.dogmos_pending_callback_batch = null
	SSdogmos.dogmos_pending_callback_index = 0
	SSdogmos.dogmos_pending_service_callbacks = 0
	SSdogmos.dogmos_stale_callback_count = 0
	SSdogmos.dogmos_health_preflight_count = 0
	SSdogmos.dogmos_runtime_topology_records = 0
	SSdogmos.dogmos_runtime_topology_calls = 0
	SSdogmos.dogmos_runtime_topology_max_queued = 0
	SSdogmos.dogmos_runtime_topology_deferrals = 0
	SSdogmos.reset_mixture_snapshot_cache()
	SSdogmos.dogmos_gas_ids = list()
	SSdogmos.dogmos_gas_paths = list()
	var/list/numeric_records = list()
	var/list/keys = list()
	var/list/names = list()
	var/gas_id = 0
	for(var/gas_path in GLOB.gas_data.datums)
		var/datum/gas/gas = GLOB.gas_data.datums[gas_path]
		SSdogmos.dogmos_gas_ids[gas_path] = gas_id
		SSdogmos.dogmos_gas_ids[gas.id] = gas_id
		SSdogmos.dogmos_gas_paths += gas_path
		keys += gas.id
		names += gas.name
		numeric_records += list(gas_id, 0, 0, gas.specific_heat, gas.fusion_power, !isnull(gas.moles_visible), gas.moles_visible || 0, 0, 0, 0, 0, 0, 0)
		gas_id++

	if(dogmos_gas_metadata_install(numeric_records, keys, names, list()) != gas_id)
		stack_trace("dogmosd rejected the gas metadata registry.")
		dogmos_service_shutdown()
		SSdogmos.service_ready = FALSE
		return FALSE

	var/list/reaction_records = list()
	var/list/reaction_keys = list()
	var/list/requirement_records = list()
	SSdogmos.dogmos_reaction_ids = SSair.dogmos_reactions.Copy()
	for(var/reaction_id in 1 to length(SSair.dogmos_reactions))
		var/datum/gas_reaction/standard/reaction = SSair.dogmos_reactions[reaction_id]
		var/execution = 0
		switch(reaction.type)
			if(/datum/gas_reaction/standard/plasmafire)
				execution = DOGMOS_REACTION_PLASMA
			if(/datum/gas_reaction/standard/h2fire)
				execution = DOGMOS_REACTION_HYDROGEN
			if(/datum/gas_reaction/standard/tritfire)
				execution = DOGMOS_REACTION_TRITIUM
			if(/datum/gas_reaction/standard/freonfire)
				execution = DOGMOS_REACTION_FREON

		var/minimum_temperature = reaction.min_requirements["TEMP"]
		var/maximum_temperature = reaction.min_requirements["MAX_TEMP"]
		var/minimum_energy = reaction.min_requirements["ENER"]
		var/minimum_fire_reagents = reaction.min_requirements["FIRE_REAGENTS"]
		reaction_records += list(
			(reaction_id - 1) % 65536,
			floor((reaction_id - 1) / 65536),
			execution,
			reaction.priority,
			!isnull(minimum_temperature),
			minimum_temperature || 0,
			!isnull(maximum_temperature),
			maximum_temperature || 0,
			!isnull(minimum_energy),
			minimum_energy || 0,
			!isnull(minimum_fire_reagents),
			minimum_fire_reagents || 0,
		)
		reaction_keys += reaction.id
		for(var/requirement in reaction.min_requirements)
			if(requirement == "TEMP" || requirement == "MAX_TEMP" || requirement == "ENER" || requirement == "FIRE_REAGENTS")
				continue
			var/requirement_gas_id = SSdogmos.dogmos_gas_ids[requirement]
			if(isnull(requirement_gas_id))
				CRASH("Dogmos reaction [reaction.id] references unknown gas [requirement].")
			requirement_records += list(reaction_id - 1, requirement_gas_id, reaction.min_requirements[requirement])

	if(dogmos_reaction_metadata_install(reaction_records, reaction_keys, requirement_records) != length(SSair.dogmos_reactions))
		stack_trace("dogmosd rejected the reaction metadata registry.")
		dogmos_service_shutdown()
		SSdogmos.service_ready = FALSE
		return FALSE
	return TRUE

/** Closes admission before service teardown, including for suspended map-loading producers. */
/datum/controller/subsystem/dogmos/proc/begin_service_shutdown()
	service_shutdown_requested = TRUE
	service_ready = FALSE
	SSair?.dogmos_clear_machinery_prefetch()

/** Stops the production service without attempting a mid-round restart. */
/proc/dogmos_shutdown()
	SSdogmos.begin_service_shutdown()
	return dogmos_service_shutdown()
