# Meridian-Rift agent instructions

Meridian-Rift is a BYOND/DreamMaker SS13 codebase downstream of Nova Sector and tgstation. Be direct, inspect existing implementations before editing, preserve unrelated work, and do not commit, push, reset, checkout, merge, or change branches without explicit authorization.

## Generated documentation and verification outputs

Store generated plans, audits, handoffs, patch archives, profiles and verification artifacts in the central `GitHub/.agent_docs/meridian-rift/` directory, grouped by work area. Dogmos work uses its `dogmos/` subdirectory. This location is shared across checkouts; do not create another `.agent_docs` inside a repository or worktree.

Keep maintained source documentation, agent instructions, workload definitions, build caches and required shipped artifacts with their code. When maintained verification tooling requires a repository-local output directory, move completed outputs to the central archive at handoff, preserving their manifests and hashes. Move registered qualification worktrees with `git worktree move` so their Git metadata remains valid.

## Required reading

- All DM work: [.github/guides/STYLE.md](.github/guides/STYLE.md), [.github/guides/AUTODOC.md](.github/guides/AUTODOC.md), and [.github/guides/STANDARDS.md](.github/guides/STANDARDS.md).
- Routing: [docs/agent/README.md](docs/agent/README.md) and [docs/agent/source-authority.md](docs/agent/source-authority.md).
- Placement: [docs/agent/placement-and-markers.md](docs/agent/placement-and-markers.md) and [modular_nova/readme.md](modular_nova/readme.md).
- General gates: [docs/agent/verification.md](docs/agent/verification.md), [docs/agent/meridian-mcp.md](docs/agent/meridian-mcp.md), [docs/agent/rift-controller.md](docs/agent/rift-controller.md), [docs/agent/generated-content.md](docs/agent/generated-content.md), and [docs/agent/upstream-drift.md](docs/agent/upstream-drift.md).
- Dogmos ownership: [docs/agent/dogmos-integration.md](docs/agent/dogmos-integration.md), [docs/agent/dogmos-gameplay-events.md](docs/agent/dogmos-gameplay-events.md), and [docs/agent/dogmos-service-lifecycle.md](docs/agent/dogmos-service-lifecycle.md).
- Dogmos measurement and gates: [docs/agent/dogmos-performance-and-memory.md](docs/agent/dogmos-performance-and-memory.md) and [docs/agent/dogmos-verification.md](docs/agent/dogmos-verification.md).
- Native contract: [docs/agent/native-artifacts.md](docs/agent/native-artifacts.md).

Read [.github/guides/HARDDELETES.md](.github/guides/HARDDELETES.md) before `Destroy()` or reference-ownership changes, and [.github/guides/VISUALS.md](.github/guides/VISUALS.md) before planes, layers, filters, overlays, or visual systems.

## High-frequency rules

New Meridian-owned work belongs under `modular_aphelion` and uses canonical `APHELION EDIT` markers. Preserve inherited `modular_nova` paths and `NOVA EDIT`; do not convert them in bulk. Dogmos has one narrow fork-owned atmosphere exception documented in [Dogmos integration](docs/agent/dogmos-integration.md). It does not exempt unrelated machinery, gameplay, UI, or subsystem files.

Use Meridian-MCP for DreamMaker parsing, discovery, exact symbol inspection, references, diagnostics, and Tracy after `dm_parse_environment`; reparse after DM changes. Use PowerShell for DreamMaker, DreamDaemon, Rust, Docker, process measurement, and test entry points. Focused tests are iteration evidence, never a completion claim.

Treat human-authored creative work as protected. Agents may implement technical systems and mechanically integrate user-approved material, but do not author or materially rewrite art, sound, lore, flavor text, descriptions, or user-facing names. Present properly licensed external candidates for human selection before importing them.

Human-authored critical infrastructure remains protected for changes outside the authorized task. Before making unrelated changes to `BUILD.cmd`, `RIFT_BUILD.cmd`, bootstrap/build implementation, `.github/workflows/`, dependency authority, release tooling, Docker files, TGS scripts, or deployment configuration, name the exact file and effect, explain why a separate Meridian-owned extension is insufficient, and obtain explicit user approval. Release publication, live deployment, and production restarts also require applicable authorization.

### Artifact rebuild authorization

Authorized implementation and verification work includes rebuilding native binaries, regenerating bindings, contract defines, manifests and artifact lock data, and synchronizing the verified matching artifact set into a local development or test checkout. Do not request separate per-file permission for these operations because an output or its authority file is described as protected. Necessary in-scope protocol and generator updates follow the same task authorization, with their required review and verification gates.

Use the maintained build, generation and synchronization tools, preserve unrelated changes, and verify the complete shim/service contract. Generated outputs must never be hand-edited. This rule supersedes older local plans that require exact-file approval to regenerate protected outputs.

Dogmos optimization targets DreamDaemon's constrained address space. Rust allocations in the currently loaded 32-bit DLL are DreamDaemon allocations. The selected Windows play-test uses the in-process root engine; see [the in-process contract](docs/agent/dogmos-in-process.md). Retained service guides and paired artifact gates apply when selecting the service backend. Measure service memory separately when that backend is used.
