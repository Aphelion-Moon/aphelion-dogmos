/** Integrity probe for the opt-in diagnostic; absent from production's DME. */
/obj/fusion_damage_probe
	uses_integrity = TRUE
	max_integrity = 100
	resistance_flags = NONE

/** Models an object consumed synchronously by a pre-fire signal handler. */
/obj/fusion_damage_probe/proc/consume_during_pre_fire()
	SIGNAL_HANDLER
	update_integrity(0)

/** Checks both stale exposure and ordinary damage without changing the live explosion queues. */
/proc/verify_fusion_damage_regressions()
	var/obj/fusion_damage_probe/destroyed = new
	destroyed.update_integrity(0)
	// Nullspace plus zero integrity models the retained pellet-cloud grenade.
	destroyed.ex_act(EXPLODE_HEAVY)
	destroyed.fire_act(1000, 100)
	if(destroyed.get_integrity() != 0)
		CRASH("Stale exposure changed a destroyed object's integrity.")
	qdel(destroyed)

	var/obj/fusion_damage_probe/healthy = new
	healthy.fire_act(1000, 100)
	if(healthy.get_integrity() != 80)
		CRASH("Healthy objects must still take ordinary fire damage.")
	healthy.ex_act(EXPLODE_LIGHT)
	if(healthy.get_integrity() >= 80)
		CRASH("Healthy objects must still take ordinary blast damage.")
	qdel(healthy)

	var/obj/fusion_damage_probe/consumed = new
	consumed.RegisterSignal(consumed, COMSIG_ATOM_PRE_FIRE_ACT, TYPE_PROC_REF(/obj/fusion_damage_probe, consume_during_pre_fire))
	consumed.fire_act(1000, 100)
	if(consumed.get_integrity() != 0)
		CRASH("Pre-fire signal did not consume the probe.")
	qdel(consumed)
	file("[GLOB.log_directory]/fusion-damage-regressions.json") << json_encode(list("passed" = TRUE))
