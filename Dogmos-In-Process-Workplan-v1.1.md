# Dogmos in-process restoration and optimization workplan

**Version:** 1.1 — consolidated final handoff  
**Prepared:** 19 September 2026  
**Updated:** 19 September 2026  
**Repositories:** `Aphelion-Moon/aphelion-dogmos` and `Aphelion-Moon/Meridian-Rift`  
**Initial qualification platform:** Windows on WUFF  
**Status:** Implementation handoff. Preparing this document does not execute changes, qualify a build, authorize publication, or authorize production operations.

## Revision record

This consolidated v1.1 supersedes v1.0 for execution. It incorporates the agreed review amendments directly into the existing phases, acceptance rules, tests and handoff records; a separate addendum is not required. The production objective and P00–P09 sequence are unchanged. No additional architecture or exploratory workstream is introduced.

| Amendment | Integrated location |
| --- | --- |
| Align conflicting architectural instructions before implementation | Section 3; P00/P02; G0/G1 |
| Isolate test persistence and external effects | Section 3; P00/P02; T16 |
| Define concurrent state visibility and effect publication | Section 5.1; P01/P04–P06; T17 |
| Cover abrupt process failure and hangs, not only returned errors | Section 5.2; P06/P09; T18 |
| Qualify the exact release artifacts under the intended launch arrangement | Sections 6.3 and 6.5; P02/P07–P09; T19 |
| Separate resource requirements, uncertainty and safety limits | Sections 6.1/6.4; P03; T12 |
| Reserve final-validation cases and test the runner's rejection logic | Section 7; P03/P07; T20 |
| Retain maintained regression gates and explicit requalification triggers | Section 10; P08; T21 |

Historical evidence and review anchors are carried forward from v1.0, not represented as newly executed benchmarks or fresh repository inspections. New implementation requirements come from the agreed review; additional primary documentation supports only the specific runtime and loader cautions identified in the sources.

## 1. Decision and requirements

Build a production-ready **32-bit, in-process Dogmos backend**. Start from the retained implementation, preserve Dogmos's intentional mechanics, and rewrite components where evidence shows that is necessary. The external 64-bit service is no longer the intended production destination for this work.

**Dogmos defines correct behaviour. LINDA defines the resource-performance comparison.** Do not turn Dogmos back into LINDA to obtain a favourable benchmark.

The following requirements come from the maintainer's decisions in this conversation, not from the historical service roadmap.

| Area | Agreed requirement |
| --- | --- |
| Behaviour | Preserve special Dogmos behaviours and its independence from LINDA/upstream. Repair defects without silently erasing intentional differences. |
| Architecture | Native 32-bit code inside DreamDaemon. Rewrites are permitted; another external simulation service is out of scope. |
| Workload | Full Icebox, 60 active players, three-hour shifts. Include credible severe incidents approaching approximately 10,000 active turfs. |
| Memory | Meet or beat LINDA's realistic-shift memory use and preserve resource headroom. Any demonstrated saving is useful; there is no arbitrary percentage improvement target. |
| Processing | Beat LINDA on end-to-end atmosphere processing under representative gameplay. Memory is the higher priority, but a memory-only win does not finish the processing objective. |
| Initial release | Windows on WUFF. Linux runtime/performance qualification is not a prerequisite for this release. Do not gratuitously break existing portability. |
| Change scope | Rewrite anything necessary within the task. This is permission, not an instruction to replace working components or restructure unrelated systems. |

Correctness and safe operation are prerequisites. Among correct candidates, prioritize memory/headroom, then processing improvements, while retaining startup and responsiveness safeguards. Never trade a correctness failure for a resource saving.

## 2. Evidence and its limits

The supplied `performance-memory-decision.md` is an interim storage/interface study: 12 accepted runs, two fresh-process repetitions per engine/density, rather than its planned three. It used full MetaStation and historical game revisions, not the newly specified Icebox production workload. [S1, lines 3, 101–106]

Its results justify investigating in-process Dogmos; they do not already qualify it:

| Historical observation | Implication for this plan |
| --- | --- |
| Ordinary-map DreamDaemon private-memory medians: LINDA 2,411.6 MiB; legacy 2,663.2 MiB; service 2,417.9 MiB. Historical content drift limits attribution. | Establish a same-content baseline before attributing the difference to the backend. Do not assume legacy already saves whole-process memory. |
| Historical legacy counters identify roughly 126 MiB of preallocated native arena floor. | Account for live data, capacity, address reservation and actual committed pages before selecting a storage repair. This is not proof that all 126 MiB is recoverable. |
| Legacy and service both completed the million-mixture dense storage fixture; LINDA reached its configured guard earlier. | Compact native storage is promising without requiring the service. This is capacity evidence, not realistic active-simulation evidence. |
| For one million two-gas mixtures, allocation medians were 3.3 s / 5.1 s / 41.7 s for LINDA / legacy / service; mutation/readback medians were 3.1 s / 6.5 s / 79.9 s. | Removing service IPC is not enough to prove superiority over LINDA. Measure and optimize the remaining DM/native interface. |
| Master processing was paused for the storage/interface measurements. | Do not call those numbers atmosphere throughput or player-visible lag results. |
| Release/reuse checks passed, but the study does not establish long-duration leak freedom; some historical legacy starts failed before successful unchanged retries. | Preserve failures in the record and qualify startup, teardown, and sustained activity explicitly. |

Source: [S1, lines 16, 30–46, 57–66, 95, 103–106]. Historical large-mixture fixtures remain diagnostic tools, not release-decision workloads. The old 70% Dogmos-attributable memory and 32 MiB shim targets belong to the service design and must not be copied into the in-process acceptance contract. [S1, line 97]

### Source anchors carried forward from the v1.0 review

| Repository | Remote reference observed | Commit |
| --- | --- | --- |
| Native Dogmos | `master` | `fc70f567a9c8131184460052c135210775f10ab8` |
| Meridian-Rift | `dogmos` | `061bb6fb0bbfaa532896210c37430b19b41a0975` |

These are review anchors, **not instructions to reset the user's checkout**. Local work, later commits and locally qualified artifacts may differ. P00 must establish the actual implementation inputs. The observed references do not identify a production deployment or a qualified return-to-legacy pair. [S2]

The decision report names `optimization-workplan.md`, `consultation-questions.md`, `temporary-adjustments.md`, `protocol.md`, `verification.json`, frozen inputs, cohort definitions and runner scripts. The v1.0 review recorded those companion documents as unavailable and did not locate them among the supplied ZIP's file names. Their contents have not been reviewed in this revision. Retrieve them from the original archive when executing P00. Record anything unavailable; do not infer its contents. [S1, line 112]

## 3. Scope, authority and operating boundaries

This document specifies future work. Implementation, repository writes and test execution require the applicable task authorization. Commits, pushes, releases, production deployment, production restarts and infrastructure changes remain separately controlled. Do not interpret this plan as permission to alter the live server.

Work in explicitly authorized, isolated checkouts. Preserve unrelated changes and the active branch. Read both repositories' `AGENTS.md` and scoped guidance before editing; do not reset, clean, switch or merge an existing checkout to make the plan easier to execute. Use one writer per worktree. Keep the handoff resumable without requiring any particular agent orchestration framework. [S3, S4]

**Align authority early.** During P00, record the maintainer's in-process decision and identify directly conflicting service-era instructions. Update those instructions in the authorized working copies before the affected implementation begins; complete backend-specific tooling alignment in P02. Do not wait until P08 to correct instructions that require growing state to live outside DreamDaemon. Preserve their applicability to the archived service path, and retain unrelated safety, review and generated-artifact rules. The maintained decision must state: in-process Dogmos is the production target for this work; service-only ownership, artifact and performance requirements apply only to the preserved service implementation. This is a targeted documented amendment, not a general waiver of repository instructions.

Preserve the external-service sources, exact artifacts, generated contracts and evidence. Archive the implementation rather than deleting it wholesale. No continuing service optimization or repeated service benchmark campaign is required for this work. Do not remove shared core mathematics, test fixtures or support crates merely because the service used them.

Use the existing central archives:

- Native evidence: `GitHub/.agent_docs/aphelion-dogmos/`.
- Game-integration evidence: `GitHub/.agent_docs/meridian-rift/dogmos/`.

Create a cross-referenced run directory under each as needed, not a new `.agent_docs` tree inside a repository. Keep maintained workloads, source documentation and required shipped artifacts with their code. Registered worktrees must be moved using Git-aware tooling. [S3, S4]

WUFF is shared. Inventory current services and load without interfering with them. Test processes, collectors and temporary files need explicit ownership. Identify processes by PID **and creation time**; do not reuse a historical PID from a report or terminate processes by image name. Do not change host-wide affinity, priority, power, antivirus, database or TGS settings as an optimization shortcut. [S1, line 107; proposed operating safeguards]

**Isolate persistence and external effects.** Before any test world starts, record a test-environment manifest covering database access, credentials, save and round-persistence directories, configured outbound integrations, collectors and cleanup ownership. Test instances must not write production data or send production announcements, webhooks or other external effects. Use isolated data and destinations for capabilities required by the workload; otherwise disable or redirect them explicitly. Do not copy production secrets into evidence or fixtures. Any authorized copy of data must follow its existing access and sanitization rules.

Use equivalent test integration configuration and availability for LINDA and Dogmos. Disabled features, stubbed responses and residual differences belong in the run manifest; do not compare a healthy database cohort with one repeatedly timing out. Before representative or populated tests, prove with harmless test writes/events that enabled integrations reach only designated test destinations. Apply this isolation to startup tests, fault injection, launch rehearsals and rollback rehearsals as well as benchmarks. Production activation is a separate boundary in P09.

## 4. Intended ownership and compatibility

This is the target ownership model, not a mandatory new crate layout.

| Owner | Responsibility |
| --- | --- |
| DM/game integration | Live objects and identity, public gas-mixture API, subsystem cadence, machinery/pipenets, player/admin policy, atom movement, presentation and gameplay effects. |
| In-process native engine | Authoritative compact numerical state, native mixture/reaction work, atmosphere graphs, FDM/Katmos/TurfHeat processing, bounded scratch storage and workers. |
| Native/DM boundary | Validated conversions, compatible public calls, lifetime checks, bounded main-thread effect delivery, caller-legible errors and diagnostics. |
| Build and qualification tooling | Explicit backend selection, exact artifact identity, deterministic binding generation, reproducible tests and evidence capture. |

Preserve one authoritative numerical store. Do not retain service-only caches, mirrored worlds or protocol state without a demonstrated in-process need. Necessary archival/staging buffers are permitted only with a documented consistency purpose and a measured memory cost.

The retained root `dogmos` package already depends on shared `dogmos-core` and `dogmos-perf`, and its selected default features include turf processing, Katmos, superconductivity, slow decompression and Aphelion reactions. Reuse appropriate parts; do not assume all shared core code requires a service. Freeze the actual production feature selection in P01/P02 rather than silently relying on mutable defaults. [S5]

Keep public DM proc paths and caller-visible errors compatible unless a deliberate, reviewed migration includes every caller. Apply the existing narrow fork-owned exception to gas-mixture/environmental code; it does not authorize bulk rewrites of unrelated machinery, UI or inherited modules. Follow `APHELION EDIT` and existing `NOVA EDIT` placement rules. [S4, S6]

## 5. Behaviour contract

P01 must turn documented intent and reviewed implementation into a testable contract before optimization changes are accepted.

Inventory FDM diffusion, Katmos/equalization and slow decompression, TurfHeat, planetary atmospherics, gas chemistry and reaction priority, native versus DM reaction effects, firelock/pressure interactions, visual updates, gas-mixture mutators and all public consumers. Include all production gases and reaction families. An empty-reaction benchmark cannot stand in for reaction qualification.

For each behaviour, record: owner, source anchor, intended rule, deliberate LINDA difference, observable effect, independent test, numerical tolerance and unresolved cases. Classify historical differences as **intentional**, **confirmed defect**, or **unresolved**. A historical output is not automatically correct because the old engine produced it. Isolate unresolved cases and seek a focused maintainer decision only where the sources cannot establish intent; continue unrelated work.

The reviewed numerical guide provides concrete starting rules: finite external values; non-negative moles/volume; immutable-mixture protection; existing temperature bounds; conservation within named tolerances; reciprocal, duplicate-free, self-edge-free topology with cardinal degree at most six including multiz; explicit elapsed-time heat processing; and stable gameplay coefficients. It also specifies a deliberate trace sink: 0.0001-mole transfer arithmetic, positive per-gas results below 0.01 mole canonicalized to zero at commit, and exactly 0.01 retained. Verify these rules against the selected legacy path and its history before encoding them as its accepted contract; document any conflict instead of silently importing service behaviour. [S7]

Do not optimize by reducing simulated time, changing diffusion coefficients, shortening reaction inventories, increasing sleep thresholds without proof, dropping effects, disabling heat/equalization or changing the relaxation-iteration budget. For approved bug fixes, add an independently reasoned failing test first and retain the reason for changing prior output.

### 5.1 Concurrent state visibility and effect publication

For each asynchronous or reentrant operation, specify when numerical inputs are read, which state a public caller may observe, when mutations become authoritative, how intervening changes invalidate pending work, and when associated gameplay effects may be delivered. Include multi-mixture operations and ordering between numerical changes and callbacks. Record this in `behaviour-contract.md` before changing storage or scheduling.

The mechanism is an implementation choice. A simple lock or scheduling rule is acceptable when correct and within budget; this requirement does not mandate the service's transactions, snapshots, receipts or protocol. Prevent lost updates, half-applied transfers, stale results overwriting newer state, duplicate effects, and effects delivered against an invalid state or target. Define supported callback reentrancy and lock ordering so the main thread cannot wait for a worker that is itself waiting for a main-thread callback.

Use controlled interleavings: machinery writes after a worker reads but before it applies results; a two-mixture transfer overlaps pending work; a reaction callback re-enters gas operations; and a turf or identity slot is replaced before an effect is delivered. Specify the expected coherent outcome independently of the implementation. Preserve these tests across P04/P05 rewrites.

### 5.2 Native failure boundaries and containment

Native workers must not make unsafe BYOND calls or use stale live-object references. Retain main-thread dispatch and validated lifetimes. Catch unwinding panics at exported boundaries and do not let them cross the FFI boundary; this does not make memory corruption recoverable or give an in-process DLL process isolation. On a detected fatal inconsistency while the process remains responsive, stop admitting unsafe simulation work and use the approved whole-world shutdown path. [S6, S8; in-process adaptation]

Distinguish returned operation errors, caught unwinding panics, and process-aborting or unresponsive failures. Rust's `catch_unwind` does not catch an aborting panic; the documented default allocation-error handler for a binary linked to `std` aborts. Verify the actual pinned toolchain/build behaviour rather than assuming every native failure returns a DM-visible error. [S13]

Use isolated tests to establish containment for abrupt termination and an unresponsive owned test process. Record the existing supervisor/operator responsible for detection, bounded evidence retention, termination and any approved restart. Test fallible allocation paths separately for valid state and correct admission/rejection after failure. Do not exhaust WUFF globally or corrupt production memory to trigger a failure. Diagnostic fault-injection builds are separate evidence, not the production performance candidate.

The required outcome is detection and safe containment, not transparent mid-round recovery. Never silently continue with missing effects, reconstruct an empty authoritative atmosphere, hot-switch backends, or introduce a new orchestration service for this work.

## 6. Acceptance contract

Freeze metrics, workload weighting, numerical tolerances, contamination rules and analysis procedures **before** comparing optimization candidates. The nominal resource requirement is no regression; a measurement uncertainty band is not permission to spend more resources.

### 6.1 Memory and headroom — release gate

Measure the whole DreamDaemon process at safe playable readiness, settled baseline, each workload phase, observed peak, post-incident settling, end of shift and cleanup. Record private commit, working set, reserved/committed virtual regions, total free address space, largest free region, allocation failures and native live/capacity counters. Report sampling interval and both sampled peaks and available OS lifetime peak counters; do not label a sampled maximum as a guaranteed instantaneous maximum.

Pass requires meeting or beating LINDA on representative settled/peak/post-incident memory and preserving comparable free-address and contiguous-allocation headroom, with no unexplained ongoing growth, guard trips or allocation failures. Lower average private bytes cannot compensate for materially worse peak or contiguous headroom. Attribute atmosphere storage separately for diagnosis, but use **whole-process** outcomes for acceptance.

Check the actual DreamDaemon executable architecture, address-space configuration and loaded modules. A virtual-region scan must use that process's address range, not the 64-bit host's free space. Private commit and resident working set are different measurements; report them separately. [S9, S10, S11]

Set operational abort limits and required transient-allocation headroom from the actual executable configuration, observed phase demands and WUFF's shared-host constraints. Record numeric limits, sampling lag/possible overshoot, actions and authority before heavy testing. The historical 3,300 MiB private-memory / 128 MiB largest-free-region guards were fixture stop conditions, not universal production limits; do not reuse them automatically. [S1, lines 40–46] Parity with a LINDA run that itself breaches the agreed safe operating envelope is not evidence of safe operation.

### 6.2 Processing — independent release objective

Predeclare an end-to-end primary processing statistic over a fixed representative workload mix, using complete atmosphere-cycle latency and atmosphere CPU per simulated second as the principal measurements. Publish phase-specific values as well as the aggregate. Include native workers, main-thread integration, machinery calls and callback delivery; do not count a worker's early return as completed atmospheric work.

A processing win requires a repeatable improvement in the predeclared end-to-end statistic, without sustained simulation backlog or material regressions in total CPU, ordinary-load performance, cycle completion, callback age or p95/p99 game-tick responsiveness. An individual getter need not beat LINDA; the actual representative workload must. Do not use a tiny improvement in one microbenchmark to claim success for the whole engine.

For each run record simulated time completed, wall time, cycle count/age, pending work, reaction/effect progress and active-versus-scanned populations. Faster wall time obtained by processing fewer simulated seconds or omitting effects fails.

### 6.3 Startup, reliability and maintenance

Measure process start to genuinely safe playable readiness, including required atmosphere readiness. Report loading phases and database availability separately. Do not hide initialization by moving unfinished work after a readiness marker. Require no material regression against the matched LINDA startup cohort under the frozen analysis rules.

The candidate must pass correctness, native-load, focused DM, complete applicable DM-suite, repeated clean startup/shutdown and sustained-load gates. Record all attempts and failures; unchanged successful retries do not erase failures. Existing unrelated failures require an exact baseline and impact assessment, not a blanket waiver.

Release packaging must be reproducible and unambiguous. No service executable, IPC session or service manifest may be required to run the selected in-process engine. Final performance, endurance and launch evidence must identify the exact runnable release candidate under section 6.5. A developer-shell boot does not replace the isolated Windows/TGS launch rehearsal.

### 6.4 Interpreting results

Use at least three independent fresh-process controls and three candidates for controlled comparative workloads, alternating or counterbalancing order. Three is a minimum, not automatic statistical adequacy. Estimate repeatability using control-versus-control runs. Analyze independent run/block results; thousands of tick samples from one run are not thousands of independent experiments. [S9; proposed analysis detail]

Keep three quantities separate in `acceptance-contract.json`:

| Quantity | Interpretation |
| --- | --- |
| Resource requirement | Memory/headroom must meet or beat LINDA; processing must satisfy the independent improvement objective. No automatic percentage regression allowance is granted. |
| Measurement uncertainty | Estimated from independent controls and run/block variation. It limits what the experiment can establish; it cannot relax the resource requirement. |
| Operational safety limits | Predeclared abort/headroom limits and responses, independently required even when LINDA also approaches them. |

Use the result states **improved**, **equivalent within calibrated resolution**, **regressed**, **inconclusive**, and **not tested**. Publish raw paired values, absolute differences, percentages and uncertainty. Failure to detect a difference is not proof of equivalence. Predeclare the method and resolution needed to substantiate parity before examining candidates; control repeatability determines whether that resolution is achievable, not how much regression may be accepted. An equivalence verdict needs affirmative support under that method, not merely a non-significant difference. Do not enlarge the acceptance band when WUFF is noisy or conceal a consistent directional loss of headroom. When resolution is inadequate, obtain cleaner/repeated evidence within budget or report inconclusive.

A speed-only win with worse memory fails. A memory win with speed parity is a useful milestone but leaves the agreed speed objective open. A noisy apparent win is inconclusive. Do not silently weaken requirements or authorize release when test budget runs out; stop with a bounded evidence report.

### 6.5 Exact release-candidate identity and launch rehearsal

Before final performance, endurance and launch qualification in P07, freeze the DLL, compiled game, generated bindings/defines, features, toolchain/build settings and relevant runtime configuration. Record their hashes and compatibility identities. Complete executable-changing release preparation before this freeze. Promote that runnable set through P08/P09 without rebuilding it. Packaging-only changes may reuse evidence only after confirming unchanged runnable contents and configuration.

The manifest distinguishes frozen behaviour-affecting settings from declared environment bindings: test versus production data destinations, credential references, ports and paths. Rehearsals retain isolated bindings; the intended production mapping is reviewed before activation without publishing secrets. A declared environment substitution requires integration-impact review, not an unexplained change to simulation settings, features or diagnostics.

A rebuilt, regenerated or behaviourally reconfigured candidate requires a recorded impact assessment and rerunning affected gates. Changed executable behaviour cannot automatically inherit performance or endurance evidence. Reproducibility builds may check for byte identity, but do not silently substitute their outputs for the qualified set. Diagnostic/test-only binaries and fault hooks remain separately identified and cannot stand in for production performance; never silently ship a debug/fault-injection configuration because it passed a functional test.

Rehearse the frozen candidate in an isolated Windows/TGS instance using the intended production launch arrangement: account/security context, working directory, environment, permissions, native dependencies and instance settings. Preserve the test-data/outbound-effect isolation in section 3. Record deliberate differences from production. Verify loaded module paths and identities as well as intended file paths. Windows resolves dependent DLLs using its documented search rules, so identifying the top-level DLL alone does not establish the identity of every dependency. [S14]

A successful rehearsal must establish correct backend/features, safe readiness, contained data/effects, expected stop/restart behaviour and correct loaded dependencies. It does not authorize altering the live TGS instance.

## 7. Qualification workloads

Use full Icebox and its normally loaded levels, content, machinery and configuration. Approximately 10,000 active turfs is a severe-test target, **not a hard engine cap** and not a reason to omit the rest of the loaded graph or freeze excess activity. Count loaded turfs, registered mixtures, scanned nodes and genuinely active work separately.

| Workload | Purpose and observations |
| --- | --- |
| W0 — Cold/warm startup and settled map | Readiness, registration costs, baseline memory, idle processing and actual native allocations. Keep cold/warm states separate. |
| W1 — Ordinary occupied shift | Movement, doors, breathing/life support, routine machinery, pipenets and gas access. Capture real activity distributions rather than equating connected clients with work. |
| W2 — Machinery-heavy activity | Pumps, vents, scrubbers, tanks and portable devices; simultaneous reads/writes and representative production gas mixtures. |
| W3 — Local breach/fire and recovery | Pressure effects, reaction work, heat, gas visuals, sleeping/waking and return to a stable state. |
| W4 — Credible severe incident | Approach 10,000 active turfs using a documented trigger and spatial pattern. Record the actual active count; do not force identical engine internal work by changing mechanics. |
| W5 — Topology and lifetime churn | Doors, destruction, construction, gas transfers, allocation/deletion, late map/shuttle changes where applicable, and repeated reuse. |
| W6 — Full three-hour shift | Sustained normal activity, bounded incidents, recovery and late-round headroom on Icebox. |

Use two complementary comparison modes. First, common numerical/API fixtures measure implementations performing equivalent defined operations. Second, matched initial conditions and player/script actions compare whole-engine costs while permitting intentional Dogmos/LINDA behavioural differences. Publish work and outcome differences; do not normalize away the real costs of Dogmos's chosen mechanics.

Development scripts approximate 60-player activity for repeatable testing. Label them **scripted workload**, not a completed 60-player test. Freeze measured activity rates and scene composition; do not invent a million-mixture substitute. Actual populated acceptance must include a three-hour Icebox observation targeting 60 active players, with population/activity recorded throughout. Report disconnects, low-population intervals and unavailable coverage rather than claiming full qualification.

Use 10,800 seconds of observed wall time for the three-hour endurance window and report simulation time separately, so slow simulation cannot shorten the exposure. Controlled reproducible runs support comparative resource claims; a populated candidate shift validates operational realism. Compare matched populated LINDA sessions where available and identify remaining population/workload confounding. A lone candidate playtest cannot prove comparative speed by itself.

Reserve a small final-validation set in P03 that is not used to tune the implementation. Keep it within Icebox's agreed operating range; vary seeds, incident placement/order and representative machinery/topology activity without creating a new scale target. Freeze identities, expected invariants, phase coverage and evaluation rules. Apply these held-out cases to both control and candidate during P07. If a case is inspected and used to guide changes, mark it as development evidence and refresh the reserved set before final acceptance; do not claim it remains held out.

Test the qualification runner itself before it is trusted. Feed it deliberately invalid result sets with missing phases, incomplete simulated progress, wrong artifact identity and early termination. Each must be rejected with a specific reason rather than marked complete because a wrapper returned zero. Verify the valid counterpart is accepted only when all required evidence is present.

Synthetic dense-storage extremes may remain opt-in capacity/correctness tests. They do not drive release acceptance and should not consume the primary optimization budget.

## 8. Phased implementation

The sequence below provides safe stopping points. Each phase records its exact inputs, diff, executed gates, failed attempts, measurements and next action. No phase is complete because code compiles alone.

### P00 — Preserve inputs and establish the working boundary

**Depends on:** implementation authorization.

Inventory both actual checkouts, dirty state, toolchain pins, Cargo lock, BYOND/TGS versions, current artifact sets and available evidence. Do not assume the remote review anchors or historical binaries are deployed. Preserve the complete service snapshot and the actual known-good production rollback set independently; neither is automatically the restored legacy candidate.

Locate the decision report's companion files and original raw measurements. Preserve hashes, cohort definitions, failed attempts and temporary adjustments. Read relevant native/game source-authority, numerical, FFI, integration, release and verification guidance. Record the in-process architecture decision in maintained guidance; amend directly conflicting service-only requirements in the authorized working copies before affected implementation begins. Keep service guidance explicitly scoped to its preserved implementation. Carry a conflict-resolution ledger into P02; do not postpone operative corrections to P08.

Prepare isolated work areas under the required authorization. Inventory WUFF's current load, test ports, paths and process ownership. Create the section 3 test-environment manifest and verify its isolation before starting any test world. Establish a bounded test budget and initial contamination/abort policy. Identify existing supervisor/operator authority for isolated failure tests. Heavy benchmarking and production changes are not part of inventory.

**Deliver:** source/artifact manifest, archive index, workspace plan, maintained architecture decision and instruction amendments, conflict-resolution ledger, test-environment manifest and operating safeguards.  
**Exit:** inputs and rollback evidence are recoverable; unrelated work is untouched; operative instructions support this architecture; test configuration cannot write production persistence or produce production external effects.

### P01 — Establish Dogmos's behaviour and failure contract

**Depends on:** P00.

Build the behaviour inventory described in section 5. Extract existing independent fixtures before refactoring. Record exact gas metadata, coefficients, reaction order, feature selection and simulation timing. Verify sparse/dense mixtures, fire chemistry, pressure effects, TurfHeat, planetary exchange, immutable mixtures, zero/infinite capacity cases and multiz boundaries where supported.

Turn known defects into failing regression tests. Do not automatically adopt either LINDA output or the service's latest output when it differs from intended Dogmos behaviour. Capture ambiguity in a small decision record with reproduction and impact.

Specify the section 5.1 read/mutation/publication contract, supported reentrancy, lock ordering, callback ordering and conflict outcomes. Add controlled-interleaving tests for machinery writes, multi-mixture transfers, reaction re-entry and replaced/reused targets. Map cancellation/shutdown and worker lifetimes. Distinguish recoverable errors, caught unwinding panics and unresponsive/aborting process failures under section 5.2; specify state validity and admission after each handled failure.

**Deliver:** maintained behaviour/publication/failure contract, feature manifest, independent fixtures and defect/ambiguity ledger.  
**Exit:** intended mechanics and concurrent interactions are testable; unresolved release-critical behaviour remains an explicit blocker rather than an invented answer.

### P02 — Restore a coherent in-process integration and build contract

**Depends on:** P00; feature/behaviour/publication inventory from P01.

Build the retained root `dogmos` implementation explicitly for `i686-pc-windows-msvc`. Restore its matching generated bindings and game-facing integration in the isolated candidate. Retain applicable modern correctness fixes instead of blindly restoring an old binary. Make the first restoration mechanical; measure it before optimization.

Inventory every service assumption in initialization, subsystem scheduling, gas wrappers, stage publication, snapshots, diagnostics, shutdown, artifact synchronization, RIFT profiles and release workflows. Remove or replace those assumptions for the in-process target and close directly relevant instruction conflicts from P00. Do not simply rename a shim, omit a service file from a paired manifest, or disable a validator until an incorrect bundle boots.

Add explicit in-process backend identity to the maintained artifact contract. Bind the engine kind, native/game revisions or content-addressed local snapshots, ABI/BYOND compatibility, exact features, generated bindings and binary hashes. Include production build settings and relevant runtime configuration in the reproducible input manifest. Test that wrong backend, wrong architecture, stale bindings and incompatible versions are rejected clearly. Local uncommitted test snapshots, diagnostic builds and release identities remain distinguishable.

Regenerate outputs through maintained tooling. Adapt that tooling and tests where it currently requires a service pair. A successful build must prove that the selected DLL owns the simulation and does not launch or require `dogmosd`. Establish a production-configuration build and launch recipe now; the final runnable set is frozen before P07's final acceptance measurements, not rebuilt in P08.

Construct a LINDA comparison build from the **same game-content base** using the smallest reviewed backend differences. Keep both test configurations reproducible, but do not introduce hot switching or a permanent production abstraction merely for benchmarking. Inventory unavoidable differences. Verify equivalent isolated database/integration availability and demonstrate that harmless fixture writes/outbound events reach only designated test destinations. Do not use production credentials for a launch smoke test.

**Deliver:** buildable in-process reference, same-content LINDA control, deterministic backend-specific validation, production build/launch recipe, native-load smoke and isolation evidence, restoration diff and resolved instruction conflicts.  
**Exit:** both worlds initialize correctly with intended features and contained effects; startup failures are understood; no mixed contract, hidden service dependency or conflicting operative instruction remains.

### P03 — Instrument and freeze the matched baseline

**Depends on:** P01, P02.

Reuse existing process/Tracy tooling and extend only missing observations. Normal telemetry should use bounded counters and high-water marks; expensive region walks, allocator scans and traces belong to diagnostic windows. Measure collector overhead and use equivalent instrumentation in both cohorts. [S9]

Record memory, worker/main-thread CPU, end-to-end stage/cycle timings, callback depth/age, loaded/scanned/active counts, allocations/capacity, gas reads/writes, reaction/effect counts and initialization phases. Separate overlapping worker and main-thread spans rather than adding inclusive durations and calling the result CPU time.

Validate workload triggers, completion markers, correctness checks, artifact attribution and cleanup first. Run the section 7 negative runner tests; an incomplete, mismatched or prematurely terminated run must not be accepted. Perform control-versus-control checks, then matched LINDA versus restored Dogmos measurements. Keep service reproduction optional and diagnostic; the new decision does not need another complete three-engine matrix.

Freeze the representative workload mix, numerical oracles, independent-run analysis method, evidence classifications and finite rerun budget before optimization candidates. Record the resource requirements, attainable measurement resolution and operational safety limits in separate fields. Derive abort limits and transient-allocation headroom from the actual process and workload rather than automatically adopting historical fixture guards. Noisy controls do not authorize larger resource regressions.

Reserve the small final-validation set of seeds/incident sequences and runner identities described in section 7. Establish a component-level memory account and a ranked end-to-end profile. The first decision is which measured costs obstruct memory parity and processing speed, not which rewrite is most attractive.

**Deliver:** frozen manifests and acceptance rules, reproducible development and reserved workloads, runner self-test evidence, initial matched report, memory ledger and ranked bottleneck list.  
**Exit:** invalid results are rejected; the experiment can detect relevant changes without relaxing the requirement; safety limits are explicit; baseline differences are attributable or bounded.

### P04 — Remove unnecessary in-process memory cost

**Depends on:** P03; P01 tests remain mandatory.

Account for mixture slots, unused arena capacity, gas vectors, gas/heat graphs, adjacency, identity/lookup data, per-worker scratch, staging/archival buffers, callback payloads, DM wrappers and service remnants. Reconcile native accounting with process observations; report unexplained differences rather than treating estimates as measured totals.

Profile the actual occupancy and gas-density distributions. Evaluate changes independently: map-sized or chunked growth instead of oversized eager capacity; compact metadata and indices; storage suited to ordinary sparse mixtures without pathological dense behaviour; reusable scratch with bounded retention; and removal of duplicate service-only state. These are hypotheses, not mandated structures.

Before moving storage, test stable identities, slot reuse, index-width/overflow, relocation, references held by workers and callbacks, partial allocation failure, and the section 5.1 publication/conflict rules. Avoid replacing a fixed floor with large growth spikes or persistent fragmentation. Test cold startup, steady state, peak incidents, settling and subsequent reuse.

Do not call allocator-retained capacity a leak without evidence; do not call it free merely because objects were retired. Tune release/retention policy against both headroom and repeated-allocation cost. Avoid forced trimming in hot paths just to improve a sampled memory number.

**Deliver:** individually measured memory changes and an updated accounting ledger, with cold/steady/peak costs.  
**Exit:** demonstrated memory improvement toward parity without correctness or responsiveness regressions. No guaranteed MiB saving is assumed.

### P05 — Improve complete atmosphere processing

**Depends on:** P03; normally apply after the highest-value P04 work.

Rank total atmosphere costs, including DM/native crossings, scalar access, conversions, FDM work selection, graph traversal, Katmos/equalization, TurfHeat, reaction lookup/execution, machinery integration, locks, workers and effects. Profile ordinary and severe workloads separately.

Reduce repeated boundary work where consumers demonstrably repeat it. Prefer coherent bulk operations at natural ownership boundaries over persistent world-sized caches. Any caching needs complete invalidation and controlled reentrant/concurrent mutation tests against section 5.1; an in-process call is not automatically cheap enough to ignore.

Evaluate scanned-versus-changed work. Change work selection only after proving wake-up and invalidation rules for neighbouring changes, temperature-only changes, machinery writes, planetary exchange, newly reactive mixtures and topology churn. Sleeping/deferred work cannot postpone mechanics contrary to P01.

Remove repeated allocation, redundant sorting/lookups, avoidable graph copies and unnecessary lock scope when profiles justify it. Benchmark small-work serial execution against parallel execution, tune bounded worker/scratch budgets on WUFF, and retain main-thread/other-service headroom. Do not enable all available workers or architecture-specific tuning solely because the host permits it.

Preserve simulation intervals, relaxation semantics, reaction ordering and pressure/heat behaviour. Keep independent candidate changes small enough to attribute gains and reversibly discard regressions. Recheck P04 memory gates after every speed-oriented cache, buffer or parallelism change.

**Deliver:** ranked, measured processing improvements with complete-work and memory evidence.  
**Exit:** progress toward or achievement of the section 6 processing objective, without using reduced simulation fidelity as a shortcut.

### P06 — Harden lifetime, error and shutdown behaviour

**Depends on:** P01/P02; revisit after every P04/P05 ownership change.

Test stale/reused identities, deletion while work is pending, map/unload changes, cancellation, worker panic and join, teardown/restart, reentrancy, malformed FFI values and critical-callback capacity pressure. Exercise the section 5.1 controlled interleavings. Retain bounded admission and visible fatal-state handling; do not lose writes/effects or deadlock while awaiting main-thread work.

Ensure ordinary callbacks remain timely, native workers do not outlive their state, shutdown clears owned references, and allocator/storage reuse cannot expose old state to new objects. Treat bounded critical queues as correctness mechanisms, not targets to raise until a stress test passes.

Test fallible allocation/operation failures for valid state and explicit admission/rejection. Separately test abrupt termination and an unresponsive owned instance under the section 3 isolation policy. Verify the designated existing supervisor/operator detects the condition, captures bounded evidence and follows the approved containment/stop/restart procedure without touching another instance. Do not depend on an in-process error handler running after an abort. Keep fault-injection builds distinct from the release candidate and exclude test-only fault hooks from its production configuration.

Repeat clean startups to investigate historical failure classes. Separate fixture/game-content faults from native faults without excluding either from the operational report. Preserve all attempts, including abrupt exits and watchdog interventions.

**Deliver:** regression and interleaving tests, recoverable/fatal fault matrix, isolated detector/containment evidence and reproducible fixes.  
**Exit:** no unresolved release-critical native/lifecycle/publication failure or unexplained retained state; both responsive and non-responsive failure procedures are demonstrated. Performance figures from defective or fault-injection builds remain exploratory.

### P07 — Freeze and qualify the release candidate

**Depends on:** P04–P06 candidate; frozen P03 contract.

Freeze the production runnable set under section 6.5 before final acceptance measurements: DLL, compiled game, generated files, features, build settings and relevant runtime configuration. Retain a release-candidate manifest with hashes and selected dependencies. Preliminary functional test builds and diagnostic builds are separately identified; they do not substitute for performance/endurance evidence from this exact runnable set. A change to executable behaviour sends the affected gates back to qualification rather than inheriting the old verdict.

Run the cheapest relevant test first: numerical/unit/property and interleaving checks, i686 build/static checks, generated-artifact checks, DM compile and focused integration, clean boot, then the full applicable game suite. Run short complete workloads before long endurance runs. A failed prerequisite stops expensive dependent tests, with artifacts retained.

Rehearse the frozen set in the isolated production-style Windows/TGS launch arrangement described in section 6.5. Verify actual loaded module paths/identities, account/environment/working-directory assumptions, safe readiness, stop/restart handling and data/outbound-effect isolation. Resolve failures before expensive acceptance runs; a developer-shell launch alone does not pass T19.

For promising candidates, complete repeated matched W0–W5 comparisons plus the reserved final-validation cases, then full W6 controlled three-hour endurance runs. Apply the section 6 independent-run minimum to comparisons used to claim improvement. Keep development and held-out evidence distinguishable; mark and replace cases used for further tuning. Do not declare three-hour qualification from a five-minute soak.

Only after those gates, conduct operator-coordinated populated acceptance targeting 60 active players for a three-hour Icebox shift using the frozen runnable set and isolated data/integrations. Record actual coverage and distinguish scripted evidence from human play. Collect operator/staff observations of pressure handling, fires, heat, overlays, breathing and machinery alongside telemetry.

Record test-source/build and runner hashes, exact commands, return codes, fresh artifacts, executed/ignored test counts, runtimes, warning signatures, termination reason and cleanup. A live process or a zero wrapper exit does not establish completion. A wrong artifact, missing phase, incomplete progress or early termination invalidates acceptance under the tested runner rules. Stop only owned test processes; never disturb production to make a run cleaner.

**Deliver:** frozen release-candidate manifest, qualification report and raw evidence, held-out results, production-launch rehearsal and all failures/untested scope.  
**Exit:** every required gate passes for the identified runnable set, or the candidate is explicitly blocked/inconclusive. Missing populated coverage cannot be relabelled a pass.

### P08 — Review and promote the qualified artifact set

**Depends on:** P07 for the frozen candidate.

Independently review behaviour/publication preservation, memory accounting, benchmark methodology, isolation, failure containment and maintainability. Review CI/build/generation tooling with the same care as native code. Confirm actual features, backend, loaded dependencies and evidence identities. Review findings that change executable behaviour return the candidate to affected qualification gates.

Complete the documentation alignment started in P00/P02. Maintain the in-process architecture, agent, build, deployment and performance guidance; leave archived service instructions explicitly historical/service-scoped. Verify no operative instruction still directs this project back to an external engine. This is the completion audit, not the first correction of conflicting requirements.

Promote the exact P07 Windows DLL, compiled game, bindings/defines, configuration and feature/ABI contract with its checksums and qualification record. Do not rebuild a different release candidate after qualification. Verify packaging leaves runnable contents unchanged. Install that set into an isolated clean target with stale service files absent; separately confirm wrong/stale artifacts are rejected. Linux runtime/performance qualification remains deferred, not falsely passed.

Wire the inexpensive regression, interleaving, public-API, binding, backend-selection and runner checks into the maintained workflow. Preserve affected shared-code tests. Publish the section 10 change-to-requalification rules and reproducible WUFF/three-hour test entry points; expensive runs need not execute on every edit. They must remain usable after this release, not exist only in an archive.

Prepare the tested activation/rollback runbook and remaining-limitations summary, including the supervisor/operator authority for an unresponsive or terminated instance. Keep source changes uncommitted unless separately authorized. Do not publish or activate automatically.

**Deliver:** unchanged qualified artifact set, review and documentation audit, maintained regression gates, requalification map, change manifest and activation/rollback runbook.  
**Exit:** hashes bind approval to what was tested; launch/restore procedures are demonstrated; safeguards survive release; technical qualification remains separate from deployment authorization.

### P09 — Controlled activation and post-release verification

**Depends on:** P08 and separate production authorization.

Record the live deployment and restorable configuration immediately before activation. Back up relevant artifacts/configuration and handle persistent data under its existing policy. Do not assume the historical service pair or a raw DLL is the correct rollback target. Record the intended production data/integration configuration explicitly; never accidentally activate a test database, test credentials or test announcement route. Confirm that differences from the isolated rehearsal are intentional and reviewed.

Activate the exact verified runnable set at an approved restart/round boundary. Verify hashes, loaded DLL/dependencies, backend/features, launch context, intended mechanics and monitoring. Never replace the active numerical backend mid-round or improvise live-state migration. An unreviewed rebuild or configuration change invalidates the assumption that the qualified set is being activated.

Monitor initial production shifts against the qualified envelope. Critical runtime errors, missing effects, stalls, sustained backlog, allocation failures, material headroom loss and unresponsive/terminated instances trigger the documented operator/supervisor response. Use the tested detection/containment procedure when no DM error handler can run; keep evidence bounded and never kill by image name. Emergency authority must be named before activation.

Roll back through a controlled restart into the complete known-good set. Do not replay stale atmosphere state, initialize an empty atmosphere in a running shift, or overwrite newer persistent player data. Preserve the failure and affected artifact identities for diagnosis.

**Deliver:** activation/identity record and initial production observations, or rollback record with preserved failure evidence.  
**Exit:** stable operation is demonstrated within the stated scope. Improvements outside that scope require new evidence, not extrapolation.

## 9. Required test coverage

| ID | Coverage | Minimum pass condition |
| --- | --- | --- |
| T01 | Gas-mixture math, finite/negative/immutable inputs | Independent numerical rules and documented error behaviour hold. |
| T02 | Trace thresholds and temperature/heat edge cases | Exact boundaries and intended sinks/sources preserved; no stale thermal activity. |
| T03 | FDM, topology, multiz | Valid connectivity, conservation/tolerances and intended iterations; invalid topology rejected. |
| T04 | Katmos/equalization and decompression | Intentional pressure/equalization behaviour and visible effects preserved. |
| T05 | Production chemistry and reaction priority | All selected gases/reactions present; ordering and native/DM outcomes correct. |
| T06 | TurfHeat and planetary exchange | Correct elapsed-time handling and intended boundaries; no repeated radiation or accidental omission. |
| T07 | Public DM API and machinery/living consumers | Gas reads/writes, transfers, breathing, pipelines and presentation remain compatible. |
| T08 | Lifetimes, slot reuse and reentrancy | No stale writes, old callbacks acting on new objects, or dead references; T17 supplies explicit concurrent publication cases. |
| T09 | Caught unwinding panic, fallible allocation/capacity failure and queue pressure | No FFI unwind, silent critical-effect loss, deadlock or unsafe continuation; abrupt/unresponsive failures are separately covered by T18. |
| T10 | Shutdown and repeated initialization | Workers and owned state end cleanly; failed starts remain visible. |
| T11 | Generated contract/native load | Wrong backend, bitness, hashes, ABI/features or bindings fail clearly; correct bundle boots. |
| T12 | Memory/address-space accounting and limits | Whole-process parity/improvement supported across phases; capacity explained; uncertainty does not relax requirements; operational safety limits also pass. |
| T13 | Processing/progress and responsiveness | End-to-end improvement, no hidden backlog or material latency/CPU regressions. |
| T14 | Three-hour endurance and populated Icebox | W6 completed; real population/activity and unmet coverage accurately reported. |
| T15 | Full integration and rollback | Applicable game suite assessed; complete restore verified in isolation. |
| T16 | Persistence and outbound-effect isolation | Test writes/events reach only designated test destinations; equivalent cohort configuration and cleanup verified. |
| T17 | Concurrent state visibility and effect publication | Controlled interleavings preserve coherent state, transfers and ordered effects; no lost update, stale overwrite, duplicate effect or reentrant deadlock. |
| T18 | Abrupt termination and unresponsive process | Existing detector/operator contains the correct owned instance, retains bounded evidence and follows approved stop/restart policy without relying on DM error handling. |
| T19 | Frozen runnable identity and Windows/TGS launch | Final performance/endurance artifacts equal promoted artifacts; actual module identities, launch context, readiness and isolation pass in the production-style rehearsal. |
| T20 | Reserved cases and qualification-runner rejection | Held-out cases pass within the agreed workload range; missing phases, incomplete progress, wrong artifacts and early termination are rejected. |
| T21 | Maintained regression gates and requalification | New inexpensive checks run through the maintained workflow; long-run commands, change triggers and evidence invalidation rules remain reproducible. |

## 10. Execution conventions and source navigation

Use the repositories' pinned toolchain and locked dependencies. Explicitly select the native root package and Windows target; an unqualified workspace/host build is not a release selection. The initial root defaults are visible in `Cargo.toml`; the generator and verification routes must be reconciled with P02 before copying old service commands. [S3, S5, S8, S11]

The following are **command shapes for the execution manifest**, not commands run during preparation and not a complete gate script:

```powershell
# Run in the authorized native checkout, using its verified pinned toolchain.
cargo fmt --all -- --check
cargo clippy -p dogmos --locked --target i686-pc-windows-msvc --all-targets -- -D warnings
cargo test -p dogmos --locked --target i686-pc-windows-msvc
cargo build -p dogmos --lib --release --locked --target i686-pc-windows-msvc
```

These shapes initially use default features. Replace that implicit selection with the recorded feature selection where required; do not copy commands that accidentally omit production reactions. Stop on each nonzero exit status. The implementation's verified wrapper must record and check exits explicitly. Run the affected shared-package and supported-feature tests too; do not mistake `-p dogmos` for coverage of every dependency or use intentionally invalid `--all-features` combinations. Cargo's package/target and lock options are documented upstream. [S12]

For DM work, parse the **actual candidate environment** with Meridian-MCP before symbol/reference analysis and reparse after changes. Use maintained PowerShell/RIFT DreamMaker and DreamDaemon gates. Update service-dependent profiles to an explicit in-process contract rather than inventing unimplemented command flags. Emit the exact verified commands in `command-manifest.json`. Do not run bare compiler invocations and call that production qualification. [S4, S11]

Start navigation at the native root `Cargo.toml`, `src/turfs/processing.rs`, `src/turfs/superconduct.rs`, `crates/auxcallback/src/lib.rs`, and their callers/owners; and at the game gas-mixture/environmental implementation, `modular_aphelion/modules/dogmos`, SSair consumers and native-artifact tooling. Revalidate all paths, symbols and owners in P00. No line-number patch instructions from historical plans are authoritative for the new checkout.

Keep code human-maintainable: cohesive responsibilities, explicit state lifetime, comments explaining invariants and surprising costs, and tests located with the behaviour they protect. Avoid broad renaming, universal backend abstractions, singleton removal for its own sake or unrelated upstream cleanup. Rewrites must have a measured purpose and a reversible integration point.

### Maintained regression checks and requalification

Add inexpensive new correctness, interleaving, public-API, binding, backend and runner self-tests to the normal relevant build/CI workflow as they are developed; P08 verifies their persistence. Keep long WUFF and three-hour entry points maintained and operator-controlled. Archive their results, not the only runnable copy of the test.

Use the following change categories to determine affected gates. Record an impact assessment; this table is not permission to claim unchanged performance after an unassessed rebuild.

| Change category | Required requalification focus |
| --- | --- |
| Storage, allocator, retention, cache or identity layout | Numerical/lifetime/publication tests, whole-process memory, relevant processing comparisons and three-hour retention/endurance. |
| Scheduling, workers, locking, callback or publication order | Controlled interleavings, effects/progress, responsiveness, total CPU, scratch memory, fatal/normal shutdown and representative endurance. |
| Reaction, FDM, Katmos, TurfHeat or gameplay-boundary behaviour | Behaviour contract/oracles and explicit intentional-change review where needed; relevant workload, effect, resource and endurance coverage. |
| Native/game build settings, toolchain, ABI, dependencies, generated bindings or executable-changing configuration | New runnable identity; load/contract and Windows/TGS rehearsal; affected correctness and production-configuration performance/endurance gates. |
| Runner, acceptance analysis or telemetry | Negative/positive runner self-tests, overhead/equivalence checks, reanalysis only from sufficient raw evidence, and reruns when data collection or comparability changed. |
| Documentation or packaging only | Verify executable/configuration hashes unchanged and links/manifest valid; runtime evidence is reusable only when behaviour and measurement scope are unchanged. |

A reserved case used to guide a fix becomes development evidence. Refresh the final-validation set and rerun affected control/candidate comparisons instead of presenting it as unseen evidence.

## 11. Evidence package and handoff state

Use a compact set of durable records; do not duplicate the same facts across a large document tree. The following are proposed deliverable names, not claims that these files already exist.

| Record | Required content |
| --- | --- |
| `inputs.json` | Both revisions/dirty snapshots; hashes; native/game artifacts; ABI/features; tool/build versions and settings; Icebox/config/workload identity; diagnostic flags; host/run environment; instruction-conflict resolution references. |
| `test-environment.json` | Owned instance/PIDs, ports, paths, database/save/persistence targets, credential references without secret values, outbound allowlist/redirections, configuration parity and isolation checks. |
| `release-candidate.json` | Exact frozen DLL/game/generated-file hashes, ABI/features, build settings, runtime config, dependency and launch identity; evidence links and any assessed post-freeze change. |
| `behaviour-contract.md` | Intended mechanics, deliberate LINDA differences, tolerances, oracles, state-visibility/publication and failure rules, controlled interleavings and unresolved defects. |
| `acceptance-contract.json` | Separate resource requirements, uncertainty/resolution and operational safety limits; metrics, workload mix, run design, development/held-out identities, exclusions, abort responses, budget and pass/fail rules frozen before candidates. |
| `command-manifest.json` | Actual maintained commands/arguments, scope, expected result artifacts, production-style launch recipe, runner self-tests and durable regression/requalification entry points. |
| `runs/<run-id>/` | Raw measurements, bounded logs/traces, event/progress records, exact runnable and runner identities, actual loaded modules, isolated destinations, all start/stop/failure reasons and cleanup. |
| `results.md` | Per-workload memory/speed/correctness findings; independent repetitions; uncertainty; all failures/exclusions; claims not established. |
| `change-manifest.md` | Phase/task, hypothesis, files, before/after evidence, tests, dependency changes and reversal method. |
| `release-and-rollback.md` | Frozen runnable identity, launch/isolation rehearsal, production configuration differences, readiness, operator/supervisor authority, abrupt/hung-instance containment, failure triggers and tested restore. |

Every run must declare whether it is diagnostic, correctness, scripted performance, endurance or populated acceptance. Record cold/warm state, actual runtime, population/activity, seeds, feature selections and external host activity. Missing samples must not be imputed as zero. Keep trace/log storage bounded and avoid unnecessary player-identifying content.

At each handoff state: completed phases; exact candidate and instruction-decision identity; unresolved defects; gates passed/failed/not run; memory and processing verdicts; safety/isolation status; reserved/populated coverage; release-freeze and evidence-validity status; artifact paths; and the next bounded action. Do not reset the plan to another architectural exploration when an optimization fails.

## 12. Stop/go decisions and completion

| Gate | Decision |
| --- | --- |
| G0 — Preservation, authority and behaviour | Before affected work, align operative instructions and isolate test data/effects; no optimization acceptance until intended mechanics/publication rules and sources are identifiable. |
| G1 — Coherent restoration | No serious performance claim until both controls boot with verified, comparable inputs, contained effects and no mixed contract or hidden service dependency. |
| G2 — Matched baseline | No broad rewrite until the memory account/profile identify the obstruction, runner rejection is tested, and uncertainty, safety limits and reserved cases are fixed separately from resource requirements. |
| G3 — Resource candidate | Continue only measured changes; memory regressions block a speed-only promotion. |
| G4 — Frozen-candidate correctness and endurance | Publication/fatal-handling defects, unexplained growth, incomplete progress or unreliable startup block release; final resource/endurance results must belong to the frozen runnable set. |
| G5 — Populated qualification and promotion | Missing 60-player/three-hour or held-out/launch-rehearsal coverage remains missing; promote unchanged qualified artifacts with maintained regression gates. |
| G6 — Deployment approval | Qualification provides an exact-artifact approval package and tested containment/rollback procedure, never automatic production authority. |

When a phase produces no defensible improvement, retain useful diagnostics/tests, revert or isolate the unsuccessful change, and choose the next measured bottleneck. If the bounded effort does not meet both resource objectives, report the limiting costs and remaining uncertainty. Do not invent gains, lower the simulation's fidelity, or restart the external-service project without a new maintainer decision.

**Definition of done:** The frozen Windows in-process Dogmos runnable set preserves its agreed mechanics and publication rules, meets or beats LINDA's realistic-shift memory/headroom within a separately safe operating envelope, demonstrates faster representative complete atmospheric processing, and passes lifecycle, failure-containment, integration, held-out and three-hour Icebox qualification with the stated populated coverage. It passes an isolated production-style launch/restore rehearsal, is promoted without an unqualified rebuild, and retains maintained regression gates and a reviewed reversible deployment package. Production activation remains a separate authorized step.

## Sources and attribution

Repository anchors and sources S1–S12 are the v1.0 evidence record carried into this revision. They were not freshly re-audited against WUFF or current checkouts while preparing v1.1. P00 must still establish actual execution inputs. The changes summarized in the revision record implement the review amendments accepted by the maintainer in this conversation; they are proposed requirements, not new benchmark findings. S13–S14 were checked for the specific v1.1 runtime/loader cautions.

**[S1] Supplied decision report.** `performance-memory-decision.md`, 113 lines. Line references above use the supplied file's original numbering. This is historical evidence, not a qualification of this plan's target workload. SHA-256: `369dace937411811d23aa77e27cd5362a183ec53607fa8dacf71a6c29e3c477d`.

**[S2] Remote reference checks from v1.0.** GitHub branch reads recorded during that preparation returned native `master` at `fc70f567a9c8131184460052c135210775f10ab8` and game `dogmos` at `061bb6fb0bbfaa532896210c37430b19b41a0975`.

**[S3] Native repository instructions.** `AGENTS.md` at the native review anchor: archive location, source preservation, generated artifacts, ownership and verification boundaries.

**[S4] Game repository instructions.** `AGENTS.md` at the game review anchor: placement, protected work, Meridian-MCP, maintained PowerShell gates, archives and authorization boundaries.

**[S5] Native Cargo manifest.** `Cargo.toml` at the native anchor: root `dogmos` cdylib, default features and shared dependencies.

**[S6] Game integration guidance.** `docs/agent/dogmos-integration.md` at the game anchor: public API/gameplay ownership, narrow fork exception and validation rules. Its service-specific requirements are historical context to migrate, not instructions to retain a service.

**[S7] Numerical guidance.** `docs/agent/numerical-invariants.md` at the native anchor. Use as documented intent, then resolve selected-legacy-path conflicts as specified in P01.

**[S8] Native boundary guidance.** `docs/agent/ffi-and-generated-bindings.md` at the native anchor: panic boundaries, generated output and compatible public paths. Migrate service-specific contract parts in P02 without weakening validation.

**[S9] Measurement guidance.** `docs/agent/performance-and-memory.md` at the native anchor: separate memory observations, repeated workloads, bounded telemetry and profiling. The service-only numeric targets are superseded for this work.

**[S10] Microsoft measurement definitions recorded in v1.0.** `PROCESS_MEMORY_COUNTERS_EX` defines private commit and working-set fields; `VirtualQueryEx` queries regions in a specified process. These sources support measurement definitions, not proposed speedups.

**[S11] Native verification guidance.** `docs/agent/verification.md` at the native anchor: i686 evidence, repeated controls, region measurement, maintained game gates and distinct evidence classes. Migrate only the service-specific release prerequisites as part of P02/P08.

**[S12] Cargo documentation recorded in v1.0.** Package/target selection and locked-dependency semantics; not a substitute for the selected repositories' pinned build contract.

**[S13] Rust failure semantics, checked for v1.1 on 19 September 2026.** Official `std::panic::catch_unwind` and `std::alloc::handle_alloc_error` documentation: only unwinding panics are caught; allocation-error handling may abort, with abort the documented `std` default. Verify the selected pinned build; these general contracts do not qualify its failure handling.

**[S14] Windows DLL resolution, checked for v1.1 on 19 September 2026.** Microsoft, “Dynamic-link library search order”: dependency resolution follows loader rules and can search by module name even when the top-level library is loaded by full path. Supports verifying actual dependencies during the launch rehearsal; no host configuration change is prescribed here.

**Revision provenance.** v1.0 input: `Dogmos-In-Process-Workplan.md`, SHA-256 `a49e04094e2cc5e68c67ba3683c3080801529124f8feb480c2b1d03bfebcddb7`. The v1.0 file remains unchanged. v1.1 consolidates the review amendments without claiming implementation, benchmark or deployment completion.

Stable source locations:

```text
Native repository anchor:
https://github.com/Aphelion-Moon/aphelion-dogmos/tree/fc70f567a9c8131184460052c135210775f10ab8

Game repository anchor:
https://github.com/Aphelion-Moon/Meridian-Rift/tree/061bb6fb0bbfaa532896210c37430b19b41a0975

Microsoft process counters:
https://learn.microsoft.com/en-us/windows/win32/api/psapi/ns-psapi-process_memory_counters_ex

Microsoft virtual-region query:
https://learn.microsoft.com/en-us/windows/win32/api/memoryapi/nf-memoryapi-virtualqueryex

Cargo build:
https://doc.rust-lang.org/cargo/commands/cargo-build.html

Cargo locked dependencies:
https://doc.rust-lang.org/cargo/commands/cargo.html

Rust caught-panic scope:
https://doc.rust-lang.org/std/panic/fn.catch_unwind.html

Rust allocation-error handling:
https://doc.rust-lang.org/std/alloc/fn.handle_alloc_error.html

Windows DLL search order:
https://learn.microsoft.com/en-us/windows/win32/dlls/dynamic-link-library-search-order
```

All phase definitions, new acceptance procedures, workload assignments and deliverable names are proposed implementation instructions derived from the maintainer's requirements and accepted review amendments. They are not reported test results. Preparing v1.1 changed only this handoff artifact; no native compilation, live benchmark, WUFF operation or repository modification was performed.
