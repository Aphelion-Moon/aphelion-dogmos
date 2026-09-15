# Runtime observation contract

The maintained `tools/perf/Compare-DogmosPerformance.ps1` routes schema-2 runtime reports to `tools/perf/runtime_contract.py`. Python 3.11 or later is required, as in the pinned game tooling. Existing summary-only reports retain their legacy memory/service-tick comparison; they do not satisfy this runtime contract.

## Report shape

Each input is one cohort with `schema_version: 2`, `kind: "runtime_isolation"`, `cohort: "control"` or `"candidate"`, and `mode: "synchronous"` or `"jobs"`.

`identity` contains equal workload inputs: `map`, `map_sha256`, integer `seed`, sorted unique `features`, `byond_version`, positive `duration_seconds`, `scenario_sha256`, `command_sequence_sha256`, and a nonempty `settings` object. Record physics, map/configuration, profiling settings and machine/workload conditions here. All identity fields, including extensions, must match. Hash actual files/commands used; do not substitute the phase-plan hash for a command transcript or an unexecuted scenario for observed work.

`build` records `game_revision` and `native_revision` as complete 40-character revisions, and `game_dmb_sha256`, `shim_sha256`, `service_sha256`, `bindings_sha256`, `contract_sha256` as 64-character SHA-256 digests. Hash the actual compiled game, since uncommitted DM changes can share a Git revision and an unchanged native pair. These are deliberately separate from workload identity: a reviewed candidate is expected to change code or artifacts. Within a cohort, every run must use its stated build. Preserve the original run/build verification artifacts alongside the report; this validator checks evidence structure and equivalence, not executable authenticity.

`runs` contains at least the `minimum_repetitions` in `budget.toml`, never fewer than three. Every run has a unique `run_id`, a unique `pair_id` matching exactly one run in the other cohort, and `contaminated: false`. Retain excluded observations separately with reasons and replace the affected pair; the comparator does not silently discard them. Do not reuse a run ID across cohorts.

Each run records:

- `metrics`: raw arrays for `game_tick_ms`, `ssair_main_thread_ms`, `rpc_wait_ms`, `native_prepare_ms`, `native_commit_ms`, `cycle_age_ms`, `job_age_ms`, `callback_age_ms`, and integer `callbacks_pending`; integer counters for `conflicts` and `completed_cycles`. Arrays need at least two finite, nonnegative samples in acquisition order. Counters cover the measured window, not process lifetime. Keep full capture coverage and sampling cadence in the companion evidence.
- `not_applicable`: only synchronous runs may declare `native_prepare_ms`, `native_commit_ms`, `job_age_ms` and `conflicts` inapplicable. Each declaration needs a reason and a null metric value. Missing game tick/RPC wait/callback observations are insufficient evidence, never zero. If native stage costs cannot yet be split, record that limitation and retain the stage trace separately.
- `equivalence`: `state_sha256` for the independently canonicalized final numerical state, and an ordered `events` array. Empty events means an observed empty sequence; omitted events means absent evidence. Use the same canonicalization/sampling contract for each paired run. Cross-platform numerical tolerances require a separately reviewed canonicalization/comparison method.
- `processes`: separate `dreamdaemon` and `dogmosd` arrays. Each sample records `elapsed_ms`, `private_bytes`, `working_set_bytes`, `virtual_bytes`, and `cpu_total_seconds`. Time must increase and CPU totals must not decrease. Samples must cover the first and last one percent of the observation window. Retain stable PID/start-time ownership and raw sampler output in the companion evidence; memory roles are never added together.

## Results

| Status | Exit | Meaning |
| --- | --- | --- |
| `insufficient_evidence` | 4 | Missing/invalid identity, observations, repetitions, applicability or pair coverage |
| `identity_mismatch` | 2 | Valid cohort reports describe different workloads |
| `equivalence_failure` | 3 | Paired numerical state or ordered event records differ |
| `progress_regression` | 3 | Any candidate pair completed fewer cycles, or ended with growing age/backlog above its control |
| `evidence_complete` | 0 | Evidence prerequisites passed; not performance acceptance |

Complete comparable reports retain `raw_runs`, separate `builds`, `modes`, report-byte hashes, and per-run nearest-rank p50/p95/p99/max/count distributions. Missing observations do not enter an aggregate. Cohort percentiles are not pooled. Rejected source reports must also be retained; the command never rewrites them.

`acceptance_passed` and `performance_evaluated` remain false for this R0 contract. Zero exit means the input evidence can proceed to analysis. Runtime speedup, control noise, allocation high water, shim address-space limits, overshoot and production acceptance still require the roadmap's measurements and review. Three synthetic fixture reports cannot establish any real performance improvement.

## Current collection gap

The existing one-click server collector remains the operator entry point. It captures DM traces and separate process samples; it cannot derive service-internal preparation/publication timings from DM spans. The existing shift-start fixture observes normal loaded-map activity without injecting the proposed five-phase workload. Neither currently emits this complete report automatically.

The runtime phase plan is retained in `workloads/runtime-isolation.json` with `execution_ready: false`. Binding fixed representative-map coordinates, action transcripts, numerical/event extraction and the missing native timing spans remains part of R0. Validation of that document checks the plan's structure, not the existence or success of its driver. No server capture is launched by the manifest preparer.
