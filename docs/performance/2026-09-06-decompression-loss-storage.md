# Decompression loss storage

## Change and correctness

Decompression now stores each turf's local gas loss and accumulated descendant pressure in one
slot-sorted vector. Previously, it populated a local-loss tree and cloned the whole tree between
two cooperation points. Both values are initialized during the existing sorted, charged traversal;
binary searches find mutable source and target records, and only the accumulated field changes
during reverse traversal. Capacity scales with mutable turfs in the current component. This removes
both loss trees and their clone without storage proportional to the largest external slot.

At 100,000 corridor turfs, each pass removes 32,850 allocations and 2,675,572 allocated bytes.
Calling-thread cycles fall in all three paired timing runs. Wall time and chunk tails remain mixed,
so this is not live tick-budget or DreamDaemon performance acceptance.

Production scope is `crates/dogmos-core/src/world/component.rs`. Normal equalization and other
stages are unchanged. Decompression retains every cooperation point, work/chunk count, arithmetic
operation and event order. The [previous mixture lookup removal](2026-09-06-equalize-mixture-lookups.md),
dense visited flags and earlier repairs are present in both measured variants.

A new literal fixture in `crates/dogmos-core/tests/equalize_traversal.rs` distinguishes local floor
loss from propagated pressure at a junction. A component with 130 mutable moles, four mutable turfs
and one immutable boundary removes 8.125 moles from each mutable turf. The junction carries
16.25 moles of pressure toward the boundary but emits a floor-rip event for only its own 8.125-mole
loss. The fixture checks every final gas amount and all seven ordered events at work limits 1, 7
and 4,096, with bounded completion.

Discovery starts at the far end of the graph, using frontier epoch 2, so its BFS order differs from
ascending turf-slot order. This exercises the sorted-vector lookup invariant with sparse turf slots
and unrelated mixture slots/generations.

The fixture passed against the control before implementation. Deliberately using accumulated loss
for floor rip fails its literal event assertion; using local loss for pressure also fails it.
Both mutations were restored byte for byte. All five traversal fixtures pass after the change.
Replacing sorted loss initialization with BFS-order initialization also fails the fixture. Review
confirmed sortedness, initialized entries for every searched source/target, component-sized capacity,
and unchanged local-loss, arithmetic/event, generation and cooperation semantics.

## Allocation evidence

The focused corpus uses corridor, grid and three-layer multiz worlds at 1,000, 10,000 and 100,000
turfs. Roots every 97 slots are immutable. Before cycles two and three, mutable gas amounts are
restored to their original literal fixture values outside allocation counting. This exercises
active decompression on all three cycles. Event capacity is twice the turf count on both sides.

A pre-edit control established the baseline. Three subsequent control/candidate process pairs
alternate order, reversing pair two. All six recorded affinity mask 1 and exit code 0. The
162 allocation rows have identical state/event hashes and work counts across variants, and every
non-timing field repeats exactly within each variant. Counting and timing run in separate processes.

At 100,000 turfs:

| Topology / cycle | Control allocations | Candidate allocations | Control allocated bytes | Candidate allocated bytes |
| --- | ---: | ---: | ---: | ---: |
| Corridor / first | 84,065 | 51,215 | 149,702,211 | 147,026,639 |
| Corridor / second and third | 83,751 | 50,901 | 11,405,312 | 8,729,740 |
| Grid / first | 78,894 | 46,075 | 152,335,523 | 149,663,039 |
| Grid / second and third | 78,610 | 45,791 | 10,923,844 | 8,251,360 |
| Multiz / first | 83,686 | 50,836 | 148,334,347 | 145,658,775 |
| Multiz / second and third | 83,444 | 50,594 | 11,359,224 | 8,683,652 |

The corridor removes 32,850 allocations and 2,675,572 allocated bytes per pass. These numbers are
allocator traffic, not retained memory or process footprint. Neither DreamDaemon nor `dogmosd`
memory was sampled.

Review caught an invalid pre-edit comparison in the temporary validator: different output filename
lengths leave a one-byte difference in process-wide peak live bytes outside stage counters. That
cross-invocation comparison now excludes peak live bytes and timing while retaining exact stage
counters, hashes, work and reusable capacities. Within-variant peak repeatability remains required.

## Paired timing evidence

Three paired timing processes produced 432 summaries, 216 paired stages and 170,352 raw chunks.
All numerical/event hashes, work and chunk counts match, including comparison with the preceding
pass's active-decompression candidate. All three process records have affinity mask 1 and exit 0.

The diagnostic links separate control and candidate core copies into one executable. It runs
three fresh bounded processes, each containing eight fresh world pairs per topology, three cycles
and both variants at 100,000 turfs: 144 summaries per process. Setup, timing, hash/drain and mutable
gas reseeding order are counterbalanced. Only core stage calls are timed; setup, reseeding, sample
recording and hashing are outside the timed intervals. Each stage is bounded to 8,192 chunks.

The independent validator requires exact work/chunk counts and numerical/event hashes across all
variants, trials and processes. It also compares every case against the preceding pass's verified
active-decompression candidate. Raw sample sequence, totals, nearest-rank p50/p95/p99 and maxima
are checked independently. Calling-thread cycles remain a processor-specific diagnostic, not
portable elapsed time.

Summed active-decompression stage calls over all topologies, trials and cycles:

| Process | Control ms | Candidate ms | Control billion cycles | Candidate billion cycles |
| --- | ---: | ---: | ---: | ---: |
| 1 | 19,431.338 | 17,551.625 | 43.985 | 40.476 |
| 2 | 21,660.551 | 21,281.729 | 47.488 | 44.362 |
| 3 | 29,701.620 | 30,872.964 | 44.226 | 42.016 |

The median process total falls 1.75% in wall time and 5.00% in calling-thread cycles. All three
cycle totals are lower, but process three's wall total is higher. Each topology/cycle case has 24
paired observations; median paired wall changes range from -9.09% to -4.47%. A ratio of independent
medians can differ from the median paired ratio: grid cycle three is +0.50% by the former and
-5.94% by the latter. Neither metric establishes a universal improvement.

Tails remain mixed. Median p99 wall time changes are +3.52%, +16.10% and -23.14% for corridor cycles
one through three, and +4.44%, -2.72% and -7.47% for multiz. Grid p99 medians improve in all three
cycles. Multiz cycle one's median maximum chunk time rises 15.45%; several other maxima fall.
These observations leave tail and live tick-budget acceptance open.

An earlier prototype merged both losses into one tree record. It removed 16,450 corridor
allocations but did not improve timing: median total wall/cycles were +0.81%/+0.45%, with mixed
tails. It was replaced by the vector implementation. Its separate source copies and data remain
under `tmp/equalize-losses/`; none of its timing observations are pooled with the vector results.

The validator accepts pristine data and rejects three deliberately altered copies: coherent wrong
hash order in both summary/raw files, zero active work in both variants for cycle two, and a changed
state/event hash. Requiring agreement with the previously verified active workload prevents matching
but inactive variants from passing. Source manifests and executable hashes were checked against
the measured files; final workspace core production source matches the measured vector candidate.

Both isolated builds use `rustc 1.98.0 (88d9e12ae 2026-08-18)`, locked offline dependencies, x64
Windows release mode, fat LTO and one codegen unit. Their production source differs only in
`core/src/world/component.rs`. The observed competing Rust profile/build job finished before
timing began; the initial timing preflight observed no Cargo or rustc processes. This is still a
shared-host synthetic measurement, not live tick-budget or DreamDaemon acceptance.

## Final native verification

| Gate | Result |
| --- | --- |
| Windows i686 workspace tests | 447 passed; two doc tests ignored |
| Windows x64 core/server/protocol/perf tests | 322 passed |
| Linux x64 core/server/protocol/perf tests | 321 passed |
| Windows/Linux i686 workspace and x64 changed-package strict Clippy | Passed, all targets |
| Windows/Linux i686 supported feature configurations | All 12 passed on each platform |
| Windows/Linux i686 shim links | Passed |
| Python tooling tests, including generated bindings | 42 passed |
| Maintained i686-to-x64 IPC probe | Passed: 1,030 lifecycle cycles and five expected stale-continuation rejections; probe/service processes exited |
| Formatting, whitespace and agent-document checks | Passed |
| Linux i686 executable tests | Not rerun: this environment previously rejected them with `Exec format error`; compile/link/static evidence only |
| Current-source paired game compile, boot, full DM suite and live performance | Not run; clean paired release prerequisite remains open |

The initial temporary Linux test launcher had CRLF line endings and its commands did not run.
That output was excluded. The launcher was corrected to LF, invoked with `bash -e`, and the actual
Linux test and Clippy logs were checked after successful completion. The new core fixture explains
the one-test increase on each native test target.

The three vector timing processes succeeded. A surrounding temporary PowerShell command then
incorrectly checked an unset native `$LASTEXITCODE` after a PowerShell-only runner and reported a
wrapper failure. Process exit records, stdout, empty stderr and raw data establish successful runs;
the timings were retained, and the allocation phase was dispatched separately. No timing run was
repeated to replace that orchestration error.

Local evidence is under ignored `tmp/equalize-loss-vectors/`: isolated source copies and SHA-256 manifests,
build logs, pre-edit allocation baseline, six allocation runs, paired timing data, validators,
deliberate-failure logs and final gate logs. Allocation probes use maintained example code with the
focused fixture adaptations in `tmp/equalize-losses/setup.py`; `run_allocations.ps1` invokes the bounded alternating
processes. The adjacent timing diagnostic comes from `setup_paired.py` and `run_paired.ps1`.
`validate_paired.py` checks both corpora, and `check_evidence.py` checks source/executable identity.

Tests and strict Clippy use `cargo +1.98.0`, `--locked --offline`, explicit targets and `--all-targets`
for Clippy. Feature checks use maintained `tools/check_feature_matrix.ps1` with pinned offline Cargo;
IPC uses `tools/test_cross_bitness_ipc.ps1`. No generated binding, release manifest or paired game
artifact was edited. Changes remain uncommitted. Current-source game qualification still requires
the [clean paired release prerequisite](2026-09-06-lifecycle-ipc-qualification.md#paired-game-prerequisite).
