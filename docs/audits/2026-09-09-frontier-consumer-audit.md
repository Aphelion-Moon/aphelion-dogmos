# Frontier execution and allocation audit

This follow-up uses native master `27762739d6b3ead84c4438bf1f3232b712900b8e`
as its control. The preceding audit and installed-pair qualification are separate
checkpoints; they do not qualify these new source changes.

## Finding and execution model

`FrontierState` already preserves insertion order in an append-only vector with
tombstones and an index-valued membership map. Effective deltas invalidated a
`OnceLock<Vec<TurfHandle>>`. The next read scanned the whole vector through the hash
map and grew a fresh contiguous copy. Both service telemetry and stage preparation
used that read, including before the stage's bounded preparation loop. The older
sparse-update probe stopped its timer before this first consumer.

Stage execution now walks the authoritative ordered storage directly. Each inspected
position, including a removed entry, consumes one preparation work item. The cursor
checks cancellation between positions and preserves the original live-handle order,
including placing re-added handles at the end. Membership checks still compare both
the complete generational handle and its current position, so an old occurrence
cannot resurrect after removal and re-addition.

The cursor uses `usize` internally because storage can contain more positions than
live membership. Protocol progress and remaining-work estimates saturate to `u32`.
Stage telemetry reports storage inspection progress; service `frontier_count` remains
the exact live membership count, obtained without building a view. Component scratch
reservation also uses live membership. Retry paths restart storage inspection at zero.

The public contiguous inspection API remains available. Dense frontiers borrow their
existing vector directly. Fragmented inspection allocates one exactly sized view.
Production bounded stages and service telemetry no longer need that view. This does
not make every other stage operation allocation-free or constant-time.

## Structural choice and costs

Retaining ordered storage avoids moving a full stable-compaction pass into every
sparse removal. That alternative would make bursts of edits pay repeated whole-set
work before any consumer ran. No numerical kernel, coefficient, public DM proc, wire
layout, or upload reservation/publication rule changes in this patch.

The existing compaction threshold is retained: once physical length exceeds twice
live membership, mutation compacts the storage. That bulk mutation can still scan
the frontier. Before this threshold, tombstones can increase preparation work and
RPC chunk count; they are now visible to the budget rather than hidden in an initial
full scan. The burst fixture at 100,000 turfs requires 1,563 chunks instead of 1,555
at a work limit of 64. This tradeoff needs to remain visible in game qualification.

## Reproducible focused measurement

The maintained example is `crates/dogmos-perf/examples/frontier_lifecycle.rs`:

```powershell
cargo +1.98.0 build -p dogmos-perf --example frontier_lifecycle --release --locked --offline --target x86_64-pc-windows-msvc
& target/x86_64-pc-windows-msvc/release/examples/frontier_lifecycle.exe --output frontier.csv
```

The same example was compiled against the control before editing core/server source.
Control and candidate executables are preserved locally under
`target/audit-20260909-frontier/`. SHA-256:

- Control: `4c7a4f9ba88181c8b21402d60b8be34db1bdb0ffdb5c0d6164fb2e5a46c617f6`.
- Candidate: `e68e03adcb20d6be28cadc00488262d7a29d636a6e163ff013fe3e93f4d6e38f`.

There are three fresh worlds for each of ten cases at 1,000, 10,000 and 100,000
turfs. Mutation and first-consumer phases are measured separately. Cases include
initial reads, append, sparse and bulk removal, remove/re-add, 64 consecutive edits,
one-work-item stage entry and complete preparation in 64-work-item chunks. Setup,
ordered-vector oracle construction and equality/hash assertions are outside timing.
The stage benchmark uses registered turfs without mixtures to isolate frontier
overhead; it is not an atmosphere or gameplay workload.

Raw records are checked in under `docs/performance/2026-09-09-frontier-lifecycle/`.
All 90 control/candidate ordered-frontier cases agree. Allocator counters count
successful allocations/reallocations and requested bytes, not peak live memory.

Consumer-phase observations at 100,000 turfs:

| Consumer | Control allocations / bytes | Candidate allocations / bytes | Median time, control / candidate |
| --- | ---: | ---: | ---: |
| Initial dense read | 16 / 2,097,120 | 0 / 0 | 10.9175 ms / below timer resolution |
| Read after adding 16 | 16 / 2,097,120 | 0 / 0 | 8.0151 ms / below timer resolution |
| Read after removing 16 | 16 / 2,097,120 | 1 / 799,872 | 5.1382 ms / 2.3627 ms |
| First stage chunk after removing 16 | 17 / 2,097,144 | 1 / 24 | 6.1739 ms / 0.0022 ms |
| Full frontier-only stage after removing 16 | 18 / 2,097,168 | 2 / 48 | 9.8257 ms / 5.4497 ms |
| Full frontier-only stage after 64 edits | 18 / 2,097,168 | 2 / 48 | 6.9722 ms / 5.0989 ms |

These are local three-sample medians, not stable latency thresholds. Allocation
elimination and bounded preparation are the principal evidence. They do not establish
DreamDaemon private-byte savings, SSair speedup, whole-game numerical equivalence,
or tick-budget qualification. DreamDaemon and service measurements must remain
separate in any paired workload.

## Regression and verification evidence

The new one-work-item regression was observed failing on the control: frontier
retained element storage rose from 36,576 to 44,768 bytes solely from starting a
bounded chunk and reading telemetry. It passes with the new execution path. The test
also traverses a 250-entry removed run one budgeted position at a time, cancels and
restarts under a new stage epoch.

A second fixture compares fragmented removal/re-add storage with a fresh ordered
upload at work limits 1, 7 and 4,096 for all five stages. Final mixture snapshots,
heat state and event transcripts agree exactly. Its reaction registry is empty;
existing reaction/callback tests remain separate coverage. All 46 frontier integration
tests pass, including publication contention, cancellation, work limits and ordering.
The four existing reservation/no-op unit regressions remain required.

Native validation uses Rust 1.98.0 (`88d9e12ae`, 2026-08-18), `--locked` and offline
dependencies. Logs are under `target/audit-20260909-frontier/`.

- Windows x64 core/server/protocol/perf: 343 passed, no failures or ignored tests.
- Windows i686 workspace: 472 passed, no failures; two existing ignored doc examples.
- Strict Windows i686 workspace/all-target Clippy: passed without diagnostics.
- Windows supported feature matrix: all 12 configurations passed.
- Dependency-direction/release-contract tooling: 13 tests passed. Exact generated
  binding drift: one additional test passed.
- Maintained cross-bitness IPC: x86 client/x64 service passed the ordered reaction
  callback case and 1,030 continuation lifecycle cycles across five replacement
  modes, with no pending work. Initial launcher attempts stopped on an unreadable
  host Git ignore file; process-local configuration isolation allowed the maintained
  gate to run without source changes. Expected rejected continuation requests emitted
  service errors; the rejection assertions and final probe passed.
- Linux x64 core/server/protocol/perf: 342 passed, no failures or ignored tests.
- Linux i686 workspace: 459 passed, no failures; two existing ignored doc examples.
- Strict Linux i686 workspace/all-target Clippy: passed. All 12 supported feature
  combinations passed with the same arguments as `tools/check_feature_matrix.ps1`,
  using a local shell helper and the separate `target/linux-continuation` cache.
  Its first invocation stopped because Cargo was absent from the WSL command PATH;
  the completed invocation selected the pinned Cargo explicitly through its PATH.
- Formatting and `git diff --check`: passed.
- Independent Luna High source review: no actionable correctness findings in the
  frontier access, cursor, retries, telemetry, tests or measurement example.

Paired artifact/runtime qualification remains pending for this native source
checkpoint. No candidate pair has been installed at this checkpoint.

## Next audit target

Pipenet request decoding, service wire/core handle conversion, reconciliation planning,
snapshot materialization and response encoding still allocate request-local vectors.
The adjacent snapshot-batch path already has reusable buffers. The next useful probe
should measure repeated reconciliation with legal duplicates, stale-handle rejection,
zero-volume and immutable mixtures before changing ownership. Preserve first-seen
output order and validate every handle before mutation. Source inspection alone does
not establish that this is a material CPU or DreamDaemon memory cost.
