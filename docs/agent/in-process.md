# In-process build contract

The production direction is the root `dogmos` engine inside 32-bit DreamDaemon.
DM owns object identity, public procs, scheduling and gameplay effects. The native
engine owns numerical state, graphs and workers; BYOND callbacks run on the main
thread. Shared core mathematics remain reusable. Preserve the service sources and
their existing release workflow as a separate backend.

Build the Windows play-test candidate with Rust 1.98.0, locked dependencies and
`i686-pc-windows-msvc`. Select `turf_processing,katmos,superconductivity,katmos_slow_decompression,aphelion_reactions`
explicitly with default features disabled. `tools/build_in_process.ps1` builds the
DLL and runs the binding generator, without running tests or a game instance.
Generated bindings and the DLL must be used together with an in-process game
integration; the service game's bindings are incompatible.

The generator selects `DOGMOS_IN_PROCESS` and embeds the source snapshot identity.
Linux selects `libdogmos_in_process`, preventing accidental use of a retained
`libdogmos.so` service shim; this Windows play-test does not ship that Linux library.
The current game port preserves reaction signals through its main-thread
`dogmos_react` callback and samples host memory through `dogmos-process-metrics`.
Install with Meridian-Rift's `tools/dogmos/sync_in_process.py`; it generates the
matching installed lock and contract without accepting this bundle as a service release.

The service-only guides describe that backend's contracts, not requirements to
move this engine's state outside DreamDaemon. The in-process objective is whole
DreamDaemon memory/headroom parity or improvement against matched LINDA, together
with faster complete atmosphere processing and preserved Dogmos mechanics. The
service's 70%/32 MiB targets do not apply.

Compilation is the only requested gate for the current play-test preparation.
Runtime correctness, boot, lifecycle, performance and populated qualification are
deferred to the maintainer. A build manifest identifies unqualified local artifacts;
it is not a release manifest or deployment authorization.
