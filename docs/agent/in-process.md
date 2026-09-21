# In-process build contract

The production target is the root `dogmos` engine inside 32-bit DreamDaemon. DM owns object identity, public procs, scheduling and gameplay effects. Native code owns numerical state, graphs and workers; callbacks run on the main thread.

Build with Rust 1.98.0, locked dependencies and the platform's i686 target. The selected features are `turf_processing,katmos,superconductivity,katmos_slow_decompression,aphelion_reactions`. The Windows builder is `tools/build_in_process.ps1`; it generates the DLL, symbols, bindings and exact source snapshot. Install through the game repository's `tools/dogmos/sync_in_process.py`.

Generated bindings select `DOGMOS_IN_PROCESS`, embed the source identity and load `dogmos.dll` on Windows or `libdogmos_in_process.so` on Linux. A Windows playtest bundle does not qualify Linux. Whole DreamDaemon memory/headroom, simulation latency and preserved gameplay are the acceptance targets. Compilation, boot, focused/full tests, populated play and performance remain separate evidence.
