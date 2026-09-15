# Atmosphere runtime isolation design

Status: proposed design for review, 2026-09-14. Implements the runtime workstream of the [roadmap](../../performance/2026-09-14-atmosphere-roadmap.md). N and G mean the repositories and exact revisions defined there.

## Outcome

Let other gameplay run while Dogmos prepares a simulation result, while keeping immediate atmosphere reads/writes coherent and preserving numerical rules, stage order, event order, and bounded DreamDaemon memory. First remove avoidable DM work; then introduce service jobs without sharing mutable world state across worker threads.

## Current behavior and source anchors

| Anchor at reviewed revision | Behavior |
| --- | --- |
| G `code/controllers/subsystem/air.dm`, `SUBSYSTEM_DEF(air)` and `fire` | Background priority, 0.5-second cadence; sequential machinery, native stages, callbacks, visuals, and other DM work |
| G `code/controllers/subsystem.dm`, `ignite` | `waitfor = FALSE` supports sleeping; it does not release DM during a synchronous native call |
| G `modular_aphelion/modules/dogmos/code/service_backend.dm`, `dogmos_run_stage` | Loops over synchronous work-item-limited requests; checks the remaining MC budget between them |
| N `crates/dogmos-byond/src/client.rs:336` | `round_trip` waits on `recv_timeout` |
| N `crates/dogmos-server/src/lib.rs:886` | Dispatch computes a stage chunk before replying |
| N `crates/dogmos-core/src/world/versioned.rs` | Tentative records become visible through publication; intervening writes invalidate a tentative publication |
| G `air.dm`, `dogmos_prefetch_machinery_snapshots` | Builds a list from the whole machine run before bounded snapshot transmission |
| G `service_backend.dm`, `sync_dogmos_frontier` | Incremental wire updates still require DM scans to discover differences |

BYOND executes DM and manages its data on one thread. Native async returns are available in the pinned byondapi header, but the first implementation uses small submit/poll/commit requests and MC resumption; it does not require changing every binding to `await`. See [BYOND threading/native calls](https://www.byond.com/docs/ref/info.html#/{notes}/Byondapi). The public synchronous gas API remains synchronous and must stay responsive.

## Global constraints

- Rust 1.98.0 with `--locked`; BYOND 516.1687 for the anchored game; revalidate pins before execution.
- Windows and Linux i686 shims; x86_64 service on each platform. Only the shim depends on byondapi.
- No subagents. Preserve unrelated work. No commits or production operations without the applicable authorization.
- No atmosphere coefficient, FDM iteration-count, 0.5-second nominal step, or critical-event-order change.
- Fixed-size shim transport and job metadata; authoritative state, scratch, and event outbox stay in `dogmosd`.
- Generated bindings and manifests are regenerated only with maintained tools.
- Mid-round service death, transport timeout, or identity corruption remains fatal; ordinary scheduling yield is not a transport error.

## 1. Bound DM preparation

### Machinery prefetch

Keep the existing processing order, including its reverse traversal of `currentrun`. Prefetch only the next 32 processing entries, lowering that number when fewer remain. Collect their component mixtures and turf mixtures under the existing snapshot limits; the collector itself must resume if gathering would exceed its work budget. Mark a chunk prefetched only after successful validation. Recheck the MC budget after prefetch and before processing its first machine.

Retain only a cursor, the current bounded collection, and the existing run list. Deleted entries are skipped without replaying earlier machines. A mutation continues to invalidate its affected cached snapshot; prefetch does not grant permission to use stale values. This work does not reduce machinery cadence or move machinery policy into Rust.

### Frontier journal

Route active-set membership changes through explicit helpers while retaining their original side effects and ordering. Journal the previously acknowledged full handle and the desired current membership. A removal followed by re-addition must remove the old service position and append the new one even if the handle is unchanged; coalescing to a simple set difference would change traversal order.

The journal holds at most 512 distinct pending entries. Overflow sets `needs_rescan` and stops adding entries; it never drops the requirement to reconcile. A bounded full reconciliation cursor is used at startup, overflow, and MC recovery. Increment a DM membership revision on every routed change. If a yielded reconciliation sees a revision change, restart its unpublished candidate at the next allowed frontier boundary; preserve the old committed identity set until each acknowledged transaction is applied.

Implementation clarification from the writer audit: `active_turfs` is the canonical desired order. A generation replacement of an active member removes its old list position and appends the replacement, without repeating activation or excited-group side effects. This makes both the journal and overflow rescan reconstruct the specified replacement order without retaining an unbounded event history or another permanent membership mirror. The already captured maintenance/visual snapshot remains the current cycle's snapshot. Existing list removal remains linear; the optimization claim concerns frontier discovery and publication, not all membership mutations. Rescan preparation and upload are bounded; temporary candidate/retired maps exist only through reconciliation and are drained in bounded slices.

An active native stage retains the existing topology/frontier fence. Do not flush the journal from a destructor or signal by sleeping. At a safe boundary, transmit ordered removals and additions using the existing protocol, updating acknowledged handles only from accepted replies. Keep a bounded shadow-comparison diagnostic during qualification. Production avoids a permanent second full-world membership mirror.

## 2. One service owner, two execution phases

The service actor exclusively owns `ServiceState` and `DogmosWorld`. A transport worker owns frame I/O and feeds one bounded request slot to the actor; it never accesses the world. The actor alternates control requests and native preparation quanta. This avoids holding a world lock while another thread waits for DM or mutates the same state.

```mermaid
sequenceDiagram
    participant DM as SSair / other DM consumers
    participant IO as Bounded transport
    participant S as Service world owner
    DM->>IO: StageJobSubmit
    IO->>S: Validate and admit one job
    S-->>DM: Accepted(job)
    Note over DM: SSair pauses; other subsystems run
    loop Until next publication unit is prepared
        S->>S: Bounded native preparation
        DM->>IO: Immediate gas read or write
        IO->>S: Execute against committed state
        S-->>DM: Ordered result
    end
    DM->>S: StageJobPoll
    S-->>DM: Ready(publication token)
    DM->>S: StageJobCommit(token)
    S-->>DM: Receipt, counts, event availability
    Note over DM: Invalidate cache before yielding; budget callbacks
```

At most one stage job exists per world. At most one completed receipt is retained for retry/recovery. There is no queue of future atmosphere ticks. Process pending commands FIFO, with at most eight ordinary commands before giving an admitted job one quantum; after each quantum check ingress again. Shutdown is honored at the next safe boundary. Park while idle or awaiting a commit; do not spin on a ready job.

The initial quantum is 1,000 microseconds with at most 256 work items. The core checks a distinct scheduling predicate between bounded work units. Exhaustion returns pending with scratch intact. The existing cancellation predicate remains independent and still discards unpublished work on fatal cancellation. Measure the largest uninterruptible unit; split expensive validation, reservation, clearing, and scans where needed. There is no hard wall-time guarantee until these paths and OS scheduling have been measured.

The short Submit frame deadline covers admission only; it must not expire the admitted job after the request has already completed. Quantum time is likewise not a job lifetime. Retain integrity/transport deadlines and reaction-continuation deadlines, but represent ordinary job age as progress telemetry. An incomplete job that grows older under load fails performance qualification rather than being silently completed, dropped, or advanced with a larger physics timestep.

## 3. Publication and consistency

Autonomous preparation MUST NOT publish gas values or enqueue gameplay callbacks. Otherwise DM caches could remain valid according to DM's epoch while their service values changed invisibly. Polling reports readiness but also does not publish.

`StageJobCommit` is the linearization point. It validates job, stage, frontier, topology, generations, and the complete read set; then publishes the prepared values and their complete event batch atomically. DM validates the receipt and invalidates its snapshot epoch before any sleep or callback dispatch. The FFI worker never calls DM, and a session lock is never held across an MC pause.

Publication units preserve existing semantics:

| Stage | Publication unit |
| --- | --- |
| Diffusion | Complete diffusion stage |
| Heat | Complete heat stage |
| Reactions | Existing complete reaction-stage transaction, including continuation/event admission |
| Equalization and excited groups | One disconnected component; earlier committed components survive later cancellation |

Core preparation must expose the existing unit boundary before the current commit call, not change the arithmetic or split an atomic component into visible fragments. After a component commit, the job prepares its next component. Return cumulative committed counts plus a monotonic unit token; DM applies only the difference since its last receipt so repeated polls cannot double-count work/events.

Immediate reads see the latest committed state. Immediate writes execute in the actor's serialized command order. A write to an input used by pending preparation invalidates that publication and produces `Retrying`, retaining earlier committed components. Rebuild only the unpublished unit. Reads must be tracked even when a record is not ultimately written, including immutable boundary inputs. Existing versioned writes alone are insufficient proof of read-set validation.

Topology and mixture-lifecycle operations retain the current pending-stage restrictions. Do not allow them concurrently merely because the transport is asynchronous. DM queues those operations using its existing ownership/fence rules. Mutable gas commands permitted today remain permitted and participate in conflict validation.

Critical events and DM reaction continuations retain their existing sequence, capacity, ownership, and deadline rules. A commit that cannot admit its complete event batch changes neither gas nor event state. Required callback drains occur at their existing phase boundaries; there are no trigger-only visual events. Do not complete a cycle until its required callbacks and DM work finish.

## 4. Protocol and API proposal

Baseline protocol is 14. These additions require the next protocol version and a regenerated paired bundle; recheck numbering when integrating other work. Proposed unused operation IDs at the anchor are 49-52. Encoding is explicit little-endian; reserved fields must be zero.

| Operation | Request | Meaning |
| --- | --- | --- |
| 49 `StageJobSubmit` | stage u16, flags u16=0, work cap u32, frontier epoch u64, stage epoch u64, seconds f64, quantum us u32, reserved u32=0 (40 bytes) | Admit only when no live job; allocate nonzero monotonic job u64 |
| 50 `StageJobPoll` | job u64 (8 bytes) | Read status without advancing or publishing work |
| 51 `StageJobCommit` | job u64, unit token u64 (16 bytes) | Validate and publish exactly that prepared unit |
| 52 `StageJobCancel` | job u64, reason u32=0, reserved u32=0 (16 bytes) | Discard unpublished work; preserve previously committed units |

All requests retain the existing authenticated frame world generation/nonce and request ID. Bounds: work cap 1-4096, quantum 1-1000 us, finite positive seconds matching the job for its lifetime. The game requests the existing configured seconds, not elapsed job age. Reject stale IDs, mismatched stages/epochs, nonzero reserved fields, invalid lengths, and exhausted IDs before mutation.

The common 64-byte response contains job u64; status u16; stage u16; reserved u32; unit token u64; cumulative executed work u32; remaining estimate u32; cumulative committed units u64; cumulative equalize/group/heat seed counts and callback count (four u32); detail u32; reserved u32. Counts saturate rather than wrap. Status values: Accepted=1, Running=2, Ready=3, Retrying=4, Done=5, Cancelled=6. Existing typed frame errors cover Busy, invalid identity, allocation, and event backpressure. Polls and repeated commits do not enqueue events. Keep the previous unit's receipt until a subsequent unit commits; a repeated commit for it returns the same receipt, an older token is stale. A new job retires the terminal receipt from the previous job.

Proposed DM internal bindings: `dogmos_stage_job_submit(fields)`, `dogmos_stage_job_poll(job_words)`, `dogmos_stage_job_commit(job_and_unit_words)`, and `dogmos_stage_job_cancel(job_words)`. Encode each u64 as four 16-bit DM numbers, using existing helpers. Existing public mixture proc paths remain unchanged. Keep `SimulationStage` as the synchronous compatibility route through the same core preparation and immediate-commit logic; reject mixed synchronous/job execution while a job is live.

## 5. MC integration and bounded overload

`dogmos_run_stage` becomes a state machine for the optional asynchronous mode. Submit once, retain job/stage/frontier/unit identity, and pause. Poll at most once per eligible MC tick, never busy-loop. A completed I/O result or ready status does not authorize continuing with the previous fire's budget: recompute `Master.current_ticklimit - TICK_USAGE` before every poll, commit, and callback chunk.

The initial submit/poll/commit calls remain short synchronous control round trips. Thus the first release removes the long simulation wait but is not a zero-wait FFI design. An OS-stalled service can still reach the bounded transport failure path. If measured control round trips dominate afterward, add a separately qualified async binding/transport completion API; never hide this limitation in benchmark labels.

Use `Submitted`, `Preparing`, `Ready`, `Committing`, `Draining`, and `Idle` DM states, with `Failed` terminal for the production latch. Recover them with the existing SSair MC recovery state. A replayed receipt cannot run callbacks twice; preserve event sequence and callback cursor. Shutdown cancels unpublished work, closes the session with existing bounded ownership cleanup, and never launches an empty replacement service.

Keep cycle age, publication age, conflicts, and retries visible. Under sustained conflict, there is still only one job and its reusable scratch; no retry queue accumulates. Qualification must prove progress with repeated writes and topology edits. If that fails, the asynchronous mode is not enabled. Lowering SSair priority, skipping simulation cycles, changing `share_max_steps`, or increasing simulated seconds to catch up is outside this design.

## 6. File ownership and rollout

Create focused N modules `crates/dogmos-core/src/stage_job.rs`, `crates/dogmos-server/src/jobs.rs`, `crates/dogmos-server/src/transport.rs`, and `crates/dogmos-protocol/src/stage_job.rs`; keep numerical kernels in their current modules. Extract only code needed by these boundaries, without an unrelated rewrite of `world.rs` or the server dispatcher.

G changes concentrate in `air.dm` and `service_backend.dm`, with all active-set writers routed explicitly, and tests in `service_backend_test.dm`. Use the game configuration system for a boot-selected `dogmos_async_stages` option defaulting off during qualification. Enabling it requires a matching negotiated protocol. Never switch modes mid-cycle. The [runtime work plan](../plans/2026-09-14-atmosphere-runtime-isolation.md) maps each requirement to tests and delivery gates.

Alternatives rejected for the first release: a free-running service clock (changes cadence/ordering), a world lock held by a long worker (moves stalls to reads), another full gas mirror inside DD (address-space cost), and a global conversion of gas getters to asynchronous procs (breaks caller contracts).
