# Dogmos

## In very simple terms

Space Station 13 has pretend air. That air moves around, gets hot, catches fire, and leaks into space.

**Dogmos does the maths for that air.**

- A window breaks: Dogmos works out how the air escapes.
- A fire starts: Dogmos works out which gases burn and how much heat they make.
- Hot air touches a cold wall: Dogmos works out how their temperatures change.

The game still draws everything, moves people, and decides what damage they take.
Dogmos supplies the air and heat calculations.
It is a helper for the game server, and requires changes be made to the game server to function.

## Overview

Dogmos is Rust-based atmospherics for [Meridian Rift](https://github.com/Aphelion-Moon/Meridian-Rift), a Space Station 13 downstream.
It is a maintained downstream of [Auxmos](https://github.com/Putnam3145/auxmos), using [byondapi](https://github.com/spacestation13/byondapi-rs) to communicate with BYOND.

The active implementation is the root `dogmos` package under [`src/`](src/).
Its gas mixtures, graphs, allocations and workers live inside 32-bit DreamDaemon.
DM owns identity, scheduling and gameplay; native callbacks run on the main thread.
Generated bindings are produced by the [source-bound builder](tools/build_in_process.py).

The former split-process shim/service implementation is preserved on
[`archived-dogmos-64bit`](https://github.com/Aphelion-Moon/aphelion-dogmos/tree/archived-dogmos-64bit).
It is outside the active workspace and build. The checked-in
[build workflow](.github/workflows/build.yml) packages the in-process engine for Windows and Linux.
The historical service inventory below describes that archived branch, not the active engine.

## Feature list

The inventory below describes implemented capabilities. The in-process engine's
optional features are listed separately, and the service-specific section does
not imply that those capabilities are enabled in every Meridian Rift deployment.

### Gas mixtures and atmosphere data

The [in-process gas API](src/lib.rs) and [mixture implementation](src/gas/mixture.rs)
provide:

- Runtime registration of gas IDs, names, specific heats, visibility thresholds,
  flags, and fuel/oxidizer properties, including fire products, enthalpy, and radiation.
- Per-gas mole counts, total moles, temperature, volume, pressure, heat capacity,
  partial heat capacity, and thermal energy.
- Setting and adjusting individual gases, temperature-aware additions, and
  multi-gas adjustments.
- Copying, clearing, adding, subtracting, multiplying, and dividing mixtures.
- Merging mixtures; removing or transferring a fixed amount or fraction; and
  selecting gases by explicit gas lists or metadata flags.
- Scrubbing selected gases into another mixture.
- Volume-aware equalization against a combined mixture or across a list of mixtures.
- Heat exchange between two gas mixtures or between gas and a non-gas heat reservoir.
- Mixture comparison to decide whether composition or temperature differs enough
  to require more processing.
- Fuel-amount and oxidation-power queries.
- Immutable mixtures for fixed atmosphere reservoirs.
- Parsing gas strings such as `o2=2500;plasma=5000;TEMP=370`.
- Reusable, lock-protected mixture storage, inline storage for small mixtures,
  cached heat capacity, and active/allocated mixture counts.

### Tile atmosphere, equalization, and breaches

The [turf engine](src/turfs.rs) and its [processing modules](src/turfs/) provide:

- Registered gas-flow graphs with adjacency updates, simulation-enable flags, and
  horizontal and vertical neighbors.
- Parallel, snapshot-based finite-difference diffusion of gas and heat between tiles.
- FDM-only processing or Katmos zone equalization, selected through the game-side
  processing configuration.
- Connected-zone gas redistribution and pressure-difference reports for the game.
- Excited-group processing that averages the atmosphere of connected groups.
- Planetary reference atmospheres and relaxation toward those reference mixtures.
- Immutable space boundaries used to detect openings into vacuum.
- Connected-room slow decompression, limited to one quarter of the room's average
  moles per visited turf regardless of breach frontage.
- Firelock-consideration callbacks and pressure/direction information for
  game-owned movement and decompression effects.
- Floor-rip notifications for the gas layer bordering space, based on actual gas loss.
- Caller-supplied processing budgets and stage work/cost counters.

The in-process engine scans registered graph nodes during its processing passes.
The persistent active-frontier and resumable-stage interfaces described below
belong to the archived service implementation.

### Heat, superconductivity, and space cooling

The [thermal engine](src/turfs/superconduct.rs) provides:

- A separate heat graph for turf temperature, conductivity, heat capacity, and
  horizontal/vertical heat connections.
- Gas-to-turf exchange and turf-to-turf conduction, including blocked heat directions.
- An owned heat worker, reusable numerical scratch buffers, and elapsed-time
  conduction through the shared core solver.
- Space cooling using blackbody radiation or the simpler vacuum-cooling mode
  selected by the game's radiation setting.
- A cosmic-background temperature floor.
- Generation-checked notifications when a turf reaches its destruction condition;
  actual map changes remain the game's responsibility.
- Heat-node, registration, processing-work, and contention diagnostics.

### Reactions and fire

The default [`aphelion_reactions` backend](src/reaction/aphelion.rs) implements:

- Plasma combustion, including oxygen-rich tritium production.
- Hydrogen combustion.
- Tritium combustion.
- The freon/oxygen cooling reaction.

The [reaction registry](src/reaction.rs) supports gas requirements, temperature
bounds, minimum thermal energy, fire-reagent requirements, and execution priority.
The in-process engine also supports hypernoblium reaction suppression, reaction
stop flags, and execution of registered DM reactions that do not have a native
implementation.

Native reactions perform their numerical work in Rust and call the appropriate
DM completion hooks after releasing mixture locks. The game retains responsibility
for reaction signals, bookkeeping, radiation effects, damage, and other gameplay.
Optional per-reaction timing reports feed the game's Kennel diagnostics.

Alternative, nondefault reaction backends are available:

- [`citadel_reactions`](src/reaction/citadel.rs): plasma, tritium, fusion, and
  metadata-driven generic fire.
- [`yogs_reactions`](src/reaction/yogs.rs): the implemented native plasma reaction.

These backends use different formulas and products. They are mutually exclusive,
not interchangeable balance presets. Native fire reactions are not a separate
Rust implementation of every game-side fire-group or hotspot system.

### Game integration, callbacks, and lifecycle

- Generated BYOND bindings and DM compatibility wrappers rather than a replacement
  for the game's entire atmosphere subsystem.
- Game-supplied gas/turf registration and scheduling; machinery policy, object
  movement, administration, logging, and UI remain in DM.
- Main-thread delivery of reaction, pressure, firelock, and destruction work.
- In-process gas visibility tracking and overlay updates, including multiz render
  offsets and avoidance of unchanged visual updates.
- Turf-generation checks that discard callbacks for replaced registrations.
- Callback queue depth, high-water, and enqueue-failure diagnostics.
- Panic containment at exported native boundaries, panic counters, and worker
  panic reporting to `dogmos_panic.log`.
- Explicit shutdown of native workers and arenas, with support for reinitializing
  state when a loaded library is reused by another world.

### Diagnostics, benchmarks, and verification tools

- JSON telemetry for operation counts, errors, payload sizes, mixture storage,
  gas/heat graphs, callbacks, and allocator/process diagnostics.
- Opt-in bounded operation transcripts, latency histograms, and reaction-cost
  profiling, plus optional Tracy tracing.
- Archived service telemetry for callback/continuation queues, timeouts, protocol failures,
  active stages/frontiers, topology, and reusable-workset estimates.
- DreamDaemon process measurements, and archived service process measurements, with
  availability flags for platform-dependent counters.
- Windows exact-PID process sampling and workload-identity/budget comparison tools
  under [`tools/perf/`](tools/perf/).
- Synthetic core allocation, chunk-latency, and continuation-lifecycle probes in
  [`dogmos-perf`](crates/dogmos-perf/), including optional Windows thread-cycle sampling.
- Archived local IPC benchmarks, cross-bitness probes, callback-pressure tests, and
  service-process isolation/timeout checks.
- Workload specifications for boot registration, idle stations, canister and corridor
  breaches, reaction storms, throttled callbacks, dense machinery, and sparse/dense heat.
- Golden mixture transcripts, numerical-property tests, protocol/identity tests,
  publication-conflict tests, continuation tests, and generated-binding checks.
- Supported-feature checks, dependency-direction guards, and deterministic
  artifact generation/verification.

The workload preparation tool validates inputs and writes a run manifest; it does
not launch the game scenario. Synthetic benchmarks and checked-in tests are tools
for gathering evidence, not a claim that every integration has passed. See the
[performance guide](docs/performance/README.md) for procedures and recorded results.

## Build-time features

These flags apply to the **root in-process `dogmos` package**:

| Feature                     | Default              | Purpose                                                                                                      |
| --------------------------- | -------------------- | ------------------------------------------------------------------------------------------------------------ |
| `turf_processing`           | Yes                  | Registered-turf atmosphere processing.                                                                       |
| `katmos`                    | Yes                  | Zoned equalization and space decompression; enables `fastmos`.                                               |
| `fastmos`                   | Via `katmos`         | Enables the fastmos-related processing configuration and `turf_processing`; alone it does not enable Katmos. |
| `katmos_slow_decompression` | Yes                  | One-quarter room-average gas loss per visited turf; enables `fastmos`.                                       |
| `superconductivity`         | Yes                  | Thermal graph and turf heat processing; enables `turf_processing`.                                           |
| `aphelion_reactions`        | Yes                  | Meridian's four native reactions; enables `reaction_hooks`.                                                  |
| `reaction_hooks`            | Via reaction backend | Native reaction-hook support.                                                                                |
| `citadel_reactions`         | No                   | Alternative Citadel reaction implementation.                                                                 |
| `yogs_reactions`            | No                   | Alternative Yogs plasma reaction implementation.                                                             |
| `zas_hooks`                 | No                   | Ratio-based mixture sharing, including one-way sharing.                                                      |
| `tracy`                     | No                   | Tracy tracing; exposes a local profiling port.                                                               |

Do not use `--all-features`: enabling multiple reaction backends is rejected.
The supported combinations are listed in
[`tools/check_feature_matrix.py`](tools/check_feature_matrix.py); the PowerShell entry point remains a compatibility wrapper.

The archived `dogmos-byond` package also has an optional `diagnostic-bindings`
feature for IPC qualification exports. Root-package flags are not a service
configuration API.

## Building and integration

Use the exact native source snapshot paired with your Meridian Rift revision. A branch name
or commit alone does not describe uncommitted playtest repairs. Never mix bindings or
platform libraries from different source snapshots.

Use Rust `1.98.0`, locked dependencies, and the platform's i686 target. Build a new bundle:

```sh
# Linux: Python 3.10+, Git, rustup, g++-multilib, libclang and binutils are required.
python3 -B tools/build_in_process.py --target i686-unknown-linux-gnu --output target/linux-playtest
```

```powershell
# Windows: MSVC build tools and libclang must be available.
tools/build_in_process.ps1 -OutputDirectory target/windows-playtest
```

Install with the matching game checkout's `tools/dogmos/sync_in_process.py`, then run
`tools/dogmos/verify_contract.py verify-installed --root .`. The builder supplies the
library, debug symbols, generated bindings and exact source manifest. Never hand-edit
these artifacts. Windows loads `dogmos.dll`; Linux loads `libdogmos_in_process.so`.

See [the build contract](docs/agent/in-process.md) for complete platform prerequisites,
installation commands and glibc compatibility, and [verification gates](docs/agent/verification.md).
Native Linux support does not port the Windows RIFT controller. A successful native build
alone does not qualify loading, game initialization, gameplay or performance.

## Archived split-process service - Processing atmos outside of DD entirely

I've abandonded efforts on the external 64-bit worker. The current implementation
does technically work, however, gains are only seen in extreme atmospheric conditions.
If you want to, for whatever reason, perform genuine mass-scale atmos calcs (we're talking
tens of thousands to hundreds of thousands to a million plus atmospheric calcs per cycle)
then this is something to investigate. This variant has a lengthy initialization,
and slower atmospheric ticks, but it will save you 100's of MB on DD.exe by
passing quantized data out of the game environment while providing numerous additional
entry points for statistics and calculation tracking.

If you have anything under 20k active turfs normally, you do not need this.
If your CPU does not support AVX-512 or AVX-10, I do not recommend trying to use
this variant at all. There are next to zero functional gains for a typical SS13 environment
unless you want to do stuff like... Simulating real planetary atmos. Which I do not.

In the archived implementation, the
[shared core](crates/dogmos-core/src/) and [service](https://github.com/Aphelion-Moon/aphelion-dogmos/tree/archived-dogmos-64bit/crates/dogmos-server/src/)
implement:

- Authoritative mixture and turf state outside DreamDaemon, using generation-checked
  handles, mixture revisions, and validated gas/reaction metadata.
- A fixed 32-gas mixture representation, scalar queries, mixture mutations,
  compound transfers, heat exchange, and immutable-state handling.
- Single and batched snapshots, revision-checked state seeding, and staged
  begin/append/commit uploads for larger state batches.
- Pipenet reconciliation that validates and deduplicates mixture handles,
  redistributes gas by volume, and returns updated snapshots.
- Gas and heat topology updates, with validated reciprocal gas connections,
  no duplicate/self edges, up to six cardinal neighbors, and firelock edge metadata.
- Active-frontier replacement and incremental additions/removals, checked by
  generation and epoch.
- Chunked, resumable diffusion, equalization, excited-group, heat, and reaction
  stages, with work limits, progress cursors, cancellation, and conflict detection.
- Transactional publication of numerical results and their events. Equalization
  and excited groups commit per disconnected component, so cancelling later work
  does not undo already completed independent components.
- Native plasma, hydrogen, tritium, and freon reactions, plus continuations for
  reactions that must execute in DM.
- Single-use, deadline-bearing reaction continuations with scoped mixture changes,
  resume/cancel operations, and cleanup when their owners disappear.
- Typed reaction-finished, pressure-difference, floor-rip, firelock-consideration,
  turf-destruction, DM-reaction, and reaction-profiling events.
- Bounded callback queues and drains, transaction-isolated reaction events,
  sequence checks, and complete-batch rejection when callback capacity is exhausted.

The archived [shim](https://github.com/Aphelion-Moon/aphelion-dogmos/tree/archived-dogmos-64bit/crates/dogmos-byond/src/) and
[protocol](https://github.com/Aphelion-Moon/aphelion-dogmos/tree/archived-dogmos-64bit/crates/dogmos-protocol/src/) add:

- Explicit little-endian wire encoding, fixed-width handles, request IDs, world
  identity, payload validation, and typed error responses.
- Local socket communication, authenticated startup, single-client ownership,
  Windows current-user access restrictions, and Unix socket permissions.
- Service launch, health queries, PID/world-generation reporting, graceful shutdown,
  and bounded recent stderr diagnostics.
- A dedicated I/O worker for bounded post-connect requests; request timeouts poison
  the client, cancel pending transport work, and terminate the owned service.
- Windows kill-on-close process ownership.
- Source-revision and feature identity, executable SHA-256 checks by the launcher
  and service, and deterministic release manifests.

**Integration limits:** the shim exports coarse operations, not the root engine's
legacy gas-mixture proc inventory. DM must resolve and apply drained gameplay
events; there is no service visual-update event. Transport qualification operations
and optional benchmark bindings are diagnostics, not additional gameplay APIs.
There is no transparent mid-round restart with empty atmosphere state.

### Numerical safeguards and performance mechanisms

- Finite-value and physical-bound validation at numerical boundaries, nonnegative
  gas/volume rules, immutable-mixture protection, and corruption-repair paths.
- Quantized gas transfer and trace-gas cleanup. The root engine uses a
  `0.0001`-mole cutoff; the shared-core service path removes positive traces below
  `0.01` mole at state commits.
- Conservation and stability checks for mixture operations, diffusion, and
  conduction, with explicit exceptions for trace removal and atmosphere reservoirs.
- Reusable arenas, graph storage, stage work buffers, and cached numerical metadata.
- Parallel in-process processing with Rayon.
- Runtime AVX2 selection with a fallback for annotated in-process routines.
  A CPU-specific build can have stricter requirements; AVX2 is not a blanket
  requirement for every build.

## Further reading

- [Architecture and ownership](docs/agent/architecture-and-ownership.md)
- [Protocol source and wire definitions](https://github.com/Aphelion-Moon/aphelion-dogmos/tree/archived-dogmos-64bit/crates/dogmos-protocol/src/lib.rs)
- [Core state and simulation implementation](https://github.com/Aphelion-Moon/aphelion-dogmos/blob/archived-dogmos-64bit/crates/dogmos-core/src/world.rs)
- [Generated native boundary and binding rules](docs/agent/ffi-and-generated-bindings.md)
- [Release and artifact contract](docs/agent/release-and-artifacts.md)
- [Verification matrix](docs/agent/verification.md)
- [Performance evidence and workloads](docs/performance/README.md)

Older notes in [`docs/AUXGM.md`](docs/AUXGM.md), [`docs/FIRE.md`](docs/FIRE.md), and
[`docs/MIGRATING.md`](docs/MIGRATING.md) describe historical Auxmos integration.
Their old feature names and gameplay formulas are not the current Dogmos default
contract; current code, manifests, and generated bindings take precedence.

## License and credits

[MIT](LICENSE). Based on Auxmos by Putnam and its contributors, with downstream
Dogmos development for Meridian Rift.

Contributor rules start at [AGENTS.md](AGENTS.md) and [the agent guide index](docs/agent/README.md).
## Read-only installation diagnosis

Run `python -B tools/diagnose_deployment.py --game-root <paired-checkout> --target
i686-pc-windows-msvc --bundle <matching-build-directory> --json` to compare source,
installed artifacts, symbols and manifest qualification. Use
`i686-unknown-linux-gnu` for the Linux library. An optional `--runtime-report`
accepts saved `dogmos_in_process_capabilities()` JSON and labels its freshness as
unchecked. This command does not load the library or start a world. Matching
disk bytes do not establish runtime or performance qualification.
