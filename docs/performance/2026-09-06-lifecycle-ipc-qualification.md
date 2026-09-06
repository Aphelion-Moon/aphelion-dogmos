# Lifecycle IPC qualification — 2026-09-06

The continuation batching and stale-callback repair now have real i686-to-x64 process coverage in
addition to the [native lifecycle tests and benchmark](2026-09-06-continuation-lifecycle.md).
This follow-up changes test tooling only; it establishes no additional performance speedup.

## Expanded cross-process probe

The maintained `cross_bitness_probe` now executes 1,030 lifecycle cycles through the real service.
Five replacement modes alternate queued and already-delivered target callbacks: mixture generation,
turf generation, turf mixture reassignment, detachment, and change-then-restore within one batch.
Each of the ten mode/delivery combinations runs 103 times. Two fixed mixture slots and two fixed
turf slots are reused with increasing generations and frontier epochs, creating 2,060 suspended
reactions cumulatively against a negotiated capacity of 1,024 pending continuations.

Each cycle requires two callbacks initially and one continuation/callback after owner replacement.
The surviving callback must have the other mixture and turf as its subject and target in the same
general queue. Frontier responses must acknowledge the exact epoch/count, and resumption must
return exactly zero flags, zero further work, no pending reaction and general transaction ID zero.
The survivor's three-mole snapshot remains unchanged. Cleanup unregisters both fixture owners.

The first delivered cycle for each replacement mode submits a nested write using the invalidated
token. The response must be the typed `UnknownContinuation` error, and the other mixture's snapshot
must remain identical. The five corresponding service error log lines are intentional negative-test
outcomes; arbitrary errors, timeout or disconnection do not satisfy the assertions.

After the earlier functional cases, the probe transfers its existing connection to the production
`BoundedDogmosClient`. Every new lifecycle request and shutdown uses a five-second deadline; the
worker closes before the successful child wait. This bounds those request waits, not the entire
harness: earlier raw-client phases, initial handshake and the final child wait have no new global
watchdog. The old diagnostic-memory sample intervals precede this bounded-client phase.

## Tests of the tests

- Skipping service cleanup for registration-only lifecycle batches reproduced the prior stale-token
  fault. The actual process probe failed with continuation depth two versus expected one.
- A service mutant slept for 15 seconds before acknowledging the first new frontier begin. The
  probe returned `RequestTimeout` after 5.137 seconds from the emitted stall
  marker, exited unsuccessfully and removed the owned service process. PID absence was checked.
- Every temporary source mutation was restored byte-for-byte. The final real implementation passed
  all 1,030 cycles in debug and release runs. Read-only review found no blocking correctness issue.

The first local mutation-launch attempt used Windows PowerShell and stopped in build-identity
preflight on a sandbox Git warning; that was not a behavioral test result. The recorded mutant and
final process runs use PowerShell 7, matching the active shell.

## Final gates

| Gate | Result |
| --- | --- |
| i686 Windows workspace tests | 442 passed; 2 doc tests ignored |
| i686 Windows/Linux workspace, all-target strict Clippy | Passed |
| Python tooling tests | 42 passed, including exact generated-binding drift checks |
| Debug cross-bitness probe | Passed, including 1,030 lifecycle cycles and five typed rejection checks |
| Release callback pressure | 10,000 cycles / 10,240,000 diagnostic callbacks enqueued and drained; depth zero; lifecycle extension passed afterward |
| Release process isolation | 512 MiB diagnostic service allocation; service private bytes grew 537,923,584; i686 probe growth zero; lifecycle extension passed afterward |
| Three PowerShell script syntax checks | Passed |
| Formatting and whitespace | Passed |
| Current candidate DreamMaker/DreamDaemon tests | Not run; exact clean artifact contract required first |

The pressure run sampled zero private-byte range for each process across five checkpoints. Those
samples and the isolation arena belong to the synthetic i686 probe and `dogmosd`, respectively;
neither is a DreamDaemon measurement. This follow-up did not repeat unchanged x64 core/server tests
or previously blocked i686 Linux executable tests; their earlier results retain their original scope.

The three maintained process-test scripts now pass `--locked` directly alongside their exact
`+1.98.0` toolchain and `--offline` options. No local Cargo wrapper is needed. Commands:

```powershell
./tools/test_cross_bitness_ipc.ps1
./tools/test_callback_pressure.ps1 -Cycles 10000
./tools/test_process_isolation.ps1
cargo +1.98.0 test --workspace --locked --offline --target i686-pc-windows-msvc
cargo +1.98.0 clippy --workspace --all-targets --locked --offline --target i686-pc-windows-msvc -- -D warnings
python -m unittest discover -s tools/tests -v
cargo +1.98.0 fmt --all -- --check
git diff --check
```

Linux Clippy uses the same pinned flags with `i686-unknown-linux-gnu` and the separate
`target/linux-continuation` build directory. Local raw evidence is in ignored `tmp/lifecycle-ipc/`:
process logs, source hashes, deliberate failure logs, timeout timing, pressure/isolation samples and
paired-contract comparison. No production Rust code remains altered by the experiments.

## Paired game prerequisite

The registered `dogmos` game worktree is at `39e05dec05938972148414074b68386eea83ff3e`. Its installed contract
passed the maintained `verify_contract.py verify-installed` check, but pins native revision
`46209bccd3703d38db0efedabeebf0f79e950234`. The native checkout is at
`31a96c42f284519d80cb04a22f40a05e94bf1dbf` with uncommitted edits. Both current Windows artifact hashes differ
from the installed contract. Running the older installed pair would not qualify these changes.

The native release generator rejects dirty source. The game's maintained `sync_contract.ps1` also
requires a clean source repository and exact revision, and RIFT requires overlay hashes to match
the verified installed pair. There is no supported dirty-development override in those entry points.
No game files were changed during this inspection.

The next integration step requires an explicitly approved commit scope and permission to update
protected game artifacts. The working tree also contains edits that predate this follow-up, including
diffusion publication changes; they must not silently enter a commit. The complete synchronization
would update these game files through the generator/synchronizer, without hand-editing them:

- `dogmos.dll`, `dogmosd.exe`, `libdogmos.so`, `dogmosd`;
- `code/__DEFINES/dogmos_bindings.dm`, `code/__DEFINES/dogmos_contract.dm`;
- `dogmos.lock.json`.

After choosing the commit scope and producing a clean revision, rebuild both platform pairs with
that revision, generate and verify the release bundle, synchronize it, then run the maintained RIFT
compile, focused/full test and soak gates. Live performance acceptance still needs at least three
matched controls and candidates with independent DreamDaemon/service measurements. Changes remain
uncommitted; this document does not claim whole-repository completion.
