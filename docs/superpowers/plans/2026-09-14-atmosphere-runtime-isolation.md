# Atmosphere Runtime Isolation Implementation Plan

> **For agentic workers:** Use `superpowers:executing-plans` to execute inline, task by task. No subagents. Checkboxes track implementation, not planning completion. Do not commit automatically.

**Goal:** Reduce atmosphere-attributable main-thread stalls while preserving simulation progress and immediate gas API semantics.

**Architecture:** First bound DM preparation and record frontier changes at their source. Then keep one native world owner running resumable preparation jobs between control requests, with DM-authorized publication and budgeted event dispatch.

**Tech Stack:** Rust 1.98.0, fixed-width Dogmos IPC, i686 BYOND shim, x86_64 service, DreamMaker 516.1687, maintained PowerShell/RIFT verification.

**Spec:** [Runtime isolation design](../specs/2026-09-14-atmosphere-runtime-isolation-design.md). Read the [roadmap and qualification commands](../../performance/2026-09-14-atmosphere-roadmap.md) alongside this plan. N/G paths and source revisions are defined there.

## Global constraints

- Rust 1.98.0 with `--locked`; BYOND 516.1687 for the anchored game; revalidate pins before execution.
- Windows and Linux i686 shims; x86_64 service on each platform. Only the shim depends on byondapi.
- No subagents. Preserve unrelated work. No commits or production operations without the applicable authorization.
- No atmosphere coefficient, FDM iteration-count, 0.5-second nominal step, or critical-event-order change.
- Fixed-size shim transport and job metadata; authoritative state, scratch, and event outbox stay in `dogmosd`.
- Generated bindings and manifests are regenerated only with maintained tools.
- Mid-round service death, transport timeout, or identity corruption remains fatal; ordinary scheduling yield is not a transport error.

## R0: Establish the workload and observability contract

**Files:** Modify N `tools/perf/Invoke-DogmosWorkload.ps1`, `tools/perf/Compare-DogmosPerformance.ps1`, `tools/tests/test_perf_contract.py` only where existing schemas lack the fields below. Add N `docs/performance/workloads/runtime-isolation.json`. Inspect G `modular_aphelion/modules/dogmos/code/shift_start_performance_test.dm`, `code/controllers/subsystem/air.dm`, and `modular_aphelion/tools/dogmos_tracy/README.md`; reuse existing collection rather than starting another profiler framework.

**Interface:** Workload identity contains map hash, seed, command-sequence hash, BYOND/native identities, settings, duration, and cohort. Observation fields are `game_tick_ms`, `ssair_main_thread_ms`, `rpc_wait_ms`, `native_prepare_ms`, `native_commit_ms`, `cycle_age_ms`, `job_age_ms`, `callback_age_ms`, `callbacks_pending`, `conflicts`, `completed_cycles`, and separate process resource samples. Counters are always bounded; distributions are diagnostic-only.

R0 measures the current synchronous path through existing traces and adds diagnostic spans/counters in N `client.rs`/`session.rs` and G `air.dm` only if those observables are missing. R4 populates native job preparation/commit/age fields; R5 populates the corresponding DM state and cache/publication markers. Reports declare their mode and metric applicability: job age is not applicable to the synchronous control, while missing game-tick or RPC-wait measurements remain insufficient evidence. Do not substitute zero for an unavailable measurement.

- [x] Verify the implementation checkout contains the anchored Dogmos integration and parse that DME before semantic inspection. Record both HEADs and dirty files; do not switch or reset the unrelated game checkout.
- [x] Extend the comparison fixture with the following explicit cases. Missing required measurements must produce `insufficient_evidence`, never zero. Preserve raw samples alongside aggregates.

```python
# Table consumed by the comparison test; the test constructs paired reports.
cases = [
    ({"seed": 1}, {"seed": 2}, "identity_mismatch"),
    ({"rpc_wait_ms": [1, 2]}, {"rpc_wait_ms": None}, "insufficient_evidence"),
    ({"completed_cycles": 100}, {"completed_cycles": 50}, "progress_regression"),
    ({"events": ["open", "move"]}, {"events": ["move", "open"]}, "equivalence_failure"),
]
```

- [x] Observe these cases fail under the old comparison behavior, then add schema checks and classification. Do not encode a performance conclusion from synthetic samples.
- [ ] Specify deterministic workload phases: 60 s idle, 60 s fixed machinery schedule, 60 s breach/fire schedule, 60 s repeated door/turf changes, 60 s recovery. Use existing maintained workload-driver interfaces and fixed fixture coordinates from the selected representative map; record the resulting scenario bytes/hash before either cohort. Do not claim this artificial run represents populated production load.
- [x] Run `python -B -m unittest discover -s tools/tests -p test_perf_contract.py -v`. Validate the workload via `./tools/perf/Invoke-DogmosWorkload.ps1 -ValidateOnly` in PowerShell.
- [ ] Arrange at least three controls and three candidates under identical settings for each later change. The current planning request does not schedule or run server captures. Review the R0 diff and retain a baseline report before proceeding to performance conclusions.

**Deliverable/gate:** A report distinguishes wall-time waiting, DM work, native work, and backlog. Profiles that cannot make this distinction are usable for discovery only.

**Execution note:** The validator and pending five-phase document are implemented. The executable representative-map fixture, missing observations and matched reports remain open; see [the execution checkpoint](../../performance/2026-09-14-workplan-execution.md). Valid synthetic reports do not qualify performance.

## R1: Prefetch machinery in processing order and bounded chunks

**Files:** Modify G `code/controllers/subsystem/air.dm` (`process_atmos_machinery`, `dogmos_prefetch_machinery_snapshots`, `Recover`) and `modular_aphelion/modules/dogmos/code/service_backend_test.dm`. Reuse `prefetch_mixture_snapshots` and its wire limits in `service_backend.dm`.

**Interfaces:** Replace the whole-run collector with a resumable collector over the next at most 32 processing entries. Add SSair cursors `dogmos_machine_prefetch_start`, `dogmos_machine_prefetch_end`, and `dogmos_machine_prefetch_cursor`; retain a single bounded `dogmos_machine_prefetch_mixtures` list. Inputs are `currentrun` and its existing reverse consumption order. Output is a validated cached range; no change to `process_atmos(seconds)` or its result.

- [x] Add `/datum/unit_test/dogmos_runtime_prefetch` before changing production. Use a test-only SSair subtype that records prefetch and processing visits while real mixture fixtures exercise snapshot invalidation. Define its recorder inside the fixture so production does not gain a test hook.
- [x] Use this independent schedule oracle, with a 33-entry run and a deliberately exhausted budget immediately after prefetch:

```text
initial list: [1, 2, ..., 33]
first collected processing entries: [33, 32, ..., 2]
after yield: no machine processed; cached range retained
next resume: process 33 first, never 1 first
after processing 33 and deleting 32: next processed is 31
last chunk: [1]
combined processing transcript: each surviving original entry exactly once
```

- [x] Add boundary cases for 0/1/32/33/65 entries, many component mixtures in one entry, a noncomponent gas-leaker, duplicate mixtures, deletion during a yield, and cache invalidation after a write. Bound collection by both entries and mixture count; resume within a component rather than building its entire list above the limit.
- [x] Observe the old whole-run collector fail the first-chunk or pre-budget oracle. Implement collection, request/validation, budget recheck, and normal machinery processing in that order:

```text
if no current prefetched range: collect next bounded range, retaining cursor
if collection pending: pause and return
prefetch range; validate reply; mark range valid
if MC budget exhausted: pause and return
process next original entry; apply existing invalidation and process result
advance range only when its original entries are exhausted
```

- [x] Preserve these cursors across `Recover`, clear them at a new run and fatal shutdown, and never refetch already consumed entries solely because the MC paused.
- [x] Run RIFT focused test with `--focus /datum/unit_test/dogmos_runtime_prefetch --minimum-tests 1`; use the roadmap's `dogmos-ci`, installed pair, and offline arguments. Run applicable DreamChecker/ticked-file checks and inspect raw runtimes.
- [ ] Compare R0 workload against the control; record collection allocation high water, first-return latency, cache misses, and machine order. Review the diff without committing.

**Deliverable/gate:** Bounded collection and transmission, unchanged processing order/cadence, no repeated machinery side effects. Stop here as an independent DM-only candidate if useful.

**Execution note:** Independent candidate compiled and passed four focused tests with zero runtimes and clean natural shutdown. The old implementation failed the budget oracle first. Matched performance and broader release qualification remain open; see [the execution checkpoint](../../performance/2026-09-14-workplan-execution.md).

## R2: Record ordered frontier changes at membership writers

**Files:** Modify G `air.dm` (`add_to_active`, both removal paths, setup, recovery), `service_backend.dm` (`sync_dogmos_frontier`), `modular_aphelion/master_files/code/game/turfs/turf.dm` (replacement identity), and `code/modules/atmospherics/environmental/LINDA_turf_tile.dm` (direct active-list removal). Inspect every `active_turfs` write with Git/rg before editing. Add tests to G `service_backend_test.dm`.

**Interfaces:** New internal helpers `dogmos_note_frontier_add(turf)`, `dogmos_note_frontier_remove(turf)`, and `dogmos_note_frontier_reset()` update an ordered journal capped at 512 distinct entries. Each entry preserves acknowledged old handle, desired membership, and whether re-insertion is required. `dogmos_reconcile_frontier_chunk(max_entries)` performs bounded recovery/overflow reconciliation and returns pending or complete. Use exact word-encoded epochs, not floating-point counters beyond DM's integer precision.

- [ ] Write `/datum/unit_test/dogmos_runtime_frontier_journal` against literal expected service order. The fixture saves/restores SSair lists and fences, drains test-owned lifecycle work safely, and deletes only its own turfs/mixtures.

```text
acknowledged [A:1, B:1, C:1]
remove B:1; add B:1                 => [A:1, C:1, B:1]
replace A:1 with A:2                => [C:1, B:1, A:2]
add D:1; remove D:1 before publish  => unchanged
513 distinct changes               => needs_rescan; at most 512 journal entries
rejected addition reply            => acknowledged epoch/handle not advanced
mutation during yielded rescan     => unpublished scan invalidated/restarted
```

- [x] Observe the absent journal fail the bounded-work oracle. Route every discovered writer; preserve existing activation, excited-group, and removal side effects. A new source check must reject unreviewed direct active-list writers outside the explicit bootstrap/reconciliation allowlist.
- [x] Implement coalescing without losing remove/re-add order, including repeated replacement and deletion of a queued turf. Capture old generations before replacement. No destructor, signal handler, or non-sleeping proc may run the yielding reconciler.
- [x] Implement a 512-entry journal flush at the safe frontier boundary. Keep the old acknowledged map authoritative until replies succeed. Partial accepted wire batches update only their acknowledged portion; any later protocol failure takes the existing fail-closed route before simulation proceeds.
- [x] Add bounded full-rescan fallback for bootstrap, reset, overflow, and recovery. Candidate scans carry a membership revision; changes during a pause invalidate unpublished work. Test sustained changes for eventual publication at a stable boundary rather than silent starvation.
- [ ] Run the focused fixture and existing frontier/multiz/lifecycle regression tests; verify no-op delta epochs, frozen stages, and callback generations. Compare journal and legacy rescan outputs in diagnostics on the same ordered mutations.
- [ ] Measure DM work versus dirty-entry count, including overflow. Review and retain this as an independent candidate; do not claim all frontier work is O(changes) when the recovery path ran.

**Deliverable/gate:** Equivalent ordered frontier, bounded retained journal, explicit overflow recovery, no full-set discovery scan in the steady no-change path.

**Execution note:** The combined R1/R2 candidate passes 19 focused DM tests with zero runtimes; the additional lifecycle/multiz run passes four tests with zero runtimes. Literal native order tests pass on Windows x64 and i686. Matched performance and live shadow comparison remain open. See the [execution checkpoint](../../performance/2026-09-14-workplan-execution.md).

## R3: Add scheduling yields and explicit core publication

**Files:** Create N `crates/dogmos-core/src/stage_job.rs` and `crates/dogmos-core/tests/stage_job.rs`; modify `src/lib.rs`, `src/stage_cursor.rs`, `src/world.rs`, `src/world/component.rs`, and `src/world/versioned.rs`. Keep numerical kernels unchanged.

**Interfaces:** Define `JobProgress` with `Running`, `Ready { unit: u64 }`, `Retrying`, and `Done`; `StageJobSpec` contains the existing stage/frontier/stage-epoch/seconds fields. Add `DogmosWorld::prepare_job_chunk(spec, work_limit, should_yield, should_cancel) -> Result<JobProgress, WorldError>` and `DogmosWorld::commit_job_unit(unit) -> Result<StageChunkResult, WorldError>`. Both predicates are zero-argument closures returning bool. Add `cancel_job_unpublished()` preserving committed components. Synchronous `process_stage_chunk_cancellable` uses the same primitives with immediate publication and unchanged external results.

- [x] Add a fake-clock predicate so tests control scheduling without sleeps. Use a world with two connected mixtures at 300 K and 10/0 moles of one gas, plus an unrelated mixture. Record literal original states before preparation and compare completed results against the unchanged synchronous path.
- [x] Add the following contract sequence; the fixture builds metadata, handles, topology, and frontier through existing public core APIs, never by mutating private arena fields:

```text
prepare until Ready(unit): snapshots and event outbox remain original
write a read-set mixture: live value changes; commit(unit) cannot overwrite it
prepare again, commit: synchronous oracle matches; each event appears once
commit same unit again: same receipt; no extra mutation/event
cancel unpublished second component: first component stays committed
yield after every work position: same final state and ordered events
```

- [x] Observe old stage execution violate the prepare-only visibility oracle. Add unit boundaries immediately before existing publication calls for all five stages. Track input revisions as well as tentative writes; cover a read-only boundary mixture changing between preparation and commit.
- [x] Add scheduling-yield checks through frontier inspection, component traversal, scratch preparation, publication preparation, cleanup, and retries. Exhausting a quantum retains progress; fatal cancellation retains only reusable capacity and earlier committed components. Never pass the scheduling predicate as the old fatal-cancellation predicate.
- [x] Make event/continuation admission part of commit validation. Capacity failure changes neither authoritative values nor outbox; generation and topology mismatch cannot publish stale work. Keep whole-stage versus component publication exactly as specified.
- [x] Run `cargo +1.98.0 test -p dogmos-core --locked --target x86_64-pc-windows-msvc --test stage_job`, then existing core tests on x64 and i686. Inspect allocation/work-unit evidence for worst-case preparation and teardown; do not count only the arithmetic loop.
- [x] Compare complete synchronous transcripts and cancellation fixtures. Review the core diff before enabling any autonomous service job.

**Deliverable/gate:** A time-sliceable prepare-only engine with explicit atomic publication. Existing synchronous callers still pass; no new transport yet.

**Execution note:** The core candidate passes 23 job tests and the complete core/profiling checks on Windows and Linux x64/i686. Large synthetic probes identified and removed bulk gas/captured-record relocation and cancellation tree cleanup. Measured event admission and other residual costs remain explicit; no hard deadline or main-server performance acceptance is claimed. See [the checkpoint and source archive identity](../../performance/2026-09-14-workplan-execution.md).

## R4: Expose service jobs without blocking the control plane on a whole stage

**Files:** Create N `crates/dogmos-protocol/src/stage_job.rs`, `crates/dogmos-server/src/jobs.rs`, `crates/dogmos-server/src/transport.rs`, `crates/dogmos-server/tests/stage_jobs.rs`. Modify protocol `lib.rs`, server `lib.rs`/`state.rs`, and existing `tests/control_plane.rs`/`tests/common/mod.rs` where needed. Add native cross-bitness tests to the existing Windows/i686 harness, not a host-only replacement.

**Interfaces:** Implement operations 49-52 and the 40/8/16/16-byte requests plus 64-byte status receipt from the design. Internal `StageJobController` owns exactly one job and the latest committed receipt. `ServiceState` remains the only world owner; the transport worker exchanges bounded owned byte buffers with it and cannot call core APIs.

- [x] Add protocol golden-byte tests, including a job ID with nonzero high words, nonzero reserved fields, truncated/oversized messages, invalid status, zero quantum, quantum 1001, work limit 4097, NaN seconds, and reused stage epoch. Include one byte-for-byte assertion:

```rust
// Proposed protocol type from this task; no platform-sized wire values.
let poll = StageJobPoll { job: 0x0001_0002_0003_0004 };
assert_eq!(poll.encode(), [4, 0, 3, 0, 2, 0, 1, 0]);
assert!(StageJobPoll::decode(&[0; 7]).is_err());
```

- [ ] Observe decode/API failures, then implement explicit codecs and version bump. Revalidate unused operation IDs before integration; update source tests and generated contracts through maintained tooling.
- [x] Refactor frame ingress into one bounded request slot and one response slot. Ensure blocked transport I/O can be released during shutdown; join only owned workers within bounds. Do not let requests grow an unbounded channel or copy a complete world.
- [x] Implement actor scheduling: service queued request, run at most one quantum, check ingress again; after eight consecutive ordinary requests grant one native quantum. Park when there is no runnable work. Keep FIFO command ordering and reject a second live job with Busy.
- [x] Test that Submit admission deadlines, scheduling quanta, transport failure timeouts, and reaction-continuation expiry are distinct. An admitted job survives its completed Submit frame's deadline; an exhausted quantum preserves progress; an expired continuation cannot be resumed.
- [ ] Test with deterministic scheduler hooks: submit a long job, issue snapshot/write/health requests between quanta, observe their responses before job completion, and verify that no prepared value is visible before Commit. Assert maximum queued-buffer counts and scheduling turns, not fragile microsecond timing in unit tests.
- [ ] Test idle waiting without spin, malformed/late responses, terminal receipt replay, repeated Commit/Cancel, connection closure, server death, callback capacity pressure, topology rejection, and no worker/handle leak over repeated service starts. Simulate sustained ordinary commands and conflicting writes to verify job progress is represented honestly.
- [x] Run protocol/core/server tests on both supported architectures. The process integration suite must execute on Windows/i686 with a separately built x64 service; record counts so cfg-skipped tests cannot be mistaken for coverage. Review before adding game bindings.

**Deliverable/gate:** An admitted stage progresses independently of repeated DM SimulationStage requests, while the world owner services gas commands between bounded quanta.

**Execution note:** The original controller/transport source has its own [checkpoint](../../performance/2026-09-14-service-job-evidence.json). Later protocol-16 timing/age observations, sustained-conflict qualification, generated contracts and local pair installation are recorded in [the observation evidence](../../performance/2026-09-14-job-observation-evidence.json). The component acknowledgement correction has [four-target tests, strict Clippy, both feature matrices and three explicit i686-client/x64-service process tests](../../performance/2026-09-14-effect-free-component-evidence.json). Broad adversarial checkboxes above remain open where not every named condition has separate evidence. Ordinary game configuration still leaves asynchronous stages disabled.

## R5: Integrate submit/poll/commit with MC pauses and cache ownership

**Interactive follow-up:** The heavy local playtest exposed repeated same-tick MC resumes despite the native poll guard. The [incremental correction and follow-up work sequence](../../performance/2026-09-14-interactive-playtest.md) add explicit earliest resumption, exercise the actual MC queue, and retain unfinished-cycle accounting. The correction passed 673 DM tests and a separate three-minute async progress observation. Heavy-fire/event correlation, publication batching, matched performance and main-server acceptance remain open. The newer profile also exposed local database connection cost and a source-level backoff defect; keep those separate from native preparation timing.

**Files:** Modify N `crates/dogmos-byond/src/lib.rs`, `client.rs`, `session.rs`, `tests/api_inventory.rs`, `tests/bounded_io.rs`, and `tests/production_commands.rs`; regenerate bindings. Modify G `air.dm`, `service_backend.dm`, `service_backend_test.dm`, and `code/controllers/configuration/entries/general.dm` for boot-only `dogmos_async_stages`. Preserve existing maintained include layout.

**Interfaces:** Add the four internal bindings from the spec. SSair retains exact job/unit words and last cumulative committed counts. Existing `dogmos_run_stage(stage, remaining_ms)` continues returning pending/completed to its callers. A boot-selected mode defaults off; both modes use the same physics and service ownership.

- [x] Write `/datum/unit_test/dogmos_runtime_scheduling` and native binding fixtures before integration. The DM test uses a controlled pending-job fixture and a recurring sentinel proc to demonstrate that another DM proc runs while native preparation is pending; it does not infer asynchrony from service PID existence.

```text
submit -> SSair pauses -> sentinel advances -> poll Running -> pause
poll Ready -> fresh MC budget too small -> no Commit
next eligible tick -> Commit -> invalidate snapshot epoch -> consume receipt
repeated receipt -> no second event and no double-counted work
MC recovery during Preparing/Ready/Draining -> same job and event cursor
```

- [x] Test a cached gas read before preparation, a live mutation by a different DM consumer, failed/retried publication, and a read after commit. Every read must reflect the latest committed writes; no callback can run before cache invalidation.
- [x] Implement submit-once and at-most-once-per-eligible-tick polling. Recompute the MC budget after every resume and after each control RPC. Preserve the existing frontier fence, FDM pass count, heat completion, callbacks, and visual cursors. Do not make non-sleeping lifecycle handlers await.
- [ ] Serialize short control RPCs through the existing bounded client. Release the session lock before returning to DM. Preserve panic boundaries, numeric validation, world identity, cancellation, and failure latches. Keep unsupported mixed modes fail-closed.
- [ ] Test shutdown, service death, stalled control I/O, malformed receipt, stale world/job/token, exhausted event capacity, partial callback drain, and resumed reaction continuation. No automatic service restart or mid-cycle switch to the old path is allowed.
- [ ] Run i686 native gates, generated binding drift, installed-contract verification, focused runtime/prefetch/frontier tests, and applicable existing cadence/lifecycle/recovery tests. Inspect raw runtimes. Review source and artifact identity before a full suite.

**Deliverable/gate:** Other DM work runs during native preparation; the short control calls and DM publication/callback work remain explicitly measured residual costs.

**Execution note:** Focused run `20260914T160319Z-b085a3ac` passed all fifteen scheduling, native-cache, receipt, malformed-response, recovery, prefetch, frontier and observation tests with zero runtimes and clean shutdown. Earlier failing runs and source identities remain in [the execution record](../../performance/2026-09-14-workplan-execution.md). The first real-map async observation failed cycle-progress acceptance despite passing its basic test gate. With the effect-free-component acknowledgement correction, [repeat observation `20260914T161356Z-07d739f3`](../../performance/2026-09-14-async-noeffect-observation.json) passed its additional progress gate: 30 completed atmosphere cycles and 242 completed native stage jobs during 180.119 seconds of gameplay, with zero runtimes and clean shutdown. This single busy-host run is not matched performance or populated-server acceptance. The full suite subsequently failed on a frontier append at offset 512. The separately frozen bounded unique-snapshot correction subsequently passed eighteen focused tests, all 670 default-mode full-suite tests, a fresh three-minute async progress observation and a full-build 300-second async soak, all without runtimes. The corrected async observation completed 52 cycles and 421 native jobs. See the frontier correction evidence and controlled server-playtest handoff. Main-server performance and remaining adversarial coverage stay open.

## R6: Qualify each candidate and prepare the release handoff

**Files:** Update N `docs/performance/2026-09-14-atmosphere-roadmap.md` with links to new evidence; create dated audit report and machine-readable data under N `docs/performance/` with no personal paths. Use existing release and game profiler tooling unchanged unless a concrete missing metric requires a reviewed update.

- [ ] Run the full native matrix and paired compile/focused/boot/full/300-second-soak gates from the roadmap. Add Linux BYOND loading separately; a Linux library build is not a load test.
- [ ] Capture three or more matched repetitions per cohort for R1, R2, and asynchronous mode separately. Freeze the quantum, work cap, map, seed, numerical configuration, and scenario before collection. Keep setup/trace collection overhead equivalent.
- [ ] Compare p50/p95/p99/max game tick and blocking durations, total CPU, request counts, cycle/queue age, completed cycles, numerical transcript, events, and separate process resources. Treat missing measurements as unqualified. Check final recovery after bursts, not just steady-state averages.
- [ ] Test long-running churn for growing retry scratch, DM journal capacity, service outbox, stale generations, and repeated MC recovery. Any smoother-but-falling-behind candidate fails acceptance.
- [ ] Prepare the complete paired release and rollback bundle through maintained tooling. Leave asynchronous mode disabled until the qualifying server test is accepted; enable only on a controlled restart. Retain actual failed gates and limitations in the handoff.
- [ ] Review `git diff --check`, artifact identities, test counts, and source diff. Leave changes uncommitted. Do not publish, deploy, or restart a server as an implicit final step of this plan.

**Deliverable/gate:** A concrete, reviewable candidate with measured responsiveness and progress, independently attributable changes, and a complete rollback path.
