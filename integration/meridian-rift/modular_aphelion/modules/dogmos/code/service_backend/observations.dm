/** Converts the shim's exact 16-bit word pair back into a 32-bit identity field. */
/datum/controller/subsystem/dogmos/proc/join_u32_words(low_word, high_word)
	return low_word + high_word * DOGMOS_PROCESS_WORD_BASE

/** Converts four exact 16-bit words into one unsigned process metric. */
/datum/controller/subsystem/dogmos/proc/join_u64_words(word_one, word_two, word_three, word_four)
	return word_one + DOGMOS_PROCESS_WORD_BASE * (word_two + DOGMOS_PROCESS_WORD_BASE * (word_three + DOGMOS_PROCESS_WORD_BASE * word_four))

/** Splits one bounded nonnegative integer into two exact little-endian 16-bit words. */
/datum/controller/subsystem/dogmos/proc/split_u32_words(value)
	if(!IS_FINITE(value) || value < 0 || value > DOGMOS_MAX_EXACT_INTEGER || round(value) != value)
		CRASH("Dogmos cannot encode invalid u32-compatible value [value].")
	return list(value % DOGMOS_PROCESS_WORD_BASE, floor(value / DOGMOS_PROCESS_WORD_BASE))

/** Advances one four-word exact epoch without converting it to an imprecise DM number. */
/datum/controller/subsystem/dogmos/proc/increment_u64_words(list/words)
	if(!islist(words) || length(words) != 4)
		CRASH("Dogmos received a malformed exact epoch.")
	var/list/advanced = words.Copy()
	for(var/word_index in 1 to 4)
		if(advanced[word_index] < DOGMOS_PROCESS_WORD_MAX)
			advanced[word_index]++
			return advanced
		advanced[word_index] = 0
	CRASH("Dogmos exact epoch capacity exhausted.")

/** Returns whether two exact four-word epochs are identical. */
/datum/controller/subsystem/dogmos/proc/equal_u64_words(list/left, list/right)
	if(!islist(left) || !islist(right) || length(left) != 4 || length(right) != 4)
		return FALSE
	for(var/word_index in 1 to 4)
		if(left[word_index] != right[word_index])
			return FALSE
	return TRUE

/** Returns whether a list is one exact unsigned 32-bit value encoded as two 16-bit words. */
/datum/controller/subsystem/dogmos/proc/u32_words_are_valid(list/words)
	if(!islist(words) || length(words) != 2)
		return FALSE
	for(var/word in words)
		if(!isnum(word) || !IS_FINITE(word) || word < 0 || word > DOGMOS_PROCESS_WORD_MAX || round(word) != word)
			return FALSE
	return TRUE

/** Validates and decodes one fixed-width process-metrics snapshot. */
/datum/controller/subsystem/dogmos/proc/decode_process_metrics(list/words)
	if(!islist(words) || length(words) != DOGMOS_PROCESS_METRICS_WORDS)
		return null
	for(var/word in words)
		if(!IS_FINITE(word) || word < 0 || word > DOGMOS_PROCESS_WORD_MAX || round(word) != word)
			return null

	var/layout_version = join_u32_words(words[DOGMOS_PROCESS_LAYOUT_WORD], words[DOGMOS_PROCESS_LAYOUT_WORD + 1])
	var/dreamdaemon_flags = join_u32_words(words[DOGMOS_PROCESS_HOST_FLAGS_WORD], words[DOGMOS_PROCESS_HOST_FLAGS_WORD + 1])
	var/service_flags = join_u32_words(words[DOGMOS_PROCESS_SERVICE_FLAGS_WORD], words[DOGMOS_PROCESS_SERVICE_FLAGS_WORD + 1])
	var/reserved = join_u32_words(words[DOGMOS_PROCESS_RESERVED_WORD], words[DOGMOS_PROCESS_RESERVED_WORD + 1])
	if(layout_version != DOGMOS_PROCESS_METRICS_LAYOUT_VERSION || dreamdaemon_flags > DOGMOS_DREAMDAEMON_ALL_AVAILABLE || service_flags > DOGMOS_SERVICE_ALL_AVAILABLE || reserved)
		return null

	var/private_bytes = join_u64_words(words[DOGMOS_PROCESS_HOST_PRIVATE_BYTES_WORD], words[DOGMOS_PROCESS_HOST_PRIVATE_BYTES_WORD + 1], words[DOGMOS_PROCESS_HOST_PRIVATE_BYTES_WORD + 2], words[DOGMOS_PROCESS_HOST_PRIVATE_BYTES_WORD + 3])
	var/virtual_bytes = join_u64_words(words[DOGMOS_PROCESS_HOST_VIRTUAL_BYTES_WORD], words[DOGMOS_PROCESS_HOST_VIRTUAL_BYTES_WORD + 1], words[DOGMOS_PROCESS_HOST_VIRTUAL_BYTES_WORD + 2], words[DOGMOS_PROCESS_HOST_VIRTUAL_BYTES_WORD + 3])
	var/working_set_bytes = join_u64_words(words[DOGMOS_PROCESS_HOST_WORKING_SET_BYTES_WORD], words[DOGMOS_PROCESS_HOST_WORKING_SET_BYTES_WORD + 1], words[DOGMOS_PROCESS_HOST_WORKING_SET_BYTES_WORD + 2], words[DOGMOS_PROCESS_HOST_WORKING_SET_BYTES_WORD + 3])
	var/service_rss_bytes = join_u64_words(words[DOGMOS_PROCESS_SERVICE_RSS_BYTES_WORD], words[DOGMOS_PROCESS_SERVICE_RSS_BYTES_WORD + 1], words[DOGMOS_PROCESS_SERVICE_RSS_BYTES_WORD + 2], words[DOGMOS_PROCESS_SERVICE_RSS_BYTES_WORD + 3])
	var/service_cpu_total_milliseconds = join_u64_words(words[DOGMOS_PROCESS_SERVICE_CPU_MILLISECONDS_WORD], words[DOGMOS_PROCESS_SERVICE_CPU_MILLISECONDS_WORD + 1], words[DOGMOS_PROCESS_SERVICE_CPU_MILLISECONDS_WORD + 2], words[DOGMOS_PROCESS_SERVICE_CPU_MILLISECONDS_WORD + 3])
	if(!(dreamdaemon_flags & DOGMOS_DREAMDAEMON_PRIVATE_BYTES_AVAILABLE) && private_bytes)
		return null
	if(!(dreamdaemon_flags & DOGMOS_DREAMDAEMON_VIRTUAL_BYTES_AVAILABLE) && virtual_bytes)
		return null
	if(!(dreamdaemon_flags & DOGMOS_DREAMDAEMON_WORKING_SET_BYTES_AVAILABLE) && working_set_bytes)
		return null
	if(!(service_flags & DOGMOS_SERVICE_RSS_BYTES_AVAILABLE) && service_rss_bytes)
		return null
	if(!(service_flags & DOGMOS_SERVICE_CPU_MILLISECONDS_AVAILABLE) && service_cpu_total_milliseconds)
		return null

	return list(
		"dreamdaemon" = list(
			"private_bytes" = private_bytes,
			"virtual_bytes" = virtual_bytes,
			"working_set_bytes" = working_set_bytes,
			"available" = dreamdaemon_flags == DOGMOS_DREAMDAEMON_ALL_AVAILABLE,
		),
		"dogmosd" = list(
			"rss_bytes" = service_rss_bytes,
			"cpu_total_milliseconds" = service_cpu_total_milliseconds,
			"available" = service_flags == DOGMOS_SERVICE_ALL_AVAILABLE,
		),
	)

/** Returns one validated on-demand snapshot of DreamDaemon and dogmosd process metrics. */
/proc/dogmos_process_metrics_snapshot()
	var/list/decoded = SSdogmos.decode_process_metrics(dogmos_process_metrics())
	if(!decoded)
		CRASH("dogmosd returned malformed process metrics.")
	return decoded

/** Decodes bounded protocol-16 job observations, retaining exact words alongside display durations. */
/datum/controller/subsystem/dogmos/proc/decode_job_observations(list/words)
	if(!islist(words) || length(words) != DOGMOS_SERVICE_TELEMETRY_WORDS)
		return null
	for(var/index in DOGMOS_JOB_TELEMETRY_START to DOGMOS_SERVICE_TELEMETRY_WORDS)
		var/word = words[index]
		if(!isnum(word) || !IS_FINITE(word) || word < 0 || word > DOGMOS_PROCESS_WORD_MAX || round(word) != word)
			return null
	var/list/job_words = words.Copy(DOGMOS_JOB_TELEMETRY_START, DOGMOS_JOB_TELEMETRY_STATUS)
	var/status = join_u32_words(words[DOGMOS_JOB_TELEMETRY_STATUS], words[DOGMOS_JOB_TELEMETRY_STATUS + 1])
	var/has_job = job_words[1] || job_words[2] || job_words[3] || job_words[4]
	if(status > 6 || (!has_job != !status))
		return null
	if(!has_job && (words[189] || words[190] || words[191] || words[192]))
		return null
	var/list/decoded = list(
		"job_words" = job_words,
		"status" = status,
		"raw_words" = words.Copy(DOGMOS_JOB_TELEMETRY_START),
	)
	var/static/list/counter_names = list(
		"age", "prepare_calls", "prepare_total", "prepare_max", "prepare_last",
		"commit_calls", "commit_total", "commit_max", "commit_last",
		"publication_retries", "completed_jobs", "cancelled_jobs",
	)
	var/static/list/duration_names = list("age", "prepare_total", "prepare_max", "prepare_last", "commit_total", "commit_max", "commit_last")
	for(var/index in 1 to length(counter_names))
		var/name = counter_names[index]
		var/start = DOGMOS_JOB_TELEMETRY_COUNTERS + (index - 1) * 4
		decoded["[name]_words"] = words.Copy(start, start + 4)
		if(name in duration_names)
			decoded["[name]_ms"] = join_u64_words(words[start], words[start + 1], words[start + 2], words[start + 3]) / 1000000
	return decoded

/** Collects one on-demand observation; this RPC is never added to normal atmosphere ticking. */
/proc/dogmos_job_observations_snapshot()
	var/list/decoded = SSdogmos.decode_job_observations(dogmos_service_telemetry())
	if(!decoded)
		CRASH("dogmosd returned malformed job observations.")
	return decoded

/// Returns the number of registered mixture slots.
/datum/controller/subsystem/air/proc/get_max_gas_mixes()
	return length(SSdogmos.dogmos_mixture_slots)

/// Returns the number of live registered mixtures.
/datum/controller/subsystem/air/proc/get_amt_gas_mixes()
	return length(SSdogmos.dogmos_mixture_slots) - length(SSdogmos.dogmos_free_mixture_slots)

/// Returns the number of reactions accepted by dogmosd.
/proc/dogmos_reaction_count()
	return length(SSdogmos.dogmos_reaction_ids)

/// Returns the number of FFI panics exposed by the service adapter.
/proc/dogmos_ffi_panic_count()
	return 0

/// Returns callback rejection telemetry from dogmosd.
/proc/dogmos_callback_enqueue_failures()
	var/list/telemetry = dogmos_service_telemetry()
	return SSdogmos.join_u32_words(telemetry[25], telemetry[26])

/// Returns the number of stale turf callbacks rejected by the DM identity boundary.
/proc/dogmos_stale_callback_count()
	return SSdogmos.dogmos_stale_callback_count

/// Returns the bounded service telemetry list.
/proc/dogmos_perf_snapshot()
	return json_encode(dogmos_service_telemetry())

/// Detailed service telemetry is always bounded and cannot be disabled.
/proc/dogmos_perf_set_detailed(enabled)
	return TRUE
