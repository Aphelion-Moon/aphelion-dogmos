/**
 * Golden-value tests for /datum/gas_mixture.
 *
 * These pin the *observable physics and shapes* of the gas mixture API against the DM implementation
 * as it behaves today, so that swapping the internals to Dogmos has something concrete to fail
 * against. They deliberately assert conservation laws, formulae and return shapes rather than
 * hardcoded magic numbers, so they remain meaningful under either implementation while still catching
 * the failure modes that swap silently: an inverted ratio, a swapped argument, lost clamping, or a
 * changed return shape.
 *
 * Changes to the expected values are behavior changes and need explicit review.
 */

/// Builds a standard-atmosphere mixture: O2 + N2 at T20C in one cell's worth of volume.
/datum/unit_test/proc/allocate_standard_mix()
	var/datum/gas_mixture/mix = allocate(/datum/gas_mixture)
	mix.set_volume(CELL_VOLUME)
	mix.set_moles(/datum/gas/oxygen, MOLES_O2STANDARD)
	mix.set_moles(/datum/gas/nitrogen, MOLES_N2STANDARD)
	mix.set_temperature(T20C)
	return mix

/// Pressure, heat capacity and thermal energy follow from the gas laws and the gas metadata.
/datum/unit_test/gas_mixture_golden_state

/datum/unit_test/gas_mixture_golden_state/Run()
	var/datum/gas_mixture/mix = allocate_standard_mix()

	TEST_ASSERT_EQUAL(round(mix.total_moles(), 0.01), round(MOLES_CELLSTANDARD, 0.01), "A standard mix should hold exactly MOLES_CELLSTANDARD")

	// PV = nRT, the definition return_pressure() implements.
	var/expected_pressure = MOLES_CELLSTANDARD * R_IDEAL_GAS_EQUATION * T20C / CELL_VOLUME
	TEST_ASSERT_EQUAL(round(mix.return_pressure(), 0.01), round(expected_pressure, 0.01), "A standard mix at T20C should sit at one atmosphere")

	// Heat capacity is the mole-weighted sum of each gas's specific heat.
	var/list/specific_heats = GLOB.meta_gas_info[META_GAS_SPECIFIC_HEAT]
	var/expected_capacity = MOLES_O2STANDARD * specific_heats[/datum/gas/oxygen] + MOLES_N2STANDARD * specific_heats[/datum/gas/nitrogen]
	TEST_ASSERT_EQUAL(round(mix.heat_capacity(), 0.01), round(expected_capacity, 0.01), "Heat capacity should be the mole-weighted sum of specific heats")

	TEST_ASSERT_EQUAL(round(mix.thermal_energy(), 0.01), round(expected_capacity * T20C, 0.01), "Thermal energy should be heat capacity times temperature")

	// The turf subtype floors heat capacity for vacuums; the base type does not.
	var/datum/gas_mixture/turf/empty_turf_mix = allocate(/datum/gas_mixture/turf)
	TEST_ASSERT_EQUAL(empty_turf_mix.heat_capacity(), HEAT_CAPACITY_VACUUM, "An empty turf mixture should floor at HEAT_CAPACITY_VACUUM")

	var/datum/gas_mixture/empty_mix = allocate(/datum/gas_mixture)
	TEST_ASSERT_EQUAL(empty_mix.heat_capacity(), 0, "An empty non-turf mixture should have no heat capacity")

/// merge() conserves both matter and energy.
/datum/unit_test/gas_mixture_golden_merge

/datum/unit_test/gas_mixture_golden_merge/Run()
	var/datum/gas_mixture/receiver = allocate_standard_mix()
	var/datum/gas_mixture/giver = allocate(/datum/gas_mixture)
	giver.set_volume(CELL_VOLUME)
	giver.set_moles(/datum/gas/plasma, 50)
	giver.set_temperature(1000)

	var/total_moles_before = receiver.total_moles() + giver.total_moles()
	var/total_energy_before = receiver.thermal_energy() + giver.thermal_energy()
	var/giver_moles_before = giver.total_moles()

	TEST_ASSERT(receiver.merge(giver), "merge() should report success when given a mixture")

	TEST_ASSERT_EQUAL(round(receiver.total_moles(), 0.01), round(total_moles_before, 0.01), "merge() should conserve total moles")
	TEST_ASSERT_EQUAL(round(receiver.thermal_energy(), 0.01), round(total_energy_before, 0.01), "merge() should conserve thermal energy")
	TEST_ASSERT_EQUAL(round(receiver.get_moles(/datum/gas/plasma), 0.01), 50, "merge() should transfer the giver's plasma")
	TEST_ASSERT_EQUAL(round(giver.total_moles(), 0.01), round(giver_moles_before, 0.01), "merge() must not modify the giver")

	TEST_ASSERT(!receiver.merge(null), "merge(null) should report failure rather than runtime")

/// remove() and remove_ratio() split a mixture without creating or destroying matter.
/datum/unit_test/gas_mixture_golden_remove

/datum/unit_test/gas_mixture_golden_remove/Run()
	var/datum/gas_mixture/source = allocate_standard_mix()
	var/starting_moles = source.total_moles()

	var/datum/gas_mixture/removed = source.remove(10)
	TEST_ASSERT_NOTNULL(removed, "remove() should return a mixture when there is gas to take")
	TEST_ASSERT_EQUAL(round(removed.total_moles(), 0.01), 10, "remove(10) should take exactly 10 moles")
	TEST_ASSERT_EQUAL(round(source.total_moles() + removed.total_moles(), 0.01), round(starting_moles, 0.01), "remove() should conserve total moles")
	TEST_ASSERT_EQUAL(round(removed.return_temperature(), 0.01), round(source.return_temperature(), 0.01), "Removed gas should keep the source temperature")

	// Ratios split proportionally, and the removed portion is a genuinely separate mixture.
	var/datum/gas_mixture/half = source.remove_ratio(0.5)
	TEST_ASSERT_EQUAL(round(half.total_moles(), 0.01), round(source.total_moles(), 0.01), "remove_ratio(0.5) should split the mixture evenly")

	// Over-removal clamps rather than going negative.
	var/datum/gas_mixture/everything = source.remove(1e9)
	TEST_ASSERT_EQUAL(round(source.total_moles(), 0.01), 0, "Removing more than exists should empty the mixture")
	TEST_ASSERT(everything.total_moles() > 0, "Over-removal should still return the gas that was there")

	// The two zero cases differ in shape, and callers depend on that difference.
	var/datum/gas_mixture/nothing = allocate_standard_mix()
	TEST_ASSERT_NULL(nothing.remove(0), "remove(0) returns null")
	TEST_ASSERT_NOTNULL(nothing.remove_ratio(0), "remove_ratio(0) returns an empty mixture, not null")

/// copy_from() and equalize-style operations reproduce state faithfully.
/datum/unit_test/gas_mixture_golden_copy

/datum/unit_test/gas_mixture_golden_copy/Run()
	var/datum/gas_mixture/source = allocate_standard_mix()
	var/datum/gas_mixture/target = allocate(/datum/gas_mixture)
	target.set_volume(CELL_VOLUME)

	target.copy_from(source)
	TEST_ASSERT_EQUAL(round(target.total_moles(), 0.01), round(source.total_moles(), 0.01), "copy_from() should reproduce the mole count")
	TEST_ASSERT_EQUAL(round(target.return_temperature(), 0.01), round(source.return_temperature(), 0.01), "copy_from() should reproduce the temperature")
	TEST_ASSERT_EQUAL(round(target.return_pressure(), 0.01), round(source.return_pressure(), 0.01), "An equal-volume copy should read the same pressure")

	// A copy is independent of its source.
	target.adjust_moles(/datum/gas/oxygen, 100)
	TEST_ASSERT(target.total_moles() > source.total_moles(), "Modifying a copy must not affect the original")

/// Reaction gating: hypernoblium suppresses reactions outright before any of them run.
/datum/unit_test/gas_mixture_golden_reactions

/datum/unit_test/gas_mixture_golden_reactions/Run()
	var/datum/gas_mixture/inert = allocate_standard_mix()
	TEST_ASSERT_EQUAL(inert.react(null), NO_REACTION, "A standard air mix at room temperature should not react")

	var/datum/gas_mixture/empty_mix = allocate(/datum/gas_mixture)
	TEST_ASSERT_EQUAL(empty_mix.react(null), NO_REACTION, "An empty mixture should not react")

	// Hypernoblium above the oppression threshold stops everything, including reactions that would
	// otherwise fire. This check happens before any reaction is considered.
	var/datum/gas_mixture/oppressed = allocate(/datum/gas_mixture)
	oppressed.set_volume(CELL_VOLUME)
	oppressed.set_moles(/datum/gas/hypernoblium, REACTION_OPPRESSION_THRESHOLD + 1)
	oppressed.set_moles(/datum/gas/plasma, 100)
	oppressed.set_moles(/datum/gas/oxygen, 100)
	oppressed.set_temperature(FIRE_MINIMUM_TEMPERATURE_TO_EXIST + 100)
	TEST_ASSERT_EQUAL(oppressed.react(null), STOP_REACTIONS, "Hypernoblium above the oppression threshold should stop all reactions")
	TEST_ASSERT_EQUAL(oppressed.__react(null), STOP_REACTIONS, "Dogmos' direct reaction hook must enforce Hypernoblium oppression")
