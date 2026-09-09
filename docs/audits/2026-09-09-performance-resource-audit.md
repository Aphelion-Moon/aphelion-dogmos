# Performance and resource audit on master

## Checkout and scope

The clean local `master` branch was fast-forwarded from `8456726` to
`14f0a4c2cb1a6db9a7e1685e385e0fb3d3fd7ced`, incorporating all three commits from
local `dogmos`. The branch remains `master`. Topology and expiry changes were committed
as `6274480`; the subsequent lifecycle work is described below. No push was performed.

Inspection covered core topology/lifecycle ownership, frontier storage, continuation
publication and expiry, and service/shim buffer ownership. Current implementation,
not historical audit conclusions, determined the changes. Rust was verified as
`rustc 1.98.0 (88d9e12ae 2026-08-18)`.

## Implemented changes

### Separate topology layer removal

`DogmosWorld` previously removed gas edges by collecting heat neighbors in a heap
vector, removing both layers, and reconnecting heat. Heat removal similarly copied
and reconstructed gas links, including firelock flags. Even a no-op re-registration
of a heat-only or gas-only turf caused allocations and topology revision churn.

`PackedTopology::remove_gas_slot` and `remove_heat_slot` now remove only the requested
layer and its reciprocal links. They share bounded, stack-only removal with
`remove_slot`. Neighbor order, the retained layer, and firelock metadata are untouched;
an effective removal advances the revision once and an empty removal does not advance
it. World lifecycle cleanup uses these methods. The obsolete current-handle lookup
and reconstruction code were removed.

The existing heat-only re-registration/conduction test was strengthened first and
failed on the original implementation: revision was `3`, expected `1`. It passes
after the change. Additional topology coverage exercises six neighbors, reciprocal
removal, retained order/firelocks, absent slots, repeated removal, edge counts, and
subsequent complete removal.

### Deadline-aware continuation expiry

Every callback drain previously scanned every pending continuation and reserved
expiry scratch for the complete pending map, even when no deadline was due.

The service now retains one optional earliest-deadline lower bound. Publishing a
continuation lowers the bound. Callback drains return from expiry checking before
scanning or reserving while that bound is in the future. A due sweep computes the
next deadline while doing the existing cancellation/queue cleanup. Removing the
earliest token may leave a conservatively early bound and cause one unnecessary
sweep; it cannot postpone expiry. An empty pending map clears the bound.

This keeps the pending map authoritative and avoids maintaining a second growing
deadline index. Actual expiry still scans the map and cleans queues; no claim is
made that due-expiry work is constant time.

The new non-expiring-drain regression failed before implementation because expiry
scratch grew to capacity `4` for one future continuation. It now remains at zero
over 100 drains, then expires the token at its exact deadline and clears core and
service ownership. Another test inserts deadlines out of order, cancels the earliest,
and checks remaining callbacks and exact subsequent expiry. Existing continuation
generation, lifecycle, resume, cancellation, and transaction tests remain in the gate.

## Matched local topology probe

New executable: `crates/dogmos-perf/examples/topology_lifecycle.rs`.
It constructs fresh worlds for each of three repetitions of each case at 1,000,
10,000, and 100,000 turfs. Setup, state hashing, and output are outside the timed and
allocation-counted update. Baseline is merged `14f0a4c` core plus the identical probe;
candidate includes direct topology layer removal. All 27 corresponding authoritative
mixture/heat/ownership state hashes match.

At 100,000 turfs:

| Case | Baseline allocations | Candidate allocations | Bytes requested before / after | Median update ms before / after |
| --- | ---: | ---: | ---: | ---: |
| Heat-only re-registration | 116,666 | 16,666 | 6,628,352 / 3,428,352 | 32.9193 / 26.7904 |
| Gas-only re-registration | 216,666 | 116,666 | 13,828,352 / 9,028,352 | 66.7774 / 57.4421 |
| Clear already-absent heat | 100,000 | 0 | 4,800,000 / 0 | 20.4140 / 4.2378 |

Allocation counts are identical across all three repetitions per case. Each baseline
case advances topology revision 299,998 times; each candidate case leaves it unchanged.
Raw observations are in
[`baseline.csv`](../performance/2026-09-09-topology-lifecycle/baseline.csv) and
[`candidate.csv`](../performance/2026-09-09-topology-lifecycle/candidate.csv).

These are service-core synthetic update measurements. Requested allocation bytes
are not process footprint or peak live bytes. The hash checks cover stored state,
not an end-to-end gameplay event transcript; topology and numerical behavior are
separately exercised by the Rust tests. Timings are local observations with visible
noise, not an SSair speedup, DreamDaemon memory improvement, or production acceptance.

Reproduce from repository root:

```powershell
cargo +1.98.0 build -p dogmos-perf --locked --target x86_64-pc-windows-msvc --release --example topology_lifecycle
New-Item -ItemType Directory -Force target/audit-20260909 | Out-Null
& target/x86_64-pc-windows-msvc/release/examples/topology_lifecycle.exe --output target/audit-20260909/topology-candidate.csv
```

The preserved local baseline executable is `target/audit-20260909/topology-baseline.exe`,
SHA-256 `c9fd2adf089f55c398d5432a364e2417b809010eb124e17f6d8b37d3ff9b4264`.
The measured candidate executable SHA-256 is
`c196af0b21451193259b9c2b310d765ac287c332b2ada2d470fc28b3989f4aae`.
These temporary binaries are not release artifacts.

## Continuation-aware lifecycle cleanup

Core now maintains its live continuation cardinality at allocation, completion and
owner invalidation. Rotation leaves it unchanged; rejected or generation-exhausted
allocation does not increment it. This replaces an arena scan for every count query.
Lifecycle free-list reservation uses the live count rather than historical arena size.

The service compares this count before and after each successful lifecycle batch.
These batches can only invalidate continuations, so an unchanged count proves there
is no callback ownership to prune. Actual invalidation still uses the existing queue
cleanup and transaction recount. Core remains the sole authority on owner matching.
Unrelated replacement still performs core owner validation/invalidation scanning;
this is not a reverse index for continuation owners.

The regression test first observed 117 allocations (27,736 requested bytes) for two
idempotent registrations with 512 pending transactions. It now stays under the
bounded 16-allocation allowance and checks that all callback ownership is unchanged,
then replaces the actual owner and verifies complete cleanup. Additional core coverage
checks count conservation across capacity rejection, token rotation, duplicate
completion, free-slot reuse, exhausted generations and single/multiple-owner invalidation.

`crates/dogmos-server/examples/lifecycle_allocations.rs` measures 100 one-owner
updates with 64, 512 and 2,048 pending transactions, in three fresh repetitions.
The baseline is `6274480` with the same probe. All 27 corresponding canonical
callback transcript hashes match; deadline timestamps are normalized because they
depend on setup wall time. Every continuation is subsequently cancelled and counts
return to zero. Mixture snapshots are unchanged.

At 2,048 pending transactions, for 100 updates:

| Case | Allocations before / after | Requested bytes before / after | Median ms before / after |
| --- | ---: | ---: | ---: |
| Mixture no-op | 20,200 / 200 | 7,070,800 / 20,400 | 24.4005 / 0.0151 |
| Turf no-op | 20,300 / 300 | 7,077,200 / 26,800 | 23.1640 / 0.0497 |
| Unrelated mixture replacement | 20,300 / 300 | 7,085,200 / 34,800 | 26.2001 / 0.1647 |

Raw measurements: [baseline](../performance/2026-09-09-continuation-lifecycle/baseline.csv)
and [candidate](../performance/2026-09-09-continuation-lifecycle/candidate.csv).
These are synchronous service-operation observations, not DreamDaemon footprint or
whole-game performance results. The test allocator counts successful allocation and
reallocation requests on the measured thread; it does not count peak live memory.

```powershell
cargo +1.98.0 build -p dogmos-server --locked --target x86_64-pc-windows-msvc --release --example lifecycle_allocations
& target/x86_64-pc-windows-msvc/release/examples/lifecycle_allocations.exe --output target/audit-20260909/lifecycle-candidate.csv
```

Preserved baseline executable SHA-256:
`499f4c8a2af7475b8453584b3683a3c79d23fa57d881fe8929e711f257b6f439`.
Measured candidate executable SHA-256:
`b4580548d58f9aae4057d2a2252d427696e3730f8628a6e161d54e9a757ced92`.

## Remaining source-backed audit targets

1. **Frontier reads materialize a complete cached copy after deltas.**
   `FrontierState::add/remove` discard `committed_view`, even for empty adds or
   missing-handle removes; the next `committed()` scans and allocates the full view.
   Existing sparse-removal timing ends before that read. Measure delta plus the
   first stage/read as one operation before choosing a cursor or packed-view redesign.
   Preserve deterministic surviving order and remove/re-add semantics.
2. **Frontier fallible reservation arithmetic needs a focused correction.**
   `begin` passes target minus capacity to `try_reserve`, whose additional count is
   relative to length. After buffer reuse, this can under-reserve, letting later
   resize/insert use an infallible allocation. Test a cleared reusable buffer followed
   by growth beyond capacity, including the bitset and duplicate set, with allocation
   failure coverage before changing the error path.
3. **Pipenet reconciliation still allocates request-local vectors.**
   The server decoder/response path and `ServiceState::reconcile_pipenet` build handle
   and snapshot vectors per request. Compare with snapshot-batch buffer reuse and
   measure actual pipenet frequency before adding scratch ownership.

Broad replacement of the core arena is not justified by these findings. Existing
reverse ownership indexes already bound edge/turf cleanup to affected owners. The
largest remaining structural opportunity in this audit is eliminating repeated
whole-set work at lifecycle/frontier boundaries while preserving domain authority.

## Verification and qualification boundaries

The lifecycle follow-up passed i686 Windows workspace tests (466 executable tests,
zero failed, two existing ignored documentation examples), strict all-target Clippy,
formatting and whitespace checks. Logs use the `lifecycle-` prefix under
`target/audit-20260909/`. Linux WSL with Rust 1.98.0 and `--locked --offline` passed
336 x64 core/server/protocol/perf tests and 453 i686 workspace tests (zero failures,
two ignored documentation examples on i686), plus strict i686 all-target Clippy.
Linux logs use the `linux-` prefix. Independent source review found no actionable
issues in count conservation or the lifecycle guard. The earlier checkpoint below
remains separate evidence.

- x86_64 Windows core/server/protocol/perf: **335 tests passed**, zero failed/ignored.
  Command: `cargo +1.98.0 test -p dogmos-core -p dogmos-server -p dogmos-protocol -p dogmos-perf --locked --target x86_64-pc-windows-msvc`.
- Dependency direction and release-contract tooling: **13 tests passed** using
  `python -m unittest tools.tests.test_dependency_direction tools.tests.test_dogmos_contract`.
- i686 Windows workspace: **464 executable tests passed**, zero failed; two existing
  documentation examples were ignored. Command: `cargo +1.98.0 test --workspace --locked --target i686-pc-windows-msvc`.
- Strict i686 Clippy: **passed, no warnings**. Command:
  `cargo +1.98.0 clippy --workspace --locked --target i686-pc-windows-msvc --all-targets -- -D warnings`.
- Supported feature matrix: **12/12 configurations passed** with
  `tools/check_feature_matrix.ps1 -Target i686-pc-windows-msvc` and the repository pin.
- Exact generated binding drift: **passed**, one test, using
  `python -m unittest tools.tests.test_generated_bindings`; generation ran twice and
  matched the checked-in canonical bytes.
- Maintained `tools/test_cross_bitness_ipc.ps1`: **passed** with an x86 PE client and
  x64 PE service, two ordered reaction callbacks, independent resume/cancel, and
  1,030 continuation lifecycle cycles across five replacement modes with queued and
  delivered targets and no pending work. This uses development builds, not the
  installed game pair. Log: `target/audit-20260909/cross-bitness.log`.
- x64 release service build: **passed** using
  `cargo +1.98.0 build -p dogmos-server --bin dogmosd --release --locked --target x86_64-pc-windows-msvc`.
- i686 release shim build: **passed** using
  `cargo +1.98.0 build -p dogmos-byond --release --locked --target i686-pc-windows-msvc`.
  Both builds remain development-identity artifacts; they were not packaged or installed.
- `cargo +1.98.0 fmt --all -- --check` and `git diff --check`: **passed**.
  Detailed local logs are under `target/audit-20260909/`. i686 integration fixtures
  intentionally emitted errors for rejected invalid requests; their assertions passed.
- Independent Luna High source review: **no actionable findings** in topology removal,
  the expiry lower-bound invariant, tests, or the measurement claims.
- Linux/i686 Linux, candidate paired native-load, DM compile/focused/full suite,
  boot/soak and repeated DreamDaemon/service workload: **not run for these edits**.
  The paired checkout currently pins `14f0a4c`, which precedes these uncommitted edits.
  Exercising that installed pair would not qualify this candidate.

Before integration, commit the reviewed native source when authorized, generate and
verify a complete candidate artifact pair through maintained release tooling, then
run the paired game's supported compile, focused tests, full suite and boot/soak.
Keep protected artifact installation as its explicit approval gate. Runtime consumers
must restart to load a new shim/service pair. Finish with at least three identical
controls and candidates, separate DreamDaemon and service process measurements, and
numerical/event equivalence; retain every unrun gate as an unrun gate.
