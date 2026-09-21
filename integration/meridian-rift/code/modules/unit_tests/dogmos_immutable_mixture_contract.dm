/**
 * Verifies that Dogmos preserves the inherited immutable gas-mixture contract.
 */

/// A direct immutable mixture is finalized during construction and rejects mutation.
/datum/unit_test/dogmos_immutable_mixture_contract

/datum/unit_test/dogmos_immutable_mixture_contract/Run()
	var/datum/gas_mixture/immutable/immutable_mix = allocate(/datum/gas_mixture/immutable)
	var/original_temperature = immutable_mix.return_temperature()
	var/original_heat_capacity = immutable_mix.heat_capacity()
	var/datum/gas_mixture/giver = allocate(/datum/gas_mixture)
	giver.set_moles(/datum/gas/oxygen, 100)
	giver.set_temperature(T20C)

	TEST_ASSERT(immutable_mix.is_immutable(), "A direct /datum/gas_mixture/immutable must be immutable after New().")
	TEST_ASSERT(!immutable_mix.merge(giver), "An immutable mixture must reject merge().")
	immutable_mix.copy_from(giver)
	immutable_mix.set_moles(/datum/gas/oxygen, 50)
	immutable_mix.set_temperature(T20C)
	immutable_mix.set_min_heat_capacity(100)
	TEST_ASSERT_EQUAL(immutable_mix.react(null), NO_REACTION, "An immutable mixture must reject reactions.")

	TEST_ASSERT_EQUAL(immutable_mix.total_moles(), 0, "An immutable mixture must reject gas writes and copy_from().")
	TEST_ASSERT_EQUAL(immutable_mix.return_temperature(), original_temperature, "An immutable mixture must reject temperature writes.")
	TEST_ASSERT_EQUAL(immutable_mix.heat_capacity(), original_heat_capacity, "An immutable mixture must reject heat-capacity writes.")
