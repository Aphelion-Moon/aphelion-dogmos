# Stage-only timing and slot-storage comparison

## Measurement repair

The previous whole-process timings mixed fixture construction, allocation-counter overhead,
simulation, hashing and output. They could not isolate the runtime cost of dense slot storage.
`core_stage_latency` now times only stage calls with the normal allocator and reports chunk
p50/p95/p99/max, chunk count and summed stage-call duration. Samples are preallocated, and an
8,192-chunk bound rejects a nonterminating workload. Setup, statistics and transcript hashing
remain outside the timed intervals.

Both probes share the existing deterministic fixture and hashing implementation. A preserved
pre-refactor allocation executable and the refactored executable matched all 135 rows for
allocation/deallocation counts and bytes, work counts, state/event hashes and reusable capacities.
This comparison establishes that extraction did not alter the allocation workload.

## Isolated storage comparison

The experiment copied the current core source into two ignored local directories, without
changing the active checkout. The copies have identical source hashes except for `slot_index.rs`:
one uses current dense records; the other uses the sparse record/epoch implementation from
`ab8b867`. Both retain current component membership repairs. Dependency lockfiles match, and both
use Rust 1.98.0, the x64 Windows target, fat LTO, one codegen unit and release optimization.

The source snapshot was taken at HEAD `31a96c4` with the in-progress diffusion-publication edits
present. Exact per-file hashes are saved in each copy's `source-hashes.json`. This comparison does
not qualify those publication edits or reconstruct the entire historical implementation.

Three fresh processes per variant ran alternately after compilation finished. Each produced 135
rows: three sizes, three topologies, five stages and three successive cycles. Every row matched
state/event hash, logical work and chunk count across all six processes. React has an empty
reaction inventory; successive cycles continue the same world.

Summed stage-call time, milliseconds:

| Run | Sparse records | Dense records |
| --- | ---: | ---: |
| 1 | 4,052.24 | 3,584.25 |
| 2 | 5,382.37 | 4,003.77 |
| 3 | 4,251.51 | 4,339.13 |
| Median | 4,251.51 | 4,003.77 |

Dense storage's median was 5.8% lower across the complete corpus, with one slower run. Per-stage
medians of summed durations across the corpus were:

| Stage | Sparse ms | Dense ms |
| --- | ---: | ---: |
| Diffusion | 786.88 | 694.69 |
| Turf heat | 443.32 | 368.32 |
| Equalization | 1,693.25 | 1,720.53 |
| Excited groups | 1,257.37 | 1,115.70 |
| React, empty inventory | 118.15 | 90.62 |

These per-stage medians are calculated independently and do not sum to the median complete run.
Equalization's aggregate median was 1.6% higher; results do not support a universal stage speedup.
The native evidence supports retaining compact storage while continuing to profile component
CPU cost. It does not establish a production tick-budget improvement.

For the 100,000-turf corridor's third cycle, median-of-three observed chunk quantiles were:

| Stage | Variant | p50 ms | p95 ms | p99 ms | Max ms |
| --- | --- | ---: | ---: | ---: | ---: |
| Diffusion | Sparse | 1.383 | 3.657 | 3.683 | 3.683 |
| Diffusion | Dense | 1.126 | 1.273 | 1.705 | 1.705 |
| Turf heat | Sparse | 0.186 | 0.858 | 1.009 | 1.305 |
| Turf heat | Dense | 0.119 | 0.509 | 0.749 | 0.861 |
| Equalization | Sparse | 0.119 | 1.052 | 1.498 | 1.601 |
| Equalization | Dense | 0.072 | 1.182 | 1.413 | 1.590 |
| Excited groups | Sparse | 0.450 | 1.238 | 1.373 | 1.427 |
| Excited groups | Dense | 0.408 | 0.893 | 1.065 | 1.636 |
| React, empty inventory | Sparse | 0.255 | 0.475 | 0.511 | 0.511 |
| React, empty inventory | Dense | 0.147 | 0.229 | 0.235 | 0.235 |

Host scheduling and cache effects remain. Quantiles describe chunks within a stage, not repeated
whole-stage latencies. These are service-side synthetic workloads, with no DreamDaemon process,
IPC, live map, gameplay load or process-memory acceptance measurement.

## Verification and evidence

- Literal nearest-rank tests cover reversed 100-sample data, a skewed short sample, empty input
  and singleton input. Both initially failed against a stub, then passed.
- A literal two-turf test checks that the timed driver performs the conservative 5/6 to
  5.125/5.875-mole diffusion step and finishes publication. Substituting an empty React stage
  deliberately fails this test; the source was restored.
- The ordinary workspace test discovery includes these checks through an integration-test entry
  point. They do not rely on CI explicitly running example tests.
- Independent read-only review found no blocking measurement or extraction issue. Its test
  discovery concern was repaired.
- Final `dogmos-perf` tests: 10 passed on i686 Windows and 10 passed on x64 Windows, including
  the three newly discovered benchmark checks. Strict all-target Clippy passed for that package
  on both targets. Formatting and whitespace checks passed. These focused package gates do not
  qualify unrelated in-progress core changes or replace the complete integration matrix.

```text
cargo +1.98.0 test --locked --offline --target i686-pc-windows-msvc -p dogmos-perf
cargo +1.98.0 test --locked --offline --target x86_64-pc-windows-msvc -p dogmos-perf
cargo +1.98.0 clippy --locked --offline --target i686-pc-windows-msvc -p dogmos-perf --all-targets -- -D warnings
cargo +1.98.0 clippy --locked --offline --target x86_64-pc-windows-msvc -p dogmos-perf --all-targets -- -D warnings
```

Raw evidence is under ignored `tmp/stage-latency/`: allocation control/refactor CSVs, six latency
CSVs, `comparison.json`, `corridor-quantiles.json`, source snapshots/hashes, build logs and test
logs. Commands use the pinned toolchain and `--locked --offline`; the isolated experiments first
generate their own dependency lockfiles offline and then build locked.

The remaining repository goal includes component CPU profiling, final-source publication repair
qualification, current paired-artifact/runtime evidence and a review of outdated architecture
guidance. This measurement checkpoint does not mark those complete.
