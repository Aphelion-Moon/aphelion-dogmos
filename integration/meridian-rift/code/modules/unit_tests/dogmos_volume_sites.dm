/** Regression coverage for typed gas-mixture volume access in the HFR UI. */

/// Covers the HFR interface's `cooling_volume` read (ui_data) and write (ui_act) sites in hfr_parts.dm.
/datum/unit_test/hfr_cooling_volume_ui

/datum/unit_test/hfr_cooling_volume_ui/Run()
	var/obj/machinery/atmospherics/components/unary/hypertorus/core/core = allocate(/obj/machinery/atmospherics/components/unary/hypertorus/core)
	var/obj/machinery/hypertorus/interface/panel = allocate(/obj/machinery/hypertorus/interface)
	panel.connected_core = core

	var/datum/gas_mixture/core_coolant = core.airs[1]
	TEST_ASSERT_NOTNULL(core_coolant, "The HFR core did not get an airs[1] gas mixture from Initialize()")

	var/list/data = panel.ui_data()
	TEST_ASSERT_EQUAL(data["cooling_volume"], core_coolant.return_volume(), "ui_data() did not report the core's actual coolant volume")

	// ui_act() reads ui.user, so it needs a real /datum/tgui rather than the null the base call defaults to.
	// Not calling ui.open() - nothing here needs a client, and the test mob has none.
	var/mob/living/carbon/human/operator = allocate(/mob/living/carbon/human/consistent)
	var/datum/tgui/ui = allocate(/datum/tgui, operator, panel, "Hypertorus") // APHELION EDIT CHANGE - DOGMOS - ORIGINAL: var/datum/tgui/ui = new(operator, panel, "Hypertorus")

	panel.ui_act("cooling_volume", list("cooling_volume" = "900"), ui)
	TEST_ASSERT_EQUAL(core_coolant.return_volume(), 900, "ui_act(\"cooling_volume\") did not apply the requested volume to the core's coolant mixture")

	panel.ui_act("cooling_volume", list("cooling_volume" = "50000"), ui)
	TEST_ASSERT_EQUAL(core_coolant.return_volume(), 2000, "ui_act(\"cooling_volume\") did not clamp an over-max request to the 50-2000 range")

	panel.ui_act("cooling_volume", list("cooling_volume" = "1"), ui)
	TEST_ASSERT_EQUAL(core_coolant.return_volume(), 50, "ui_act(\"cooling_volume\") did not clamp an under-min request to the 50-2000 range")

/// Covers the atmos control computer's "adjust_input" injector rate clamp in _atmos_control.dm, which reads
/// the injector's real air volume through the same airs[N] pattern.
/datum/unit_test/atmos_control_injector_rate

/datum/unit_test/atmos_control_injector_rate/Run()
	var/obj/machinery/computer/atmos_control/computer = allocate(/obj/machinery/computer/atmos_control)
	computer.atmos_chambers = list("unit_test_chamber" = "Unit Test Chamber")

	var/obj/machinery/air_sensor/sensor = allocate(/obj/machinery/air_sensor)
	var/obj/machinery/atmospherics/components/unary/outlet_injector/input = allocate(/obj/machinery/atmospherics/components/unary/outlet_injector)
	sensor.inlet_id = input.id_tag
	computer.connected_sensors["unit_test_chamber"] = sensor.id_tag

	var/datum/gas_mixture/input_air = input.airs[1]
	TEST_ASSERT_NOTNULL(input_air, "The outlet injector did not get an airs[1] gas mixture from Initialize()")
	// Deliberately below MAX_TRANSFER_RATE so the clamp is actually exercised against the injector's own
	// air volume rather than degenerating to MAX_TRANSFER_RATE regardless of what airs[1] read as.
	input_air.set_volume(75)

	// ui_act() reads ui.user, so it needs a real /datum/tgui rather than the null the base call defaults to.
	var/mob/living/carbon/human/operator = allocate(/mob/living/carbon/human/consistent)
	var/datum/tgui/ui = allocate(/datum/tgui, operator, computer, "AtmosControl") // APHELION EDIT CHANGE - DOGMOS - ORIGINAL: var/datum/tgui/ui = new(operator, computer, "AtmosControl")

	computer.ui_act("adjust_input", list("chamber" = "unit_test_chamber", "rate" = "[MAX_TRANSFER_RATE]"), ui)
	TEST_ASSERT_EQUAL(input.volume_rate, 75, "adjust_input did not clamp volume_rate to the injector's actual air volume")

	input_air.set_volume(500)
	computer.ui_act("adjust_input", list("chamber" = "unit_test_chamber", "rate" = "[MAX_TRANSFER_RATE]"), ui)
	TEST_ASSERT_EQUAL(input.volume_rate, MAX_TRANSFER_RATE, "adjust_input did not clamp volume_rate to MAX_TRANSFER_RATE when the injector's air volume exceeds it")
