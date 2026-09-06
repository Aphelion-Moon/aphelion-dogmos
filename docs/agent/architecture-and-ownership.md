# Architecture and ownership

## Legacy and service implementations

The root `dogmos` package still builds the legacy in-process `cdylib`. When that DLL is used,
its arenas, graphs, workers, scratch buffers, registries and callback queues share DreamDaemon's
32-bit address space. It is the migration source, not the shim selected by the paired release
workflow.

The [release workflow](../../.github/workflows/build.yml) builds `dogmos-byond` for i686 and
`dogmos-server` for x86_64 on Windows and Linux. The shim converts BYOND values, registers
metadata and identity, submits typed requests, validates responses and dispatches gameplay events.
DM owns datum/turf identity, subsystem cadence, machinery, gameplay effects, administration and UI.

The service constructs a BYOND-free `dogmos_core::world::DogmosWorld`. Core owns the
generation-checked mixture slots, immutable numeric gas-metadata registry, adjacency map, validated
diffusion graph, reusable input/output buffers, snapshots, and atomic stage commit. Core also owns an
immutable reaction registry with fixed-width IDs, validated gas requirements, and a compact numeric
priority order. Its implemented stages include diffusion, equalization, excited groups, turf heat
and reactions, with generation-checked reaction continuations. `dogmos-server` translates
fixed-width protocol values and owns transport and callback delivery state; it does not own a
duplicate mixture arena. Core simulation state and resumable work stay in the 64-bit service.

These are source ownership facts, not a claim of complete gameplay parity or runtime qualification.
Use the [verification matrix](verification.md) for each candidate artifact pair.

## Ownership boundary

| Component | Owns | Must not own |
| --- | --- | --- |
| `dogmos-byond` | BYOND value conversion, connection lifecycle, bounded IPC windows, response validation, main-thread event dispatch | Growing world state, numerical arenas, DM policy |
| `dogmos-protocol` | Fixed-width handles, versioned messages, codecs, stable error/event kinds | `byondapi`, pointers, allocator-owned wire fields, world logic |
| `dogmos-core` | Gas/mixture state, reactions, graphs, numerical kernels, typed commands/events, world generation | `ByondValue`, DM refs, transport, process globals |
| `dogmos-server` / `dogmosd` | Authoritative 64-bit `DogmosWorld`, scheduling, workers, bounded event outbox, health and metrics | BYOND references, player/admin policy, automatic empty-state restart |

Only `dogmos-byond` may depend on `byondapi`. Public protocol/core types use fixed-width integers and explicit generations rather than `usize` or raw slots. A mixture or turf handle is valid only for its world generation; slot reuse must not make a stale request target new state.

`tools/check_dependency_direction.py` enforces that `dogmos-core` and `dogmos-protocol` do not
depend on `byondapi`, contain DM-call identifiers, or expose pointer-sized public numeric state
fields such as `usize`. The CI tooling-test suite runs this guard while extraction is in progress.

DM remains authoritative for datum identity, public proc compatibility, subsystem cadence, machinery decisions, atom movement, gameplay consequences, logs, rights, and TGUI. `dogmosd` returns typed facts/events; the shim validates and dispatches them but does not invent game policy.

Move code by responsibility, not filename. Extract pure math before moving orchestration. Keep an adapter only while differential transcript tests prove old and new paths equivalent. Do not duplicate a growing arena in the shim as a fallback.
