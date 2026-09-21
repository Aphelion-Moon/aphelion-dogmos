# Atmospherics

This document describes the current Meridian Rift atmospheric pipeline. It is intentionally a
system overview rather than a copy of implementation comments. The authoritative behavior is in
the DM and Rust sources linked below.

## Ownership

Dogmos owns gas storage and the hot environmental simulation in Rust. In the current audited build,
that Rust state lives inside the 32-bit `dogmos.dll` loaded by DreamDaemon; a DLL allocation is still
a DreamDaemon allocation. The target architecture moves growing state and compute into the separate
64-bit `dogmosd` service while retaining a fixed-size BYOND adapter in-process. DM retains the public
`/datum/gas_mixture` API, reactions, atmospheric machinery, pipeline machinery, player feedback,
and subsystem scheduling. The two sides share registered gas and turf handles through the bindings
in `code/__DEFINES/dogmos_bindings.dm`.

The Rust crate is in `aphelion-dogmos/`. The DM integration lives primarily in:

- `code/controllers/subsystem/air.dm` — scheduling, compatibility lists, machinery, effects, and
  the Dogmos Kennel telemetry surface.
- `code/modules/atmospherics/gasmixtures/` — the DM gas-mixture API and immutable source types.
- `code/modules/atmospherics/reactions.dm` — reaction definitions and DM-side effects.
- `modular_aphelion/modules/dogmos/` and its master-file overrides — initialization and turf hooks.
- `aphelion-dogmos/src/gas/` — gas data, mixture operations, reactions, and the FFI arena.
- `aphelion-dogmos/src/turfs/` — FDM flow, Katmos pressure equalization, and TurfHeat conduction.

Do not add a second gas store or bypass the mixture API. A gas mixture's
`_extools_pointer_gasmixture` is an internal Dogmos handle, not application state.

The fork-owned edit exception is limited to `code/modules/atmospherics/gasmixtures/**`,
`code/modules/atmospherics/environmental/**`, and the generated `code/__DEFINES/dogmos_bindings.dm`
and `code/__DEFINES/dogmos_contract.dm` files. It does not exempt atmos machinery, unrelated gameplay,
subsystem, turf, UI, build, or deployment files. Use `APHELION EDIT`
for new Meridian-owned core changes outside the exception and preserve inherited `NOVA EDIT`.

## One air-subsystem cycle

`SSair` runs every `0.5 SECONDS` and yields between stages when the master-controller budget is
exhausted. The normal order is:

1. Rebuild adjacent turf state and pipenets when topology changed.
2. Process pipenets and atmospheric machinery.
3. Walk a bounded batch of active turfs for DM maintenance and run Dogmos FDM processing for
   environmental gas flow.
4. Process hotspots and their visual or gameplay effects.
5. Run Dogmos excited-group maintenance for low-pressure regions.
6. Apply Dogmos Katmos pressure equalization and drain queued high-pressure movement callbacks.
7. Start the asynchronous Dogmos TurfHeat conduction pass for blocked paths.
8. Process atoms registered for atmospheric exposure.

The order is significant. Rebuilds must precede processing, hotspots run before group cleanup, and
pressure movement is applied after the flow pass has produced its deltas. The conduction worker is
started from the cycle but completes through bounded callbacks, so its work is not measured as a
zero-cost synchronous DM proc.

## Gas mixtures

Rust currently stores mixtures in an in-process lock-protected arena. The service migration moves the
arena out of DreamDaemon without changing the public DM procs. DM datums keep an opaque,
generation-checked handle and expose operations
such as `get_moles`, `set_moles`, `adjust_moles`, `remove`, `copy_from`, `share`, `react`, and
`return_pressure`. Use those procs instead of writing implementation state directly.

Gas metadata is registered once by `SSdogmos` and maps DM gas typepaths to stable string IDs. Hot
paths use the registered IDs; they must not parse gas strings or reconstruct metadata per tick.

The mixture math uses the ideal-gas relationship for pressure and tracks thermal energy through
temperature and heat capacity. Molar transfers are quantized at the DM compatibility boundary so
Rust and DM callers observe the same conservation behavior. Empty mixtures keep a safe temperature
and heat capacity instead of producing `NaN` values.

Immutable mixtures represent infinite sources such as space and planetary atmosphere. They may be
read or copied, but merge, reaction, moles, temperature, heat-capacity, and transfer operations must
not mutate them. New immutable subtypes should defer finalization until their initial gas data has
been loaded; see `immutable_mixtures.dm`.

The legacy `archive()` proc remains as a compatibility no-op because Dogmos snapshots the state it
needs during turf processing. `share()` remains for non-turf equipment and compatibility callers;
turf-to-turf flow uses the Rust graph.

## Environmental flow

Dogmos FDM processes registered turf mixtures in bounded parallel steps. Each step calculates gas
movement from the current graph, records low- and high-pressure regions, and queues only the DM
callbacks needed for effects. `post_process()` applies reaction and overlay bookkeeping after the
flow step. `planet_share_ratio` controls the bounded exchange with planetary source mixtures.

The DM `active_turfs` list is still used for activation, topology maintenance, exposure checks, and
compatibility bookkeeping. It is not a second implementation of turf-to-turf gas flow. The legacy
walk is deliberately bounded by `ACTIVE_TURFS_WALK_BATCH_SIZE`; avoid turning it back into a full
round-wide scan.

Pressure callbacks and Rust-to-DM event callbacks are delivered in bounded batches. Callback code
must remain cheap, validate that its target still exists, and avoid retaining hard references to
short-lived atoms.

## Reactions and effects

Reactions are initialized by `SSdogmos` and exposed to Rust in a stable, priority-ordered table.
Reaction calculations run in Dogmos, while player-visible consequences remain DM-side: hotspots,
fire groups, turf overlays, decompression feedback, explosions, and machine responses. A reaction
that changes gameplay state must use the existing DM setters, signals, logging, and feedback helpers.
The DM `react()` wrapper also enforces Hypernoblium oppression; Dogmos' direct reaction hook mirrors
that cheap gate so Rust-driven processing cannot bypass it.

Atmospheric machinery and pipenets continue to use their normal DM lifecycle. If a machine leaves
the processing list, remove it through the subsystem helper. If a reaction or callback stores an
atom reference, use the established deletion or weak-reference patterns.

## Heat conduction

Dogmos maintains a `TurfHeat` graph for heat transfer through walls, windows, doors, and other
blocked atmospheric paths. The graph is refreshed when turf topology or conductivity changes.
`process_turf_heat()` schedules a bounded worker pass; completion updates DM turf temperatures and
cleans stale graph entries through guarded callbacks.

Relevant values are:

- `thermal_conductivity` — how readily heat enters a turf.
- `heat_capacity` — the thermal mass of a turf and its melt threshold input.
- `atmos_superconductivity` — directions that block gas flow but may still conduct heat.

Do not restore a DM neighbor walk for this behavior without measuring the effect on the worker and
graph lifecycle. The Rust graph is the authority for turf-to-turf heat conduction.

## Performance and correctness rules

- Keep work frame-independent: scale per-second quantities by `seconds_per_tick` in Rust.
- Use the remaining subsystem budget and the existing bounded queues; do not create timers or
  callbacks for work that can be completed in the current stage.
- Keep cheap validity checks before FFI, list scans, and lock acquisition.
- Acquire multiple mixture locks in a stable arena-slot order.
- Treat FFI handles, weak references, callback targets, and queued atoms as invalid until checked.
- Keep immutable source behavior explicit in every mutating mixture operation.
- Prefer one pass over a collection and reuse batch buffers in hot paths.

When changing a formula, state the units and conservation invariant in the test or nearby
technical documentation. Add a focused in-game unit test for DM-visible contracts and a Rust test
for pure Rust math or graph behavior.

## Debugging

The Atmospherics entry in the MC tab reports the counts and rolling costs for each stage. Dogmos
also exposes the Kennel UI for recent reactions, fire groups, breaches, pressure events, overlays,
and machine costs. Kennel history is bounded and event targets are weakly retained; a missing target
is expected after deletion and should be displayed as an unavailable track action.

For a controlled verification pass, use the project's normal DreamMaker, focused unit-test, and
Rust test workflows. The production gate remains a clean DreamMaker compile; a live server boot and
focused tests are required before claiming behavioral verification.
