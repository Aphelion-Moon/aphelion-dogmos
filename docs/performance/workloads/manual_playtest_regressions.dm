/** Fixed synthetic pipe graph isolates the real pipeline traversal from map generation. */
/obj/machinery/atmospherics/pipe/manual_profile_probe
	volume = 200
	has_gas_visuals = FALSE
	device_type = 0
	/// Explicit graph edges, including duplicates and a closing cycle.
	var/list/test_links = list()

/obj/machinery/atmospherics/pipe/manual_profile_probe/Initialize(mapload)
	// Retain ordinary lifetime registration without scheduling synthetic machinery.
	return ..(mapload, FALSE)

/obj/machinery/atmospherics/pipe/manual_profile_probe/pipeline_expansion(datum/pipeline/reference)
	return test_links

/** Checks the real traversal's membership, gas, volume and resumable result on a cyclic graph. */
/proc/verify_manual_pipeline(size, resume_each_node = FALSE, blocking = FALSE)
	var/list/pipes = list()
	for(var/index in 1 to size)
		pipes += new /obj/machinery/atmospherics/pipe/manual_profile_probe
	for(var/index in 1 to size)
		var/obj/machinery/atmospherics/pipe/manual_profile_probe/pipe = pipes[index]
		pipe.test_links = list(pipes[index == size ? 1 : index + 1], pipes[index == 1 ? size : index - 1], pipes[index == size ? 1 : index + 1])
	var/datum/pipeline/net = new
	var/obj/machinery/atmospherics/pipe/first = pipes[1]
	first.replace_pipenet(null, net)
	var/obj/machinery/atmospherics/pipe/second = pipes[2]
	second.air_temporary = new(200)
	second.air_temporary.set_moles(GAS_O2, 5)
	var/datum/controller/subsystem/air/settlement_probe/probe = new
	var/old_limit = Master.current_ticklimit
	var/started = REALTIMEOFDAY
	var/resumes = 0
	if(blocking)
		net.build_pipeline_blocking(first)
	else
		net.members = list(first)
		net.set_air(new /datum/gas_mixture(200))
		var/list/border = list(first)
		while(length(border))
			Master.current_ticklimit = resume_each_node ? -1 : 100000
			probe.state = SS_RUNNING
			probe.expand_pipeline(net, border)
			resumes++
	var/elapsed = (REALTIMEOFDAY - started + 24 HOURS) % (24 HOURS)
	Master.current_ticklimit = old_limit
	var/passed = length(net.members) == size && net.air.return_volume() == size * 200 && abs(net.air.get_moles(GAS_O2) - 5) < 0.0001 && !second.air_temporary
	for(var/obj/machinery/atmospherics/pipe/pipe as anything in pipes)
		passed = passed && pipe.parent == net
	if(resume_each_node)
		passed = passed && resumes > 1
	var/list/record = list("size" = size, "resume_each_node" = resume_each_node, "blocking" = blocking, "elapsed_ms" = elapsed * 100, "calls" = resumes, "passed" = passed)
	file("[GLOB.log_directory]/pipeline-measurements.jsonl") << json_encode(record)
	// Clear ownership before teardown, so synthetic pipes never schedule real map rebuilds.
	net.members.Cut()
	for(var/obj/machinery/atmospherics/pipe/manual_profile_probe/pipe as anything in pipes)
		pipe.test_links.Cut()
		pipe.replace_pipenet(net, null)
		qdel(pipe)
	qdel(net)
	qdel(probe)
	return passed

/** Reproduces action-ID allocation while another same-named action has no HUD button yet. */
/proc/verify_manual_action_id()
	var/mob/owner = new
	var/datum/hud/hud = new(owner)
	owner.hud_used = hud
	var/datum/action/first = new
	var/datum/action/second = new
	owner.actions = list(first, second)
	var/atom/movable/screen/movable/action_button/button = new
	first.SetId(button, owner)
	var/passed = button.id == 1
	var/atom/movable/screen/movable/action_button/existing = new
	existing.id = 1
	second.viewers[hud] = existing
	first.SetId(button, owner)
	passed = passed && button.id == 2
	second.viewers.Cut()
	owner.actions.Cut()
	qdel(button)
	qdel(existing)
	qdel(first)
	qdel(second)
	qdel(hud)
	qdel(owner)
	return passed

/** Storage teardown must finish after the viewer's HUD is gone. */
/proc/verify_manual_storage_cleanup()
	var/mob/viewer = new
	var/obj/item/container = new
	var/datum/storage/storage = new(container)
	var/datum/storage_interface/interface = new(null, storage, viewer)
	storage.storage_interfaces = list()
	storage.storage_interfaces[viewer] = interface
	storage.is_using = list(viewer)
	viewer.active_storage = storage
	storage.hide_contents(viewer)
	var/passed = !viewer.active_storage && !length(storage.is_using) && !length(storage.storage_interfaces) && QDELETED(interface)
	qdel(storage)
	qdel(container)
	qdel(viewer)
	return passed

/** Suit teardown tolerates a removed tongue and retains ordinary speech restoration. */
/proc/verify_manual_infiltrator_cleanup()
	var/mob/living/carbon/human/wearer = new
	var/obj/item/mod/control/control = new
	var/obj/item/mod/module/infiltrator/module = new
	control.wearer = wearer
	module.mod = control
	var/obj/item/organ/tongue/tongue = wearer.get_organ_slot(ORGAN_SLOT_TONGUE)
	module.on_part_activation()
	var/passed = tongue.temp_say_mod == "states"
	module.on_part_deactivation(deleting = TRUE)
	passed = passed && tongue.temp_say_mod == initial(tongue.temp_say_mod)
	tongue.Remove(wearer, special = TRUE)
	module.on_part_activation()
	module.on_part_deactivation(deleting = TRUE)
	passed = passed && !HAS_TRAIT(wearer, TRAIT_UNKNOWN_VOICE)
	module.mod = null
	control.wearer = null
	qdel(tongue)
	qdel(module)
	qdel(control)
	qdel(wearer)
	return passed

/** Runs independent checks so a negative control records every reproduced runtime. */
/proc/verify_manual_playtest_regressions()
	var/list/results = list()
	results["pipeline_resume"] = verify_manual_pipeline(128, resume_each_node = TRUE)
	results["pipeline_blocking"] = verify_manual_pipeline(128, blocking = TRUE)
	for(var/run in 1 to 3)
		results["pipeline_4096_[run]"] = verify_manual_pipeline(4096)
	try
		results["action_id"] = verify_manual_action_id()
	catch(var/exception/action_error)
		results["action_id"] = FALSE
		file("[GLOB.log_directory]/manual-expected-errors.jsonl") << json_encode(list("test" = "action_id", "error" = action_error.name))
	try
		results["storage_cleanup"] = verify_manual_storage_cleanup()
	catch(var/exception/storage_error)
		results["storage_cleanup"] = FALSE
		file("[GLOB.log_directory]/manual-expected-errors.jsonl") << json_encode(list("test" = "storage_cleanup", "error" = storage_error.name))
	try
		results["infiltrator_cleanup"] = verify_manual_infiltrator_cleanup()
	catch(var/exception/infiltrator_error)
		results["infiltrator_cleanup"] = FALSE
		file("[GLOB.log_directory]/manual-expected-errors.jsonl") << json_encode(list("test" = "infiltrator_cleanup", "error" = infiltrator_error.name))
	file("[GLOB.log_directory]/manual-regressions.json") << json_encode(results)
	for(var/check in results)
		if(!results[check])
			throw EXCEPTION("Manual playtest regression failed: [check]")
