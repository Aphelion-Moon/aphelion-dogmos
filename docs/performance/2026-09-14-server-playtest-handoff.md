# Dogmos server playtest handoff

Status update after the interactive local playtest: movement remained responsive, but atmosphere progress and fire behavior failed operator acceptance. The [playtest investigation](2026-09-14-interactive-playtest.md) records a reproduced MC scheduling defect and a separate gas/fire timing investigation. Its incremental scheduler correction passed all 673 DM tests and a separate three-minute async progress check; it is not included in the archived ZIP below. Keep asynchronous mode disabled in ordinary configuration until controlled performance and fire behavior are accepted.

The archived candidate below previously passed local qualification: the native pair, eighteen focused DM tests, all 670 full-suite tests, an async progress observation and the 300-second soak had zero runtimes. Those results apply to that candidate and do not establish interactive performance acceptance or qualify later changes. No release or live deployment has been performed.

## Candidate and rollback

- Native source: `master` base `6b6321b2c4a0658933b7529e1d732acfac9cc5a4`, with the exact uncommitted candidate archived in `target/r6-local-qualification-05/source.zip`.
- Matching native pair, symbols, generated bindings and manifest: `target/r6-local-qualification-05/bundle/`.
- Protocol 16 / ABI 2; fingerprint `2950234a5e53e82ce5e19f3ae303a9308d6a2ae17e44498aa9f8ec9786590421`.
- Matching cumulative R1/R2/R5 DM source, opt-in observer and frontier correction: [patch](../patches/2026-09-14-meridian-frontier-candidate.patch), based on the isolated Meridian-Rift checkout at `1604655c7fa4d5e2e4c466132acb2ae64bb389b3`. Its twelve-file archive is `target/r6-frontier-candidate-dm-source.zip`, SHA-256 `640e5ac8acc575e3244a31ba259e8a5843a0c331ab31e4373f175a647dbc5559`. Review integration against the server's actual checkout before building. The generated defines and lock belong to the complete native artifact set and must come from maintained synchronization.
- Exact prior seven-file local installation: `target/r6-protocol16-before-noeffect-rollback/`, verified before replacement. A server rollback also needs that server's previous compiled game and deployment configuration.

Use the maintained synchronizer and installed-contract verifier, then create the server DMB through `BUILD.cmd` from the reviewed matching source. The source archives, [native evidence](2026-09-14-effect-free-component-evidence.json) and [frontier qualification](2026-09-14-frontier-upload-evidence.json) retain the qualified identities when later documentation changes occur. Files remain uncommitted.

## Profiler entry point

Local qualification keeps the modes separate:

| Gate | Game mode | Current result |
| --- | --- | --- |
| Four-target native matrix and paired artifacts | Protocol 16 bundle 05 | Passed; see native evidence |
| Eighteen focused DM tests | Ordinary mode plus explicit async fixtures | Passed, zero runtimes |
| Full DM suite | Async disabled | 670 passed, zero runtimes |
| Three-minute gameplay observation | Async enabled | Passed; 52 completed cycles, 421 completed jobs |
| Full-build boot and 300-second soak | Async enabled | Passed; zero errors/warnings/runtimes, clean owned cleanup |
| Profiler CheckOnly | No game attachment | Passed locally |
| Populated server playtest and matched performance | Controlled cohorts | Not run |

Use the existing `dogmos-server-profiler-20260910.zip`, SHA-256 `97ea4ab44c475348b025587be8f0b3db284307382cd913292daf1a8db3416e15`. Extract it on the Windows game server. The `START_CAPTURE.cmd` launcher selects Windows PowerShell 5.1 and its built-in modules.

Before arming, run the packaged `Start-DogmosCapture.ps1` with `-GameDirectory <deployment directory> -CheckOnly`. It verifies the collector bundle and the deployed DMB/native-pair inputs. Local CheckOnly passed against the archived pair. A subsequent local Tracy launch failed with native exception `0xc0000409`; its cause remains unconfirmed. The successful interactive session used built-in BYOND profiling. Portable Tracy live acceptance remains open; CheckOnly is not live attachment proof.

For the authorized controlled server test, run `START_CAPTURE.cmd` as administrator and supply the deployment directory and the DreamDaemon executable selected by TGS. The normal operator flow arms a capture for the next round and waits; the operator controls the restart. Retain the complete output directory, including deployment identities, launch/capture metadata, traces and separate DreamDaemon/service resource samples. No capture is currently armed by this work.

## Acceptance sequence

1. Collect a server control with asynchronous stages disabled. Record the actual game revision, artifact identity, BYOND version, map, seed, configuration, database availability, population and relevant activity.
2. Select `DOGMOS_ASYNC_STAGES` only for a controlled candidate restart using the matching compiled game and native pair. Keep the same quantum, work cap, workload, map and instrumentation. Do not toggle mode during a round.
3. Exercise machinery and pipenets, breaches, connected gas/heat changes, reaction callbacks, turf replacement and recovery. Check gas/event outcomes and completed atmosphere cycles as well as frame and blocking durations. A smoother game with stalled atmosphere progress fails acceptance.
4. Preserve R1, R2 and async comparisons as separate cohorts with at least three matched repetitions each. The existing R0 phase document is not yet an executable five-phase scenario runner; do not label ad-hoc play or the local sampler as that workload.
5. Return the full profiler output and operator notes. Review initialization and steady-state results separately, including [the library/database diagnostic](2026-09-14-startup-observation.md). Startup overlap and build-time preparation decisions should follow the server's actual critical path.

The corrected source completed 52 atmosphere cycles and 421 native stage jobs during its three-minute async observation, with zero runtimes or publication retries. This passes functional progress acceptance; it is not a matched benchmark or populated-server acceptance. Linux library/service builds and tests pass, but actual Linux BYOND loading remains unrun because no local engine was found.
