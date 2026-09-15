# Legacy retention decision

Decision for the September 2026 cleanup: retain the root `dogmos` implementation and its
explicit `byondapi` exception. Meridian-Rift's maintained artifact path selects the i686
shim and x64 service. Qualification of that path does not certify all legacy consumers.

## Consumers and dependencies

| Consumer | Evidence and disposition |
| --- | --- |
| Unqualified root builds | [Cargo.toml](../../Cargo.toml) selects the root `cdylib`; it remains a separate supported implementation. |
| Legacy binding generation | Root `bindings.dm` and `src/lib.rs`'s `generate_binds` test remain coupled to legacy exports. The production pair uses the shim example. |
| Alternative features | Root features include `zas_hooks`, `citadel_reactions`, `yogs_reactions`, `fastmos` and related combinations. Build success does not establish service gameplay parity for them. |
| Numerical references | The independent [legacy transcript](../../crates/dogmos-core/tests/fixtures/legacy_mixture_transcript_v1.txt) is consumed by core equivalence tests and the [cross-bitness probe](../../crates/dogmos-byond/examples/cross_bitness_probe.rs). Preserve its provenance and literal expectations. |
| Shared support | `auxcallback` serves the legacy boundary; `auxmacros` also discovers paired shim bindings. Removing the root crate cannot imply removing both packages. |
| Meridian-Rift paired runtime | Maintained synchronization, manifest/lock, RIFT gates and Linux CI staging select `dogmos-byond` plus `dogmosd`. |
| Historical Meridian-Rift Dockerfile | The inherited root Dockerfile builds a single root-crate `libdogmos.so`. It is a legacy consumer, not evidence of paired deployment. The isolated Linux container probe qualifies paired service/IPC behavior separately. |
| Other external users | A complete downstream usage census is unavailable from these local repositories. Unknown consumers are not assumed absent. |

## Capability matrix

| Capability | Evidence or difference | Retirement consequence |
| --- | --- | --- |
| Current Meridian mixtures and configured reactions | Core properties, independent transcripts, DM-visible consumers and paired runtime gates | Supports this integration; preserve coefficients and event order. |
| Generational identities, bounded callbacks, resumable receipts | Protocol/shim/core tests and DM recovery/publication tests | Service contracts are not an interchangeable in-process ABI. |
| Windows/Linux | i686 shim and x64 service have separate build and artifact identities | Both pairs need qualification; host-only success is insufficient. |
| Gameplay effects | DM owns atom movement, rights and callback effects | Codec parity cannot establish all gameplay parity. |
| World failure | Admission closes without automatic empty-world restart | Intentional architecture policy, with explicit platform cleanup limits. |
| Alternate legacy configurations | Build-checked; complete paired runtime parity is unproven | Blocks blanket retirement. |
| Dynamic metadata | Paired compatibility procs return explicit errors for unsupported mid-round replacement | A retained proc name does not establish equivalent legacy capability. |
| Rollback | Matching local artifact sets and source commits remain archived | Restore complete contracts, never individual binaries. |

Before removal, obtain a maintainer decision covering known consumers, qualify retained
configurations or explicitly deprecate them, preserve reference and generation dependencies,
migrate deployment selectors, and retain a verified rollback set. This review chooses retention;
it does not schedule deletion or claim universal parity. Exact runtime results belong in the
central qualification archive rather than this maintained policy.
