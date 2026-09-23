# Reaction and input contract

The in-process gas-string loader accepts a complete semicolon-separated list of
`id=number` entries, optional outer whitespace, and one trailing semicolon. Empty
input clears gas amounts and preserves temperature. `TEMP` is the only metadata
key. Duplicate keys use their last value, including zero. Negative gas amounts,
unknown IDs, non-finite values and unparsed suffixes fail without changing the
destination. Finite temperatures below TCMB are clamped. Volume, minimum heat
capacity and immutability are preserved.

Migration: the old prefix parser silently accepted malformed suffixes and names
containing `TEMP`. Those inputs now produce caller-visible errors. The internal
prefix parser remains for inspection; the public loader always validates the
whole request. Meridian's map/config atmosphere cache currently uses its DM
`params2list` path, not this native export; changing that separate grammar is not
part of this correction.

Reaction publication validates nonempty IDs, finite priorities, non-negative
finite requirements, supported requirement keys, registered gas IDs, temperature
bounds, duplicate IDs/hash collisions and duplicate priorities. A rejected
replacement leaves both existing tables intact. The whole reaction chain holds
a dispatch scope: registry replacement and world teardown/initialization are
rejected during dispatch. No registry borrow crosses a DM callback.

Eligibility is captured at the beginning of the chain. Newly eligible reactions
wait until the next opportunity, and reaction bodies retain their current-state
guards. This preserves the current native scheduling contract; registry safety
does not silently introduce repeated global eligibility evaluation.

Callback budgets are finite non-negative milliseconds, including fractions. Zero
admits no callback; a positive budget checks elapsed time before dequeue. The
return value indicates actual queued work. Running DM callbacks cannot be
preempted, so the budget is an admission deadline, not a hard execution bound.

An unexpected FFI/initialization panic latches uncertain simulation state. Further
simulation calls and callback production/execution are rejected; identity,
metrics and shutdown remain available. Only clean shutdown followed by new-world
initialization clears the latch. Ordinary invalid inputs do not fault the world.
Initialization errors also fault admission because registry setup may be partial.
This does not recover access violations, allocation aborts or arbitrary native
faults, and does not authorize mid-round recovery.
