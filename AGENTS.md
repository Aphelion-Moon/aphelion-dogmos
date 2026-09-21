# aphelion-dogmos agent instructions

aphelion-dogmos is the Rust half of Meridian-Rift's Dogmos atmosphere integration. Be direct, inspect existing implementations before changing them, preserve unrelated work, and leave changes uncommitted unless the user explicitly authorizes a commit.

## Generated documentation and verification outputs

Store generated plans, audits, handoffs, patch archives, profiles and verification artifacts in the central `GitHub/.agent_docs/aphelion-dogmos/` directory. This location is shared across checkouts; do not create another `.agent_docs` inside a repository or worktree.

Keep maintained source documentation, agent instructions, workload definitions, build caches and required shipped artifacts with their code. When maintained verification tooling requires a repository-local output directory, move completed outputs to the central archive at handoff, preserving their manifests and hashes. Move registered qualification worktrees with `git worktree move` so their Git metadata remains valid.

## Required reading

- Routing and authority: [docs/agent/README.md](docs/agent/README.md) and [docs/agent/source-authority.md](docs/agent/source-authority.md).
- Architecture: [docs/agent/architecture-and-ownership.md](docs/agent/architecture-and-ownership.md), and [docs/agent/gameplay-events.md](docs/agent/gameplay-events.md).
- Optimization: [docs/agent/performance-and-memory.md](docs/agent/performance-and-memory.md) and [docs/agent/numerical-invariants.md](docs/agent/numerical-invariants.md).
- Native boundary: [docs/agent/ffi-and-generated-bindings.md](docs/agent/ffi-and-generated-bindings.md).
- Gates and releases: [docs/agent/verification.md](docs/agent/verification.md) and [docs/agent/release-and-artifacts.md](docs/agent/release-and-artifacts.md).
- Source updates: [docs/agent/upstream-drift.md](docs/agent/upstream-drift.md).

## Ownership and implementation rules

The production target is the 32-bit in-process root `dogmos` engine. Follow [the build contract](docs/agent/in-process.md). Native arenas, graphs, workers and callback queues consume DreamDaemon address space. DM owns identity, scheduling and gameplay effects; callbacks run on the main thread. Keep shared numerical kernels in `dogmos-core` and instrumentation in the dedicated telemetry/host-metrics crates.

Preserve public DM proc paths and caller-legible errors. No panic may unwind across BYOND FFI. Validate finite numerical inputs and preserve established atmosphere coefficients. Never hand-edit generated bindings or manifests; regenerate and compare exact output.

## Artifact rebuild authorization

Authorized implementation includes native rebuilds, generated bindings/defines/manifests and verified local synchronization. Use maintained tools and preserve unrelated changes. Release publication, live deployment, production restarts and unrelated infrastructure changes retain their own authorization requirements.

## Verification boundary

Use the exact pinned Rust toolchain and `--locked`. Run formatting, strict Clippy, tests, supported feature combinations and generated binding/artifact checks on the appropriate i686 target. Run the game repository's maintained DreamMaker/DreamDaemon gates. Report Rust, compile, focused tests, boot, full suite and performance separately. Performance acceptance requires repeated equivalent workloads and whole DreamDaemon memory measurements.
