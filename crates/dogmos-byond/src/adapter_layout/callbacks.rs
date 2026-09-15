//! Maintained callbacks adapter field order, encoding and units.

record_layout! { callback_request, "CALLBACK_REQUEST";
	(SCOPE, 1, "enum/tag, existing protocol values", "scope", "scope"),
	(TRANSACTION, 4, "exact u16 words, 0..65535 each", "identity", "transaction"),
	(MAX_EVENTS, 2, "exact u16 words, 0..65535 each", "count", "max events"),
}

record_layout! { callback_header, "CALLBACK_HEADER";
	(RETURNED, 2, "exact u16 words, 0..65535 each", "count", "returned"),
	(REMAINING, 2, "exact u16 words, 0..65535 each", "count", "remaining"),
	(CAPACITY, 2, "exact u16 words, 0..65535 each", "count", "capacity"),
	(HIGH_WATER, 2, "exact u16 words, 0..65535 each", "count", "high water"),
	(REJECTED, 4, "exact u16 words, 0..65535 each", "count", "rejected"),
}

record_layout! { continuation_token, "CONTINUATION_TOKEN";
	(WORLD_GENERATION, 2, "exact u16 words, 0..65535 each", "identity", "world generation"),
	(ID, 4, "exact u16 words, 0..65535 each", "identity", "id"),
	(DEADLINE, 4, "exact u16 words, 0..65535 each", "ticks", "deadline"),
}

record_layout! { callback_event, "CALLBACK_EVENT";
	(SEQUENCE, 4, "exact u16 words, 0..65535 each", "identity", "sequence"),
	(TRANSACTION, 4, "exact u16 words, 0..65535 each", "identity", "transaction"),
	(SCOPE, 1, "enum/tag, existing protocol values", "scope", "scope"),
	(KIND, 1, "enum/tag, existing protocol values", "kind", "kind"),
	(FLAGS, 1, "reserved, zero", "flags", "flags"),
	(SUBJECT_SLOT, 2, "exact u16 words, 0..65535 each", "identity", "subject slot"),
	(SUBJECT_GENERATION, 2, "exact u16 words, 0..65535 each", "identity", "subject generation"),
	(TARGET_SLOT, 2, "exact u16 words, 0..65535 each", "identity", "target slot"),
	(TARGET_GENERATION, 2, "exact u16 words, 0..65535 each", "identity", "target generation"),
	(VALUES, 4, "finite scalar, protocol domain validated", "event-dependent", "values"),
	(AUX, 2, "exact u16 words, 0..65535 each", "event-dependent", "aux"),
	(TOKEN_PRESENT, 1, "boolean, 0 or 1", "flag", "token present"),
	(TOKEN, super::continuation_token::LEN, "continuation_token record", "record", "All-zero token words when absent"),
}

record_layout! { continuation_command, "CONTINUATION_COMMAND";
	(TOKEN, super::continuation_token::LEN, "continuation_token record", "record", "token"),
	(COMMAND, crate::adapter_layout::mixtures::mixture_command::LEN, "mixture_command record", "record", "command"),
}

record_layout! { continuation_resume, "CONTINUATION_RESUME";
	(TOKEN, super::continuation_token::LEN, "continuation_token record", "record", "token"),
	(REACTION_RESULT, 1, "exact unsigned integer, 0..16777216", "existing reaction flags", "reaction result"),
}

pub(crate) const LAYOUTS: &[&crate::adapter_layout::Layout] = &[
	&callback_request::LAYOUT,
	&callback_header::LAYOUT,
	&continuation_token::LAYOUT,
	&callback_event::LAYOUT,
	&continuation_command::LAYOUT,
	&continuation_resume::LAYOUT,
];
