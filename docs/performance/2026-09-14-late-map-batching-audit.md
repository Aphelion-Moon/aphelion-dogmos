# Late-map batching call-chain audit

Status: source audit; S1 implementation and qualification remain open. The inspected game checkout is detached at `1604655c7fa4d5e2e4c466132acb2ae64bb389b3` with the R1/R2/R5 candidates. Live Meridian-MCP generation 14 retains the 127 baseline DreamChecker errors and three warnings; this is separate from compiler evidence.

`SSair.StopLoadingMap()` clears `map_loading`, walks `queued_for_activation` in its existing order, registers each turf, calls `add_to_active(T, TRUE)`, and clears the queue only after the complete loop. A failed iteration leaves the queue intact. Preserve that clearing point and partial-prefix behavior.

## Registration and immediate reads

- `modular_aphelion/master_files/code/game/turfs/turf.dm`, `register_dogmos_air`: establishes a generation and initial solid temperature when absent, then calls `update_air_ref` with the actual current gas association.
- `modular_aphelion/modules/dogmos/code/service_backend.dm`, `update_air_ref`: fresh registration queues gas lifecycle and all seven heat fields, flushes full batches, then flushes partial batches when neither owner flag is set.
- Re-registration is **not write-only**: a non-null `dogmos_registered_mixture_slot` calls `__dogmos_heat_temperature` first. That getter uses matching queued heat data when available; otherwise it performs a native heat snapshot read. Preserve this read and the current solid temperature. Do not reuse a fresh-only call-count claim for re-registered turfs.
- `__dogmos_heat_temperature` reads only the exact current turf generation. It does not flush another owner's pending topology. Pending records already provide the same-turf read-through behavior needed by existing nested batches.

The initial S1 implementation should batch contiguous fresh registrations and restore/flush its own prefix before a re-registration that can perform a native read. Existing outer ownership and a frozen frontier still defer publication. This narrows the optimization to the proven scope without changing the read's visibility boundary. A later extension can batch re-registrations only with its own exact pending/native temperature transcript.

## Activation side effects

`add_to_active` wakes eligible atmosphere machines by adding them to the processing list; it does not execute those machines. It resets the share ticker, dismantles an excited group when requested, sets the excited flag and appends through the ordered frontier journal. Excited-group garbage collection clears member references, list membership and optional diagnostic visuals; it does not read gas or run a native stage. The fallback for a closed initialized turf recursively activates its existing adjacency list. None of these inspected bodies yields.

Fresh batching must retain register-then-activate order. It must not eagerly activate the entire queue, copy a map-sized work list, or clear entries that have not completed. Failure cleanup must restore the runtime owner, attempt only the permitted pending-prefix flush, retain a secondary flush diagnostic, and rethrow the original error.

## Qualification still required

The existing runtime topology call counter counts adjacency RPCs, not lifecycle and heat registration calls. It cannot establish the proposed 1/512/513 registration oracle. Add bounded lifecycle/heat request counters at the actual maintained dispatch points, preserving their recovery semantics, or use a separately verified profiler call-count witness. Setup and teardown must be excluded.

Required tests remain fresh 1/512/513 records, repeated/native heat reads, outer ownership, frozen frontier, activation order, failure prefix, and horizontal/multiz state. These findings do not establish a startup speedup. Repeated identical full-readiness measurements and main-server traces remain required.
