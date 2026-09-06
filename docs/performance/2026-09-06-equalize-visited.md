# Dense equalization visitation

## Result and scope

Equalization now tracks visited turfs with dense flags in its captured component kernel. This
removes repeated tree-node allocation, lookup and destruction. `SlotIndex::index_of` validates
the complete slot/generation key before returning a position; positions stay stable until the
index is cleared. The kernel is fully captured before computation and remains immutable during it.
Storage is proportional to captured turfs, including when their external slots are sparse.

The change preserves BFS and transfer order, every cooperation point, hard component limits,
transaction/publication behavior and numerical coefficients. It builds on the earlier
[parent/balance vector change](2026-09-06-equalize-vectors.md), which is present in both controls
and candidates here. The previous continuation lifecycle and diffusion publication changes are
also identical on both sides.

The synthetic native corpus shows lower total equalization time and fewer allocations. Tail
latency remains mixed, so this is **not live tick-budget acceptance**. The earlier
[cycle diagnostic results](2026-09-06-thread-cycle-validation.md) remain separate measurements.

## Matched measurement

Two isolated source copies use `rustc 1.98.0 (88d9e12ae 2026-08-18)`, locked offline dependencies,
x64 Windows release mode, fat LTO and one codegen unit. Their source manifests differ only in
`core/src/slot_index.rs` and `core/src/world/component.rs`. A later review strengthened a unit-test
assertion without changing the measured release implementation.

Each probe ran in three alternating control/candidate pairs, with reverse order in pair two.
All twelve processes recorded affinity mask 1 and exit code 0. Timing uses the normal allocator;
allocation counting runs separately. Each process executes the same 135 cases across five stages,
three topologies, three sizes and three successive cycles.

Independent Python validation checked 810 timing summaries against all 55,836 paired raw chunks:
sequential indices, totals, nearest-rank p50/p95/p99 and maxima for wall time and calling-thread
cycles. Every timing run has identical state/event hashes, work counts and chunk counts. All 810
allocation rows match those state/event hashes and work counts after normalizing hash encoding.
Every non-timing allocation field repeats exactly within each variant.

Summed equalization calls across the corpus:

| Pair | Control ms | Candidate ms | Control billion cycles | Candidate billion cycles |
| --- | ---: | ---: | ---: | ---: |
| 1 | 1,380.309 | 1,061.341 | 3.382 | 2.620 |
| 2 | 1,333.507 | 1,206.469 | 3.262 | 2.819 |
| 3 | 1,351.156 | 1,146.110 | 3.311 | 2.810 |

The median total falls 15.18% in wall time and 15.15% in calling-thread cycles. Other stage medians
still vary: diffusion is -0.65% wall/-0.09% cycles, heat -4.12%/-3.45%, excited groups
+11.41%/+3.76%, and reactions -3.06%/-3.47%. These variations constrain attribution of small
differences; cycle counts are not a processor-independent time unit.

Repeatable allocation results at 100,000 turfs:

| Topology / cycle | Control allocations | Candidate allocations | Control allocated bytes | Candidate allocated bytes |
| --- | ---: | ---: | ---: | ---: |
| Corridor / first | 35,334 | 18,669 | 147,327,691 | 146,265,915 |
| Corridor / second and third | 34,470 | 17,805 | 6,254,000 | 5,192,224 |
| Grid / first | 33,823 | 17,808 | 150,193,979 | 149,190,587 |
| Grid / second and third | 32,955 | 16,940 | 6,044,572 | 5,041,180 |
| Multiz / first | 35,076 | 18,414 | 145,937,087 | 144,875,671 |
| Multiz / second and third | 34,284 | 17,622 | 6,214,520 | 5,153,104 |

The corridor removes 16,665 allocations and 1,061,776 allocated bytes per pass. First-cycle peak
live allocation bytes are effectively unchanged; warm corridor peak live bytes fall from
181,966,846 to 180,905,072. These are native allocator observations, **not DreamDaemon footprint
measurements**. No service RSS or DreamDaemon resource sampling was performed in this comparison.

Median-of-three p99 chunk observations at 100,000 turfs:

| Topology / cycle | Control ms | Candidate ms | Control million cycles | Candidate million cycles |
| --- | ---: | ---: | ---: | ---: |
| Corridor / first | 2.550 | 2.783 | 6.096 | 6.644 |
| Corridor / second | 0.824 | 1.397 | 1.803 | 2.562 |
| Corridor / third | 0.905 | 0.630 | 1.827 | 1.363 |
| Grid / first | 3.808 | 3.219 | 8.050 | 7.845 |
| Grid / second | 1.429 | 0.948 | 3.336 | 2.095 |
| Grid / third | 1.343 | 0.981 | 3.127 | 2.134 |
| Multiz / first | 3.191 | 3.061 | 8.079 | 7.309 |
| Multiz / second | 1.097 | 0.652 | 2.356 | 1.487 |
| Multiz / third | 1.032 | 0.655 | 2.336 | 1.378 |

The second corridor cycle improves in median total time (70.930 to 64.546 ms) but worsens at p99.
Pair two is an outlier in the opposite direction: 70.930 to 159.260 ms, with 54.3% more thread
cycles. The raw candidate peaks occur at different computation chunks in different runs, and both
cycle and wall metrics vary. The data does not establish a uniform tail improvement or explain
away the higher tail values.

## Tests of the implementation and tests

- Dense-position tests check sparse slots, insertion stability, generation replacement and clear/
  reinsertion. A deliberate generation-check bypass fails the stale-key assertion. A separate
  mutant that reorders dense records while preserving ordinary lookups fails insertion stability.
- A cyclic sparse fixture checks literal final moles and the exact four pressure events across
  two successive stages at work limits 1, 7 and 4,096. Marking all turfs as already visited fails
  its final gas assertion. The existing branched fixture independently checks parent paths and
  atomic visibility. The cyclic fixture passed against the control before the refactor.
- Review confirmed kernel position lifetime, generation validation and unchanged limit/cooperation
  ordering. It identified the missing insertion-stability assertion, which was added and then
  demonstrated failing against the position-moving mutant. All mutations were restored byte for
  byte before final verification.
- The independent measurement validator also rejects deliberately altered state/event hashes,
  incorrect p99 summaries and a missing workload case. These checks modify separate copies of the
  CSV files; the original measurements remain intact.

## Verification and reproduction

| Gate | Result |
| --- | --- |
| i686 Windows workspace tests | 444 passed; 2 doc tests ignored |
| x64 Windows core/server/protocol/perf tests | 319 passed |
| x64 Linux core/server/protocol/perf tests | 318 passed |
| i686 Windows/Linux workspace and x64 Windows/Linux changed-package strict Clippy | Passed, all targets |
| Python tooling tests | 42 passed, including generated bindings |
| Maintained i686-to-x64 IPC probe | Passed, including 1,030 lifecycle cycles and five expected stale-continuation rejections |
| Formatting and whitespace | Passed |
| Linux i686 executable tests | Not rerun: this WSL environment previously rejected the binaries with `Exec format error`; compile/Clippy evidence only |
| Current-source paired game compile, boot, full DM suite and live performance | Not run; clean paired release prerequisite remains open |

Rust commands use `cargo +1.98.0`, `--locked --offline` and explicit targets. The Windows i686
gate is `test --workspace --no-fail-fast`; x64 gates use
`test -p dogmos-core -p dogmos-server -p dogmos-protocol -p dogmos-perf --no-fail-fast`.
Clippy uses `--all-targets -- -D warnings`, workspace scope on i686 and those four packages on
x64. WSL retains the separate `target/linux-continuation` output directory. The remaining gates
are `python -m unittest discover -s tools/tests -v`, `tools/test_cross_bitness_ipc.ps1`,
`cargo +1.98.0 fmt --all -- --check` and `git diff --check`.

The two extra core tests account for the increase from the preceding qualification. Windows has
one more test than Linux because of the platform-specific cycle-counter coverage. The final core
release implementation matches the measured candidate; only the later unit-test assertion differs.

Local evidence is under ignored `tmp/equalize-visited/`: immutable measured source copies and
hash manifests, release build logs, executable hashes in `runs.csv`, twelve probe summaries,
six raw timing companions, `validated-comparison.json`, mutation logs and final test logs.
`validate.py` recomputes the measurements independently; `run.ps1` runs the alternating bounded
processes. Rebuild either isolated source with:

```powershell
cargo +1.98.0 build --release --locked --offline --target x86_64-pc-windows-msvc --manifest-path tmp/equalize-visited/control/Cargo.toml
cargo +1.98.0 build --release --locked --offline --target x86_64-pc-windows-msvc --manifest-path tmp/equalize-visited/candidate/Cargo.toml
pwsh -NoProfile -File tmp/equalize-visited/run.ps1
python tmp/equalize-visited/validate.py
```

The repository's ordinary `core_stage_latency` and `core_stage_allocations` examples exercise the
same fixture and measurement code. Changes remain uncommitted. Current-source paired DreamMaker,
DreamDaemon and live performance gates still require the clean paired release described in
the [IPC qualification report](2026-09-06-lifecycle-ipc-qualification.md#paired-game-prerequisite).
