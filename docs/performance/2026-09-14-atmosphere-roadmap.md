# Atmosphere responsiveness and startup roadmap

Status: design and work plans prepared for review on 2026-09-14. No implementation, benchmark, artifact replacement, deployment, or commit is part of this documentation change.

Execution was subsequently authorized; see the [work-plan execution checkpoint](2026-09-14-workplan-execution.md) for current progress, test evidence and restart requirements.

## Reading order

1. [Runtime design](../superpowers/specs/2026-09-14-atmosphere-runtime-isolation-design.md): reduce the time atmosphere prevents other gameplay from executing.
2. [Runtime work plan](../superpowers/plans/2026-09-14-atmosphere-runtime-isolation.md): bounded DM work, native preparation jobs, explicit publication, and qualification.
3. [Startup design](../superpowers/specs/2026-09-14-atmosphere-startup-preparation-design.md): reduce time to a playable world using batching, preparation, and build artifacts.
4. [Startup work plan](../superpowers/plans/2026-09-14-atmosphere-startup-preparation.md): independently useful startup changes and prerequisite gates for the larger redesign.

Runtime work is the first priority from the latest discussion. Startup remains a separate workstream because it has different dependency and acceptance boundaries. Execute inline, with no subagents. Leave changes uncommitted unless separately authorized. Follow the applicable repository instructions before implementation; preparing these plans does not authorize production operations.

When implementation is authorized, rebuilding native artifacts, regenerating bindings/contracts/manifests/artifact lock data, and synchronizing the complete verified pair into a local development or test checkout are included. Do not ask for separate protected-artifact approval. Necessary in-scope protocol and generator updates use that same authorization. Preserve all contract, build and qualification checks; publication and live production operations remain separate.

## Source anchors and workspace boundary

| Repository | Reviewed revision | Relevant state |
| --- | --- | --- |
| Native, abbreviated N below | `6b6321b2c4a0658933b7529e1d732acfac9cc5a4` | `master`, clean before documentation changes |
| Meridian-Rift, abbreviated G below | `1604655c7fa4d5e2e4c466132acb2ae64bb389b3` | Dogmos implementation read directly from Git |

The current G checkout is `custom-emotes` with unrelated dirty changes. It is not the Dogmos source reviewed here. That checkout remains unchanged. At implementation time, establish an authorized checkout containing the Dogmos integration and preserve unrelated work. Recheck both revisions and every source anchor after integration; do not apply line numbers from these plans blindly. Use Meridian-MCP only after parsing that actual Dogmos environment, not the current unrelated checkout.

The artifact approval policy was updated separately in an isolated detached G worktree at N's `target/meridian-artifact-policy`, based on the G revision above. Its uncommitted guidance and test-fixture edits are also preserved in the [paired policy patch](../patches/2026-09-14-meridian-artifact-rebuild-policy.patch). Carry these edits into the eventual Dogmos implementation checkout after checking the patch against that checkout; do not apply it to the unrelated active game branch. The native policy is in the current root `AGENTS.md`.

## Delivery order

| Milestone | Deliverable | Depends on | Safe stopping point |
| --- | --- | --- | --- |
| R0 | Matched workload and bounded diagnostic contract | Existing profiler | Baseline evidence only |
| R1 | Chunked machinery prefetch | R0 | DM-only candidate |
| R2 | Ordered, bounded frontier change journal | R0 | DM-only candidate; retain recovery rescan |
| R3 | Core preparation separated from publication; scheduling quantum | R0 | Synchronous compatibility path still works |
| R4 | Service jobs and responsive control requests | R3 | Native protocol tests; disabled game path |
| R5 | DM submit/poll/commit integration | R4 | Qualified optional mode selected at boot |
| R6 | Paired release and server acceptance | R1-R5 | Deployment candidate with rollback bundle |
| S1 | Late-map registration batching | R0 measurement conventions | Independent DM-only candidate |
| S2 | Explicit bulk mixture factory | S1, constructor audit | Native/game paired candidate |
| S3 | Overlap native startup preparation with independent initialization | R3-R5 mechanisms, S2 | Readiness-tested candidate |
| S4 | Deterministic build preparation artifact | S2/S3 evidence | Optional verified accelerator |

R1, R2, and S1 can be evaluated separately. Do not bundle their measurements with an asynchronous runtime change. S4 is conditional on a measured repeatable cost; a cache of already-cached gas strings alone is not a reason to build it.

## Acceptance contract

These are proposed qualification criteria, not measured results or promised speedups.

- Use at least three controls and three candidates, alternating order, with identical map, seed, configuration, numerical settings, binaries per cohort, BYOND version, workload sequence, and duration. Record machine activity and exclude contaminated pairs explicitly.
- Capture idle station, sustained occupied-station activity, a breach/fire, a machinery-heavy region, and rapid topology changes. Record command/event sequences so changes in workload progress cannot masquerade as lower resource use.
- Runtime primary outcome: lower atmosphere-attributable main-thread blocking and p95/p99/max game-tick latency. Also report total SSair CPU, completed cycles, cycle age, pending job age, callback age/depth, conflicts/retries, and request counts. A smoother game with a steadily growing atmosphere backlog fails.
- Startup primary outcome: process start to safe playable readiness; report Mapping, Atoms, Atmos, native preparation, and final join separately. Earlier logging or moving work past readiness does not pass.
- Compare numerical state and ordered critical events under controlled schedules. Concurrent schedules also need consistency tests for live mutations and eventual progress. Preserve the configured 0.5-second atmosphere step and FDM iteration count; do not compensate for backlog by silently changing physics.
- Report DreamDaemon private/committed bytes, working set, address-space pressure, and shim capacity separately from service memory/CPU. New shim storage must be fixed-size; the existing 32 MiB shim/mapped-space ceiling still applies. Avoid a new world-sized DM mirror.
- Scheduling starts with a 1,000 microsecond native quantum, capped at 256 work items, as an experimental setting. Measure overshoot including allocation, preparation, publication, and cleanup. This is a cooperative target, not a guaranteed 1 ms stall bound. Tune from data and record the final setting before matched runs.
- No raw runtimes, stale writes, dropped/duplicated critical events, leaked child processes, unexplained retained native memory, or starvation. Main-server acceptance remains distinct from local/native test success.

## Maintained verification entry points

Run only the gates relevant to the implemented milestone, then the complete matrix for a paired release. Commands below are execution instructions, not commands run while writing this roadmap. Stop on a nonzero command result; preserve the failing artifacts.

From N in PowerShell:

```powershell
rustc +1.98.0 --version
cargo +1.98.0 fmt --all -- --check
cargo +1.98.0 clippy --workspace --locked --target i686-pc-windows-msvc --all-targets -- -D warnings
cargo +1.98.0 test --workspace --locked --target i686-pc-windows-msvc
cargo +1.98.0 test -p dogmos-core -p dogmos-protocol -p dogmos-server --locked --target x86_64-pc-windows-msvc
python -B -m unittest discover -s tools/tests -v
$env:RUSTUP_TOOLCHAIN = '1.98.0'
& ./tools/check_feature_matrix.ps1 -Target i686-pc-windows-msvc
cargo +1.98.0 build -p dogmos-byond --release --locked --target i686-pc-windows-msvc
cargo +1.98.0 build -p dogmos-server --bin dogmosd --release --locked --target x86_64-pc-windows-msvc
cargo +1.98.0 run --quiet --locked --target i686-pc-windows-msvc -p dogmos-byond --example generate_bindings
```

Set `RUSTUP_TOOLCHAIN` only in the verification shell and restore its previous value afterward. On the supported Linux runner repeat formatting/tooling, strict Clippy, workspace tests and feature matrix for `i686-unknown-linux-gnu`, core/protocol/server tests for `x86_64-unknown-linux-gnu`, and both release targets. Some transport integration tests are Windows/i686-gated: a zero-test Linux or x64 result does not cover them. Record executed test counts. Preserve the i686 stalled-read cancellation gate.

Generate and compare bindings deterministically. Use N `.github/workflows/build.yml` and `tools/dogmos_contract.py` for the complete release bundle, and G `tools/dogmos/sync_contract.ps1` for installation. Resolve revision/feature identity through maintained tooling. Do not hand-edit generated files or install a DLL independently of the service, manifests, and bindings.

From the prepared G checkout in PowerShell, after installing a matching full contract:

```powershell
python -B tools/dogmos/verify_contract.py verify-installed --root .
.\RIFT.cmd doctor --network offline
.\RIFT.cmd compile --mode full --network offline --format result
.\RIFT.cmd test --profile dogmos-ci --focus /datum/unit_test/dogmos_runtime_scheduling --minimum-tests 1 --shim dogmos.dll --service dogmosd.exe --network offline --format result
.\RIFT.cmd test --profile dogmos-ci --shim dogmos.dll --service dogmosd.exe --network offline --format result
.\RIFT.cmd soak --profile dogmos --run-seconds 300 --shim dogmos.dll --service dogmosd.exe --network offline --format result
```

The focused fixture above is created by R5; earlier tasks specify their own names. Keep DM compile, focused tests, boot, full tests, 300-second soak, Linux BYOND loading, and main-server traces as separate evidence classes. Judge DreamDaemon completion from fresh result files, raw logs, natural/requested shutdown semantics, and verified cleanup, not wrapper exit alone. Run applicable DreamChecker and ticked-file checks from the game repository. Never use bare `dm.exe tgstation.dme` for production qualification.

The existing one-click profiler in G `modular_aphelion/tools/dogmos_tracy/START_CAPTURE.cmd` remains the operator entry point. Preserve its deployment identity checks, operator-controlled restart, bounded collector ownership, and separate process samples. Do not launch another local timing campaign on a busy machine or restart the main server as part of preparing these plans.

## Review and rollback

Each milestone records exact source/bundle hashes, implementation diff, focused oracles, failed and passing gates, and performance scope. Review the diff without committing. Runtime mode is selected at boot; no live switching with an active stage. Retain a complete known-good paired bundle. Rollback requires a controlled restart into that bundle; never replace the authoritative service mid-round.

Prior September 10 local measurements did not establish a startup improvement; see G `docs/audits/2026-09-10-dogmos-initialization-and-server-capture.md` at the anchored revision. This roadmap makes no new performance claim.
