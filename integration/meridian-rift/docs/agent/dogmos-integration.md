# Dogmos integration and ownership

Dogmos replaces the inherited gas-mixture representation and environmental atmosphere processing while preserving the public DM API and SS13 gameplay boundary.

## Ownership

DM owns datum/turf identity, `/datum/gas_mixture` compatibility procs, `SSair` scheduling and time budgets, atmos machinery/pipenets, player/admin input, atom movement, gameplay effects, logging, TGUI, and callback consumption. Rust owns gas arrays, validated mixture math, reaction kernels, FDM/Katmos/TurfHeat numerical work, graphs, and native workers. In the implemented service architecture those growing Rust structures live only in 64-bit `dogmosd`; the 32-bit shim translates values and dispatches typed events. The installed artifact contract selects the pair; qualification is recorded separately in the gates described by [Dogmos service lifecycle](dogmos-service-lifecycle.md).

Do not create a second authoritative gas store. DM handles are opaque, generation-checked identities rather than application state. Rust never receives or retains DM refs. The shim never decides gameplay policy.

Service callbacks are typed, sequence-numbered events containing numeric handles and generations,
never closures or DM refs. Keep the queue and its history in `dogmosd`; DreamMaker drains bounded
batches and resolves targets on its main thread. Saturation is a fail-closed error, not permission
to drop critical gameplay work. Before replacing an existing callback, inventory its ordering,
stale-target fence, arguments, error behavior, and visible side effects, then prove equivalence.
The required envelope, inventory, ownership, and commit rules are defined in
[Dogmos gameplay events](dogmos-gameplay-events.md).

## Narrow fork-owned exception

The forced gas-mixture implementation under `code/modules/atmospherics/gasmixtures/**` and environmental simulation under `code/modules/atmospherics/environmental/**` are Dogmos-owned because the representation change cannot be expressed as isolated overrides without copying large inherited procs. The only additional generated-file exceptions are `code/__DEFINES/dogmos_bindings.dm` and `code/__DEFINES/dogmos_contract.dm`.

This exception does not cover `code/controllers/subsystem/air.dm`, `code/modules/atmospherics/machinery/**`, unrelated gameplay, turfs, UI, or deployment/build files. Existing inherited files outside the exception use `APHELION EDIT` for new Meridian work. Preserve inherited `NOVA EDIT`; do not convert it. Generated files remain generator-owned even when their path is exempt from inline markers.

The module entry point and turf hooks live under [the Dogmos module](../../modular_aphelion/modules/dogmos/readme.md). The current processing overview is [Atmospherics](../../code/modules/atmospherics/Atmospherics.md).

## Change rules

Preserve public proc behavior and test it at the first DM-visible consumer. Route pure math/invariants to Rust tests, lifecycle and gameplay consequences to focused DM tests, and generated proc changes to binding/contract drift checks. Validate handles, references, callback targets, numeric inputs, and authority after any input or asynchronous boundary.

Do not alter diffusion/equalization/heat gameplay coefficients as a performance optimization. Establish invariants, operation transcripts, and repeated measurements first.
