/** Validates and returns a typed mixture-command response. */
/datum/controller/subsystem/dogmos/proc/mixture_command(list/fields, expected_response)
	if(!service_ready)
		if(!service_failure_latched && !service_shutdown_requested)
			CRASH("dogmosd became unavailable; in-process atmosphere fallback is forbidden.")
		var/failed_length = expected_response == DOGMOS_RESPONSE_REACTION_PROGRESS ? 8 : 4
		var/list/failed_response = new/list(failed_length)
		failed_response[1] = expected_response
		return failed_response
	var/list/response = dogmos_mixture_command(fields)
	var/expected_length = expected_response == DOGMOS_RESPONSE_REACTION_PROGRESS ? 8 : 4
	if(!islist(response) || length(response) != expected_length || response[1] != expected_response)
		CRASH("dogmosd returned malformed mixture response [json_encode(response)].")
	return response

/// Registers this mixture in dogmosd, optionally copying gases and temperature atomically.
/datum/gas_mixture/proc/__gasmixture_register(datum/gas_mixture/copy_source)
	return SSdogmos.register_mixture(src, copy_source)

/// Unregisters this mixture from dogmosd.
/datum/gas_mixture/proc/__gasmixture_unregister()
	return SSdogmos.unregister_mixture(src)

/// Numeric slot used only for bounded IPC identity translation.
/datum/gas_mixture/var/dogmos_slot
/// Generation paired with dogmos_slot to reject stale callbacks.
/datum/gas_mixture/var/dogmos_generation
/// Shared opaque registration token with no reference back to this mixture.
/datum/gas_mixture/var/list/dogmos_identity_token

/** Sends one canonical mixture command to dogmosd. */
/datum/gas_mixture/proc/dogmos_command(kind, flags = 0, datum/gas_mixture/secondary, scalar_one = 0, scalar_two = 0, scalar_three = 0, gas_id = 0, aux = 0, expected_response = DOGMOS_RESPONSE_APPLIED)
	var/secondary_slot = secondary?.dogmos_slot || 0
	var/secondary_generation = secondary?.dogmos_generation || 0
	var/list/response = SSdogmos.mixture_command(list(kind, flags, dogmos_slot, dogmos_generation, secondary_slot, secondary_generation, scalar_one, scalar_two, scalar_three, gas_id, aux), expected_response)
	if(!is_read_only_dogmos_command(kind))
		SSdogmos.evict_mixture_snapshot_cache(dogmos_slot, dogmos_generation)
		if(secondary_slot && !is_read_only_dogmos_secondary(kind))
			SSdogmos.evict_mixture_snapshot_cache(secondary_slot, secondary_generation)
	return response

/** Returns whether a canonical mixture command cannot change either mixture. */
/datum/gas_mixture/proc/is_read_only_dogmos_command(kind)
	switch(kind)
		if(DOGMOS_COMMAND_GET_MOLES, DOGMOS_COMMAND_TEMPERATURE, DOGMOS_COMMAND_VOLUME, DOGMOS_COMMAND_HEAT_CAPACITY, DOGMOS_COMMAND_PARTIAL_HEAT_CAPACITY, DOGMOS_COMMAND_TOTAL_MOLES, DOGMOS_COMMAND_PRESSURE, DOGMOS_COMMAND_THERMAL_ENERGY, DOGMOS_COMMAND_GET_MOLES_BY_FLAGS, DOGMOS_COMMAND_BURNABILITY, DOGMOS_COMMAND_COMPARE, DOGMOS_COMMAND_IS_IMMUTABLE)
			return TRUE
	return FALSE

/** Returns whether a mutating command only reads its secondary mixture. */
/datum/gas_mixture/proc/is_read_only_dogmos_secondary(kind)
	switch(kind)
		if(DOGMOS_COMMAND_COPY_FROM, DOGMOS_COMMAND_CREATE_FROM_SOURCE, DOGMOS_COMMAND_EQUALIZE_WITH, DOGMOS_COMMAND_MERGE)
			return TRUE
	return FALSE

/** Returns the common service snapshot for this exact mixture handle. */
/datum/gas_mixture/proc/dogmos_snapshot()
	return SSdogmos.mixture_snapshot(dogmos_slot, dogmos_generation)

/** Reconciles a pipenet's mixtures through one service-owned native transaction.
 *
 * Arguments:
 * * gas_mixture_list - Candidate mixtures gathered from the pipenet and custom reconcilers.
 */
/proc/dogmos_reconcile_pipeline_mixtures(list/datum/gas_mixture/gas_mixture_list)
	if(!SSdogmos.service_ready)
		return
	var/static/process_id = 0
	process_id = WRAP_UID(process_id + 1)
	var/list/datum/gas_mixture/unique_mixtures = list()
	var/list/request_fields = list()
	for(var/datum/gas_mixture/gas_mixture as anything in gas_mixture_list)
		if(gas_mixture.pipeline_cycle == process_id)
			continue
		gas_mixture.pipeline_cycle = process_id
		unique_mixtures += gas_mixture
		request_fields += gas_mixture.dogmos_slot
		request_fields += gas_mixture.dogmos_generation

	if(!length(unique_mixtures))
		return
	var/list/response_fields = dogmos_pipenet_reconcile(request_fields)
	var/expected_response_fields = length(unique_mixtures) * DOGMOS_PIPENET_RECONCILE_RECORD_FIELDS
	if(!islist(response_fields) || length(response_fields) != expected_response_fields)
		CRASH("dogmosd returned a malformed pipenet reconciliation response: got [islist(response_fields) ? length(response_fields) : "not a list"] fields, expected [expected_response_fields].")

	for(var/mixture_index in 1 to length(unique_mixtures))
		var/datum/gas_mixture/gas_mixture = unique_mixtures[mixture_index]
		var/record_start = (mixture_index - 1) * DOGMOS_PIPENET_RECONCILE_RECORD_FIELDS + 1
		var/slot = response_fields[record_start]
		var/generation = response_fields[record_start + 1]
		if(slot != gas_mixture.dogmos_slot || generation != gas_mixture.dogmos_generation)
			CRASH("dogmosd returned pipenet mixture [slot]:[generation] at index [mixture_index], expected [gas_mixture.dogmos_slot]:[gas_mixture.dogmos_generation].")
		var/list/snapshot = response_fields.Copy(record_start + 2, record_start + DOGMOS_PIPENET_RECONCILE_RECORD_FIELDS)
		SSdogmos.store_mixture_snapshot_cache(slot, generation, snapshot)

/// Returns the numeric gas id installed for a native string id.
/datum/gas_mixture/proc/dogmos_gas_id(gas_id)
	var/numeric_id = SSdogmos.dogmos_gas_ids[gas_id]
	if(isnull(numeric_id))
		CRASH("Unknown Dogmos gas id [gas_id].")
	return numeric_id

/// Sets the moles of one native string gas id.
/datum/gas_mixture/proc/__set_moles(gas_id, amount)
	return dogmos_command(DOGMOS_COMMAND_SET_MOLES, gas_id = dogmos_gas_id(gas_id), scalar_one = amount)[2]

/// Adjusts the moles of one native string gas id.
/datum/gas_mixture/proc/__adjust_moles(gas_id, amount)
	return dogmos_command(DOGMOS_COMMAND_ADJUST_MOLES, gas_id = dogmos_gas_id(gas_id), scalar_one = amount)[2]

/// Adjusts one gas while accounting for its source temperature.
/datum/gas_mixture/proc/__adjust_moles_temp(gas_id, amount, temperature)
	return dogmos_command(DOGMOS_COMMAND_ADJUST_MOLES_TEMPERATURE, gas_id = dogmos_gas_id(gas_id), scalar_one = amount, scalar_two = temperature)[2]

/// Returns the moles of one native string gas id.
/datum/gas_mixture/proc/__get_moles(gas_id)
	return dogmos_snapshot()[DOGMOS_MIXTURE_SNAPSHOT_GASES_START + dogmos_gas_id(gas_id)]

/// Returns one gas's partial heat capacity.
/datum/gas_mixture/proc/__partial_heat_capacity(gas_id)
	return dogmos_command(DOGMOS_COMMAND_PARTIAL_HEAT_CAPACITY, gas_id = dogmos_gas_id(gas_id), expected_response = DOGMOS_RESPONSE_SCALAR)[2]

/// Applies native string gas id and delta pairs in one bounded request.
/datum/gas_mixture/proc/__adjust_multi(...)
	if(!SSdogmos.service_ready)
		return 0
	var/list/fields = list(dogmos_slot, dogmos_generation)
	for(var/index in 1 to length(args) step 2)
		fields += dogmos_gas_id(args[index])
		fields += args[index + 1]
	var/list/response = dogmos_mixture_adjust_multiple(fields)
	if(!islist(response) || response[1] != DOGMOS_RESPONSE_APPLIED)
		CRASH("dogmosd rejected a multi-gas adjustment.")
	SSdogmos.evict_mixture_snapshot_cache(dogmos_slot, dogmos_generation)
	return response[2]

/// Returns the native string ids currently present in this mixture.
/datum/gas_mixture/proc/__get_gases()
	var/list/snapshot = dogmos_snapshot()
	var/list/gases = list()
	for(var/gas_index in 1 to min(snapshot[DOGMOS_MIXTURE_SNAPSHOT_GAS_COUNT], length(SSdogmos.dogmos_gas_paths)))
		if(snapshot[DOGMOS_MIXTURE_SNAPSHOT_GASES_START + gas_index - 1] > 0)
			var/gas_path = SSdogmos.dogmos_gas_paths[gas_index]
			gases += GLOB.meta_gas_info[META_GAS_ID][gas_path]
	return gases

/// Sets the mixture temperature.
/datum/gas_mixture/proc/set_temperature(temperature)
	return dogmos_command(DOGMOS_COMMAND_SET_TEMPERATURE, scalar_one = temperature)[2]

/// Returns the mixture temperature.
/datum/gas_mixture/proc/return_temperature()
	return dogmos_snapshot()[DOGMOS_MIXTURE_SNAPSHOT_TEMPERATURE]

/// Sets the mixture volume.
/datum/gas_mixture/proc/set_volume(volume)
	return dogmos_command(DOGMOS_COMMAND_SET_VOLUME, scalar_one = volume)[2]

/// Returns the mixture volume.
/datum/gas_mixture/proc/return_volume()
	return dogmos_snapshot()[DOGMOS_MIXTURE_SNAPSHOT_VOLUME]

/// Returns the mixture heat capacity.
/datum/gas_mixture/proc/heat_capacity()
	return dogmos_snapshot()[DOGMOS_MIXTURE_SNAPSHOT_HEAT_CAPACITY]

/// Returns the mixture total moles.
/datum/gas_mixture/proc/total_moles()
	return dogmos_snapshot()[DOGMOS_MIXTURE_SNAPSHOT_TOTAL_MOLES]

/// Returns the mixture pressure.
/datum/gas_mixture/proc/return_pressure()
	return dogmos_snapshot()[DOGMOS_MIXTURE_SNAPSHOT_PRESSURE]

/// Returns the mixture thermal energy.
/datum/gas_mixture/proc/thermal_energy()
	var/list/snapshot = dogmos_snapshot()
	return snapshot[DOGMOS_MIXTURE_SNAPSHOT_TEMPERATURE] * snapshot[DOGMOS_MIXTURE_SNAPSHOT_HEAT_CAPACITY]

/// Sets the mixture minimum heat capacity.
/datum/gas_mixture/proc/set_min_heat_capacity(amount)
	return dogmos_command(DOGMOS_COMMAND_SET_MINIMUM_HEAT_CAPACITY, scalar_one = amount)[2]

/// Clears all gases from this mixture.
/datum/gas_mixture/proc/clear()
	return dogmos_command(DOGMOS_COMMAND_CLEAR)[2]

/// Adds an amount to every present gas.
/datum/gas_mixture/proc/add(amount)
	return dogmos_command(DOGMOS_COMMAND_ADD, scalar_one = amount)[2]

/// Subtracts an amount from every present gas.
/datum/gas_mixture/proc/subtract(amount)
	return dogmos_command(DOGMOS_COMMAND_ADD, scalar_one = -amount)[2]

/// Multiplies all gases by a coefficient.
/datum/gas_mixture/proc/multiply(coefficient)
	return dogmos_command(DOGMOS_COMMAND_MULTIPLY, scalar_one = coefficient)[2]

/// Divides all gases by a coefficient.
/datum/gas_mixture/proc/divide(coefficient)
	return dogmos_command(DOGMOS_COMMAND_MULTIPLY, scalar_one = 1 / coefficient)[2]

/// Copies the giver mixture into this mixture.
/datum/gas_mixture/proc/copy_from(datum/gas_mixture/giver)
	return dogmos_command(DOGMOS_COMMAND_COPY_FROM, secondary = giver)[2]

/// Merges the giver mixture into this mixture.
/datum/gas_mixture/proc/__merge(datum/gas_mixture/giver)
	return dogmos_command(DOGMOS_COMMAND_MERGE, secondary = giver)[2]

/// Removes an amount into another mixture.
/datum/gas_mixture/proc/__remove(datum/gas_mixture/into, amount)
	return dogmos_command(DOGMOS_COMMAND_REMOVE_AMOUNT_INTO, secondary = into, scalar_one = amount)[2]

/// Removes a ratio into another mixture.
/datum/gas_mixture/proc/__remove_ratio(datum/gas_mixture/into, ratio)
	return dogmos_command(DOGMOS_COMMAND_REMOVE_RATIO_INTO, secondary = into, scalar_one = ratio)[2]

/// Transfers an amount into another mixture.
/datum/gas_mixture/proc/transfer_to(datum/gas_mixture/other, amount)
	return dogmos_command(DOGMOS_COMMAND_TRANSFER_AMOUNT, secondary = other, scalar_one = amount)[2]

/// Transfers a ratio into another mixture.
/datum/gas_mixture/proc/transfer_ratio_to(datum/gas_mixture/other, ratio)
	return dogmos_command(DOGMOS_COMMAND_TRANSFER_RATIO, secondary = other, scalar_one = ratio)[2]

/// Adds thermal energy to this mixture.
/datum/gas_mixture/proc/adjust_heat(heat)
	return dogmos_command(DOGMOS_COMMAND_ADJUST_HEAT, scalar_one = heat)[2]

/** Returns whether another mixture differs enough to process.
 * Computed locally from the two mixtures' cached snapshots instead of a dogmosd round trip.
 * compare() is pure arithmetic over already-fetched scalar/gas data - routing it through
 * dogmos_command() correctly avoided evicting the read cache (it's in
 * is_read_only_dogmos_command()) but never actually served from it either, so every call paid a
 * full mutex acquire, two shim allocations, two channel handoffs, and a blocking pipe round trip.
 * turf_settled() calls this once per open neighbor of every active turf, every tick - at a few
 * hundred active turfs that's on the order of a thousand uncached round trips/tick, and eating
 * enough of the tick budget there that remove_from_active() (the only path that ever shrinks
 * active_turfs in steady-state play) got starved, which read as active_turfs never settling.
 * Mirrors Command::Compare in world.rs exactly: temperature check gates on total moles too, and
 * (unlike Rust, which always evaluates both regardless) short-circuits once either check finds a
 * difference, since OR doesn't care which side proved it.
 */
/datum/gas_mixture/proc/compare(datum/gas_mixture/other)
	var/list/snapshot = dogmos_snapshot()
	var/list/other_snapshot = other.dogmos_snapshot()
	if(abs(snapshot[DOGMOS_MIXTURE_SNAPSHOT_TEMPERATURE] - other_snapshot[DOGMOS_MIXTURE_SNAPSHOT_TEMPERATURE]) > DOGMOS_COMPARE_MINIMUM_TEMPERATURE_DELTA \
			&& snapshot[DOGMOS_MIXTURE_SNAPSHOT_TOTAL_MOLES] > DOGMOS_COMPARE_MINIMUM_MOLES_DELTA)
		return TRUE
	for(var/i in DOGMOS_MIXTURE_SNAPSHOT_GASES_START to DOGMOS_MIXTURE_SNAPSHOT_FIELDS)
		if(abs(snapshot[i] - other_snapshot[i]) >= DOGMOS_COMPARE_MINIMUM_MOLES_DELTA)
			return TRUE
	return FALSE

/// Makes this mixture identical to a volume-scaled total mixture.
/datum/gas_mixture/proc/equalize_with(datum/gas_mixture/total)
	return dogmos_command(DOGMOS_COMMAND_EQUALIZE_WITH, secondary = total)[2]

/// Returns whether this mixture is immutable.
/datum/gas_mixture/proc/is_immutable()
	return dogmos_immutable

/// Marks this mixture immutable.
/datum/gas_mixture/proc/mark_immutable()
	var/updated = dogmos_command(DOGMOS_COMMAND_MARK_IMMUTABLE)[2]
	dogmos_immutable = TRUE
	return updated

/// Returns the oxidation power at an optional temperature.
/datum/gas_mixture/proc/get_oxidation_power(temperature)
	var/has_temperature = !isnull(temperature)
	return dogmos_command(DOGMOS_COMMAND_BURNABILITY, flags = has_temperature, scalar_one = temperature || 0, expected_response = DOGMOS_RESPONSE_SCALARS)[2]

/// Returns the fuel amount at an optional temperature.
/datum/gas_mixture/proc/get_fuel_amount(temperature)
	var/has_temperature = !isnull(temperature)
	return dogmos_command(DOGMOS_COMMAND_BURNABILITY, flags = has_temperature, scalar_one = temperature || 0, expected_response = DOGMOS_RESPONSE_SCALARS)[3]

/// Shares temperature with either a mixture or a non-gas heat capacity.
/datum/gas_mixture/proc/temperature_share(...)
	if(istype(args[1], /datum/gas_mixture))
		return dogmos_command(DOGMOS_COMMAND_TEMPERATURE_SHARE, secondary = args[1], scalar_one = args[2], expected_response = DOGMOS_RESPONSE_SCALAR)[2]
	return dogmos_command(DOGMOS_COMMAND_TEMPERATURE_SHARE_NON_GAS, scalar_one = args[1], scalar_two = args[2], scalar_three = args[3], expected_response = DOGMOS_RESPONSE_SCALAR)[2]

/// Returns gas paths whose installed flags overlap the requested mask.
/datum/gas_mixture/proc/get_by_flag(flag)
	return list()

/// Transfers flagged gases into another mixture.
/datum/gas_mixture/proc/__remove_by_flag(datum/gas_mixture/into, flag, amount)
	return dogmos_command(DOGMOS_COMMAND_TRANSFER_BY_FLAGS, flags = flag, secondary = into, scalar_one = amount)[2]

/// Transfers selected gas paths into another mixture.
/datum/gas_mixture/proc/scrub_into(datum/gas_mixture/into, ratio, list/gas_list)
	var/gas_mask = 0
	for(var/gas_path in gas_list)
		gas_mask |= 2 ** dogmos_gas_id(gas_string_id(gas_path))
	return dogmos_command(DOGMOS_COMMAND_TRANSFER_GASES, secondary = into, scalar_one = ratio, aux = gas_mask)[2]

/// Runs the complete native and DM reaction sequence through dogmosd.
/datum/gas_mixture/proc/__react(datum/holder)
	if(!SSdogmos.service_ready)
		return NO_REACTION
	if(get_moles(/datum/gas/hypernoblium) >= REACTION_OPPRESSION_THRESHOLD && return_temperature() > REACTION_OPPRESSION_MIN_TEMP)
		return STOP_REACTIONS
	var/reaction_profile_threshold_ms
	if(SSair.kennel_profile_reactions)
		if(!IS_FINITE(SSair.kennel_high_cost_ms_threshold) || SSair.kennel_high_cost_ms_threshold < 0)
			CRASH("Dogmos reaction profiling received an invalid cost threshold.")
		reaction_profile_threshold_ms = SSair.kennel_high_cost_ms_threshold
	var/list/holder_handle = SSdogmos.register_holder(holder)
	var/list/progress = SSdogmos.mixture_command(list(DOGMOS_COMMAND_REACT, !isnull(reaction_profile_threshold_ms), dogmos_slot, dogmos_generation, holder_handle[1], holder_handle[2], reaction_profile_threshold_ms || 0, 0, 0, 0, 0), DOGMOS_RESPONSE_REACTION_PROGRESS)
	progress = SSdogmos.dispatch_reaction_callbacks(src, progress, reaction_profile_threshold_ms)
	SSdogmos.evict_mixture_snapshot_cache(dogmos_slot, dogmos_generation)
	SSdogmos.unregister_holder(holder_handle)
	return progress[2]

/// Equalizes a bounded list through service-owned mixture commands.
/proc/equalize_all_gases_in_list(list/gas_list)
	if(!length(gas_list))
		return
	var/datum/gas_mixture/total = new(CELL_VOLUME)
	for(var/datum/gas_mixture/mixture as anything in gas_list)
		total.merge(mixture)
	for(var/datum/gas_mixture/mixture as anything in gas_list)
		mixture.equalize_with(total)
	qdel(total)
