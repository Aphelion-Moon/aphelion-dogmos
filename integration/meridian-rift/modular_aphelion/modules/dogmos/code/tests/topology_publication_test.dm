#if defined(UNIT_TESTS) || defined(SPACEMAN_DMM)

/** Inert publisher exercising the real bounded flush and retirement implementation. */
/datum/controller/subsystem/dogmos/recovery_test_copy/publication_probe
	var/failing_phase
	var/list/publication_order = list()

/datum/controller/subsystem/dogmos/recovery_test_copy/publication_probe/proc/record_publication(phase, list/records, width)
	publication_order += phase
	if(length(records) != width)
		throw "unexpected publication shape"
	if(phase == failing_phase)
		throw "publication acknowledgement unavailable"
	return 1

/datum/controller/subsystem/dogmos/recovery_test_copy/publication_probe/publish_turf_lifecycle_records(list/records)
	return record_publication(1, records, 6)

/datum/controller/subsystem/dogmos/recovery_test_copy/publication_probe/publish_turf_heat_records(list/records)
	return record_publication(2, records, 7)

/datum/controller/subsystem/dogmos/recovery_test_copy/publication_probe/publish_turf_gas_edges(list/records)
	return record_publication(3, records, 6)

/datum/controller/subsystem/dogmos/recovery_test_copy/publication_probe/publish_turf_heat_edges(list/records)
	return record_publication(4, records, 5)

/** A missing acknowledgement at every publication boundary retains only unacknowledged work. */
/datum/unit_test/dogmos_topology_publication_exception_phases/Run()
	if(!dogmos_wait_for_stage_boundary())
		return
	for(var/outer_owner in list(FALSE, TRUE))
		for(var/failing_phase in 1 to 5) // Five is the all-acknowledged control.
			var/datum/controller/subsystem/dogmos/recovery_test_copy/publication_probe/probe = allocate(/datum/controller/subsystem/dogmos/recovery_test_copy/publication_probe)
			probe.service_ready = TRUE
			probe.turf_registration_batching = TRUE
			probe.runtime_topology_batching = outer_owner
			probe.failing_phase = failing_phase
			probe.dogmos_pending_turf_lifecycle = list("11" = list(1, 11, 17, 11, 17, 0))
			probe.dogmos_pending_turf_heat = list("11" = list(11, 17, 300, 100, 0.5, 0, 0))
			probe.queue_pending_gas_adjacency(11, 17, 12, 19, TRUE, FALSE)
			probe.queue_pending_heat_adjacency(11, 17, 12, 19, TRUE)
			var/caught_expected = FALSE
			var/finished = FALSE
			try
				finished = probe.flush_turf_registration_batch()
			catch(var/error)
				caught_expected = error == "publication acknowledgement unavailable"
			if(caught_expected != (failing_phase <= 4) || finished != (failing_phase == 5))
				return Fail("Publication phase [failing_phase] lost its error or completion result.", __FILE__, __LINE__)
			if(probe.runtime_topology_batching != outer_owner || !probe.turf_registration_batching)
				return Fail("Publication changed the caller's batching ownership.", __FILE__, __LINE__)
			if(length(probe.publication_order) != min(failing_phase, 4))
				return Fail("Publication continued after an unavailable acknowledgement.", __FILE__, __LINE__)
			for(var/index in 1 to length(probe.publication_order))
				if(probe.publication_order[index] != index)
					return Fail("Publication order must remain lifecycle, heat, gas edges, heat edges.", __FILE__, __LINE__)
			var/list/pending = list(probe.dogmos_pending_turf_lifecycle, probe.dogmos_pending_turf_heat, probe.dogmos_pending_turf_adjacency, probe.dogmos_pending_turf_heat_adjacency)
			for(var/phase in 1 to 4)
				if(length(pending[phase]) != (phase >= failing_phase))
					return Fail("Phase [phase] retired without acknowledgement or retained acknowledged work.", __FILE__, __LINE__)
			if(length(probe.dogmos_pending_turf_adjacency_index) != (failing_phase <= 3 ? 2 : 0) \
				|| length(probe.dogmos_pending_turf_heat_adjacency_index) != (failing_phase <= 4 ? 2 : 0))
				return Fail("Publication separated an edge from its reverse-index ownership.", __FILE__, __LINE__)

#endif
