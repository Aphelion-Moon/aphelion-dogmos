# RIFT controller

Use `RIFT.cmd` for non-interactive agent compile, boot, focused-test, and bounded-soak work. It wraps the inherited build graph; it does not replace `BUILD.cmd` or the interactive `RUN_SERVER.cmd` path. Every allocated run writes ordered events, child output, artifacts, cleanup state, and a final summary below `data/rift-runs/<run-id>/`.

## Dogmos commands

Dogmos runtime commands require a paired DLL and service. RIFT verifies the checked-in installed contract first and rejects overlay bytes that differ from it. The pair is copied only into the isolated run workspace.

```powershell
.\RIFT.cmd run --profile dogmos --map _maps/runtimestation.json `
	--shim dogmos.dll --service dogmosd.exe --format result

.\RIFT.cmd test --profile dogmos-ci --map _maps/metastation.json `
	--focus /datum/unit_test/dogmos_service_lifecycle `
	--shim dogmos.dll --service dogmosd.exe --format result

.\RIFT.cmd soak --profile dogmos --map _maps/runtimestation.json `
	--run-seconds 300 --shim dogmos.dll --service dogmosd.exe --format result
```

Use only MetaStation or full RuntimeStation for Dogmos runtime evidence. RuntimeStation Minimal is not an accepted completion map.

## Old-to-new mapping

| Existing command | RIFT replacement | Evidence |
| --- | --- | --- |
| Direct `dm.exe tgstation.dme` compile | `RIFT.cmd compile --mode fast --profile dogmos` | Compiler only |
| `tools/dogmos/boot_probe.ps1` | `RIFT.cmd run --profile dogmos --map _maps/runtimestation.json --shim dogmos.dll --service dogmosd.exe` | Full-map boot |
| Focused `tools/dogmos/run_tests.ps1` | `RIFT.cmd test --profile dogmos-ci --map _maps/metastation.json --focus <type> --shim dogmos.dll --service dogmosd.exe` | Named focused test |
| `tools/dogmos/run_liveness_soak.ps1` | `RIFT.cmd soak --profile dogmos --map _maps/runtimestation.json --run-seconds <n> --shim dogmos.dll --service dogmosd.exe` | Bounded full-map soak |
| `tools/dogmos/sync_contract.ps1 -VerifyOnly` | Automatic installed-contract preflight; retain the script for source release synchronization | Native contract |

The PowerShell Dogmos scripts remain available until matched old/new parity is recorded. Do not delete them based only on controller unit tests or a focused runtime.

## Dogmos failure and resource data

The Dogmos profiles fail on DreamMaker runtimes, `StageConflict`, malformed stage responses, pending-stage timeouts, lifecycle rejection, any nonempty `dogmos_panic.log`, or a missing/extra/exited `dogmosd.exe`. `--format result` reports normalized runtime signatures and keeps DreamDaemon private/working-set maxima separate from `dogmosd` maxima. Compare only identical maps, duration, native artifacts, configuration, and workload.

Run `RIFT.cmd report <run-id> --format human` for a concise stored report or use `--format jsonl` for the complete event stream. See [tools/rift/README.md](../../tools/rift/README.md) for options, exit codes, evidence classes, network behavior, and record layout.
