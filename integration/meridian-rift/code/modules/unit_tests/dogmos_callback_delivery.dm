/** Verifies the live callback enqueue-failure telemetry binding. */
/datum/unit_test/dogmos_callback_delivery

/datum/unit_test/dogmos_callback_delivery/Run()
	var/failures = dogmos_callback_enqueue_failures()
	TEST_ASSERT(isnum(failures), "Dogmos callback enqueue telemetry did not return a number.")
	TEST_ASSERT_EQUAL(failures, 0, \
		"Dogmos started with [failures] callback enqueue failures; callbacks were rejected before this test ran.")

	var/health_preflights = SSdogmos.dogmos_health_preflight_count
	var/datum/gas_mixture/mixture = allocate(/datum/gas_mixture, CELL_VOLUME)
	mixture.set_temperature(T20C)
	mixture.set_moles(/datum/gas/oxygen, 1)
	mixture.return_temperature()
	mixture.return_pressure()
	TEST_ASSERT_EQUAL(SSdogmos.dogmos_health_preflight_count, health_preflights, \
		"Routine mixture IPC performed a service-health call outside SSair.fire().")
	qdel(mixture)
