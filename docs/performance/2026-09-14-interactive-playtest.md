# Interactive asynchronous atmosphere playtest

The operator reported smooth movement but stalled atmospheric reactions, including repeated fire effects without apparent gas-turf updates. The profiled game was the qualified production DMB `fa9dd86d1f58cf5764818bbf66aa16f955b29344f23625ddbc8def7b7ad4ffae`, with protocol 16 bundle 05 and `DOGMOS_ASYNC_STAGES` enabled on RuntimeStation. This is an exploratory local workload with player-triggered fusion canisters and destruction, not a matched performance comparison.

## Captured evidence

The retained session is `target/meridian-artifact-policy/data/local-profile-20260914-byond/`. The round directory is `game/data/logs/2026/09/14/round-21.06.01/`. Analysis and snapshot hashes are retained in `target/local-playtest-analysis-20260914/analysis.json`; its reproducible analysis script is `target/analyze_local_playtest.py`.

Seventeen cumulative proc snapshots were saved. Analysis subtracts `profiler-60.json` from `profiler-840.json`, covering 780 game seconds and excluding the explicit initialization-profiler counter reset. All thirteen consecutive gameplay intervals have nondecreasing call/self/total counters. Duplicate display names are aggregated per snapshot; they do not identify individual source overrides. Inclusive rows overlap and must not be added. BYOND's maintainer describes [profiler times and aggregation](https://www.byond.com/forum/post/2564440).

| Procedure | Calls in the interval | Self time, seconds | Inclusive time, seconds |
| --- | ---: | ---: | ---: |
| SSair `fire` | 11,175,419 | 45.602 | 388.633 |
| `dogmos_run_async_stage` | 11,168,217 | 19.100 | 28.564 |
| `dogmos_defer_stage_for_budget` | 11,157,785 | 1.906 | — |
| Native job Poll | 9,132 | 2.574 | — |
| Native job Commit | 9,096 | 2.475 | — |
| Native job Submit | 1,671 | 0.444 | — |
| Individual native mixture snapshot | 555,854 | 82.024 | 82.061 |
| MC `RunQueue` | 14,956 | 73.665 | 613.401 |

The proc capture proves excessive scheduling, not millions of IPC polls: the same-tick poll guard prevents most calls from reaching the service. Existing CSV stage-cost values are accumulated across resumptions and smoothed by SSair; a multi-second stage cost is not a single multi-second blocking frame. No continuous DreamDaemon/service memory series or per-publication gas/event transcript was collected in this interactive session.

## Confirmed scheduling defect

`dogmos_run_async_stage` records `world.time` after Submit/Poll. A subsequent call in the same tick returns pending through `dogmos_defer_stage_for_budget`. Its caller invokes ordinary `pause()`. MC `RunQueue` deliberately retries paused subsystems while budget remains, including multiple passes in the same game tick. Thus a job that cannot make progress remains runnable and consumes the spare MC allowance checking the same condition repeatedly.

The correction under test adds an explicit earliest resume time to a paused subsystem. The MC retains its queued state, stage cursor and uncompleted-cycle accounting, but skips it until eligible and excludes its priority from the current pass's available allocation. Dogmos uses this wait for external-job readiness; ordinary budget pauses remain eligible for fresh same-tick budget. A regression fixture invokes the real `RunQueue`, includes another runnable subsystem, and bounds the failing implementation to four visits.

## Fire behavior remains a separate correctness investigation

The capture has 527 `process_hotspots` invocations and 27,652 individual hotspot `process` calls. Those counts alone do not establish duplicate native reaction publication. `perform_exposure` has a passive path that reads the existing `reaction_results`, temperature and volume and applies `fire_act` without starting a new gas reaction. General native reaction callbacks are drained after the native active-turf/reaction stages finish. These are relevant timing boundaries, not proof of the operator's precise failure mechanism.

The next fire replay must record gas moles/temperature, published job unit, atmosphere cycle/stage, callback sequence and hotspot creation/exposure together. It must distinguish repeated visual/object effects against old committed state from a duplicated reaction, stale snapshot cache, or a slow but progressing native component. Do not hide the symptom by reducing atmosphere cadence or changing reaction coefficients.

## Publication throughput and the next work sequence

The current `dogmos_run_async_stage` permits at most one publication unit per game tick: Submit records the tick, Poll records the tick before Commit, and another unfinished unit must wait for a later Poll. `StageJobController::runnable` excludes Ready jobs, so preparation stops at an explicit publication boundary until DM acknowledges it. In `DogmosWorld::process_ready_stage_component`, each component with writes or events reaches that boundary; read-only components already bypass it. This is a source-derived throughput ceiling, not proof that it dominated this particular recording. For example, 200 effectful component units require at least 200 eligible game ticks under this protocol, before adding computation, other stages or retries.

Follow-up work, in dependency order:

1. Qualify the MC wait correction through the real queue regression, the full DM suite, and an async real-map progress observation. Preserve the old candidate and exact new source identities. Do not describe a small-fixture call-count result as a measured server speedup.
2. Add a bounded, opt-in fire replay to the existing Dogmos DM test/observer module. Run the same seeded gas composition and topology with async disabled and enabled. Include one connected burning region, many disconnected burning rooms, a fuel injector that writes during preparation, and a turf replacement. Collect a bounded transcript of mixture generation/revision, fuel/O2/products/temperature, cycle/stage, job/unit, receipt counts, callback sequence and hotspot creation/exposure. Use the existing reaction equivalence tolerances. Gate on chemical progress, exactly-once callback consumption, final numerical/event equivalence, and atmosphere cycle age as well as game responsiveness.
3. Use native preparation/commit counters, ready age and units-per-stage from that replay to separate compute time, publication waiting, revision retries and delayed DM callbacks. Existing `publication_retries` is not a pure conflict counter. Add reason-specific bounded counters only if needed; retain DreamDaemon and service memory separately.
4. If acknowledgement latency dominates, design bounded publication batches. One authorization should cover a limited amount of already-prepared compatible work, retaining revision/generation validation, atomic gas-plus-event visibility, exact replay receipts, finite callback capacity, and a short measured main-thread publication limit. A time/work cap and explicit resumption replace per-component tick latency. Do not silently authorize background publication or remove the cache fence.
5. If callbacks lag their committed gas, investigate draining a bounded batch at a safe publication boundary rather than after the whole active-turf/reaction stage. Prove ordering for DM continuations, frontier mutations and stale turfs first. A flame animation or `fire_act` call is not a chemical progress witness. Carry the gas revision with diagnostic observations before deciding whether a revision-aware hotspot rule is necessary.
6. Address repeated synchronous mixture snapshots separately using the existing bounded batch/cache structure. Verify invalidation after publication and unrelated gameplay writes before accepting fewer IPC calls. Repeat identical workloads at least three times per cohort, with event/numerical equivalence and continuous separate process measurements.

The generic MC addition uses narrow Aphelion markers. No upstream issue or PR has been opened. Remove the local addition if the upstream scheduler gains an equivalent external-wait facility, then retain the Dogmos regression against that facility.

## Follow-up profile and local database interference

The corrected-source [async observation](2026-09-14-async-mc-wait-observation.json) completed 18 additional atmosphere cycles and 147 native jobs over 180.656 wall seconds, with zero runtimes, publication retries or cancellations. It passed the functional progress gate. The initial observations spent a long interval in DM machinery processing before any native job was admitted; observing a stage cursor there does not attribute all elapsed delay to machinery itself.

Its [gameplay procedure profile](2026-09-14-mc-wait-gameplay-profile.json) recorded 820 `dogmos_run_async_stage` calls and four budget-deferral calls. SSair `fire` had 4,112 calls and MC `RunQueue` had 2,008. This is an unpopulated, instrumented CI workload, not a matched replay of the heavy interactive test; no speedup percentage follows from comparing their counts. The profile stops after the observer's final sleep and therefore extends slightly beyond the final telemetry sample (669 profiled Commit calls versus 651 sampled Commit calls).

The largest self-time entry was `SSdbcore.Connect`: 30 calls and 61.28 seconds. Other visible costs included 42,789 individual mixture snapshots (6.39 seconds self), 32,817 heat snapshots (4.927 seconds), and 42,792 turf-lifecycle batches (4.917 seconds). These are separate recorded rows, not a sum of overlapping inclusive time. Establish a healthy, consistently configured database before grading another workload; do not attribute this local connection cost to native atmosphere computation.

Source inspection also found a reconnect-backoff defect to address separately in G `code/controllers/subsystem/dbcore.dm`: `failed_connection_timeout` starts at zero, and `Connect()` clears `failed_connections` whenever that timeout is less than or equal to `world.time`. With no active timeout, consecutive failures therefore restart at zero before each attempt and cannot accumulate past the default threshold of five. A focused failure-sequence test should first prove the missing cooldown, then cover active cooldown, expiry, successful reconnection and disabling SQL. No database code or infrastructure was changed in this correction. The captured timing alone does not establish every connection attempt's outcome.

## Other observations and boundaries

- The game process has exited since the test. The MCP observed exit code 51104 and finalized its workspace-integrity record cleanly; that code alone does not establish why the operator's server stopped.
- The retained round contains 61 logged runtimes: 59 sound-length lookup failures, one null `screen_groups` access, and one repeated transit-tube-pod destruction. The earlier zero-runtime statement applied only to launch-time verification.
- Tracy's preceding launch failed after initialization with native exception `0xc0000409`; its evidence remains in the separate `local-profile-20260914T185807Z` session. The successful interactive test used BYOND proc/sendmaps profiling. Portable Tracy live acceptance remains open.
- No native binaries, bindings, gas coefficients or production deployment were changed by this analysis. Scheduler correction and its verification are tracked below as they complete.

## Correction verification

The incremental four-file [scheduler patch](../patches/2026-09-14-meridian-mc-wait.patch) applies after the qualified frontier candidate. The current candidate source archive and file hashes are retained in `target/local-playtest-analysis-20260914/mc-wait-candidate-02-source.json`. [Machine-readable correction evidence](2026-09-14-mc-wait-evidence.json) retains prior failed attempts separately. The native protocol-16 bundle is unchanged.

- The first restricted compiler launch stalled before its banner with 0.234375 CPU seconds and was terminated by verified owned PID. It did not execute the regression.
- Run `20260914T193500Z-d211d16c` failed because the initial fixture had no MC budget (`atmos=0`, sentinel=0). This is a fixture failure, not the behavioral RED result.
- Corrected RED run `20260914T194503Z-e9f6c40e` compiled with zero errors/two test-build warnings and failed the intended assertion: `atmos=4`, sentinel=1 in one queue pass, versus one visit each. It had zero test runtimes and clean owned cleanup. The exact RED source archive is retained separately.
- Focused run `20260914T195509Z-9f0d9c9a` passed four scheduling/receipt tests, including both real MC queue regressions. Its native-cache fixture completed its publication assertions but failed restoration: a detached saved frontier contained a reference now pointing to a closed hotel wall. The fixture now revalidates saved members and preserves unrelated live activations before restoration. A separate fixture test checks closed/duplicate/owned-only entries and retained activations.
- Run `20260914T200543Z-b4d1339c` did not execute tests: the new fixture used an assertion macro unavailable in this module. It was corrected to the module's existing direct `Fail` pattern. Reparsed source returned to the same 127 baseline errors/three warnings, with no new module diagnostic.
- Full run `20260914T200919Z-8037c2b3` compiled with zero errors/two existing test-build warnings and passed all 673 tests with zero runtimes and clean owned cleanup. This includes all eight runtime-scheduling/cache/failure/recovery tests under default-mode full-suite qualification.
- Separate async observation `20260914T203236Z-e60d915f` passed its test and additional progress criteria, using the existing three-minute observer and its gameplay-only BYOND procedure profile. It completed 18 additional cycles/147 jobs with zero runtimes or publication retries. Owned cleanup passed. The exact original CI configuration was restored and its hash verified.

The corrected source has DM compile, full-suite and single-run async progress evidence. Native code was unchanged, so the prior native bundle qualification remains separate. No new production build or production deployment was performed. Repeated matched workloads, the heavy fire replay and main-server acceptance remain open; this is a stopping point for the scheduling correction, not overall atmosphere-performance acceptance.
