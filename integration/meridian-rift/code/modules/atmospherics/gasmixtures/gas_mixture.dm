/* Dogmos owns gas storage and math in Rust; this datum preserves the DM API. */

GLOBAL_LIST_INIT(meta_gas_info, meta_gas_list()) //see ATMOSPHERICS/gas_types.dm

/datum/gas_mixture
	/// DM-side gas metadata such as names, icons, and specific heats.
	var/static/list/gas_meta
	/// Dogmos arena handle. Do not read or write this directly.
	var/_extools_pointer_gasmixture
	/// Initial volume passed to Dogmos during registration.
	var/initial_volume = CELL_VOLUME
	/// The last tick this gas mixture shared on. A counter that turfs use to manage activity
	var/last_share = 0
	/// Tells us what reactions have happened in our gasmix. Assoc list of reaction - moles reacted pair.
	var/list/reaction_results
	/// When this gas mixture was last touched by pipeline processing.
	var/pipeline_cycle = -1
	// APHELION EDIT ADDITION START - DOGMOS
	/// Whether Dogmos has accepted this mixture's monotonic immutable finalization.
	var/dogmos_immutable = FALSE
	// APHELION EDIT ADDITION END

/datum/gas_mixture/New(volume, datum/gas_mixture/copy_source) // APHELION EDIT CHANGE - DOGMOS_COPY_CREATION
	if(!isnull(volume))
		initial_volume = volume
	if(initial_volume <= 0)
		stack_trace("Created a gas mixture with zero volume!")
#ifdef DOGMOS_IN_PROCESS
	__gasmixture_register()
	if(copy_source)
		copy_from(copy_source)
#else
	__gasmixture_register(copy_source) // APHELION EDIT CHANGE - DOGMOS_COPY_CREATION
#endif
	reaction_results = new

/datum/gas_mixture/Del()
	if(!isnull(_extools_pointer_gasmixture))
		__gasmixture_unregister()
	return ..()

/// Turf mixtures retain a non-zero vacuum heat capacity.
/datum/gas_mixture/turf/heat_capacity()
	return ..() || HEAT_CAPACITY_VACUUM

/// Converts a DM gas typepath to Dogmos' string identifier.
/proc/gas_string_id(gas_id)
	// Warn once if a gas crosses the FFI before the registry is ready.
	if(!SSdogmos?.gases_registered)
		var/static/warned_before_registration = FALSE
		if(!warned_before_registration)
			warned_before_registration = TRUE
			stack_trace("A gas id was handed to Dogmos before SSdogmos finished registering the gas table. Dogmos will reject it and the mixture will stay empty. Check subsystem init order.")

	if(istext(gas_id))
		return gas_id
	return GLOB.meta_gas_info[META_GAS_ID][gas_id]

/// Keeps the legacy archive API available; Dogmos archives during turf processing.
/datum/gas_mixture/proc/archive()
	return TRUE //Dogmos archives internally during turf processing; nothing for DM to do here

/// Returns the moles for a gas typepath or Dogmos string id.
/datum/gas_mixture/proc/get_moles(gas_id)
	return __get_moles(gas_string_id(gas_id))

/// Sets the moles for a gas typepath or Dogmos string id.
/datum/gas_mixture/proc/set_moles(gas_id, amt_val)
	return __set_moles(gas_string_id(gas_id), amt_val)

// APHELION EDIT ADDITION START - DOGMOS
/// Preserves upstream's setter API while keeping gas storage owned by Dogmos.
/datum/gas_mixture/proc/set_gas(gas_specie, amount)
	set_moles(gas_specie, amount)
// APHELION EDIT ADDITION END

/// Adjusts a gas amount; accepts a typepath or Dogmos string id.
/datum/gas_mixture/proc/adjust_moles(id_val, num_val)
	return __adjust_moles(gas_string_id(id_val), num_val)

/// Adjusts a gas amount at a supplied temperature.
/datum/gas_mixture/proc/adjust_moles_temp(id_val, num_val, temp_val)
	return __adjust_moles_temp(gas_string_id(id_val), num_val, temp_val)

/// Returns a gas's heat capacity.
/datum/gas_mixture/proc/partial_heat_capacity(gas_id)
	return __partial_heat_capacity(gas_string_id(gas_id))

/// Adjusts multiple gases from alternating gas ids and amounts.
/datum/gas_mixture/proc/adjust_multi(...)
	var/list/args_copy = args.Copy()
	for(var/i in 1 to args_copy.len step 2)
		args_copy[i] = gas_string_id(args_copy[i])
	// __adjust_multi() reads dogmos_slot/dogmos_generation off its own src (this same mixture) -
	// it does not expect src prepended into args. Inserting it here shifted every gas_id/amount
	// pair by one, so __adjust_multi() tried to treat the mixture reference itself as a gas id
	// ("Unknown Dogmos gas id /datum/gas_mixture.") and walked off the end of the pair list.
	return __adjust_multi(arglist(args_copy))

/// Returns the typepaths of all gases present in the mixture.
/datum/gas_mixture/proc/get_gases()
	var/list/ids = __get_gases()
	var/list/paths = new/list(length(ids))
	for(var/i in 1 to length(ids))
		paths[i] = gas_id2path(ids[i])
	return paths

///Merges all air from giver into self. Deletes giver. Returns: 1 if we are mutable, 0 otherwise
/datum/gas_mixture/proc/merge(datum/gas_mixture/giver)
	if(is_immutable() || !giver)
		return FALSE
	__merge(giver)
	SEND_SIGNAL(src, COMSIG_GASMIX_MERGED)
	return TRUE

/// Add a specific amount of moles to specified gas or add a new gas to the mix
/// amount is added so make it negative to remove
/datum/gas_mixture/proc/adjust_gas(gas, amount)
	adjust_moles(gas, QUANTIZE(amount))

/// Add a specific amount of moles to all the gasses present or add a new gas to the mix
///gases_moles is an associative list of gas species to their amount to be added
/datum/gas_mixture/proc/adjust_multiple_gases(list/gases_moles)
	var/list/args_list = list()
	for(var/gas_id, value in gases_moles)
		args_list += list(gas_id, value)
	if(length(args_list))
		adjust_multi(arglist(args_list))

/// Modify the gas list as to convert moles of gas species A to gas species B
/// reactant and product are the gas species to convert and conversion_amount is the amount to be converted
/datum/gas_mixture/proc/convert_gas(datum/gas/reactant, datum/gas/product, conversion_amount)
	conversion_amount = QUANTIZE(conversion_amount)
	adjust_multi(reactant, -conversion_amount, product, conversion_amount)

///Proportionally removes amount of gas from the gas_mixture.
///Returns: gas_mixture with the gases removed, or null if amount <= 0
/datum/gas_mixture/proc/remove(amount)
	if(amount <= 0)
		return null
	var/datum/gas_mixture/removed = new type(return_volume())
	if(is_immutable())
		removed.copy_from(src) //space etc. is inexhaustible; don't drain it
	else
		__remove(removed, amount)
		SEND_SIGNAL(src, COMSIG_GASMIX_REMOVED)
	return removed

///Proportionally removes amount of gas from the gas_mixture.
///Returns: gas_mixture with the gases removed
/datum/gas_mixture/proc/remove_ratio(ratio)
	var/datum/gas_mixture/removed = new type(return_volume())
	if(ratio <= 0)
		return removed
	ratio = min(ratio, 1)
	if(is_immutable())
		removed.copy_from(src) //space etc. is inexhaustible; don't drain it
	else
		__remove_ratio(removed, ratio)
		SEND_SIGNAL(src, COMSIG_GASMIX_REMOVED)
	return removed

///Removes an amount of a specific gas from the gas_mixture.
///Returns: gas_mixture with the gas removed
/datum/gas_mixture/proc/remove_specific(gas_id, amount)
	amount = min(amount, get_moles(gas_id))
	if(amount <= 0)
		return null
	var/datum/gas_mixture/removed = new type
	removed.set_temperature(return_temperature())
	removed.set_moles(gas_id, amount)
	if(!is_immutable())
		adjust_moles(gas_id, -amount)
	return removed

/datum/gas_mixture/proc/remove_specific_ratio(gas_id, ratio)
	if(ratio <= 0)
		return null
	ratio = min(ratio, 1)
	return remove_specific(gas_id, get_moles(gas_id) * ratio)

///Distributes the contents of two mixes equally between themselves
//Returns: bool indicating whether gases moved between the two mixes
/datum/gas_mixture/proc/equalize(datum/gas_mixture/other)
	. = FALSE
	if(abs(return_temperature() - other.return_temperature()) > MINIMUM_TEMPERATURE_DELTA_TO_SUSPEND)
		. = TRUE
		var/self_heat_cap = heat_capacity()
		var/other_heat_cap = other.heat_capacity()
		var/combined_heat_cap = self_heat_cap + other_heat_cap
		if(combined_heat_cap)
			var/new_temp = (return_temperature() * self_heat_cap + other.return_temperature() * other_heat_cap) / combined_heat_cap
			set_temperature(new_temp)
			other.set_temperature(new_temp)

	var/min_p_delta = 0.1
	var/our_volume = return_volume()
	var/other_volume = other.return_volume()
	var/total_volume = our_volume + other_volume
	var/list/gas_list = get_gases() | other.get_gases()
	for(var/gas_id in gas_list)
		var/our_moles = get_moles(gas_id)
		var/their_moles = other.get_moles(gas_id)
		//math is under the assumption temperatures are equal
		if(abs(our_moles / our_volume - their_moles / other_volume) > min_p_delta / (R_IDEAL_GAS_EQUATION * return_temperature()))
			. = TRUE
			var/total_moles = our_moles + their_moles
			set_moles(gas_id, total_moles * (our_volume/total_volume))
			other.set_moles(gas_id, total_moles * (other_volume/total_volume))

///Creates new, identical gas mixture
///Returns: duplicate gas mixture
/datum/gas_mixture/proc/copy()
	// APHELION EDIT ADDITION START - DOGMOS_COPY_CREATION
	// Exact types have no custom constructor or copy hook. Subtypes retain dynamic dispatch below.
	if(type == /datum/gas_mixture || type == /datum/gas_mixture/turf)
		return new type(return_volume(), src)
	// APHELION EDIT ADDITION END
	var/datum/gas_mixture/copy = new type(return_volume())
	copy.copy_from(src)
	return copy

///Copies variables from sample, moles multiplicated by partial
///Returns: TRUE if we are mutable, FALSE otherwise
/datum/gas_mixture/proc/copy_from_ratio(datum/gas_mixture/sample, partial = 1)
	if(is_immutable())
		return FALSE
	copy_from(sample)
	multiply(partial)
	return TRUE

/// Performs air sharing calculations between two gas_mixtures
/// share() is communitive, which means A.share(B) needs to be the same as B.share(A)
/// If we don't retain this, we will get negative moles. Don't do it
/// Returns: amount of gas exchanged (+ if sharer received)
/datum/gas_mixture/proc/share(datum/gas_mixture/sharer, our_coeff, sharer_coeff)
	// Remaining callers are non-turf equipment; turf sharing is handled by Dogmos.
	var/list/our_gases = get_gases()
	var/list/sharer_gases = sharer.get_gases()
	var/list/gas_list = our_gases | sharer_gases

	var/temperature_delta = return_temperature() - sharer.return_temperature()
	var/temp_delta_threshold = abs(temperature_delta) > MINIMUM_TEMPERATURE_DELTA_TO_CONSIDER

	var/old_self_heat_capacity = 0
	var/old_sharer_heat_capacity = 0
	if(temp_delta_threshold)
		old_self_heat_capacity = heat_capacity()
		old_sharer_heat_capacity = sharer.heat_capacity()

	var/heat_capacity_self_to_sharer = 0 //heat capacity of the moles transferred from us to the sharer
	var/heat_capacity_sharer_to_self = 0 //heat capacity of the moles transferred from the sharer to us

	var/moved_moles = 0
	var/abs_moved_moles = 0

	var/list/cached_specific_heat = GAS_META[META_GAS_SPECIFIC_HEAT]
	// Deltas are collected and applied as two batched IPC calls after the loop instead of two
	// adjust_moles() round trips per gas type inside it - share() is called per machine, per tick,
	// so an unbatched loop here was doubling the pipenet reconciliation IPC cost.
	var/list/self_deltas = list()
	var/list/sharer_deltas = list()
	for(var/gas_id in gas_list) //transfer gases
		var/our_moles = get_moles(gas_id)
		var/sharer_moles = sharer.get_moles(gas_id)
		var/delta = QUANTIZE(our_moles - sharer_moles) //the amount of gas that gets moved between the mixtures

		if(!delta)
			continue

		// If we have more gas then they do, gas is moving from us to them
		// This means we want to scale it by our coeff. Vis versa for their case
		if(delta > 0)
			delta = delta * our_coeff
		else
			delta = delta * sharer_coeff

		if(temp_delta_threshold)
			var/gas_heat_capacity = delta * cached_specific_heat[gas_id]
			if(delta > 0)
				heat_capacity_self_to_sharer += gas_heat_capacity
			else
				heat_capacity_sharer_to_self -= gas_heat_capacity //subtract here instead of adding the absolute value because we know that delta is negative.

		self_deltas += list(gas_id, -delta)
		sharer_deltas += list(gas_id, delta)
		moved_moles += delta
		abs_moved_moles += abs(delta)

	if(length(self_deltas))
		adjust_multi(arglist(self_deltas))
	if(length(sharer_deltas))
		sharer.adjust_multi(arglist(sharer_deltas))

	last_share = abs_moved_moles

	//THERMAL ENERGY TRANSFER
	if(temp_delta_threshold)
		var/new_self_heat_capacity = old_self_heat_capacity + heat_capacity_sharer_to_self - heat_capacity_self_to_sharer
		var/new_sharer_heat_capacity = old_sharer_heat_capacity + heat_capacity_self_to_sharer - heat_capacity_sharer_to_self

		//transfer of thermal energy (via changed heat capacity) between self and sharer
		if(new_self_heat_capacity > MINIMUM_HEAT_CAPACITY)
			set_temperature((old_self_heat_capacity*return_temperature() - heat_capacity_self_to_sharer*return_temperature() + heat_capacity_sharer_to_self*sharer.return_temperature())/new_self_heat_capacity)

		if(new_sharer_heat_capacity > MINIMUM_HEAT_CAPACITY)
			sharer.set_temperature((old_sharer_heat_capacity*sharer.return_temperature()-heat_capacity_sharer_to_self*sharer.return_temperature() + heat_capacity_self_to_sharer*return_temperature())/new_sharer_heat_capacity)
		//thermal energy of the system (self and sharer) is unchanged

			if(abs(old_sharer_heat_capacity) > MINIMUM_HEAT_CAPACITY)
				if(abs(new_sharer_heat_capacity/old_sharer_heat_capacity - 1) < 0.1) // <10% change in sharer heat capacity
					temperature_share(sharer, OPEN_HEAT_TRANSFER_COEFFICIENT)

	if(temperature_delta > MINIMUM_TEMPERATURE_TO_MOVE || abs(moved_moles) > MINIMUM_MOLES_DELTA_TO_MOVE)
		var/our_moles = total_moles()
		var/their_moles = sharer.total_moles()
		return (return_temperature()*(our_moles + moved_moles) - sharer.return_temperature()*(their_moles - moved_moles)) * R_IDEAL_GAS_EQUATION / return_volume()

///Performs various reactions such as combustion and fabrication
///Returns: 1 if any reaction took place; 0 otherwise
/datum/gas_mixture/proc/react(datum/holder)
	if(is_immutable())
		return NO_REACTION

	// Keep this cheap wrapper gate for direct DM callers; the native hook mirrors it for Dogmos callers.
	if(get_moles(/datum/gas/hypernoblium) >= REACTION_OPPRESSION_THRESHOLD && return_temperature() > REACTION_OPPRESSION_MIN_TEMP)
		return STOP_REACTIONS

	reaction_results = new
	. = __react(holder)

	if(.) //If we changed the mix to any degree
		SEND_SIGNAL(src, COMSIG_GASMIX_REACTED)

/**
 * Returns the partial pressure of the gas in the breath based on BREATH_VOLUME
 * eg:
 * Plas_PP = get_breath_partial_pressure(gas_mixture.get_moles(/datum/gas/plasma))
 * O2_PP = get_breath_partial_pressure(gas_mixture.get_moles(/datum/gas/oxygen))
 * get_breath_partial_pressure(gas_mole_count) --> PV = nRT, P = nRT/V
 *
 * 10/20*5 = 2.5
 * 10 = 2.5/5*20
 */

/datum/gas_mixture/proc/get_breath_partial_pressure(gas_mole_count)
	return (gas_mole_count * R_IDEAL_GAS_EQUATION * return_temperature()) / BREATH_VOLUME

/**
 * Counts how much pressure will there be if we impart MOLAR_ACCURACY amounts of our gas to the output gasmix.
 * We do all of this without actually transferring it so don't worry about it changing the gasmix.
 * Returns: Resulting pressure (number).
 * Args:
 * - output_air (gasmix).
 */
/datum/gas_mixture/proc/gas_pressure_minimum_transfer(datum/gas_mixture/output_air)
	var/resulting_energy = output_air.thermal_energy() + (MOLAR_ACCURACY / total_moles() * thermal_energy())
	var/resulting_capacity = output_air.heat_capacity() + (MOLAR_ACCURACY / total_moles() * heat_capacity())
	return (output_air.total_moles() + MOLAR_ACCURACY) * R_IDEAL_GAS_EQUATION * (resulting_energy / resulting_capacity) / output_air.return_volume()


/** Returns the amount of gas to be pumped to a specific container.
 * Args:
 * - output_air. The gas mix we want to pump to.
 * - target_pressure. The target pressure we want.
 * - ignore_temperature. Returns a cheaper form of gas calculation, useful if the temperature difference between the two gasmixes is low or nonexistent.
 */
/datum/gas_mixture/proc/gas_pressure_calculate(datum/gas_mixture/output_air, target_pressure, ignore_temperature = FALSE)
	// So we don't need to iterate the gaslist multiple times.
	var/our_moles = total_moles()
	var/output_moles = output_air.total_moles()
	var/output_pressure = output_air.return_pressure()
	var/our_temperature = return_temperature()
	var/output_temperature = output_air.return_temperature()

	if(our_moles <= 0 || our_temperature <= 0)
		return FALSE

	var/pressure_delta = 0
	if(output_temperature <= 0 || output_moles <= 0)
		ignore_temperature = TRUE
		pressure_delta = target_pressure
	else
		pressure_delta = target_pressure - output_pressure

	if(pressure_delta < 0.01 || gas_pressure_minimum_transfer(output_air) > target_pressure)
		return FALSE

	if(ignore_temperature)
		return (pressure_delta*output_air.return_volume())/(our_temperature * R_IDEAL_GAS_EQUATION)

	// Lower and upper bound for the moles we must transfer to reach the pressure. The answer is bound to be here somewhere.
	var/pv = target_pressure * output_air.return_volume()
	/// The PV/R part in the equation we will use later. Counted early because pv/(r*t) might not be equal to pv/r/t, messing our lower and upper limit.
	var/pvr = pv / R_IDEAL_GAS_EQUATION
	// These works by assuming our gas has extremely high heat capacity
	// and the resultant gasmix will hit either the highest or lowest temperature possible.

	/// This is the true lower limit, but numbers still can get lower than this due to floats.
	var/lower_limit = max((pvr / max(our_temperature, output_temperature)) - output_moles, 0)
	var/upper_limit = (pvr / min(our_temperature, output_temperature)) - output_moles // In theory this should never go below zero, the pressure_delta check above should account for this.

	lower_limit = max(lower_limit - ATMOS_PRESSURE_ERROR_TOLERANCE, 0)
	upper_limit += ATMOS_PRESSURE_ERROR_TOLERANCE

	/*
	 * We have PV=nRT as a nice formula, we can rearrange it into nT = PV/R
	 * But now both n and T can change, since any incoming moles also change our temperature.
	 * So we need to unify both our n and T, somehow.
	 *
	 * We can rewrite T as (our old thermal energy + incoming thermal energy) divided by (our old heat capacity + incoming heat capacity)
	 * T = (W1 + n/N2 * W2) / (C1 + n/N2 * C2). C being heat capacity, W being work, N being total moles.
	 *
	 * In total we now have our equation be: (N1 + n) * (W1 + n/N2 * W2) / (C1 + n/N2 * C2) = PV/R
	 * Now you can rearrange this and find out that it's a quadratic equation and pretty much solvable with the formula. Will be a bit messy though.
	 *
	 * W2/N2n^2 +
	 * (N1*W2/N2)n + W1n - ((PV/R)*C2/N2)n +
	 * (-(PV/R)*C1) + N1W1 = 0
	 *
	 * We will represent each of these terms with A, B, and C. A for the n^2 part, B for the n^1 part, and C for the n^0 part.
	 * We then put this into the famous (-b +/- sqrt(b^2-4ac)) / 2a formula.
	 *
	 * Oh, and one more thing. By "our" we mean the gasmix in the argument. We are the incoming one here. We are number 2, target is number 1.
	 * If all this counting fucks up, we revert first to Newton's approximation, then the old simple formula.
	 */

	// Our thermal energy and moles
	var/w2 = thermal_energy()
	var/n2 = our_moles
	var/c2 = heat_capacity()

	// Target thermal energy and moles
	var/w1 = output_air.thermal_energy()
	var/n1 = output_moles
	var/c1 = output_air.heat_capacity()

	/// x^2 in the quadratic
	var/a_value = w2/n2
	/// x^1 in the quadratic
	var/b_value = ((n1*w2)/n2) + w1 - (pvr*c2/n2)
	/// x^0 in the quadratic
	var/c_value = (-1*pvr*c1) + n1 * w1

	. = gas_pressure_quadratic(a_value, b_value, c_value, lower_limit, upper_limit)
	if(.)
		return
	. = gas_pressure_approximate(a_value, b_value, c_value, lower_limit, upper_limit)
	if(.)
		return
	// Inaccurate and will probably explode but whatever.
	return (pressure_delta*output_air.return_volume())/(our_temperature * R_IDEAL_GAS_EQUATION)

/// Actually tries to solve the quadratic equation.
/// Do mind that the numbers can get very big and might hit BYOND's single point float limit.
/datum/gas_mixture/proc/gas_pressure_quadratic(a, b, c, lower_limit, upper_limit)
	var/solution
	if(IS_FINITE(a) && IS_FINITE(b) && IS_FINITE(c))
		solution = max(SolveQuadratic(a, b, c))
		if(solution > lower_limit && solution < upper_limit) //SolveQuadratic can return empty lists so be careful here
			return solution
	stack_trace("Failed to solve pressure quadratic equation. A: [a]. B: [b]. C:[c]. Current value = [solution]. Expected lower limit: [lower_limit]. Expected upper limit: [upper_limit].")
	return FALSE

/// Approximation of the quadratic equation using Newton-Raphson's Method.
/// We use the slope of an approximate value to get closer to the root of a given equation.
/datum/gas_mixture/proc/gas_pressure_approximate(a, b, c, lower_limit, upper_limit)
	var/solution
	if(IS_FINITE(a) && IS_FINITE(b) && IS_FINITE(c))
		// We start at the extrema of the equation, added by a number.
		// This way we will hopefully always converge on the positive root, while starting at a reasonable number.
		solution = (-b / (2 * a)) + 200
		for (var/iteration in 1 to ATMOS_PRESSURE_APPROXIMATION_ITERATIONS)
			var/diff = (a*solution**2 + b*solution + c) / (2*a*solution + b) // f(sol) / f'(sol)
			solution -= diff // xn+1 = xn - f(sol) / f'(sol)
			if(abs(diff) < MOLAR_ACCURACY && (solution > lower_limit) && (solution < upper_limit))
				return solution
	stack_trace("Newton's Approximation for pressure failed after [ATMOS_PRESSURE_APPROXIMATION_ITERATIONS] iterations. A: [a]. B: [b]. C:[c]. Current value: [solution]. Expected lower limit: [lower_limit]. Expected upper limit: [upper_limit].")
	return FALSE

/// Pumps gas from src to output_air. Amount depends on target_pressure
/datum/gas_mixture/proc/pump_gas_to(datum/gas_mixture/output_air, target_pressure, specific_gas = null, datum/gas_mixture/output_pipenet_air = null)
	var/datum/gas_mixture/input_air = specific_gas ? remove_specific_ratio(specific_gas, 1) : src
	var/temperature_delta = abs(input_air.return_temperature() - output_air.return_temperature())
	var/datum/gas_mixture/removed

	var/transfer_moles_output = input_air.gas_pressure_calculate(output_air, target_pressure, temperature_delta <= 5)
	var/transfer_moles_pipenet = output_pipenet_air?.return_volume() ? input_air.gas_pressure_calculate(output_pipenet_air, target_pressure, temperature_delta <= 5) : 0
	var/transfer_moles = max(transfer_moles_output, transfer_moles_pipenet)

	if(specific_gas)
		removed = input_air.remove_specific(specific_gas, transfer_moles)
		merge(input_air) // Merge the remaining gas back to the input node
	else
		removed = input_air.remove(transfer_moles)

	if(!removed)
		return FALSE

	output_air.merge(removed)
	return removed

/// Releases gas from src to output air. This means that it can not transfer air to gas mixture with higher pressure.
/datum/gas_mixture/proc/release_gas_to(datum/gas_mixture/output_air, target_pressure, rate=1, datum/gas_mixture/output_pipenet_air = null)
	var/output_starting_pressure = output_air.return_pressure()
	var/input_starting_pressure = return_pressure()

	//Need at least 10 KPa difference to overcome friction in the mechanism
	if(output_starting_pressure >= min(target_pressure, input_starting_pressure-10))
		return FALSE
	//Can not have a pressure delta that would cause output_pressure > input_pressure
	target_pressure = output_starting_pressure + min(target_pressure - output_starting_pressure, (input_starting_pressure - output_starting_pressure)/2)
	var/temperature_delta = abs(return_temperature() - output_air.return_temperature())

	var/transfer_moles_output = gas_pressure_calculate(output_air, target_pressure, temperature_delta <= 5)
	var/transfer_moles_pipenet = output_pipenet_air?.return_volume() ? gas_pressure_calculate(output_pipenet_air, target_pressure, temperature_delta <= 5) : 0
	var/transfer_moles = max(transfer_moles_output, transfer_moles_pipenet)

	//Actually transfer the gas
	var/datum/gas_mixture/removed = remove(transfer_moles * rate)

	if(!removed)
		return FALSE

	output_air.merge(removed)
	return TRUE

/**
 * Calls for electrolyzer_reaction reactions on the gas_mixture.
 * Arguments:
 * * working_power - working_power to use for the electrolyzer_reaction reactions.
 * * electrolyzer_args - electrolysis arguments to use for the electrolyzer_reaction reactions.
 */
/datum/gas_mixture/proc/electrolyze(working_power = 0, electrolyzer_args = list())
	for(var/reaction in GLOB.electrolyzer_reactions)
		var/datum/gas_reaction/electrolyzer/current_reaction = GLOB.electrolyzer_reactions[reaction]

		if(!current_reaction.reaction_check(air_mixture = src, electrolyzer_args = electrolyzer_args))
			continue

		current_reaction.react(air_mixture = src, working_power = working_power, electrolyzer_args = electrolyzer_args)

/// Convert a gas mixture to a string (ie. "o2=22;n2=82;TEMP=180")
/// Rounds all temperature and gases to 0.01 and skips any gases less than that amount
/datum/gas_mixture/proc/to_string()
	var/rounded_temp = round(return_temperature(), 0.01)

	var/list/atmos_contents = list()
	var/temperature_str = "TEMP=[num2text(rounded_temp)]"

	var/list/present_gases = get_gases()
	if(!length(present_gases) || total_moles() < 0.01)
		return temperature_str

	var/list/cached_gas_id = GAS_META[META_GAS_ID]
	for(var/gas_id in present_gases)
		var/gas_moles = round(get_moles(gas_id), 0.01)
		if(gas_moles >= 0.01)
			atmos_contents += "[cached_gas_id[gas_id]]=[num2text(gas_moles)]"

	atmos_contents += temperature_str
	return atmos_contents.Join(";")

/// Reconstructs a gas-id-to-moles list; targeted get_moles() calls are cheaper for known gases.
/datum/gas_mixture/proc/get_moles_list()
	var/list/snapshot = list()
	for(var/gas_id in get_gases())
		snapshot[gas_id] = get_moles(gas_id)
	return snapshot

/// Checks if the gas amount exists in the mixture.
/// Do NOT use this in code where performance matters!
/datum/gas_mixture/proc/has_gas(gas_id, amount=0)
	return amount < get_moles(gas_id)

/// Gets the gas visuals for everything in this mixture
/datum/gas_mixture/proc/return_visuals(turf/z_context)
	var/list/output = list()
	var/offset = GET_TURF_PLANE_OFFSET(z_context) + 1
	var/list/_META_MOLES_VISIBLE = GAS_META[META_GAS_MOLES_VISIBLE]
	var/list/_META_GAS_OVERLAY = GAS_META[META_GAS_OVERLAY]
	for(var/gas_id in get_gases())
		if(GLOB.nonoverlaying_gases[gas_id])
			continue
		var/amount = get_moles(gas_id)
		if(amount <= _META_MOLES_VISIBLE[gas_id])
			continue
		var/gas_overlay = _META_GAS_OVERLAY[gas_id][offset]
		output += gas_overlay[min(TOTAL_VISIBLE_STATES, CEILING(amount / MOLES_GAS_VISIBLE_STEP, 1))]
	return output

/**
 * A simple helper proc that checks if the contents of a list of gases are within acceptable terms.
 *
 * Arguments:
 * * acceptable_gas_bounds: An associated list of gas types and acceptable boundaries in moles. e.g. /datum/gas/oxygen = list(16, 30)
 * * * if the assoc list is null, then it'll be considered a safe gas and won't return FALSE.
 * * extraneous_gas_limit: If a gas not in gases is found, this is the limit above which the proc will return FALSE.
 *
 * Returns TRUE if the list of gases is acceptable, FALSE otherwise.
 */
/datum/gas_mixture/proc/check_gases(list/acceptable_gas_bounds, extraneous_gas_limit = 0.1)
	/* // APHELION EDIT REMOVAL START - DOGMOS - Gas reads update snapshot caches and telemetry.
	SHOULD_BE_PURE(TRUE)
	*/ // APHELION EDIT REMOVAL END

	var/list/gases_to_check = acceptable_gas_bounds.Copy() // thank you spaceman
	for(var/id in get_gases())
		var/gas_moles = get_moles(id)
		if(!(id in gases_to_check))
			if(gas_moles > extraneous_gas_limit)
				return FALSE
			continue
		var/list/boundaries = gases_to_check[id]
		if(boundaries && !ISINRANGE(gas_moles, boundaries[1], boundaries[2]))
			return FALSE
		gases_to_check -= id
	///Check that gases absent from the turf have a lower boundary of zero or none at all, otherwise return FALSE
	for(var/id in gases_to_check)
		var/list/boundaries = gases_to_check[id]
		if(boundaries && boundaries[1] > 0)
			return FALSE
	return TRUE
