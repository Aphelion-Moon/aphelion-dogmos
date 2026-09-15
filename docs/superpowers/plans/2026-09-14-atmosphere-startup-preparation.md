# Atmosphere Startup Preparation Implementation Plan

> **For agentic workers:** Use `superpowers:executing-plans` to execute inline, task by task. No subagents. Checkboxes track implementation, not planning completion. Do not commit automatically.

**Goal:** Reduce time to safe playable readiness through bounded map batching, explicit bulk creation, and qualified overlap/build preparation.

**Architecture:** Land late-map batching independently. Introduce a bulk factory only at proven safe call sites; reuse runtime service jobs and an explicit initialization join for later overlap. Add an optional build artifact only when measured remaining work justifies it.

**Tech Stack:** Rust 1.98.0, BYOND 516.1687, typed native protocol, DreamMaker, maintained build tooling and PowerShell/RIFT gates.

**Spec:** [Startup preparation design](../specs/2026-09-14-atmosphere-startup-preparation-design.md), plus the [roadmap and verification commands](../../performance/2026-09-14-atmosphere-roadmap.md). N/G identify the anchored repositories there.

## Global constraints

- Rust 1.98.0 with `--locked`; BYOND 516.1687 for the anchored game; revalidate pins before execution.
- No subagents. Preserve unrelated work. No commits or production operations without the applicable authorization.
- Preserve public constructor behavior, gas values, temperature/volume rules, immutable mixtures, subtype hooks, turf order, multiz edges, and critical events.
- Keep map-sized native state and preparation scratch in the 64-bit service; keep shim and transient DM batches bounded.
- Do not change physics or mark the world playable before atmosphere and its dependent machinery are ready.
- Generated bindings and manifests are regenerated only with maintained tools.

## S1: Batch late-map registration with preserved ownership

**Files:** Modify G `code/controllers/subsystem/air.dm` (`StopLoadingMap`), `modular_aphelion/modules/dogmos/code/service_backend.dm` (existing batching helpers only if needed), and `modular_aphelion/modules/dogmos/code/service_backend_test.dm`.

**Interfaces:** Reuse `runtime_topology_batching`, `turf_registration_batching`, `flush_turf_registration_batch()`, and existing 512-record limits. Public `StopLoadingMap()` retains its signature and queue-order behavior.

- [x] Parse the authorized Dogmos checkout. Trace `register_dogmos_air -> update_air_ref` and the complete `add_to_active(T, TRUE)` call chain. Confirm no immediate native read or sleep was added since the anchor. If one exists, narrow the batching scope around the proven write-only portion before implementation. The [source audit](../../performance/2026-09-14-late-map-batching-audit.md) narrows batching around the re-registration heat read; implementation remains open.
- [ ] Add `/datum/unit_test/dogmos_startup_map_batch` with real fresh gas-and-heat turfs and fixture-scoped counters around the exact target loop. Setup and cleanup must be outside the counted interval.
- [ ] Assert these focused lifecycle/heat call counts and complete state:

```text
fresh records 1:   expected 2 calls
fresh records 512: expected 2 calls
fresh records 513: expected 4 calls
```

Validate slot/generation, mixture association, all heat record fields, active-list order, and pending queue indexes against the unbatched path. Test horizontal and vertical adjacency separately; the count oracle excludes extra adjacency work.
- [ ] Add nesting, frozen-frontier, and injected failure cases. On a failure after K registrations, the same successfully completed prefix is visible as in the old loop, the outer owner flag is restored, and unprocessed entries are not reported as complete. If flushing also fails, retain both diagnostics and the original error rather than silently replacing it.
- [ ] Observe failure of the old per-turf call-count oracle. Implement this scope logic using the repository's established exception/rethrow syntax:

```text
save runtime owner; set runtime owner true
execute original ordered register-then-activate loop
on normal exit: restore owner; flush only if no remaining owner
on exception: restore owner; flush accepted prefix if permitted; rethrow original
retain original queue clearing point and frozen-frontier deferral
```

- [ ] Run RIFT with `--focus /datum/unit_test/dogmos_startup_map_batch --minimum-tests 1`, the roadmap's Dogmos CI profile and matching pair, and offline networking. Run applicable lifecycle/frontier tests and static DM checks. Fixture cleanup must remove its pending registrations even on failure without disturbing foreign entries.
- [ ] Compare three matched startup controls and candidates using full readiness and Mapping/Atoms/Atmos phases. Report the counted scope's contribution; do not infer seconds saved from RPC counts alone. Review uncommitted diff as an independent candidate.

**Deliverable/gate:** The original synchronous loop uses bounded shared batches without changing successful or partial-failure visibility.

## S2a: Implement the atomic bulk-copy contract and explicit factory

**Files:** Modify N `crates/dogmos-core/src/world/mixture_creation.rs`, `world.rs`, `crates/dogmos-protocol/src/lib.rs`, `crates/dogmos-server/src/lib.rs`/`state.rs`, and `crates/dogmos-byond/src/lib.rs`. Create N `crates/dogmos-core/tests/mixture_creation_batch.rs`. Add transport tests to existing N `crates/dogmos-byond/tests/production_commands.rs`. Modify G `gas_mixture.dm`, `service_backend.dm`, and `service_backend_test.dm` for the factory and receipt attachment only.

**Interfaces:** Core `DogmosWorld::create_from_source_batch(records)` uses the existing scalar-copy semantics atomically. Records are the 32-byte layout in the design, with an 8-byte batch header. DM factory `SSdogmos.create_map_mixture_batch(recipes)` returns the ordered attached mixture list after service acceptance; the optional internal constructor receipt is scoped, single-use, and never activates a global deferred-construction mode.

- [ ] Write the native contract fixture using existing lifecycle/state APIs to create source mixtures. Use independently specified source values (300 K, oxygen 10, nitrogen 20) and destination volumes 2500 and 1000; verify moles/temperature copy and requested volume exactly as single-copy semantics specify.

```text
2 valid records -> both destinations visible, sources unchanged
valid record + stale source -> neither destination visible
duplicate destination -> no publication
record with NaN/negative/overflowing volume -> no publication
forced reservation failure -> no new live slots or lost tombstones
512 records -> accepted; 513 -> rejected before allocation/publication
```

- [ ] Observe the missing operation fail; implement whole-batch validation and reservation before publication. Do not implement atomicity by looping over already-publishing single-copy calls.
- [ ] Add codec tests for exact lengths, high-generation words, reserved fields, count mismatch, and empty/over-limit batches. Add the next protocol revision and operation only after reconciling R4's reserved IDs; regenerate the full contract.
- [ ] Add `/datum/unit_test/dogmos_startup_bulk_factory` for receipt reuse, spoofed type/source/volume, partially failed DM attachment, constructor-side reads, source deletion, and cleanup. Verify attached prefixes retain ordinary ownership while every unattached accepted handle is unregistered.
- [ ] Implement bounded handle reservation, one native batch request, then ordered datum construction with validated receipts. Restrict to exact base mixture type initially. Preserve existing public `New(volume, copy_source)` calls, ordinary `copy()`, immutable handling, and subtype fallback.
- [ ] Run core tests on x64/i686, i686 FFI malformed-input tests, paired generated/installed-contract gates, and the focused DM factory fixture. Measure setup excluded request counts and allocation high water for 1/32/512 records.

**Deliverable/gate:** A qualified bulk primitive and factory; no production map caller has changed yet. A successful microbenchmark is not startup acceptance.

## S2b: Admit one map caller through an observable-behavior audit

**Files:** Inspect G `air.dm`, `gas_mixture.dm`, `code/modules/atmospherics/gasmixtures/immutable_mixtures.dm`, and actual turf initialization overrides found by Meridian-MCP. Modify only the proven caller and add its fixture to `service_backend_test.dm`. Create a dated audit under G `docs/audits/` recording the exact callable scope.

**Interface:** The admitted scope supplies fixed ordered factory recipes and assigns `turf.air` at the same observable point as before. It must not require all neighboring turfs' air to appear earlier than original initialization.

- [ ] Inventory repeated constructor/copy calls in the main-server initialization trace. Rank call sites by calls and wall time; choose the highest-cost scope whose complete call chain can be audited.
- [ ] Record a control transcript of constructor entry/exit, source identity/revision, requested volume, turf assignment, native reads/writes, signals, subtype hooks, yields, and neighbor reads. Include the map seed and dynamic template sequence.
- [ ] Test batching on that exact fixture with a reader after every observable boundary. Reject eligibility if batching reorders a signal, changes a read result, exposes an unregistered datum, or changes exception-prefix behavior. Expand exact-type eligibility only through its own transcript test.
- [ ] If no call site passes, finish S2 with the primitive disabled for map use and report this gate as unmet; do not retrofit arbitrary deferral into `New`. The next design review then has a measured blocker rather than a guessed implementation.
- [ ] If a call site passes, integrate it alone, run its focused test plus paired boot/full/soak gates, and compare matched startup cohorts. Record direct savings at that caller and total readiness separately.

**Deliverable/gate:** One production bulk caller with behavioral proof, or an explicit evidence-backed stop before unsafe constructor reordering.

## S3: Overlap native preparation with audited independent startup work

**Prerequisite:** Runtime R3-R5 mechanisms are qualified, and the preparation input boundary is stable. Bulk creation alone does not prove this dependency boundary.

**Files:** Modify G `code/controllers/master.dm`, `code/controllers/subsystem.dm`, `air.dm`, `service_backend.dm`, and `service_backend_test.dm`. Reuse N stage-job modules; add a distinct typed preparation job only where runtime job operations cannot express pure graph preparation without simulating a tick. Keep the registry initialization in G `modular_aphelion/modules/dogmos/code/dogmos.dm` before its existing dependents.

**Interfaces:** The optional subsystem API is `BeginInitializationPreparation() -> token|null`, `PollInitializationPreparation(token) -> Running|Ready|Failed`, and `FinishInitializationPreparation(token) -> normal initialization result`. Default subsystems opt out. The MC initially admits one preparation, SSair; ordinary `Initialize()` remains the synchronous full-readiness path.

- [ ] Inventory initialization dependencies and actual atmosphere reads/writes of candidate overlap work. Record direct and indirect dependencies, init-stage constraints, signals, and shared state. Absence from a declared dependency list is not proof of independence.
- [ ] Add `/datum/unit_test/dogmos_startup_readiness` using a controlled preparation token, independent sentinel subsystem, and dependent consumer. The expected event sequence is:

```text
registry ready -> capture stable inputs -> begin native preparation
independent sentinel completes while preparation pending
dependent consumer does not run; SSair.initialized remains false
preparation ready -> validate/reconcile -> finish SSair
dependent consumer runs -> final readiness/TGS completion becomes eligible
```

- [ ] Inject turf replacement and dirty-journal overflow while pending. Stale generation results must be rejected/rebuilt before readiness. Inject service failure and invalid result shape: no initialized flag, success signal, or TGS-ready marker may be emitted for incomplete state.
- [ ] Implement opt-in MC scheduling with current dependency sorting and stage rules. Recompute budgets when resumed, retain original result/error handling, and measure Begin/preparation/independent/join durations separately. Keep a synchronous mode for identical physics comparison.
- [ ] If no independent subsystem is proven safe, retain synchronous join and record the overlap gate as unmet. Do not declare readiness early to obtain a shorter timer.
- [ ] Verify machinery/pipenet prerequisites, all required callbacks, recovery/shutdown cleanup, and final visual state. Run focused and full paired gates, then matched readiness measurements including dynamic ruins and fixed seed.

**Deliverable/gate:** Proven overlap of independent work with native preparation and an unchanged safe-play boundary; otherwise a documented reason to keep serial initialization.

## S4: Prove and implement optional build preparation

**Entry gate:** Main-server traces after earlier changes identify repeated deterministic work with a plausible net saving after validation/load/reconciliation. Record the measured target before adding build tooling.

**Files:** Create G `tools/dogmos/export_atmos_preparation.dm`, `tools/dogmos/build_atmos_preparation.ps1`, and `tools/dogmos/tests/test_atmos_preparation.py`; register the scratch exporter through maintained tooling/ticked-file rules rather than the production DME. Create N `crates/dogmos-core/src/atmos_preparation.rs` and `crates/dogmos-core/tests/atmos_preparation.rs`. Modify G `service_backend.dm` and N startup dispatch for loading before world registration. Extend maintained build/deployment tooling only through its applicable review rules; preserve `BUILD.cmd` and `RUN_SERVER.cmd` entry behavior.

**Interfaces:** The exporter uses authoritative game definitions to produce the schema/magic, catalog, descriptors, and generated manifest from the spec. Loader returns `Accepted(catalog)`, `CacheMiss(reason)`, or a fatal native-contract error. Dynamic entries are marked ineligible and remain runtime-generated; no artifact embeds runtime handles or executable content.

- [ ] Build two exports from identical inputs in separate isolated directories and require identical bytes. Compare exported numeric recipes with runtime evaluation. Change a build define, gas ordering/value, map/template, relevant configuration, and native contract independently; each must alter the fingerprint or reject reuse.
- [ ] Add loader tests for the following cases before writing the decoder:

```text
missing file -> ordinary startup path
wrong magic/schema/hash/fingerprint -> cache miss before registration
truncated payload / excessive count / length overflow -> reject before allocation
valid payload -> fresh runtime handles, no inherited generations
native shim/service mismatch -> fatal contract error, never cache fallback
```

- [ ] Implement explicit lengths and numeric codecs, bounded validation, and fresh service-owned state. Do not parse arbitrary DM source in Rust or serialize native structs. Preserve finite values, registry order, and runtime dynamic entries.
- [ ] Export an initial-gas seam report through the runtime comparison predicate. Mark intentional boundaries separately; report coordinates and definitions without automatically editing maps or equalizing gas.
- [ ] Run artifact absent/rejected/accepted startup paths under identical seed and require equivalent final state/events. Record total build cost, cold and warm startup cost, and reconciliation cost. If loading is not a net improvement, leave the artifact path disabled and retain the evidence.
- [ ] Verify complete packaging/identity checks, boot/full/soak gates, Linux load, and server capture. Review the source and generated artifact diff without committing or deploying.

**Deliverable/gate:** An optional deterministic accelerator with tested invalidation and equivalent runtime behavior, enabled only if the measured break-even case passes.

## Final handoff

- [ ] Report S1, S2a, S2b, S3, and S4 separately as implemented/qualified, disabled prototype, or prerequisite not met. Never describe the entire roadmap as complete because one batch fixture passed.
- [ ] Link exact source and paired-bundle identities, original and candidate logs, numerical/event comparisons, three-control/three-candidate results, memory by process, and any unrun gates.
- [ ] Preserve the complete rollback pair and require controlled restart for changing native artifacts. Leave implementation uncommitted and main-server operations operator-controlled.
