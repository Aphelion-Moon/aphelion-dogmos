# Equalization cycle diagnostics and test qualification

## Result

The equalization vector candidate retains its repeatable allocation reduction and matching numerical
and event results. This follow-up does **not** establish a general latency improvement or close the
tail-latency acceptance gate. The earlier [allocation and timing results](2026-09-06-equalize-vectors.md)
remain applicable to their recorded workloads.

The maintained latency probe now offers optional Windows calling-thread cycle measurements and
paired, unsorted chunk samples. Default runs make no cycle-counter calls and leave cycle columns
blank. See [the probe instructions](README.md#core-stage-latency-probe) for units, overhead and
platform limits. No new production algorithm change was made during this diagnostic follow-up.

## Matched experiment

Two isolated source copies were built with `rustc 1.98.0 (88d9e12ae 2026-08-18)`, `--locked --offline`,
x64 Windows release mode, fat LTO and one codegen unit. Their source hashes differ only in
`dogmos-core/src/world/component.rs`: the control uses the maps from `31a96c4`; the candidate uses
component-position vectors. Both include the same current diffusion-publication source and the same
measurement code. Their lockfiles are identical.

Three alternating pairs ran with `--thread-cycles` on logical CPU 0. Every child reported affinity
mask 1 and exit code 0. Each run contains 135 cases. All six runs have identical state/event hashes,
work counts and chunk counts. An independent Python calculation validated all 810 summary rows
against 55,836 raw chunks, including chunk indices, totals and nearest-rank p50/p95/p99/max values.

Summed equalization calls across the corpus:

| Pair | Control ms | Candidate ms | Control billion cycles | Candidate billion cycles |
| --- | ---: | ---: | ---: | ---: |
| 1 | 3,899.160 | 1,904.189 | 7.044 | 4.530 |
| 2 | 1,896.548 | 2,113.917 | 4.460 | 5.006 |
| 3 | 2,099.632 | 1,984.755 | 4.586 | 4.484 |

The candidate's median total was 5.5% lower in wall time and 1.2% lower in cycles. Unchanged stages
also varied: candidate diffusion medians were 10.8% higher in wall time and 10.9% higher in cycles;
excited-groups medians were 11.7% and 6.0% higher. These differences limit causal interpretation.

Median-of-three p99 chunk observations for the 100,000-turf corridor:

| Cycle | Control ms | Candidate ms | Control million cycles | Candidate million cycles |
| --- | ---: | ---: | ---: | ---: |
| First | 8.880 | 5.853 | 14.921 | 13.536 |
| Third | 1.192 | 1.552 | 2.604 | 3.710 |

The warm-cycle tail increase is present in both metrics. It cannot be dismissed as scheduling delay
alone, nor can these variable runs establish that the vector change caused it. Retain the candidate
as an allocation-work reduction under evaluation; do not describe it as accepted for live tick
latency. No DreamDaemon footprint, IPC or paired-game performance claim follows from this experiment.

## Test audit and repairs

- Literal percentile fixtures check empty, singleton, skewed and 100-value samples. A two-turf
  diffusion fixture checks actual gas amounts and revisions through the timed driver.
- The cycle test now requires multiple chunks. A deliberate mutant that kept only the latest cycle
  sample failed with three wall samples versus one cycle sample. The real implementation passes.
  A separate counter test rejects a zero-work stub; backwards counters fail explicitly.
- A default executable run produced 135 matching workload results with blank cycle fields and no
  companion file. An invalid CLI flag returned an error without producing an output file.
- The agent-document checker incorrectly required an approval policy absent from current
  `AGENTS.md`. Its fixture and assertion reproduced the false rejection before removal of that
  obsolete requirement. Existing source-anchor, link, ownership and binding checks remain active.
- The source-ancestry test assumed Git's initial branch was `master`. It failed under a `main`
  default. Its temporary fixture now names its own branch, and all 42 tooling tests pass with that
  inherited default. Stale references to the removed policy were corrected in the guides.

## Final verification

| Gate | Result |
| --- | --- |
| i686 Windows workspace tests | 433 passed; 2 doc tests ignored |
| x64 Windows core/server/protocol/perf tests | 308 passed |
| x64 Linux core/server/protocol/perf tests in WSL | 307 passed |
| i686 Windows and Linux workspace/all-target strict Clippy | Passed |
| x64 Windows perf/all-target strict Clippy | Passed |
| x64 Linux perf/all-target compile check | Passed |
| Repository Python tooling tests | 42 passed, including inherited `main` default |
| Formatting and whitespace | Passed |
| i686 Linux executable tests | Compiled; WSL rejected 49 test binaries with `Exec format error` before execution |

The Linux test count differs because the Windows counter API and multi-chunk counter test are
replaced by one explicit unsupported-platform check. Linux i686 compile/Clippy success is not
executable-test success. Current-source paired-game compile, boot, full DM tests and live performance
qualification were not run in this follow-up; earlier source checkpoints do not substitute for them.

Final Rust commands use `cargo +1.98.0` with `--locked --offline`: `test --workspace --no-fail-fast`
on i686 Windows; `test -p dogmos-core -p dogmos-server -p dogmos-protocol -p dogmos-perf --no-fail-fast`
on x64 Windows and Linux; and `clippy --workspace --all-targets -- -D warnings` on both i686 targets.
WSL uses the separate `target/linux-continuation` target directory. The ordinary tooling gate is
`python -m unittest discover -s tools/tests -v`.

Local raw evidence is under ignored `tmp/equalize-cycles/`: six summaries and companions, verified
source/executable hashes, `runs.csv`, `validated-comparison.json`, `verification.json`, mutation
logs and final gate logs. `validate.py` independently recomputes the CSV summaries. The measured
source copies remain intact; the deliberately broken multi-chunk probe is in `test-mutation/`.
Changes remain uncommitted.
