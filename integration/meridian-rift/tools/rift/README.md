# RIFT controller

RIFT is the Meridian-owned Windows controller for repeatable compile, boot, unit-test, and bounded-soak workflows. It is a TypeScript program executed by the repository-pinned Bun runtime. It delegates the inherited build graph instead of replacing it and writes machine-readable evidence for every allocated run.

Run it from PowerShell at the repository root:

```powershell
.\RIFT.cmd doctor --network offline
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
```

## Entry points

| Entry | Purpose |
| --- | --- |
| `BUILD.cmd` | Authoritative human full-build entry point. RIFT does not modify it. |
| `RUN_SERVER.cmd` | Authoritative interactive human build-and-server launcher. It retains Juke's interactive wait behavior. |
| `RIFT.cmd` | Non-interactive controller for agents and developers. It validates offline mode before Bun starts. |
| `RIFT_BUILD.cmd` | No-argument Meridian-MCP compatibility shim. It delegates to `RIFT.cmd compile --mode full --format result`. |

Rebuilding artifacts, regenerating bindings/contracts/manifests/artifact lock data, and synchronizing a verified matching artifact set into a local development or test checkout are included in authorized implementation and verification work. Necessary in-scope protocol, generator and synchronizer updates use the same authorization. Do not request a separate protected-artifact approval. The infrastructure rules in `AGENTS.md` still apply to unrelated changes to `BUILD.cmd`, `RUN_SERVER.cmd`, inherited bootstrap/build implementation, release/deployment scripts or CI, and to release publication and live production operations.

## Commands

```text
RIFT.cmd doctor
RIFT.cmd compile --mode fast|full [--force]
RIFT.cmd run [--compile-mode fast|full] [--map <_maps/file.json>]
    [--port <1-65535>] [--readiness-timeout-seconds <n>]
    [--run-seconds <0-1800>] [--shim <dogmos.dll>]
    [--service <dogmosd.exe>]
RIFT.cmd test [--focus </datum/unit_test/name>]...
    [--map <_maps/file.json>] [--minimum-tests <n>]
    [--readiness-timeout-seconds <n>] [--shim <dogmos.dll>]
    [--service <dogmosd.exe>]
RIFT.cmd soak --run-seconds <30-1800>
    [--compile-mode fast|full] [--map <_maps/file.json>]
    [--readiness-timeout-seconds <n>]
    [--shim <dogmos.dll>] [--service <dogmosd.exe>]
RIFT.cmd report <run-id> [--format human|jsonl|result]
```

Common workflow options are:

```text
--network offline|allow
--profile <name>
--format human|jsonl|result
--wall-timeout-seconds <1-3600>
--idle-timeout-seconds <1-900>
--wait-for-lock-seconds <0-300>
--keep-workspace
```

Readiness timeouts are limited to 1-900 seconds. `--force` is valid only for a full compile. `report` accepts only `--format` and reads an existing run without allocating a new one or acquiring the workflow lock.

The checked-in profiles are:

- `default`: repository configuration, suitable for normal boot/soak work.
- `ci`: `tools/ci/ci_config.txt`, `-close`, required clean-run and unit-test artifacts, and `_maps/metastation.json` by default.
- `dogmos`: repository configuration, full RuntimeStation, Dogmos fatal rules, and exactly one continuous `dogmosd.exe` child.
- `dogmos-ci`: CI configuration, MetaStation with full CentCom, skipped Lavaland/space levels, Dogmos fatal rules, and exactly one continuous `dogmosd.exe` child. `MINIMAL_CENTCOM` is incompatible with this representative-map profile.

`test` selects `ci` when `--profile` is omitted; other commands select `default`. A test profile is rejected unless it uses the CI config, requests natural `-close` shutdown, and requires nonempty unit-test and clean-run artifacts.

Run, test, and soak commands enforce a representative map. The only accepted completion-evidence maps are `_maps/metastation.json` and `_maps/runtimestation.json`; `_maps/runtimestation_minimal.json` and other debug maps are rejected.

Examples:

```powershell
.\RIFT.cmd compile --mode fast --network offline
.\RIFT.cmd run --profile default --map _maps/metastation.json --port 1339 --run-seconds 30 --network offline
.\RIFT.cmd test --profile ci --map _maps/metastation.json --focus /datum/unit_test/simple_animal_freeze --network offline
.\RIFT.cmd soak --profile default --map _maps/runtimestation.json --run-seconds 30 --network offline
.\RIFT.cmd report 20260831T010425Z-cc8d910f --format human
```

## Network modes and tool resolution

`offline` is the default. The launcher requires the pinned Bun executable before it runs TypeScript. The controller then requires the pinned Python environment, matching requirements marker, icon cutter, Bun lockfiles, and successful offline frozen-lockfile dry runs. It sets Bun and pip offline controls for owned children. Missing prerequisites return exit 3 before the build workflow starts.

Offline mode is cooperative process-local enforcement, not a firewall. A warm shared cache can be selected with `TG_BOOTSTRAP_CACHE`. No Docker installation or image is part of RIFT.

`allow` uses the existing repository bootstrap launcher and may fetch missing pinned dependencies. It does not weaken repository qualification, version checks, path containment, fixed build targets, process ownership, timeouts, or report redaction.

BYOND resolution checks `DM_EXE`, the optional default entry in `tools/build/dm_versions.json`, standard install locations, documented registry locations, and `PATH`. The selected DreamMaker must report the exact `BYOND_MAJOR.BYOND_MINOR` pins and have a sibling `dreamdaemon.exe`.

## Workflow behavior

`compile --mode fast` copies `tgstation.dme` to run-specific root scratch names, invokes pinned DreamMaker with `-DCBT` and profile defines, requires explicit zero-error diagnostics and new nonempty artifacts, copies hashes into the run directory, and removes only its exact scratch files. This is compiler evidence, not a full build.

`compile --mode full` validates the protected build contract and invokes the fixed inherited `tools/build/build.bat build` target. `--force` removes only canonical `tgstation.dmb` and `tgstation.rsc` immediately before the build and requires fresh replacements. Without `--force`, artifacts are classified as rebuilt or reused.

The MCP shim accepts validated `MERIDIAN_RIFT_WALL_TIMEOUT_SECONDS` and `MERIDIAN_RIFT_IDLE_TIMEOUT_SECONDS` environment defaults. Explicit CLI options take precedence. Meridian-MCP sets the inner wall limit below its outer wrapper limit so RIFT retains cleanup/reporting time, and applies idle detection to RIFT's owned build child rather than the normally silent wrapper.

`run`, `test`, and `soak` deploy required inputs into the run's `workspace` directory. Repository configuration and map files are copied; they are never rewritten for a run. DreamDaemon starts in that isolated directory, and readiness and fatal rules are monitored continuously until natural completion or requested stop. Process cleanup targets only descendants captured with matching PID, executable name, and creation time; a PID without verified instance identity is never force-killed. `run` returns `ready_then_stopped` after readiness or the requested bounded window.

`test` performs a `CIBUILDING` compile and validates `data/unit_tests.json`, minimum counts, failures, profile artifacts, and natural DreamDaemon termination. BYOND 516.1687/Bun 1.3.5 on Windows produced different native exit values (224 and 176) for otherwise identical clean MetaStation test shutdowns. RIFT therefore records the native value but does not use it as the success classifier after natural termination; fresh passing result JSON, minimum counts, zero runtime failures, and required clean artifacts are authoritative. The CI profile uses MetaStation by default. Database-backed game tests still require the repository's configured MariaDB service. A disposable local MariaDB container is one optional way to supply it, but Docker is not configured or managed by RIFT.

`soak` requires a bounded 30-1800 second window, monitors fatal logs and continuous child rules, samples private and working-set bytes by stable role, and records normalized runtime signatures. When both Dogmos overlay arguments are supplied, their nonempty inputs are copied only into the isolated workspace as `dogmos.dll` and `dogmosd.exe`.

Dogmos runtime profiles require both overlay arguments. Before compile or launch, RIFT runs the checked-in installed-contract verifier against `dogmos.lock.json`, bindings, contract defines, and all four platform binaries. The supplied Windows overlay pair must byte-match that verified installed contract. Source-to-game release synchronization remains an explicit `tools/dogmos/sync_contract.ps1` operation.

Ctrl+C and Ctrl+Break mark the workflow cancelled, terminate only active owned process trees, perform normal collection/cleanup, write the final summary, and return 130.

## Run records

Runs are stored below `data/rift-runs/<run-id>/`:

```text
events.ndjson
stdout.log
stderr.log
summary.json
artifacts/
workspace/        # only while running or with --keep-workspace
```

`events.ndjson` is ordered and append-only. `summary.json` is written atomically at completion. It contains the command/status, evidence class, stable exit, Git revision/dirty state, tool versions, network mode, phase durations, supervised process results, test counts, runtime signatures, resource maxima, hashed run-relative artifacts, cleanup result, and failures. Structured events and summaries redact user-profile path segments recursively; environment blocks and arbitrary external paths are not serialized. Raw `stdout.log` and `stderr.log` preserve exact child output for debugging and must be handled as potentially sensitive local evidence.

Cleanup distinguishes failures from intentional retention: `cleanup.leftovers` names paths that should have been removed, while `cleanup.retained` names paths kept by request such as `workspace` under `--keep-workspace`.

Evidence labels are `inspection`, `compiler`, `full_build`, `boot`, `focused_test`, `full_test`, and `soak`. These scopes are intentionally distinct.

`--format result` writes exactly one `RIFT_RESULT ` line followed by compact schema-versioned JSON. Compile results include the run ID, status, evidence class, stable exit code, reuse decision, and compile artifact paths, sizes, SHA-256 hashes, and freshness. This format is the Meridian-MCP compatibility boundary; `human` and `jsonl` remain intended for people and full event consumers.

## Exit codes

| Exit | Classification |
| --- | --- |
| 0 | Passed, or run reached readiness and was intentionally stopped. |
| 2 | Invalid command, option, profile, map, or input. |
| 3 | Repository, toolchain, version, offline-cache, or build-contract preflight failure. |
| 4 | Compiler or full-build failure. |
| 5 | Server, runtime, unit-test, profile, artifact, or cleanup failure. |
| 6 | Wall, idle, readiness, or bounded-run timeout. |
| 7 | Active workflow lock could not be acquired. |
| 130 | Cancellation. |

Native child exits remain in process records and do not replace the stable CLI classification.

## Development verification

```powershell
& .\tools\bootstrap\javascript.bat test tools/rift/rift.test.ts
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& .\tools\bootstrap\javascript.bat x biome check tools/rift
exit $LASTEXITCODE
```

Leave the worktree uncommitted unless the user explicitly requests a commit. Preserve stale scratch evidence and unrelated processes; `doctor` reports stale RIFT scratch names but does not delete them.
