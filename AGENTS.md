# aphelion-dogmos agent instructions

aphelion-dogmos is the Rust half of Meridian-Rift's Dogmos atmosphere integration. Be direct, inspect existing implementations before changing them, preserve unrelated work, and leave changes uncommitted unless the user explicitly authorizes a commit.

## Generated documentation and verification outputs

Store generated plans, audits, handoffs, patch archives, profiles and verification artifacts in the central `GitHub/.agent_docs/aphelion-dogmos/` directory. This location is shared across checkouts; do not create another `.agent_docs` inside a repository or worktree.

Keep maintained source documentation, agent instructions, workload definitions, build caches and required shipped artifacts with their code. When maintained verification tooling requires a repository-local output directory, move completed outputs to the central archive at handoff, preserving their manifests and hashes. Move registered qualification worktrees with `git worktree move` so their Git metadata remains valid.

## Required reading

- Routing and authority: [docs/agent/README.md](docs/agent/README.md) and [docs/agent/source-authority.md](docs/agent/source-authority.md).
- Architecture: [docs/agent/architecture-and-ownership.md](docs/agent/architecture-and-ownership.md), [docs/agent/process-boundary-and-protocol.md](docs/agent/process-boundary-and-protocol.md), and [docs/agent/gameplay-events.md](docs/agent/gameplay-events.md).
- Optimization: [docs/agent/performance-and-memory.md](docs/agent/performance-and-memory.md) and [docs/agent/numerical-invariants.md](docs/agent/numerical-invariants.md).
- Native boundary: [docs/agent/ffi-and-generated-bindings.md](docs/agent/ffi-and-generated-bindings.md).
- Gates and releases: [docs/agent/verification.md](docs/agent/verification.md) and [docs/agent/release-and-artifacts.md](docs/agent/release-and-artifacts.md).
- Source updates: [docs/agent/upstream-drift.md](docs/agent/upstream-drift.md).

## Ownership and implementation rules

The [architecture guide](docs/agent/architecture-and-ownership.md) owns the current component map. The paired build selects a thin 32-bit `dogmos-byond` shim and a 64-bit `dogmosd` service; the root crate remains the legacy in-process implementation. Shim and legacy DLL allocations consume DreamDaemon address space. Route BYOND conversion and main-thread dispatch to `dogmos-byond`, domain rules and numerical kernels to `dogmos-core`, wire types to `dogmos-protocol`, and service lifecycle/state to `dogmos-server`. In the service architecture only the shim may depend on `byondapi`; retained legacy `dogmos` and `auxcallback` are explicit exceptions. Source implementation, artifact selection and runtime qualification are separate facts.

Preserve public DM proc paths and caller-legible errors. No panic may unwind across the BYOND FFI boundary. Inputs and numerical state must be finite and validated; do not change atmosphere coefficients from intuition.

Generated bindings and release manifests are never hand-edited. Regenerate them with maintained tooling and compare exact output. Build BYOND-facing code for `i686-pc-windows-msvc` and `i686-unknown-linux-gnu`; host-only Cargo success is not authoritative.

## Artifact rebuild authorization

Authorized implementation and verification work includes rebuilding native binaries, regenerating bindings, contract defines, manifests and artifact lock data, and synchronizing the verified matching artifact set into a local development or test checkout. Do not request separate per-file permission for these operations because an output or its authority file is described as protected. Necessary in-scope protocol and generator updates follow the same task authorization, with their required review and verification gates.

Use the maintained build, generation and synchronization tools, preserve unrelated changes, and verify the complete shim/service contract. This rule supersedes older local plans that require exact-file approval to regenerate protected outputs. Publishing releases, changing live deployments, restarting production services, and unrelated dependency or infrastructure changes retain their own authorization requirements.

## Verification boundary

Use the repository's exact pinned toolchain and `--locked`. Run formatting, strict Clippy, tests, supported feature combinations, i686 shim builds, generated-binding drift, and paired artifact verification as applicable. Verify the paired Meridian-Rift integration through its PowerShell DreamMaker/DreamDaemon gates. Report Rust, DM compile, focused tests, boot, full suite, and performance evidence separately.

Memory optimization targets DreamDaemon private/committed bytes and address-space pressure. Report `dogmosd` memory separately; do not combine it with DreamDaemon or optimize harmless 64-bit service RSS. Accept performance changes only from repeated identical workloads with numerical/event equivalence.
