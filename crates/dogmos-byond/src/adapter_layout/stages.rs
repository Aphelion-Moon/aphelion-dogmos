//! Maintained stages adapter field order, encoding and units.

record_layout! { epoch, "EPOCH";
	(EPOCH, 4, "exact u16 words, 0..65535 each", "identity", "epoch"),
}

record_layout! { word_count, "WORD_COUNT";
	(COUNT, 2, "exact u16 words, 0..65535 each", "count", "count"),
}

record_layout! { frontier_begin, "FRONTIER_BEGIN";
	(EPOCH, 4, "exact u16 words, 0..65535 each", "identity", "epoch"),
	(EXPECTED_COUNT, 2, "exact u16 words, 0..65535 each", "count", "expected count"),
}

record_layout! { frontier_append_header, "FRONTIER_APPEND_HEADER";
	(EPOCH, 4, "exact u16 words, 0..65535 each", "identity", "epoch"),
	(OFFSET, 2, "exact u16 words, 0..65535 each", "handle count", "offset"),
}

record_layout! { frontier_commit_response, "FRONTIER_COMMIT_RESPONSE";
	(EPOCH, 4, "exact u16 words, 0..65535 each", "identity", "epoch"),
	(COUNT, 2, "exact u16 words, 0..65535 each", "count", "count"),
}

record_layout! { stage_request, "STAGE_REQUEST";
	(STAGE, 1, "enum/tag, existing protocol values", "kind", "stage"),
	(FRONTIER_EPOCH, 4, "exact u16 words, 0..65535 each", "identity", "frontier epoch"),
	(STAGE_EPOCH, 4, "exact u16 words, 0..65535 each", "identity", "stage epoch"),
	(WORK_LIMIT, 2, "exact u16 words, 0..65535 each", "count", "work limit"),
	(SECONDS_PER_TICK, 1, "finite scalar, protocol domain validated", "seconds", "seconds per tick"),
}

record_layout! { stage_response, "STAGE_RESPONSE";
	(WORK_ITEMS, 2, "exact u16 words, 0..65535 each", "count", "work items"),
	(CALLBACK_EVENTS, 2, "exact u16 words, 0..65535 each", "count", "callback events"),
	(PENDING, 1, "boolean, 0 or 1", "flag", "pending"),
	(REMAINING, 2, "exact u16 words, 0..65535 each", "count", "remaining"),
	(EQUALIZE_SEEDS, 2, "exact u16 words, 0..65535 each", "count", "equalize seeds"),
	(GROUP_SEEDS, 2, "exact u16 words, 0..65535 each", "count", "group seeds"),
	(HEAT_SEEDS, 2, "exact u16 words, 0..65535 each", "count", "heat seeds"),
}

record_layout! { job_submit, "JOB_SUBMIT";
	(STAGE, 1, "enum/tag, existing protocol values", "kind", "stage"),
	(FRONTIER_EPOCH, 4, "exact u16 words, 0..65535 each", "identity", "frontier epoch"),
	(STAGE_EPOCH, 4, "exact u16 words, 0..65535 each", "identity", "stage epoch"),
	(WORK_LIMIT, 2, "exact u16 words, 0..65535 each", "count", "work limit"),
	(SECONDS_PER_TICK, 1, "finite scalar, protocol domain validated", "seconds", "seconds per tick"),
	(QUANTUM_US, 1, "exact unsigned integer, 0..16777216", "microseconds", "quantum us"),
}

record_layout! { job_identity, "JOB_IDENTITY";
	(JOB, 4, "exact u16 words, 0..65535 each", "nonzero identity", "job"),
}

record_layout! { job_commit, "JOB_COMMIT";
	(JOB, 4, "exact u16 words, 0..65535 each", "nonzero identity", "job"),
	(UNIT, 4, "exact u16 words, 0..65535 each", "nonzero identity", "unit"),
}

record_layout! { job_response, "JOB_RESPONSE";
	(JOB, 4, "exact u16 words, 0..65535 each", "identity", "job"),
	(STATUS, 1, "enum/tag, existing protocol values", "status", "status"),
	(STAGE, 1, "enum/tag, existing protocol values", "kind", "stage"),
	(UNIT, 4, "exact u16 words, 0..65535 each", "identity", "unit"),
	(WORK_ITEMS, 2, "exact u16 words, 0..65535 each", "count", "work items"),
	(REMAINING, 2, "exact u16 words, 0..65535 each", "count", "remaining"),
	(COMMITTED_UNITS, 4, "exact u16 words, 0..65535 each", "count", "committed units"),
	(EQUALIZE_SEEDS, 2, "exact u16 words, 0..65535 each", "count", "equalize seeds"),
	(GROUP_SEEDS, 2, "exact u16 words, 0..65535 each", "count", "group seeds"),
	(HEAT_SEEDS, 2, "exact u16 words, 0..65535 each", "count", "heat seeds"),
	(CALLBACK_EVENTS, 2, "exact u16 words, 0..65535 each", "count", "callback events"),
}

pub(crate) const LAYOUTS: &[&crate::adapter_layout::Layout] = &[
	&epoch::LAYOUT,
	&word_count::LAYOUT,
	&frontier_begin::LAYOUT,
	&frontier_append_header::LAYOUT,
	&frontier_commit_response::LAYOUT,
	&stage_request::LAYOUT,
	&stage_response::LAYOUT,
	&job_submit::LAYOUT,
	&job_identity::LAYOUT,
	&job_commit::LAYOUT,
	&job_response::LAYOUT,
];
