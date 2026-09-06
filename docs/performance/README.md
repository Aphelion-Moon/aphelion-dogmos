# Dogmos performance evidence

Reviewed 2026-08-30 resource-management results are in
[`2026-08-30-resource-management-results.md`](2026-08-30-resource-management-results.md). The
separate transaction follow-up is specified in
[`2026-08-30-transaction-scratch-arena-design.md`](2026-08-30-transaction-scratch-arena-design.md)
and qualified in
[`2026-08-30-transaction-scratch-arena-results.md`](2026-08-30-transaction-scratch-arena-results.md).

This directory defines reproducible workloads and acceptance budgets for the current in-process
Dogmos backend and the later 64-bit service. DreamDaemon memory and service-process memory are
always recorded separately. Only DreamDaemon footprint is used for the BYOND memory target.

Every live result records the exact map, seed, Rust revision, feature set, BYOND version, duration,
and SHA-256 of the workload file. Results with different identities are not comparable. Raw output
belongs under ignored `tmp/dogmos-perf/<revision>/<run-id>/`; checked-in documents contain only the
workload contract, measured noise budget, and reviewed summaries.

Use `tools/perf/Invoke-DogmosWorkload.ps1 -ValidateOnly` to validate the corpus. Use
`tools/perf/Measure-DogmosProcesses.ps1` to sample exact DreamDaemon and optional `dogmosd` PIDs.
Use `tools/perf/Compare-DogmosPerformance.ps1` to reject incompatible runs and calculate deltas.
DreamMaker source discovery and Tracy capture must go through Meridian-MCP after
`dm_parse_environment`; PowerShell owns process sampling and checked-in build/test entry points.

The live workload profiles require explicit in-game markers. A profile is not accepted merely
because DreamDaemon remained alive: every listed marker and correctness assertion must be recorded.

## Core stage allocation probe

Run the native core-only allocation probe in a fresh process:

```powershell
cargo +1.98.0 run --release --locked -p dogmos-perf --example core_stage_allocations -- --output "tmp/dogmos-perf/core-control.csv"
```

The probe constructs corridor, grid, and three-layer multiz fixtures at 1,000, 10,000, and 100,000
turfs. It measures three successive cycles of process-turfs, turf-heat, equalize, excited-groups,
and React, resetting an atomic `System` allocator wrapper before each cycle. React uses an empty
reaction inventory. The current CSV has 135 rows and reports allocations,
deallocations, allocated and deallocated bytes, charged work items, a final-state and ordered-event
transcript hash, and the active reusable-vector capacity lower bound. Allocation counts rank
allocation-removal work; they are not wall-time acceptance evidence.

`reusable_workset_bytes` is a lower bound over active vector capacities. It includes the complete
four-field heat-edge tuple and the component transaction's slot index, bitset, and dense entries;
it excludes tree nodes and allocator metadata. Reusable stage buffers retain their capacity after
a successful commit; cancellation can discard in-flight component storage. Retained event capacity
can remain visible until events are drained.

## Core stage latency probe

```powershell
cargo +1.98.0 run --release --locked --offline --target x86_64-pc-windows-msvc -p dogmos-perf --example core_stage_latency -- --output "tmp/dogmos-perf/core-latency.csv"
```

This probe uses the normal allocator and the same shared fixtures and state/event hashing as the
allocation probe. Only calls to `process_stage_chunk_cancellable` are timed. Fixture setup, sample
recording, percentile calculation, hashing and CSV output are outside the timed intervals. Samples
use a preallocated buffer; exceeding 8,192 chunks fails the probe instead of running indefinitely.

Each row reports summed stage-call nanoseconds and nearest-rank p50/p95/p99/max **chunk** latency,
plus chunk count, work count and a decimal state/event hash. Allocation CSV hashes are hexadecimal;
normalize their numeric representation before comparing. Small stages may contain one chunk, so
all their quantiles coincide. These are synthetic native wall-time observations, subject to host
scheduling and cache effects; they are not DreamDaemon tick or IPC acceptance results. Retain at
least three controls and candidates with identical workload/source identities, and compare each
row's work and hash before interpreting latency.

The ordinary workspace tests execute the probe's literal percentile and two-turf diffusion checks
through `crates/dogmos-perf/tests/core_stage_latency.rs`. See
[the slot-storage comparison](2026-09-06-stage-latency.md) for a controlled use of this probe.
The subsequent [equalization vector comparison](2026-09-06-equalize-vectors.md) records allocation
savings alongside mixed scheduling and tail-latency evidence.

On Windows, append `--thread-cycles` to record calling-thread CPU cycles alongside wall time:

```powershell
cargo +1.98.0 run --release --locked --offline --target x86_64-pc-windows-msvc -p dogmos-perf --example core_stage_latency -- --output "tmp/dogmos-perf/core-cycles.csv" --thread-cycles
```

The summary adds total and p50/p95/p99/max chunk cycle counts. `core-cycles.chunks.csv` contains
paired wall/cycle samples in their original chunk order. Read a companion file only with the
corresponding summary containing cycle values; diagnostics disabled means blank cycle fields.
The option fails explicitly on unsupported platforms or counter errors.

[`QueryThreadCycleTime`](https://learn.microsoft.com/en-us/windows/win32/api/realtimeapiset/nf-realtimeapiset-querythreadcycletime)
counts calling-thread user/kernel CPU cycles. Do not convert them to elapsed time or compare them
across different processors as a common time unit. Counter calls sit outside the measured wall
interval; cycle deltas bracket the clock calls and query-boundary overhead as well as
stage execution. This diagnostic perturbs execution and does not replace live tick-budget checks.
The [cycle diagnostic qualification](2026-09-06-thread-cycle-validation.md) records independent raw
sample validation, deliberate test mutations and the unresolved equalization tail-latency result.

The subsequent [dense visitation comparison](2026-09-06-equalize-visited.md) removes equalization
visited-tree allocations. Repeated native measurements show lower total equalization work and time,
while corridor tail observations remain mixed.

The [mixture lookup comparison](2026-09-06-equalize-mixture-lookups.md) removes another equalization
tree. Allocation traffic falls, and an adjacent paired diagnostic shows lower total native stage
time; separate-process timings conflict and tail latency remains mixed. Its coverage includes
repeated active decompression and literal mixture-identity, immutable-gas and event-order tests.

The [decompression loss-storage comparison](2026-09-06-decompression-loss-storage.md) combines local
loss and accumulated pressure in one record, removing a whole-tree clone between cooperation points.

## Continuation lifecycle probe

```powershell
cargo +1.98.0 run --release --locked --offline --target x86_64-pc-windows-msvc -p dogmos-perf --example continuation_lifecycle -- --output "tmp/dogmos-perf/continuation-lifecycle.csv"
```

This probe suspends one real DM reaction per turf, then times only a mixture/turf lifecycle batch.
It emits 20 cases covering 1,000/10,000 continuations, one-owner/half-owner batches, unregister,
generation replacement, reassignment and no-op registration. Outside the timed call it validates
callbacks, snapshots, exact token reuse and survivor resumption. Compare all non-timing columns
across at least three matched controls and candidates before interpreting elapsed nanoseconds.
The workload assertions also execute through the ordinary perf integration tests.

The [batched lifecycle comparison](2026-09-06-continuation-lifecycle.md) records large-batch gains,
small-batch tradeoffs, service stale-callback repair and deliberate test mutations. This synthetic
core measurement does not establish DreamDaemon tick, IPC or footprint improvements.

The [subsequent IPC qualification](2026-09-06-lifecycle-ipc-qualification.md) adds 1,030 real
i686-to-x64 lifecycle cycles, exact response checks and verified request-timeout cleanup to the
maintained process probe. It also records the clean-release prerequisite for paired game testing.

## Historical allocation results

Three fresh release processes on 2026-08-30 produced byte-identical 36-row controls with SHA-256
`9C28A0C6D019941F66237EB99B221DCF8BA9C29D2E68852829938C1B520EFE30`. At 100,000 turfs,
process-turfs made 133,396 allocations and allocated 79,892,176 bytes for every topology.
Turf-heat made 133,425-133,428 allocations and allocated 24,949,008-29,142,704 bytes. Equalize was
the largest byte allocator at 197,006,624-198,765,028 bytes and 264,873-269,491 allocations;
excited-groups made 330,967-359,948 allocations and allocated 157,116,200-158,375,520 bytes. These
controls prioritize component traversal and per-turf diffusion churn while preserving distinct
transcript hashes for each topology and stage.

Replacing the process-turfs neighbor `Vec` with the topology's six-entry stack bound produced three
byte-identical 36-row candidate runs with SHA-256
`7F4733C1E9BC9FECD003F352D34A9F05721308C723F839A31E83BBE2A44A36B4`. Every process-turfs
transcript hash matched its control. Each fixture eliminated exactly one allocation and 32 allocated
bytes per turf: the 100,000-turf cases fell from 133,396 to 33,396 allocations and from 79,892,176
to 76,692,176 allocated bytes for all three topologies.

Direct packed-topology traversal for component stages produced three byte-identical 36-row candidate
runs with SHA-256 `C569CEDAC3DAC2C96C1E0A2371DF8DEA32E4189CC99F7775A54C9C4B22FAA22C`.
Every transcript hash matched the preceding candidate. At 100,000 turfs, equalize removed
107,222-107,556 allocations and 1,952,016-2,082,224 allocated bytes, while excited-groups removed
116,667 allocations and 7,961,600 allocated bytes for every topology. These reductions exceed the
zero-noise allocation controls and retain sorted packed-topology traversal order.

The indexed transaction arena then produced three byte-identical 36-row runs with SHA-256
`019355931FA73B76C5329096859D28B1946010F5C872A6B48E63970D56CD9539`. Every transcript hash
matched the packed-topology control. At 100,000 turfs, equalize allocated 60,092,408-60,595,728
bytes, a 69.19-69.22% reduction, and excited-groups allocated 41,732,584-42,783,920 bytes, a
71.56-72.02% reduction. The full evidence and the allocation-count tradeoff are recorded in the
transaction result document.

At the August 30 checkpoint, stage-state recycling and server translation scratch were reviewed but
not implemented. Stage-state recycling was subsequently implemented; consult the September audit
and component-storage reports for current allocation/retention evidence. In the historical legal
IPC control, increasing a lifecycle batch from 1 to 1,024 records
raised p50 round-trip latency from 31.4 microseconds to 54.7 microseconds; this whole-path delta is
small beside the 739.5 microsecond p50 1,024-turf service stage and does not justify persistent
per-family translation buffers without more granular profile evidence.
