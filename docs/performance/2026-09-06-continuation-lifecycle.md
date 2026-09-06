# Batched continuation lifecycle cleanup — 2026-09-06

## Changes and behavior

Lifecycle batches used to scan the whole continuation arena once for every invalidated mixture or
turf owner. Core now records the first actual invalidation of each owner and scans the arena once
for the batch. It orders the appended free-list entries by mutation ordinal and arena slot before
clearing them, preserving exact subsequent token slots and generations. A single-owner path uses
a direct comparison and needs neither per-entry tree lookups nor sorting. The general path includes
tree lookups and sorting; it is not a strictly linear algorithm for the whole operation.

The related service repair removes stale callbacks after mixture/turf generation replacement or
turf mixture reassignment, including changing an association and restoring it within one batch.
Previously the service only recognized explicit unregister mutations, leaving invalid core tokens
in its continuation map. An old service token could therefore authorize a nested mixture command.
Service cleanup now asks core whether each exact continuation token remains pending after the
successful batch. This also removes temporary unregister sets and duplicate owner fields from the
service continuation record. No wire fields, gas coefficients or public DM proc paths change.

## Matched native experiment

Pinned toolchain: `rustc 1.98.0 (88d9e12ae 2026-08-18)`, target `x86_64-pc-windows-msvc`, release,
fat LTO, one codegen unit, locked dependencies and offline builds. Control and candidate are isolated
source copies with identical manifests, lockfiles and workload code. Their only source-file difference
is core `world.rs`; both include the existing diffusion resnapshot repair and equalization vectors.
The control is a pre-batching snapshot from the dirty checkout, not an unrelated old release.

The probe creates one real suspended DM reaction per turf in a corridor, then submits descending
owner mutations. Setup, input construction, callback validation, snapshot/state hashing, token reuse
and survivor resumption are outside the timed lifecycle call. Each fresh process emits 20 cases:
1,000/10,000 continuations, one/half the owners mutated, and five mutation types. Three controls and
three candidates run in alternating order on the same allowed CPU affinity (mask 1). All six
processes exited successfully. All 120 non-timing rows matched exactly, including pending counts and
state/event transcript hashes. These checks establish deterministic same-build native behavior for
the fixture, not complete gameplay equivalence.

Median lifecycle-call times across the three fresh processes:

| Mutation | Continuations | Owners | Control ms | Candidate ms | Change |
| --- | ---: | ---: | ---: | ---: | ---: |
| mixture_unregister | 1,000 | 1 | 0.0201 | 0.0239 | +18.9% |
| mixture_replace | 1,000 | 1 | 0.0138 | 0.0159 | +15.2% |
| turf_unregister | 1,000 | 1 | 0.0050 | 0.0039 | -22.0% |
| turf_reassign | 1,000 | 1 | 0.0034 | 0.0061 | +79.4% |
| turf_noop | 1,000 | 1 | 0.0037 | 0.0032 | -13.5% |
| mixture_unregister | 1,000 | 500 | 0.8982 | 0.5217 | -41.9% |
| mixture_replace | 1,000 | 500 | 0.8241 | 0.5111 | -38.0% |
| turf_unregister | 1,000 | 500 | 1.3789 | 0.3126 | -77.3% |
| turf_reassign | 1,000 | 500 | 0.5650 | 0.2695 | -52.3% |
| turf_noop | 1,000 | 500 | 0.1975 | 0.2023 | +2.4% |
| mixture_unregister | 10,000 | 1 | 0.1073 | 0.1138 | +6.1% |
| mixture_replace | 10,000 | 1 | 0.1184 | 0.1103 | -6.8% |
| turf_unregister | 10,000 | 1 | 0.0252 | 0.0190 | -24.6% |
| turf_reassign | 10,000 | 1 | 0.0306 | 0.0214 | -30.1% |
| turf_noop | 10,000 | 1 | 0.0047 | 0.0055 | +17.0% |
| mixture_unregister | 10,000 | 5,000 | 58.6223 | 5.7989 | -90.1% |
| mixture_replace | 10,000 | 5,000 | 59.6324 | 4.4230 | -92.6% |
| turf_unregister | 10,000 | 5,000 | 141.5414 | 2.9965 | -97.9% |
| turf_reassign | 10,000 | 5,000 | 57.3194 | 2.9037 | -94.9% |
| turf_noop | 10,000 | 5,000 | 2.7824 | 2.3451 | -15.7% |

The four 5,000-owner invalidating cases improve by 90.1–97.9% in this final comparison. Small
single-owner differences are mixed: the largest observed median increase is 0.0065 ms, and the
1,000-continuation turf reassignment increases from 0.0034 to 0.0061 ms. Do not claim a universal
speedup. The no-op case performs no continuation invalidation and remains a noise/control workload.
Earlier comparisons without the direct single-owner path exposed systematic small-batch overhead;
they are retained in the evidence directory rather than overwritten. No-op medians also varied
widely across experiment rounds, so this is not evidence of a no-op optimization.

This is native lifecycle-call CPU-path evidence only. No DreamDaemon tick, IPC round-trip or
DreamDaemon memory improvement has been measured for this change. `dogmosd` memory is a separate
metric; removing service fields is not a DreamDaemon footprint result. Current paired-game compile,
boot, focused/full DM tests and matched live performance acceptance remain outstanding.

## Test audit

The six core behavioral tests use a five-mixture fixture with deliberately different turf slots,
multiple tokens for one mixture, and a direct token without a turf owner. They check literal token
reuse sequences, stale generations, resumable unaffected reactions, pre-existing free slots, first
actual invalidation after earlier no-ops, repeated owners, generation replacement with the same
mixture, reassignment to `None`, change-then-restore, and rejection of an invalid whole batch.
A deliberate removal of the ordering step fails the intended token-identity assertions.

Both new service regressions were observed failing before the repair (the core had removed a token
while the service still counted it). They now cover queued and already-delivered callbacks, reject
commands through the invalidated token without modifying another mixture, preserve callback payloads
and transactions across no-op/rejected batches, and resume survivors. The turf case keeps an
unaffected continuation in the same general queue as the invalidated one, plus an independent
reaction transaction and diagnostic. A deliberate over-broad general-queue purge fails this test.
Original source bytes were restored after each mutation experiment.

The maintained benchmark also runs as an ordinary perf integration test with literal four-turf
pending counts for one-owner and two-owner mutations. Benchmark assertions verify exact initial
callbacks, final snapshots/associations through the comparison hash, token refill order and
successful survivor resumption, rather than trusting elapsed time alone.

## Reproduction and identity

```powershell
cargo +1.98.0 run --release --locked --offline --target x86_64-pc-windows-msvc -p dogmos-perf --example continuation_lifecycle -- --output tmp/dogmos-perf/continuation-lifecycle.csv
```

Compare at least three controls and three candidates using identical source/workload identities.
Local raw artifacts are under ignored `tmp/continuation-lifecycle/`: source manifests, isolated
control/candidate trees, six CSVs, `runs.csv`, `comparison.json`, mutation logs and gate logs.
`half-batch-*` preserves the initial large-batch comparison; `pre-single-*` preserves the expanded
comparison before the single-owner refinement. `compare.py` verifies all source hashes, six process
exits/affinities and all 120 row identities before calculating medians.

- Control core `world.rs` SHA-256: `53c2848b378da23aa6c144a2cc7f63b76a161448e329f109fa5b058a6c1720b6`.
- Control executable SHA-256: `661c99402d321928b57fe6265c57bd307bb7623d9866a55bf6f4ac3e72d40a4c`.
- Candidate core `world.rs` SHA-256: `a69a4a87d6fc0a0a3e3e1e8dc524229230bf660a0d5cdfae37093ddc94a53fde`.
- Candidate executable SHA-256: `316e6823bfaa3d1ae67a0b4cc36ef7cabae4c41c251f5220d65800995b14121f`.

## Final verification

| Gate | Result |
| --- | --- |
| i686 Windows workspace tests | 442 passed; 2 doc tests ignored |
| x64 Windows core/server/protocol/perf tests | 317 passed |
| x64 Linux core/server/protocol/perf tests | 316 passed |
| i686 Windows and Linux workspace/all-target strict Clippy | Passed |
| x64 Windows core/server/protocol/perf all-target strict Clippy | Passed |
| Windows supported feature matrix | All 12 configurations passed |
| Python tooling tests | 42 passed, including deterministic binding generation twice and exact checked-in byte comparison |
| i686 shim and x64 service release compilation | Passed on Windows and Linux; PE/ELF architectures verified |
| Windows i686-to-x64 IPC probe | Passed; two ordered frontier callbacks, independent resume/cancel, no pending work |
| Release callback-pressure probe | 10,000 cycles, 10,240,000 callbacks enqueued/drained; final depth zero |
| Formatting and whitespace | Passed |
| i686 Linux executable tests | Not rerun; the preceding checkpoint could compile them but WSL rejected execution with `Exec format error` |
| Current-source paired-game compile/boot/focused/full DM tests and live performance | Outstanding |

The Windows-only cycle-counter tests account for the one-test x64 platform count difference.
The release pressure probe sampled both processes at 1,000, 2,500, 5,000, 7,500 and 10,000 cycles.
The i686 probe's private bytes remained 1,146,880 and the service's remained 2,129,920 at every
checkpoint. These are separate synthetic-process stability measurements, not DreamDaemon memory
measurements or continuous peak measurements.

Rust tests and Clippy use `cargo +1.98.0` with `--locked --offline`; workspace/all-target checks use
`i686-pc-windows-msvc` and `i686-unknown-linux-gnu`, and service tests use the matching x64 targets.
Linux uses the separate `target/linux-continuation` build directory. Feature checks use maintained
`tools/check_feature_matrix.ps1` with offline Cargo and the checked-in toolchain pin. Process checks
use `tools/test_cross_bitness_ipc.ps1` and `tools/test_callback_pressure.ps1 -Cycles 10000`; a local
Cargo wrapper adds `--locked` to their existing pinned offline build invocations. Build identity for
those probes comes from the maintained `Get-DogmosBuildIdentity -AllowDirty` helper.

No production release manifest was generated: the maintained contract generator rejects dirty
source. Artifact compilation and the process probe do not qualify a deployable game artifact pair.
The local evidence directory retains test counts, exact commands, exit codes, logs, architecture and
artifact hashes, plus pressure samples. The final live core `world.rs` hash matches the measured
candidate. Changes remain uncommitted.
