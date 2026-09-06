# Equalization traversal vectors

## Change

Equalization already traverses a BFS-ordered component vector. Its parent and subtree-balance
maps were used only for lookups through that order. They now use vectors indexed by component
position. Reverse traversal, floating-point additions, transfer order and every cooperation point
are unchanged. Maps and sets that determine decompression event order remain intact.

This reduces allocation work in the 64-bit service. It is not a DreamDaemon footprint change.
The implementation and its tests remain uncommitted on top of `31a96c4`, alongside the earlier
latency-probe work and separate in-progress diffusion-publication edits.

## Correctness and test review

A new five-turf branched fixture uses sparse slot numbers, a non-root parent and both transfer
directions. It checks literal final amounts and the exact four-event transcript at work limits
1, 7 and 4096. It passes the control and candidate implementations. Deliberately attaching every
child to the root preserves the final gas amounts but fails the event-path assertion, demonstrating
why conservation alone would miss this regression. The deliberate mutation was restored.

The fixture initially assumed that all pending stage responses precede publication. The control
disproved that assumption: a completed component can publish while the outer stage is pending.
The corrected assertion permits either the complete old or complete new component, never partial
visibility, and checks event visibility at the same boundary.

Existing tests cover cancellation checkpoints, retry, hard component limits, immutable sinks,
duplicate mutable mixtures, and disconnected-component publication. Independent read-only review
found no actionable correctness or ordering issue in the vector replacement.

## Repeated measurements

Control executables were saved before the implementation edit. Each allocation or latency process
uses the same 135-case corpus. All candidate state/event hashes and logical work counts match the
control; latency probes also retain identical chunk counts. Each allocation variant was repeated
three times, with identical allocation counts and cumulative bytes across repetitions.

100,000-turf corridor equalization:

| Cycle | Control allocations | Candidate allocations | Control allocated bytes | Candidate allocated bytes |
| --- | ---: | ---: | ---: | ---: |
| First | 67,984 | 35,334 | 149,199,691 | 147,327,691 |
| Second | 50,470 | 34,470 | 6,558,800 | 6,254,000 |
| Third | 50,470 | 34,470 | 6,558,800 | 6,254,000 |

The allocation-count reduction is 48.0% on the first cycle and 31.7% on warm cycles. Peak live
allocator bytes were effectively unchanged; this change does not claim substantial memory relief.

Summed equalization stage-call time across the corpus, milliseconds:

| Execution | Run | Control | Candidate |
| --- | --- | ---: | ---: |
| Default scheduling | 1 | 2,093.08 | 3,538.30 |
| Default scheduling | 2 | 2,484.64 | 3,811.87 |
| Default scheduling | 3 | 3,355.82 | 2,841.86 |
| Logical CPU 0 | 1 | 2,130.06 | 1,885.77 |
| Logical CPU 0 | 2 | 3,474.57 | 2,263.53 |
| Logical CPU 0 | 3 | 2,523.85 | 2,841.72 |

The default-scheduling median was 42.4% higher for the candidate. Unchanged stages also swung
strongly; for example, candidate diffusion took roughly twice the control's time in the first two
runs. This motivated a repeat with each benchmark child pinned to the same logical CPU (verified
affinity mask 1). No other process affinity or system setting was changed.

The pinned median was 10.3% lower for the candidate, with one slower candidate run. Host load
still affects these observations. The opposite median directions do not establish a general
speedup. The indexed traversal is retained as a verified allocation-work reduction under evaluation;
live latency acceptance remains outstanding.

Tail behavior is also mixed. In the 100,000-turf corridor, median-of-three pinned first-cycle p99
chunk time rose from 4.99 to 11.62 ms; third-cycle p99 rose from 1.37 to 1.62 ms. These regressions
are retained in the evidence and require controlled profiling or paired-game qualification before
making tick-budget claims. Work-limit compliance bounds logical operations, not elapsed time.

The subsequent [thread-cycle diagnostic follow-up](2026-09-06-thread-cycle-validation.md) validates
paired raw samples, records another three matched pairs, and retains the unresolved warm-tail concern.

## Evidence and verification

Evidence is under ignored `tmp/equalize-vectors/`: control/candidate executables and hashes in
`identity.json`, three allocation runs per variant, default and pinned latency CSVs,
`timing-comparison.json`, `equalize-quantiles.json`, `pinned-runs.csv`, the reference/mutant test
logs and final gate logs. The latency probe excludes fixture construction, allocator counters,
hashing and CSV work from measured stage intervals. Cold and warm cycles are distinct workloads.

The pinned compiler is `rustc 1.98.0 (88d9e12ae 2026-08-18)` and Cargo uses `--locked --offline`.
The feature-matrix script uses `RUSTUP_TOOLCHAIN=1.98.0` and `CARGO_NET_OFFLINE=true`.

| Final gate | Result |
| --- | --- |
| i686 Windows workspace tests | 430 passed; 2 doc tests ignored |
| x64 core/server/protocol/perf tests | 305 passed |
| i686 workspace/all-target strict Clippy | Passed |
| Supported feature matrix | All 12 configurations passed |
| x64 service release build | Passed |
| Formatting and whitespace | Passed |

```text
cargo +1.98.0 test --locked --offline --target i686-pc-windows-msvc --workspace --no-fail-fast
cargo +1.98.0 test --locked --offline --target x86_64-pc-windows-msvc -p dogmos-core -p dogmos-server -p dogmos-protocol -p dogmos-perf --no-fail-fast
cargo +1.98.0 clippy --locked --offline --target i686-pc-windows-msvc --workspace --all-targets -- -D warnings
cargo +1.98.0 build --locked --offline --release --target x86_64-pc-windows-msvc -p dogmos-server
```

No wire types, generated bindings, exports, atmosphere coefficients or release manifest were
changed. This native source checkpoint does not establish paired-game compile/boot, live-round
latency, full DM suite acceptance or the required DreamDaemon memory reduction.
