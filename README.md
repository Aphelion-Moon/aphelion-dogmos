# Dogmos

Rust atmospherics for Meridian-Rift, a Space Station 13 downstream. Dogmos is maintained from
[Auxmos](https://github.com/Putnam3145/auxmos) and uses
[byondapi](https://github.com/spacestation13/byondapi-rs) at the DreamDaemon boundary.

## Start here

The [architecture guide](docs/agent/architecture-and-ownership.md) owns the component and state map:

| Component | Responsibility | Windows target | Linux target |
| --- | --- | --- | --- |
| `dogmos-byond` | Thin 32-bit BYOND shim; bounded requests and value conversion | `i686-pc-windows-msvc` | `i686-unknown-linux-gnu` |
| `dogmos-server` (`dogmosd`) | 64-bit service hosting authoritative `dogmos-core` state | `x86_64-pc-windows-msvc` | `x86_64-unknown-linux-gnu` |
| `dogmos-protocol` | Fixed-width wire messages and codecs shared by shim and service | Both architectures | Both architectures |

DM owns object identity, subsystem scheduling and gameplay effects. Growing numerical state lives
in the service; shim allocations still consume DreamDaemon's constrained address space.

## Build, generate and verify a pair

Use the pinned [Rust toolchain](rust-toolchain.toml) and locked dependencies. The maintained
[paired release workflow](.github/workflows/build.yml) explicitly selects both packages and targets.
For an uncommitted local candidate, use
[`tools/build_local_qualification.ps1`](tools/build_local_qualification.ps1), following
[Release and artifacts](docs/agent/release-and-artifacts.md). That route builds both platform pairs,
generates bindings, and captures the exact source snapshot. Building a bundle is not runtime qualification.

The production binding generator is
[`crates/dogmos-byond/examples/generate_bindings.rs`](crates/dogmos-byond/examples/generate_bindings.rs);
the maintained pair builder invokes it from that crate. Never hand-edit generated bindings or mix
them with a different shim, service or manifest. Select integrations by the verified artifact contract
and exact revision, not by a mutable branch name.

Distinguish three kinds of evidence:

- **Implemented:** the feature exists in source.
- **Selected:** the build features and installed artifact contract select that implementation.
- **Qualified:** the exact pair passed named checks in a recorded environment.

The paired Meridian SSair source defaults optional asynchronous stages off pending controlled
qualification. Source presence does not enable them. Follow the
[verification matrix](docs/agent/verification.md) for Rust, DM, native-load, lifecycle and full-suite
gates; report performance and DreamDaemon/service memory separately.

## Legacy reference

The root `dogmos` package is the retained in-process implementation. An unqualified root Cargo build
selects that package; it does **not** build the release pair. Its `bindings.dm` and `generate_binds`
test belong to that legacy path. Retain it for current consumers and differential/reference tests
until supported-target parity, rollback artifacts and an explicit retirement decision permit removal.

Contributor rules and topic-specific guidance start at [AGENTS.md](AGENTS.md) and the
[agent guide index](docs/agent/README.md).
