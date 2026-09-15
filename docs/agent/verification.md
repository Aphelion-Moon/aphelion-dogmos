# Verification matrix

Pull requests run both Windows/Linux i686 checks, x64 service checks, diagnostic-binding gates,
generated-binding drift, the resolved dependency guard and complete paired artifact generation.
Release publishing remains a separate workflow. Component README links are included in the
scoped documentation checker; public binding inventories and handwritten adapter goldens remain
independent of generated field definitions.

For isolated Linux container qualification, build `tools/linux-container.Dockerfile` and record
its immutable image ID, then invoke `python3 -B tools/test_linux_container.py --bundle <bundle>
--probe <i686-cross_bitness_probe> --output <new-output-directory> --image-id <sha256-id>`.
Build the maintained probe with Rust 1.98.0, `--locked`, and the bundle's source/feature identity.
The verifier checks the complete contract before and after execution. The container has no network,
read-only inputs, a bounded temporary filesystem and an init process; only its exact ID is removed.
This proves real i686-to-x64 IPC/transcripts and container cleanup, not DreamDaemon native loading.
Keep DreamMaker, native-load boot and full DM suite results separate.

`tools/perf/Measure-DogmosProcesses.ps1` records private, mapped, image, reserved and free regions,
including the largest free region. Its 32-bit scan is capped at 4 GiB so host 64-bit free space
cannot hide DreamDaemon pressure. Report service memory separately and preserve each run's exact
process identity. Region checkpoints complement the maintained 250 ms RIFT sampler.

| Evidence | Required use | Boundary |
| --- | --- | --- |
| Focused unit/property test | Every behavioral correction, written and observed failing first | Proves only the named break |
| `cargo fmt --all -- --check` | Rust source changes | Formatting only |
| Strict Clippy with `--locked` | Changed packages on their supported target | Static Rust gate, not runtime integration |
| i686 workspace/shim tests | BYOND-facing Rust | Required; a host-only pass is insufficient |
| x86_64 core/server tests | Service/core/protocol/performance crates | Required after the split |
| Feature matrix | Feature ownership or shared modules | Use supported combinations, not intentionally invalid all-features |
| Generated-binding/manifest drift | Exports, features, releases | Deterministic contract gate |
| PowerShell DreamMaker compile | Paired Meridian-Rift checkout | Compiler acceptance |
| PowerShell focused DM tests | Changed integration behavior | Iteration evidence only |
| PowerShell boot probe | Native load and initialization | Requires initialization marker and runtime review |
| Full DM suite | Integration completion | Required when DM behavior can regress broadly |
| Repeated process/Tracy workload | Memory or performance claim | Separate DreamDaemon/service measurements and equivalence |

Use the exact repository-pinned Rust toolchain and `--locked`. The authoritative pre-split Windows baseline is:

```powershell
cargo +1.98.0 test --workspace --locked --target i686-pc-windows-msvc
if ($LASTEXITCODE -ne 0) { throw 'Rust tests failed.' }
```

Run DreamMaker and DreamDaemon through the paired game repository's maintained PowerShell entry points. Use Meridian-MCP for DM parsing, navigation, diagnostics, and Tracy analysis, not as a substitute for those build/test gates.

Report exact commands, tool/target versions, scope, exit/result artifacts, warnings, runtime signatures, and gates not run. Distinguish executable tests from ignored doc tests. Never call a focused run, parser success, process liveness, or a plain host `cargo test` complete evidence.

Before handoff, run `git diff --check`, review changes to build and release tooling, confirm
source/contract revisions and hashes, and leave changes uncommitted unless the user authorizes otherwise.
