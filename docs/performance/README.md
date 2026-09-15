# Dogmos performance tooling

This directory keeps the maintained workloads, acceptance budgets and observation contracts.
Generated plans, reports, profiles and verification artifacts belong in the central
`GitHub/.agent_docs/aphelion-dogmos/` archive. Historical reports and raw outputs retain their
original paths beneath that archive, including `docs/performance/`, `target/` and `tmp/`.

This directory defines reproducible workloads and acceptance budgets for the current in-process
Dogmos backend and the later 64-bit service. DreamDaemon memory and service-process memory are
always recorded separately. Only DreamDaemon footprint is used for the BYOND memory target.

Every live result records the exact map, seed, Rust revision, feature set, BYOND version, duration,
and SHA-256 of the workload file. Results with different identities are not comparable. Set
`DOGMOS_EVIDENCE_DIR` to an existing run directory under `GitHub/.agent_docs/aphelion-dogmos/`
for the examples below. Move completed outputs there when a maintained runner requires a
repository-local scratch directory, preserving the original manifests and hashes.

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
cargo +1.98.0 run --release --locked -p dogmos-perf --example core_stage_allocations -- --output "$env:DOGMOS_EVIDENCE_DIR/core-control.csv"
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
cargo +1.98.0 run --release --locked --offline --target x86_64-pc-windows-msvc -p dogmos-perf --example core_stage_latency -- --output "$env:DOGMOS_EVIDENCE_DIR/core-latency.csv"
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

On Windows, append `--thread-cycles` to record calling-thread CPU cycles alongside wall time:

```powershell
cargo +1.98.0 run --release --locked --offline --target x86_64-pc-windows-msvc -p dogmos-perf --example core_stage_latency -- --output "$env:DOGMOS_EVIDENCE_DIR/core-cycles.csv" --thread-cycles
```

The summary adds total and p50/p95/p99/max chunk cycle counts. `core-cycles.chunks.csv` contains
paired wall/cycle samples in their original chunk order. Read a companion file only with the
corresponding summary containing cycle values; diagnostics disabled means blank cycle fields.
The option fails explicitly on unsupported platforms or counter errors.

## Continuation lifecycle probe

```powershell
cargo +1.98.0 run --release --locked --offline --target x86_64-pc-windows-msvc -p dogmos-perf --example continuation_lifecycle -- --output "$env:DOGMOS_EVIDENCE_DIR/continuation-lifecycle.csv"
```

This probe suspends one real DM reaction per turf, then times only a mixture/turf lifecycle batch.
It emits 20 cases covering 1,000/10,000 continuations, one-owner/half-owner batches, unregister,
generation replacement, reassignment and no-op registration. Outside the timed call it validates
callbacks, snapshots, exact token reuse and survivor resumption. Compare all non-timing columns
across at least three matched controls and candidates before interpreting elapsed nanoseconds.
The workload assertions also execute through the ordinary perf integration tests.
