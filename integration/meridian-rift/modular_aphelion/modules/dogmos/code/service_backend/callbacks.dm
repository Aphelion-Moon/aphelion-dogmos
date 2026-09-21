/** Returns a caller-legible diagnostic when a callback does not match the next expected sequence. */
/datum/controller/subsystem/dogmos/proc/callback_sequence_error(list/batch, offset, list/next_sequence)
	if(length(batch) < offset + DOGMOS_CALLBACK_EVENT_FIELDS - 1)
		return "Dogmos callback sequence at offset [offset] is truncated."
	for(var/word_index in 1 to 4)
		if(batch[offset + word_index - 1] != next_sequence[word_index])
			return "Dogmos callback sequence mismatch at offset [offset]: expected [next_sequence[1] || 0]:[next_sequence[2] || 0]:[next_sequence[3] || 0]:[next_sequence[4] || 0], received [batch[offset] || 0]:[batch[offset + 1] || 0]:[batch[offset + 2] || 0]:[batch[offset + 3] || 0]."
	return null

/** Advances one scope-local callback sequence after validating the current event. */
/datum/controller/subsystem/dogmos/proc/consume_callback_sequence(list/batch, offset, list/next_sequence)
	var/sequence_error = callback_sequence_error(batch, offset, next_sequence)
	if(sequence_error)
		return sequence_error
	for(var/word_index in 1 to 4)
		next_sequence[word_index]++
		if(next_sequence[word_index] <= DOGMOS_PROCESS_WORD_MAX)
			return null
		next_sequence[word_index] = 0
	return "Dogmos callback sequence exhausted after [batch[offset]]:[batch[offset + 1]]:[batch[offset + 2]]:[batch[offset + 3]]."

/** Validates the flattened callback batch and returns its event count. */
/datum/controller/subsystem/dogmos/proc/validate_callback_batch(list/batch, scope, list/transaction_words)
	if(!islist(batch) || length(batch) < DOGMOS_CALLBACK_HEADER_FIELDS)
		CRASH("dogmosd returned a malformed callback batch.")
	var/returned = join_u32_words(batch[1], batch[2])
	if(returned > DOGMOS_CALLBACK_BATCH_SIZE || length(batch) != DOGMOS_CALLBACK_HEADER_FIELDS + returned * DOGMOS_CALLBACK_EVENT_FIELDS)
		CRASH("dogmosd returned a callback batch with an invalid event count.")
	for(var/event_index in 0 to returned - 1)
		if(!returned)
			break
		var/offset = DOGMOS_CALLBACK_EVENT_START + event_index * DOGMOS_CALLBACK_EVENT_FIELDS
		if(batch[offset + DOGMOS_CALLBACK_SCOPE_FIELD] != scope)
			CRASH("dogmosd returned a callback event in the wrong scope.")
		for(var/word_index in 1 to 4)
			if(batch[offset + DOGMOS_CALLBACK_TRANSACTION_WORD + word_index - 1] != transaction_words[word_index])
				CRASH("dogmosd returned a callback event for the wrong transaction.")
	return returned

/** Records one stale callback while keeping the exported counter exactly representable by BYOND. */
/datum/controller/subsystem/dogmos/proc/record_stale_callback()
	dogmos_stale_callback_count = min(dogmos_stale_callback_count + 1, DOGMOS_MAX_EXACT_INTEGER)

/** Dispatches one non-reaction callback after validating sequence and turf generations. */
/datum/controller/subsystem/dogmos/proc/dispatch_general_callback(list/batch, offset)
	var/sequence_error = consume_callback_sequence(batch, offset, dogmos_next_callback_sequence)
	if(sequence_error)
		stack_trace(sequence_error)
		return FALSE
	var/kind = batch[offset + DOGMOS_CALLBACK_KIND_FIELD]

	// Reactions evaluated during turf-stage FDM processing (not a synchronous mixture.react()
	// call) have no open direct-reaction transaction to attach to, so dogmosd surfaces them here
	// instead. Their subject/target fields are a mixture + holder, not turfs - dispatch them
	// before the turf-only kind gate below ever tries to resolve_turf() them.
	if(kind == DOGMOS_CALLBACK_REACTION_FINISHED || kind == DOGMOS_CALLBACK_REACTION_PROFILED || kind == DOGMOS_CALLBACK_RUN_DM_REACTION)
		dispatch_general_reaction_callback(batch, offset, kind)
		return TRUE

	if(kind < DOGMOS_CALLBACK_PRESSURE_DIFFERENCE || kind > DOGMOS_CALLBACK_TURF_DESTRUCTION_REQUEST)
		CRASH("Unexpected Dogmos callback kind [kind] during general callback processing.")

	var/subject_slot = join_u32_words(batch[offset + DOGMOS_CALLBACK_SUBJECT_SLOT_FIELD], batch[offset + DOGMOS_CALLBACK_SUBJECT_SLOT_FIELD + 1])
	var/subject_generation = join_u32_words(batch[offset + DOGMOS_CALLBACK_SUBJECT_GENERATION_FIELD], batch[offset + DOGMOS_CALLBACK_SUBJECT_GENERATION_FIELD + 1])
	var/turf/subject = resolve_turf(subject_slot, subject_generation)
	if(!subject)
		record_stale_callback()
		return TRUE

	var/turf/target
	if(kind == DOGMOS_CALLBACK_PRESSURE_DIFFERENCE || kind == DOGMOS_CALLBACK_FIRELOCK_CONSIDERATION)
		var/target_slot = join_u32_words(batch[offset + DOGMOS_CALLBACK_TARGET_SLOT_FIELD], batch[offset + DOGMOS_CALLBACK_TARGET_SLOT_FIELD + 1])
		var/target_generation = join_u32_words(batch[offset + DOGMOS_CALLBACK_TARGET_GENERATION_FIELD], batch[offset + DOGMOS_CALLBACK_TARGET_GENERATION_FIELD + 1])
		target = resolve_turf(target_slot, target_generation)
		if(!target)
			record_stale_callback()
			return TRUE

	switch(kind)
		if(DOGMOS_CALLBACK_PRESSURE_DIFFERENCE)
			if(!isopenturf(subject))
				CRASH("Dogmos pressure callback referenced a non-open turf.")
			var/turf/open/open_subject = subject
			open_subject.consider_pressure_difference(target, batch[offset + DOGMOS_CALLBACK_VALUES_FIELD])
		if(DOGMOS_CALLBACK_DECOMPRESSION_FLOOR_RIP)
			subject.handle_decompression_floor_rip(batch[offset + DOGMOS_CALLBACK_VALUES_FIELD])
		if(DOGMOS_CALLBACK_FIRELOCK_CONSIDERATION)
			subject.consider_firelocks(target)
		if(DOGMOS_CALLBACK_TURF_DESTRUCTION_REQUEST)
			var/reason = join_u32_words(batch[offset + DOGMOS_CALLBACK_AUX_FIELD], batch[offset + DOGMOS_CALLBACK_AUX_FIELD + 1])
			if(reason != DOGMOS_TURF_DESTRUCTION_SUPERCONDUCTIVE_HEAT)
				CRASH("Dogmos requested unknown turf destruction reason [reason].")
			subject.to_be_destroyed = TRUE
	return TRUE

/** Decodes a general reaction callback's exact mixture identity for fail-closed validation. */
/datum/controller/subsystem/dogmos/proc/decode_general_reaction_subject(list/batch, offset)
	var/subject_slot = join_u32_words(batch[offset + DOGMOS_CALLBACK_SUBJECT_SLOT_FIELD], batch[offset + DOGMOS_CALLBACK_SUBJECT_SLOT_FIELD + 1])
	var/subject_generation = join_u32_words(batch[offset + DOGMOS_CALLBACK_SUBJECT_GENERATION_FIELD], batch[offset + DOGMOS_CALLBACK_SUBJECT_GENERATION_FIELD + 1])
	var/target_slot = join_u32_words(batch[offset + DOGMOS_CALLBACK_TARGET_SLOT_FIELD], batch[offset + DOGMOS_CALLBACK_TARGET_SLOT_FIELD + 1])
	var/target_generation = join_u32_words(batch[offset + DOGMOS_CALLBACK_TARGET_GENERATION_FIELD], batch[offset + DOGMOS_CALLBACK_TARGET_GENERATION_FIELD + 1])
	var/turf/open/target = resolve_turf(target_slot, target_generation)
	var/datum/gas_mixture/mixture = isopenturf(target) ? target.air : null
	if(!mixture_identity_matches(mixture, subject_slot, subject_generation))
		mixture = null
	return list(mixture, subject_slot, subject_generation, target)

/** Dispatches a REACTION_FINISHED, REACTION_PROFILED, or RUN_DM_REACTION callback surfaced from
 * turf-stage FDM processing instead of a synchronous direct-reaction transaction. Mirrors the
 * equivalent kind handling in dispatch_reaction_callbacks() - same finish handlers, same
 * telemetry call, same continuation-resume call for a pending DM reaction - but without that
 * path's transaction-scoped re-drain loop: a turf-stage continuation has no transaction (id 0),
 * so any further events its resume produces route into the general queue and surface on the next
 * ordinary callback drain instead of needing to be chased synchronously here.
 */
/datum/controller/subsystem/dogmos/proc/dispatch_general_reaction_callback(list/batch, offset, kind)
	var/list/subject = decode_general_reaction_subject(batch, offset)
	var/datum/gas_mixture/mixture = subject[1]
	if(!mixture)
		record_stale_callback()
		return FALSE

	// Turf-stage reactions encode target as a turf handle (Rust's evaluate_reaction_sequence()
	// is called with target = turf.into()), not a holder handle - those are separate slot
	// registries. dispatch_reaction_callbacks() resolves target via resolve_holder() because its
	// caller is the synchronous single-mixture path, which registers a real holder; this path has
	// no holder registration and must resolve the turf directly. The finish procs below accept
	// any datum, so passing the turf through as "holder" is valid.
	var/datum/holder = subject[4]
	var/value_one = batch[offset + DOGMOS_CALLBACK_VALUES_FIELD]
	var/value_two = batch[offset + DOGMOS_CALLBACK_VALUES_FIELD + 1]
	var/value_three = batch[offset + DOGMOS_CALLBACK_VALUES_FIELD + 2]
	var/value_four = batch[offset + DOGMOS_CALLBACK_VALUES_FIELD + 3]
	var/aux = join_u32_words(batch[offset + DOGMOS_CALLBACK_AUX_FIELD], batch[offset + DOGMOS_CALLBACK_AUX_FIELD + 1])

	if(kind == DOGMOS_CALLBACK_REACTION_PROFILED)
		var/datum/gas_reaction/standard/profiled_reaction = dogmos_reaction_ids[aux + 1]
		if(!istype(profiled_reaction))
			CRASH("Dogmos profiled unknown reaction id [aux].")
		SSair.kennel_record_reaction_cost(profiled_reaction.id, holder, value_one)
		return TRUE

	if(kind == DOGMOS_CALLBACK_RUN_DM_REACTION)
		var/datum/gas_reaction/standard/reaction = dogmos_reaction_ids[aux + 1]
		if(!istype(reaction))
			CRASH("Dogmos requested unknown DM reaction id [aux].")
		var/reaction_result = reaction.react(mixture, holder)
		if((reaction_result & (REACTING | VOLATILE_REACTION)) && isopenturf(holder))
			SSair.dogmos_reacted_turfs[holder] = TRUE
		var/list/resume_fields = batch.Copy(offset + DOGMOS_CALLBACK_CONTINUATION_TOKEN_FIELD, offset + DOGMOS_CALLBACK_CONTINUATION_TOKEN_FIELD + 10)
		resume_fields += reaction_result
		var/list/progress = dogmos_continuation_resume(resume_fields)
		if(!islist(progress) || length(progress) != 8 || progress[1] != DOGMOS_RESPONSE_REACTION_PROGRESS)
			CRASH("dogmosd returned malformed continuation progress for a turf-stage DM reaction.")
		// Unlike dispatch_reaction_callbacks()'s transaction-scoped loop, no synchronous re-drain
		// is needed here: this continuation has no transaction (turf-stage origin), so any further
		// events the resume produces route back into the general queue (transaction id 0) and get
		// picked up by the next ordinary callback drain instead of needing to be chased here.
		return TRUE

	switch(aux)
		if(DOGMOS_REACTION_PLASMA)
			dogmos_aphelion_plasmafire_finish(mixture, holder, value_one, value_two)
		if(DOGMOS_REACTION_HYDROGEN)
			dogmos_aphelion_h2fire_finish(mixture, holder, value_one, value_two)
		if(DOGMOS_REACTION_TRITIUM)
			dogmos_aphelion_tritfire_finish(mixture, holder, value_one, value_two, value_three, value_four)
		if(DOGMOS_REACTION_FREON)
			dogmos_aphelion_freonfire_finish(mixture, holder, value_one, value_two, value_three)
		else
			CRASH("Dogmos returned unknown native reaction kind [aux].")
	if(isopenturf(holder))
		SSair.dogmos_reacted_turfs[holder] = TRUE
	return TRUE

/** Completes a retained general callback batch without a time limit before a synchronous reaction. */
/datum/controller/subsystem/dogmos/proc/flush_pending_general_callbacks()
	if(!dogmos_pending_callback_batch)
		return
	var/returned = validate_callback_batch(dogmos_pending_callback_batch, DOGMOS_CALLBACK_SCOPE_GENERAL, list(0, 0, 0, 0))
	while(dogmos_pending_callback_index < returned)
		var/offset = DOGMOS_CALLBACK_EVENT_START + dogmos_pending_callback_index * DOGMOS_CALLBACK_EVENT_FIELDS
		if(!dispatch_general_callback(dogmos_pending_callback_batch, offset))
			dogmos_pending_callback_batch = null
			dogmos_pending_callback_index = 0
			dogmos_pending_service_callbacks = 0
			SSair.dogmos_fail_closed_stage("callback sequence")
			return
		dogmos_pending_callback_index++
	dogmos_pending_callback_batch = null
	dogmos_pending_callback_index = 0
	dogmos_pending_service_callbacks = 0

/** Dispatches the callback kinds required by synchronous mixture reactions. */
/datum/controller/subsystem/dogmos/proc/dispatch_reaction_callbacks(datum/gas_mixture/expected_mixture, list/progress, reaction_profile_threshold_ms)
	if(!islist(progress) || length(progress) != 8 || progress[1] != DOGMOS_RESPONSE_REACTION_PROGRESS)
		CRASH("dogmosd returned malformed reaction progress.")
	var/list/transaction_words = progress.Copy(5, 9)
	if(!transaction_words[1] && !transaction_words[2] && !transaction_words[3] && !transaction_words[4])
		CRASH("dogmosd returned a zero direct-reaction transaction.")
	var/list/next_sequence = list(1, 0, 0, 0)
	var/maximum_events
	var/events_processed = 0
	while(TRUE)
		var/list/drain_fields = list(DOGMOS_CALLBACK_SCOPE_REACTION)
		drain_fields += transaction_words
		drain_fields += split_u32_words(DOGMOS_CALLBACK_BATCH_SIZE)
		var/list/batch = dogmos_callback_drain(drain_fields)
		var/returned = validate_callback_batch(batch, DOGMOS_CALLBACK_SCOPE_REACTION, transaction_words)
		if(isnull(maximum_events))
			var/events_per_reaction = isnull(reaction_profile_threshold_ms) ? 1 : 2
			maximum_events = join_u32_words(batch[5], batch[6]) + length(dogmos_reaction_ids) * events_per_reaction + 1
		events_processed += returned
		if(events_processed > maximum_events || (!returned && progress[4]))
			CRASH("Dogmos reaction continuation exceeded the bounded callback capacity.")
		for(var/event_index in 0 to returned - 1)
			if(!returned)
				break
			var/offset = DOGMOS_CALLBACK_EVENT_START + event_index * DOGMOS_CALLBACK_EVENT_FIELDS
			var/kind = batch[offset + DOGMOS_CALLBACK_KIND_FIELD]
			if(kind != DOGMOS_CALLBACK_REACTION_FINISHED && kind != DOGMOS_CALLBACK_RUN_DM_REACTION && kind != DOGMOS_CALLBACK_REACTION_PROFILED)
				CRASH("Unexpected Dogmos callback kind [kind] during direct reaction processing.")
			var/sequence_error = consume_callback_sequence(batch, offset, next_sequence)
			if(sequence_error)
				CRASH(sequence_error)

			var/subject_slot = join_u32_words(batch[offset + DOGMOS_CALLBACK_SUBJECT_SLOT_FIELD], batch[offset + DOGMOS_CALLBACK_SUBJECT_SLOT_FIELD + 1])
			var/subject_generation = join_u32_words(batch[offset + DOGMOS_CALLBACK_SUBJECT_GENERATION_FIELD], batch[offset + DOGMOS_CALLBACK_SUBJECT_GENERATION_FIELD + 1])
			var/datum/gas_mixture/mixture = expected_mixture
			if(!mixture_identity_matches(mixture, subject_slot, subject_generation))
				CRASH("Dogmos reaction callback referenced a stale or unexpected gas mixture.")

			var/target_slot = join_u32_words(batch[offset + DOGMOS_CALLBACK_TARGET_SLOT_FIELD], batch[offset + DOGMOS_CALLBACK_TARGET_SLOT_FIELD + 1])
			var/target_generation = join_u32_words(batch[offset + DOGMOS_CALLBACK_TARGET_GENERATION_FIELD], batch[offset + DOGMOS_CALLBACK_TARGET_GENERATION_FIELD + 1])
			var/datum/holder = resolve_holder(target_slot, target_generation)
			var/value_one = batch[offset + DOGMOS_CALLBACK_VALUES_FIELD]
			var/value_two = batch[offset + DOGMOS_CALLBACK_VALUES_FIELD + 1]
			var/value_three = batch[offset + DOGMOS_CALLBACK_VALUES_FIELD + 2]
			var/value_four = batch[offset + DOGMOS_CALLBACK_VALUES_FIELD + 3]
			var/aux = join_u32_words(batch[offset + DOGMOS_CALLBACK_AUX_FIELD], batch[offset + DOGMOS_CALLBACK_AUX_FIELD + 1])
			if(kind == DOGMOS_CALLBACK_REACTION_PROFILED)
				var/datum/gas_reaction/standard/profiled_reaction = dogmos_reaction_ids[aux + 1]
				if(!istype(profiled_reaction))
					CRASH("Dogmos profiled unknown reaction id [aux].")
				SSair.kennel_record_reaction_cost(profiled_reaction.id, holder, value_one)
				continue

			if(kind == DOGMOS_CALLBACK_REACTION_FINISHED)
				switch(aux)
					if(DOGMOS_REACTION_PLASMA)
						dogmos_aphelion_plasmafire_finish(mixture, holder, value_one, value_two)
					if(DOGMOS_REACTION_HYDROGEN)
						dogmos_aphelion_h2fire_finish(mixture, holder, value_one, value_two)
					if(DOGMOS_REACTION_TRITIUM)
						dogmos_aphelion_tritfire_finish(mixture, holder, value_one, value_two, value_three, value_four)
					if(DOGMOS_REACTION_FREON)
						dogmos_aphelion_freonfire_finish(mixture, holder, value_one, value_two, value_three)
					else
						CRASH("Dogmos returned unknown native reaction kind [aux].")
				if(isopenturf(holder))
					SSair.dogmos_reacted_turfs[holder] = TRUE
				continue

			var/datum/gas_reaction/standard/reaction = dogmos_reaction_ids[aux + 1]
			if(!istype(reaction))
				CRASH("Dogmos requested unknown DM reaction id [aux].")
			var/reaction_started = isnull(reaction_profile_threshold_ms) ? null : TICK_USAGE_REAL
			var/reaction_result = reaction.react(mixture, holder)
			if((reaction_result & (REACTING | VOLATILE_REACTION)) && isopenturf(holder))
				SSair.dogmos_reacted_turfs[holder] = TRUE
			if(!isnull(reaction_started))
				var/reaction_cost_ms = TICK_DELTA_TO_MS(TICK_USAGE_REAL - reaction_started)
				if(reaction_cost_ms >= reaction_profile_threshold_ms)
					SSair.kennel_record_reaction_cost(reaction.id, holder, reaction_cost_ms)
			var/list/resume_fields = batch.Copy(offset + DOGMOS_CALLBACK_CONTINUATION_TOKEN_FIELD, offset + DOGMOS_CALLBACK_CONTINUATION_TOKEN_FIELD + 10)
			resume_fields += reaction_result
			progress = dogmos_continuation_resume(resume_fields)
			if(!islist(progress) || length(progress) != 8 || progress[1] != DOGMOS_RESPONSE_REACTION_PROGRESS || !equal_u64_words(progress.Copy(5, 9), transaction_words))
				CRASH("dogmosd returned malformed continuation progress.")

		if(!progress[4])
			if(join_u32_words(batch[3], batch[4]))
				continue
			return progress

/// Drains bounded Dogmos callbacks on the Dream Maker main thread.
/proc/process_atmos_callbacks(remaining)
	var/start_tick_usage = TICK_USAGE
	var/time_budget_ms = max(0, remaining)
	if(time_budget_ms <= 0)
		return TRUE
	if(!SSdogmos.dogmos_pending_callback_batch)
		var/list/drain_fields = list(DOGMOS_CALLBACK_SCOPE_GENERAL, 0, 0, 0, 0)
		drain_fields += SSdogmos.split_u32_words(DOGMOS_CALLBACK_BATCH_SIZE)
		SSdogmos.dogmos_pending_callback_batch = dogmos_callback_drain(drain_fields)
		SSdogmos.dogmos_pending_callback_index = 0
		// Validated once on receipt and reused on every resume below instead of re-validating and
		// re-walking the whole retained batch on every single invocation across ticks.
		SSdogmos.dogmos_pending_callback_count = SSdogmos.validate_callback_batch(SSdogmos.dogmos_pending_callback_batch, DOGMOS_CALLBACK_SCOPE_GENERAL, list(0, 0, 0, 0))
		SSdogmos.dogmos_pending_service_callbacks = SSdogmos.join_u32_words(
			SSdogmos.dogmos_pending_callback_batch[3],
			SSdogmos.dogmos_pending_callback_batch[4],
		)

	var/returned = SSdogmos.dogmos_pending_callback_count
	while(SSdogmos.dogmos_pending_callback_index < returned)
		if(TICK_DELTA_TO_MS(TICK_USAGE - start_tick_usage) >= time_budget_ms)
			return TRUE
		var/offset = DOGMOS_CALLBACK_EVENT_START + SSdogmos.dogmos_pending_callback_index * DOGMOS_CALLBACK_EVENT_FIELDS
		if(!SSdogmos.dispatch_general_callback(SSdogmos.dogmos_pending_callback_batch, offset))
			SSdogmos.dogmos_pending_callback_batch = null
			SSdogmos.dogmos_pending_callback_index = 0
			SSdogmos.dogmos_pending_service_callbacks = 0
			return SSair.dogmos_fail_closed_stage("callback sequence")
		SSdogmos.dogmos_pending_callback_index++

	var/service_callbacks_remain = SSdogmos.dogmos_pending_service_callbacks
	SSdogmos.dogmos_pending_callback_batch = null
	SSdogmos.dogmos_pending_callback_index = 0
	SSdogmos.dogmos_pending_service_callbacks = 0
	// Resuming a DM reaction can append callbacks after the drain's remaining-count
	// snapshot. Require an observed empty drain before post-reaction settlement.
	return returned > 0 || service_callbacks_remain > 0
