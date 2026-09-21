# Dogmos gameplay event contract

Dogmos computation may run in `dogmosd`, but DreamMaker remains the only authority for gameplay
effects. The service reports typed facts; DM validates their targets and applies SS13 policy on the
main thread. This contract replaces direct Rust-to-DM calls and captured callback closures. It does
not authorize a second gameplay queue or a second gas store in DreamMaker.

## Memory and ownership rules

- `dogmosd` owns the bounded event queue, queue history, sequence counter, and high-water metrics.
- The 32-bit shim owns one fixed 64 KiB response buffer. It must not allocate a BYOND list per queued
  event or retain decoded events between drains.
- DM drains a bounded batch into the shim buffer, validates one record, applies it immediately, and
  then reuses the same decoding state for the next record.
- A handle is an opaque slot plus generation. Handle meaning is determined by the event field: a
  mixture handle addresses service state, while a gameplay-target handle addresses the DM registry.
  Numeric equality across registries has no meaning.
- Rust never retains a DM ref. DM never infers a target from an unscoped `locate(ref)`.
- Queue saturation rejects the complete simulation-stage result before its state commit. Critical
  gameplay events are never silently dropped, overwritten, or partially enqueued.

## Fixed event envelope

Protocol v2's 40-byte diagnostic event has only one scalar and cannot represent the callbacks in the
current source. Protocol v3 introduced the 64-byte envelope retained by the current protocol.
These historical version references do not select the active ABI or protocol; those come from
the generated `code/__DEFINES/dogmos_contract.dm` and `dogmos.lock.json`.
Meridian-Rift integration must regenerate and verify the paired contract before loading artifacts:

| Offset | Size | Field | Rule |
| ---: | ---: | --- | --- |
| 0 | 8 | `sequence` | Strictly increasing for the world generation; gaps or reordering fail closed. |
| 8 | 2 | `kind` | Closed, protocol-versioned event enum. |
| 10 | 2 | `flags` | Closed per-kind flag mask; unknown bits are errors. |
| 12 | 8 | `subject` | Slot and generation for the authoritative mixture or source turf. |
| 20 | 8 | `target` | Slot and generation for the DM gameplay target, or zero when unused. |
| 28 | 32 | `values` | Four finite little-endian `f64` values with kind-specific units. |
| 60 | 4 | `aux` | Closed kind-specific enum or bit field, never an untyped pointer or ref. |

A 64 KiB shim buffer holds the 24-byte batch header and at most 1,023 complete records. The buffer
size remains fixed even if service queue capacity grows. The event is deliberately self-contained:
DM does not retain a partial group while waiting for a later drain.

## Required event inventory

| Event | Subject and target | Values and auxiliary data | DM-owned effect and stale-target policy |
| --- | --- | --- | --- |
| Reaction finished | Subject: mixture. Target: holder atom, turf, or pipeline registry entry. | `aux`: plasma, hydrogen, tritium, or freon. Values are defined below. | Populate the type-path-keyed `reaction_results`, resolve any turf or pipeline member, then apply hotspot, radiation, or item-spawn policy. A stale mixture in the general callback queue is discarded and counted because its completed reaction no longer has a live DM owner. A stale holder suppresses only holder-dependent effects and records a metric; reaction bookkeeping still applies if the mixture is current. |
| Pressure difference | Subject and target: the two current turf registry entries. | `value[0]`: pressure difference in kPa. Other values and `aux` are zero. | Call `consider_pressure_difference()` in the encoded direction of pressure flow. If either generation is stale, skip the pair and record it; never retarget a recycled turf ID. |
| Decompression floor rip | Subject: affected turf. Target: zero. | `value[0]`: moles lost. | Call `handle_decompression_floor_rip()`. DM owns resistance checks, Kennel records and pins, feedback, sound, and `ScrapeAway()`. A stale target is skipped and counted because applying it to a replacement turf would mutate the map incorrectly. |
| Firelock consideration | Subject and target: adjacent turfs. | Values and `aux` are zero. | Call `consider_firelocks()` after both generations validate. A stale pair is skipped and counted. |
| Turf destruction request | Subject: affected turf. Target: zero. | `value[0]`: triggering temperature in K when relevant. `aux`: closed destruction reason. | DM sets or handles `to_be_destroyed` using current turf policy. A stale target is skipped and counted. |
| Visual state changed | Subject: affected turf. Target: zero. | Must carry a complete, bounded visual-state description or a versioned service snapshot token; a trigger alone is insufficient after gas state leaves DM. | DM owns overlays and planes. This event is blocked until the visual payload and maximum size are specified and verified against the gas overlay consumer. Do not port the current trigger-only callback. |
| Diagnostic | Handles and values are fixture-defined. | `aux` is zero. | Test and telemetry only. It must not share a gameplay dispatch path that can mutate world state. |

The first production migration must inventory any additional direct BYOND calls in the Rust source
and add them here before extending the enum. No generic "call proc" event is permitted.

### Reaction payloads

Each reaction is one event so its bookkeeping and dependent gameplay effects are applied together:

| Reaction | `value[0]` | `value[1]` | `value[2]` | `value[3]` |
| --- | --- | --- | --- | --- |
| Plasma | fire amount in mol | post-reaction temperature in K | zero | zero |
| Hydrogen | burned fuel in mol | post-reaction temperature in K | zero | zero |
| Tritium | burned fuel in mol | released energy in J | mixture volume in L | post-reaction temperature in K |
| Freon | reaction result amount in mol | pre-reaction temperature in K | post-reaction temperature in K | zero |

DM retains the existing probability rolls and gameplay constants for tritium radiation and hot-ice
creation. Moving those decisions to Rust would change random ordering and gameplay authority.

## Ordering and commit contract

The service builds simulation output and its complete event vector in scratch storage. It validates
capacity, deadlines, finite values, handles, and event count before committing either state. On
success, state and all events become visible together. On failure, neither does.

The shim validates the batch header before dispatch. It requires contiguous sequence numbers within
and across drains, a known kind, allowed flags, finite numeric values, and generation-valid handles.
A malformed record, sequence gap, deadline, or service disconnect stops the drain, marks the service
unhealthy, and enters the lifecycle recovery path. Recovery increments the world generation and
invalidates old events before resuming simulation.

Apply events in encoded order. Do not coalesce pressure, floor-rip, firelock, reaction, or destruction
events in DM unless a separate equivalence test proves the ordering change harmless.

## Verification gates

Before replacing a direct callback family:

1. Add protocol round-trip, unknown-kind, unknown-flag, non-finite-value, and exact-layout tests for
   its event.
2. Prove all-or-nothing state plus event commit under capacity rejection and deadline expiry.
3. Add a DM unit test for the visible effect and stale-generation behavior.
4. Run the focused Rust tests, i686 workspace tests, feature matrix, cross-bitness IPC test,
   DreamMaker compile, and a DreamDaemon boot probe.
5. Compare repeated representative playtests. Report DreamDaemon private bytes and working set
   separately from `dogmosd`; only DreamDaemon memory is the footprint acceptance target.

The visual event remains a design blocker, not an implementation TODO that may be guessed around.
