#if defined(UNIT_TESTS) && defined(DOGMOS_LEGACY_TRANSCRIPT_CAPTURE)

#define DOGMOS_LEGACY_TRANSCRIPT_PATH "data/dogmos_legacy_mixture_transcript_v1.txt"

/** Captures legacy public gas-mixture results and state for service replay. */
/datum/unit_test/dogmos_legacy_mixture_transcript
	test_flags = UNIT_TEST_FOCUS

/** Executes the fixed legacy mixture sequence and writes its transcript. */
/datum/unit_test/dogmos_legacy_mixture_transcript/Run()
	fdel(DOGMOS_LEGACY_TRANSCRIPT_PATH)
	text2file("DOGMOS_LEGACY_MIXTURE_TRANSCRIPT_V1", DOGMOS_LEGACY_TRANSCRIPT_PATH)

	var/datum/gas_mixture/mixture_a = allocate(/datum/gas_mixture)
	var/datum/gas_mixture/mixture_b = allocate(/datum/gas_mixture)
	var/datum/gas_mixture/mixture_c = allocate(/datum/gas_mixture)

	var/result = mixture_a.set_moles(/datum/gas/oxygen, 100)
	write_step("set_o2", result, mixture_a, mixture_b, mixture_c)
	result = mixture_a.set_moles(/datum/gas/nitrogen, 50)
	write_step("set_n2", result, mixture_a, mixture_b, mixture_c)
	result = mixture_a.adjust_moles(/datum/gas/oxygen, -25)
	write_step("adjust_o2", result, mixture_a, mixture_b, mixture_c)
	result = mixture_a.set_temperature(400)
	write_step("set_temperature", result, mixture_a, mixture_b, mixture_c)
	result = mixture_a.set_volume(2000)
	write_step("set_volume", result, mixture_a, mixture_b, mixture_c)
	result = mixture_b.set_moles(/datum/gas/oxygen, 20)
	write_step("seed_b", result, mixture_a, mixture_b, mixture_c)
	result = mixture_b.set_temperature(300)
	write_step("temperature_b", result, mixture_a, mixture_b, mixture_c)
	result = mixture_a.merge(mixture_b)
	write_step("merge", result, mixture_a, mixture_b, mixture_c)
	mixture_c = mixture_a.remove_ratio(0.25)
	allocated += mixture_c
	write_step("remove_ratio", mixture_c, mixture_a, mixture_b, mixture_c)
	result = mixture_a.transfer_to(mixture_b, 10)
	write_step("transfer_amount", result, mixture_a, mixture_b, mixture_c)
	result = equalize_all_gases_in_list(list(mixture_a, mixture_b))
	write_step("equalize", result, mixture_a, mixture_b, mixture_c)
	mixture_c.mark_immutable()
	result = mixture_c.set_moles(/datum/gas/oxygen, 999)
	write_step("immutable_write", result, mixture_a, mixture_b, mixture_c)

/** Writes one stable transcript row for three observed mixtures.
 * Arguments:
 * * step_name - Stable operation identifier.
 * * result - Public DM return value from the operation.
 * * mixture_a - First observed mixture.
 * * mixture_b - Second observed mixture.
 * * mixture_c - Third observed mixture.
 */
/datum/unit_test/dogmos_legacy_mixture_transcript/proc/write_step(step_name, result, datum/gas_mixture/mixture_a, datum/gas_mixture/mixture_b, datum/gas_mixture/mixture_c)
	var/result_kind = "null"
	var/result_value = 0
	if(isnum(result))
		result_kind = "number"
		result_value = result
	else if(istype(result, /datum/gas_mixture))
		result_kind = "mixture"
		result_value = 1

	var/list/fields = list(step_name, result_kind, stable_number(result_value))
	for(var/datum/gas_mixture/mixture as anything in list(mixture_a, mixture_b, mixture_c))
		fields += stable_number(mixture.return_temperature())
		fields += stable_number(mixture.return_volume())
		fields += stable_number(mixture.get_moles(/datum/gas/oxygen))
		fields += stable_number(mixture.get_moles(/datum/gas/nitrogen))
	text2file(fields.Join("|"), DOGMOS_LEGACY_TRANSCRIPT_PATH)

/** Formats a BYOND scalar without locale-dependent separators.
 * Arguments:
 * * value - Numeric value to serialize.
 */
/datum/unit_test/dogmos_legacy_mixture_transcript/proc/stable_number(value)
	return num2text(value, 20)

#undef DOGMOS_LEGACY_TRANSCRIPT_PATH

#endif
