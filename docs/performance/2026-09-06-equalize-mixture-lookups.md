# Equalization mixture lookup removal

## Result and scope

Equalization no longer builds a second tree mapping turf slots to mixture handles. It resolves
each association through the component kernel's already captured, immutable turf records. The
lookup checks the turf generation and retains the stored mixture's independent slot/generation.
The live world's associations are not consulted during computation.

The change removes 16,700 allocations and 2,635,232 allocated bytes per 100,000-turf corridor pass.
A closely paired native diagnostic reports lower total stage time in ordinary equalization and
active decompression. Separate-process timings conflict with that result, and chunk tails remain
mixed. These results support retaining the allocation removal for further qualification; they do
**not establish universal latency improvement or DreamDaemon performance acceptance**.

Both control and candidate include the preceding [dense visitation](2026-09-06-equalize-visited.md),
parent/balance vectors, continuation lifecycle repairs and diffusion publication repairs. Their
production source differs only in `crates/dogmos-core/src/world/component.rs`.

Normal equalization retains traversal, transfer, floating-point and event order, work counts,
chunk counts, hard limits and transaction/publication behavior. Decompression derives mutable
membership as the complement of validated immutable turfs. Its local-loss loop uses the existing
slot-sorted component set, preserving mutable order. It charges a cooperation checkpoint for each
skipped immutable turf so a long boundary cannot be scanned inside one uninterrupted poll.
Decompression work/chunk counts can therefore increase while numerical results remain identical.

## Allocation and separate-process evidence

Three alternating control/candidate pairs ran the ordinary five-stage corpus, reversing order in
pair two. Timing and allocation counting used separate processes. All twelve bounded processes
recorded affinity mask 1 and exit code 0. Builds used `rustc 1.98.0 (88d9e12ae 2026-08-18)`, locked
offline dependencies, x64 Windows release mode, fat LTO and one codegen unit.

Independent validation checked 810 timing summaries against 55,836 raw chunks, including sequence,
sums, nearest-rank p50/p95/p99 and maxima for wall time and calling-thread cycles. State/event
hashes, work and chunk counts match across variants and repetitions. All 810 allocation rows match
their timing identities; every non-timing allocation field repeats exactly within each variant.

Repeatable allocation results at 100,000 turfs:

| Topology / cycle | Control allocations | Candidate allocations | Control allocated bytes | Candidate allocated bytes |
| --- | ---: | ---: | ---: | ---: |
| Corridor / first | 18,669 | 1,969 | 146,265,915 | 143,630,683 |
| Corridor / second and third | 17,805 | 1,105 | 5,192,224 | 2,556,992 |
| Grid / first | 17,808 | 2,043 | 149,190,587 | 146,735,787 |
| Grid / second and third | 16,940 | 1,175 | 5,041,180 | 2,586,380 |
| Multiz / first | 18,414 | 1,897 | 144,875,671 | 142,279,559 |
| Multiz / second and third | 17,622 | 1,105 | 5,153,104 | 2,556,992 |

Warm corridor allocation count falls 93.79%. Allocated bytes measure allocator traffic, not retained
memory, peak process footprint or DreamDaemon address-space pressure. No DreamDaemon or `dogmosd`
memory sampling was performed for this change.

The separate-process median total equalization time increased **23.71%**, with calling-thread cycles
up **17.21%**. Results varied substantially across repeats and unchanged stages: excited-groups
median wall time increased 201.40%, for example. At 100,000 turfs the corridor and grid medians were
lower, while multiz was higher. This experiment remains conflicting evidence, not a speedup result.

## Closely paired diagnostic

To reduce the gap between compared observations, a separate diagnostic links isolated control and
candidate core copies into one executable. It compares adjacent stage calls on distinct but
identically constructed worlds. Three fresh bounded processes each execute eight fresh world pairs
for each of three topologies at 100,000 turfs and three successive cycles.

Three modes remain separate:

- `ordinary`: equalization without immutable boundaries.
- `decompression`: immutable roots every 97 slots, followed by two subsequent passes. Later passes
  mostly scan settled components and are not evidence of sustained active decompression.
- `active_decompression`: the same immutable roots, restoring mutable gas amounts to the original
  literal fixture values before cycles two and three, outside timing. Immutable gas is preserved.

Setup order alternates across trials. Timed-call and post-stage hash/drain order alternate across
trials and cycles. Active reseeding uses the reverse timed order, also counterbalanced. Both timed
stages finish before either world's state/events are hashed. Only core stage calls are timed;
sample buffers are allocated beforehand, with an 8,192-chunk bound. Both variants use event capacity
of twice the turf count, sufficient for pressure and floor-rip events.

An initial diagnostic always hashed the candidate last. Review identified asymmetric preconditioning,
so its timings were rejected; the third process was stopped and a corrected executable was built.
Those outputs remain under `paired-run-*` for provenance and are excluded from every result below.

The corrected `balanced-run-*` corpus contains **1,296 summaries, 648 paired stages and 433,776 raw
chunks**. An independent validator checks complete case coverage, counterbalanced order, sequential
raw samples, totals, quantiles and maxima. All numerical/event hashes match across variants, trials
and processes; ordinary cases also match the separate-process controls. Ordinary work/chunk counts
are identical. Every active decompression pass charges exactly 1,031 additional immutable skips.
Later settled corridor/multiz passes add zero; grid cycles two/three add nine/three respectively.

Median per-process summed stage calls, including all topologies, trials and cycles within each mode:

| Mode | Control ms | Candidate ms | Wall change | Calling-thread cycle change |
| --- | ---: | ---: | ---: | ---: |
| Ordinary | 7,844.479 | 7,196.187 | -8.26% | -8.31% |
| Decompression then subsequent scans | 8,694.009 | 8,337.043 | -4.11% | -5.11% |
| Active decompression | 15,103.874 | 14,516.624 | -3.89% | -4.02% |

All nine mode/process totals are lower for the candidate. Each topology/cycle case has 24 paired
observations; ordinary median stage changes range from -11.80% to -7.68%, and active decompression
from -6.43% to -2.84%. Some individual pairs are slower. These observations apply to this linked
diagnostic and do not erase the conflicting separate-process evidence. Calling-thread cycles are
a diagnostic on this processor, not portable time units or unperturbed execution measurements.

Chunk tails do not uniformly improve. In active corridor cycle one, median p99 wall time rises
**2.101 ms to 2.659 ms (+26.61%)**, p99 cycles rise 17.61%, and only six of 24 pairs have a lower
candidate p99 wall time. Median maximum chunk time rises 6.991 ms to 7.105 ms. Ordinary multiz cycle
two p99 rises 7.61%, and ordinary grid cycle three p99 rises 4.60%. Other tails improve. Decompression
also has different charged-work boundaries, so individual chunks are not matched operations.
Live tick-budget and tail acceptance remain open.

## Tests and review

Two literal fixtures were added to `crates/dogmos-core/tests/equalize_traversal.rs` and passed against
the control before implementation. They run at work limits 1, 7 and 4,096 with bounded completion:

- Unrelated mixture slots and generations verify that turf identity cannot be substituted for the
  stored mixture association. Final moles and all four ordered pressure events are checked.
- Two immutable boundaries, one retaining nonzero gas, verify immutable snapshots, three mutable
  final amounts, frontage loss and all six ordered firelock/pressure/floor-rip events. Initial test
  drafting incorrectly assumed marking immutable cleared gas; source inspection corrected that
  expectation before the implementation was changed.

Deliberately reconstructing mixture identity from the turf slot fails the association test.
Deliberately counting immutable turfs as mutable fails the boundary-loss test. Both mutations were
restored byte for byte. Review checked that the captured kernel cannot change during computation,
that the decompression queue remains within the validated component, and that sorted mutable
traversal and numerical/event order are preserved.

The independent diagnostic validator was also challenged on copied data. It accepts pristine data
and rejects coherently altered hash order in both summary/raw files, removal of all 1,031 charged
skips from active round-two candidates, and a changed numerical/event hash. Original measurements
remain intact. Source manifests and executable hashes were verified against the measured files;
the candidate core source matches the final workspace production source exactly.

## Final native verification and reproduction

| Gate | Result |
| --- | --- |
| Windows i686 workspace tests | 446 passed; two doc tests ignored |
| Windows x64 core/server/protocol/perf tests | 321 passed |
| Linux x64 core/server/protocol/perf tests | 320 passed |
| Windows/Linux i686 workspace and x64 changed-package strict Clippy | Passed, all targets |
| Windows i686 supported feature configurations | All 12 passed |
| Linux i686 supported feature configurations | All 12 passed |
| Windows i686 shim build | Passed |
| Linux i686 shim build | Passed |
| Python tooling tests, including generated bindings | 42 passed |
| Maintained i686-to-x64 IPC probe | Passed: 1,030 lifecycle cycles, five expected stale-continuation rejections, no remaining probe/service processes |
| Formatting, whitespace and agent-document checks | Passed |
| Linux i686 executable tests | Not rerun: this environment previously rejected them with `Exec format error`; compile/link/static evidence only |
| Current-source paired game compile, boot, full DM suite and live performance | Not run; clean paired release prerequisite remains open |

The two additional core tests account for the increase from the preceding qualification. Windows
has one more test than Linux because of the platform-specific cycle-counter test.

Local evidence is under ignored `tmp/equalize-mixtures/`: isolated sources, manifests, executable
hashes, raw measurements, validators, deliberate-failure logs and final verification logs.
`run.ps1` / `validate.py` reproduce the ordinary separate-process experiment. The corrected paired
diagnostic uses `setup_paired.py`, `run_paired.ps1`, `validate_paired.py`, `check_evidence.py` and
`check_validator_mutants.py`. Preserve the captured control/candidate sources before regenerating
the diagnostic. Build its generated lockfile with the pinned toolchain before the locked build:

```powershell
cargo +1.98.0 generate-lockfile --offline --manifest-path tmp/equalize-mixtures/balanced/Cargo.toml
cargo +1.98.0 build --release --locked --offline --target x86_64-pc-windows-msvc --manifest-path tmp/equalize-mixtures/balanced/Cargo.toml
pwsh -NoProfile -File tmp/equalize-mixtures/run_paired.ps1
python tmp/equalize-mixtures/validate_paired.py
python tmp/equalize-mixtures/check_evidence.py
python tmp/equalize-mixtures/check_validator_mutants.py
```

Native verification commands are recorded in `windows-gates.ps1` and `linux-gates.sh` in the same
evidence directory. Tests and strict Clippy use `cargo +1.98.0`, `--locked --offline`, explicit
targets and `--all-targets` for Clippy. Feature checks use maintained `tools/check_feature_matrix.ps1`
with the pinned offline Cargo toolchain. IPC uses maintained `tools/test_cross_bitness_ipc.ps1`.
No generated binding, release manifest or paired game artifact was edited. Changes remain
uncommitted; current-source DreamMaker/DreamDaemon qualification still requires the
[clean paired release prerequisite](2026-09-06-lifecycle-ipc-qualification.md#paired-game-prerequisite).
