# Component storage performance follow-up: 2026-09-05

Base: `ab8b867`. This records the component-storage follow-up before the subsequent continuation repairs.

## Applied changes

- Store `SlotIndex` values densely, with a compact slot-to-position lookup. Clearing retains capacity; validating the stored slot prevents stale positions from aliasing a different record. Full keys still enforce generations. Sparse slots no longer each carry a large empty record.
- Remove redundant mutable-mixture trees in equalization and excited groups. Equalization already reserves each mixture in the transaction. Excited groups now reserve during the existing validation pass and update those private candidates during averaging. Traversal, summation, candidate order, coefficients and publication boundaries are preserved.

These changes affect native core/service worksets. They do not establish reduced DreamDaemon address-space use. Dense lookup introduces an additional dependent access; allocation savings alone do not prove lower live-round latency.

## Repeated native measurements

Three control and three candidate executions of the unchanged `core_stage_allocations` harness, each with 135 rows: five stages, three topologies, three sizes and three successive cycles. Every candidate state/event hash and logical work count matched its corresponding control. Allocation counts, cumulative bytes and reusable capacities repeated exactly within each variant. Successive cycles continue the same world; React has an empty reaction inventory.

100,000-turf corridor, control to candidate:

| Stage | Cold allocated bytes | Third-cycle allocations | Retained workset bytes after third cycle |
| --- | ---: | ---: | ---: |
| Diffusion | 96,467,568 to 88,079,088 | 1 to 1 | 47,985,920 to 43,791,616 |
| Turf heat | 37,748,208 to 29,359,728 | 1 to 1 | 19,425,792 to 15,231,488 |
| Equalization | 179,478,067 to 149,199,691 | 67,170 to 50,470 | 93,406,872 to 79,251,096 |
| Excited groups | 160,976,299 to 127,465,123 | 66,674 to 16,674 | 82,748,504 to 68,592,728 |
| React, empty inventory | 14,679,888 to 10,485,648 | 1 to 1 | 7,091,456 to 4,994,304 |

Retained workset figures are lower bounds excluding tree nodes and allocator metadata. Peak allocator live-byte measurements include fixtures; neither metric is process committed memory. Chunk maxima from the allocation runs are not a speedup gate: concurrent compilation and host scheduling can affect them.

Evidence: `tmp/performance-followup-control-{1,2,3}.csv`, `tmp/performance-followup-candidate-{1,2,3}.csv`, companion `.updates.csv` files and `tmp/performance-followup-summary.json`. The saved control executable was built before production edits.

An additional six alternating whole-process timing pairs, with no compilation launched by this task, were mixed:

| Pair | Control seconds | Candidate seconds |
| --- | ---: | ---: |
| 1 | 12.30 | 15.55 |
| 2 | 12.20 | 16.48 |
| 3 | 11.46 | 10.98 |
| 4 | 11.58 | 11.33 |
| 5 | 11.53 | 12.24 |
| 6 | 15.35 | 14.70 |

Median whole-probe time was 11.89 seconds for control and 13.47 seconds for candidate (about 13% higher). Three candidate runs were faster and three slower. These timings include fixture construction and hashing, and do not isolate stage CPU cost. Latency remains unresolved; the retained changes have demonstrated allocation/storage savings, not an accepted speedup. All six additional pairs matched all 135 state/event hashes and work counts. Evidence: `tmp/performance-followup-timings.csv`, `tmp/performance-followup-timings-extra.csv`, and `tmp/performance-followup-timed-{control,candidate}-{1..6}.csv`. A controlled stage CPU or paired-game profile is still required to assess this tradeoff.

## Test adequacy

- The sparse-record bound failed on the control and passes on compact storage.
- A separate BTreeMap model checks insertion, clearing, slot reuse and full-generation lookup. Explicit assertions also check identical-key replacement returns the previous value and duplicate set insertion returns false.
- The clear/reuse test fails when the stored-slot backreference check is deliberately removed.
- Connected duplicate-mixture tests require the exact error and unchanged complete mixture snapshot. Disabling duplicate detection fails; an excited-only mutant separately confirms the second stage is exercised. All mutants were restored.
- Existing tests enumerate prepublication cancellation cutoffs, require unchanged snapshots and empty events, and verify successful retry. Disconnected duplicate tests cover earlier components remaining committed.
- Benchmark hashes include gas bits, temperature, volume, revisions, turf heat and event order. Comparing a preserved control executable avoids treating two calls to the same candidate kernel as an independent oracle.
- Independent read-only review found no critical or important issue. Its replacement-return test gap was repaired.

## Verification and boundaries

Pinned compiler: `rustc 1.98.0 (88d9e12ae 2026-08-18)`. Cargo uses `--locked --offline`; the feature script uses the equivalent offline environment.

Final results are recorded in `tmp/performance-followup-i686-tests.log`, `tmp/performance-followup-x64-tests.log`, `tmp/performance-followup-clippy.log`, `tmp/performance-followup-features.log`, and `tmp/performance-followup-release.log`.

| Gate | Result |
| --- | --- |
| i686 Windows workspace tests | 407 passed; 2 doc tests ignored |
| x64 core/protocol/server tests | 277 passed |
| i686 strict Clippy, workspace/all targets | Passed |
| Supported feature matrix | All 12 configurations passed |
| x64 Windows service release build | Passed |
| Formatting and whitespace diff | Passed |
| Deliberately broken variants | Three expected executable assertion failures; restored |

No wire types, generated bindings, exports, shim code or DM sources changed. No paired-game compile, BYOND native-load/boot, full DM suite, Linux cross-build or live-round latency/memory acceptance was performed in this follow-up. Windows service compilation and native tests do not replace those gates. The previous Linux linker and Python policy issues were not repaired or requalified here.

## Reproduction

At the commit checkpoint, formatting and a fresh x64 run of the core library and
`frontier_processing` targets passed (31 + 40 tests). The earlier measurement and gate table above
is retained as that task's historical record; it was not treated as fresh verification by the
subsequent integration investigation.

```text
cargo +1.98.0 test --locked --offline --target i686-pc-windows-msvc --workspace --no-fail-fast
cargo +1.98.0 test --locked --offline --target x86_64-pc-windows-msvc -p dogmos-core -p dogmos-protocol -p dogmos-server --no-fail-fast
cargo +1.98.0 clippy --locked --offline --target i686-pc-windows-msvc --workspace --all-targets -- -D warnings
cargo +1.98.0 build --locked --offline --release --target x86_64-pc-windows-msvc -p dogmos-server
cargo +1.98.0 build --locked --offline --release --target x86_64-pc-windows-msvc -p dogmos-perf --example core_stage_allocations
core_stage_allocations --output candidate.csv
```

Run `tools/check_feature_matrix.ps1 -Target i686-pc-windows-msvc` with `RUSTUP_TOOLCHAIN=1.98.0` and `CARGO_NET_OFFLINE=true`. Run formatting and `git diff --check`. For deployment qualification, build matched artifacts and run the paired game's maintained compile, boot, focused and full-suite gates, then compare repeated identical live workloads.
