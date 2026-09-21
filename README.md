# Dogmos

Rust atmospherics for Meridian-Rift, maintained from [Auxmos](https://github.com/Putnam3145/auxmos). The engine runs inside 32-bit DreamDaemon and uses [byondapi](https://github.com/spacestation13/byondapi-rs) at the native boundary.

Build with the pinned Rust toolchain and locked dependencies. `tools/build_in_process.ps1` produces a Windows playtest bundle; install it with the game repository's `tools/dogmos/sync_in_process.py`. Linux uses `i686-unknown-linux-gnu` and `libdogmos_in_process.so`. See [the build contract](docs/agent/in-process.md) and [verification gates](docs/agent/verification.md).

The root engine owns numerical state and workers. `dogmos-core` supplies pure numerical kernels; telemetry and host metrics have separate small crates. DM owns scheduling and gameplay. All native memory remains part of DreamDaemon.

Historical implementation is preserved on the `archived-dogmos-64bit` branch, including the corresponding game integration snapshot. It is outside the active build and runtime.

Contributor rules start at [AGENTS.md](AGENTS.md) and [the agent guide index](docs/agent/README.md).
