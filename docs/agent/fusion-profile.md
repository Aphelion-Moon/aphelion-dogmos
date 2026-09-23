# Meridian mixture fusion: commissioning profile 1

Status: experimental, disabled by default, not gameplay-qualified. No demonstrated
player recipe or operating envelope is claimed. The authoritative numerical
values live in `dogmos-core/src/numerics/fusion.rs`; the matching binding generator
emits DM constants from those values. Runtime selection uses only Aphelion
reactions. No Citadel backend or HFR chemistry change is required.

Provenance: the plasma/CO2/tritium toroidal map is adapted from the retained
Citadel implementation at `d82f95abc447ac5ef152a91d1f841f1ff2f7cd88`,
`src/reaction/citadel.rs`. This preserves the mixture/temperature/volume-dependent
chaotic state transition but replaces exponential energy remapping with a
per-step energy change limited to 25% of existing thermal energy. Intermediate
arithmetic uses f64; engine storage remains f32. Invalid output rejects the whole
proposal without mutating its mixture.

Initial commissioning seeds are 250 mol each plasma and CO2, 1 mol tritium and
10,000 K. These historical seeds are provisional experiment inputs, not accepted
balance defaults. Supported numerical inputs require positive volume at most
1,000,000 L, positive heat capacity, temperature at most 100,000,000 K, and at
most 1,000,000,000 mol of each gas. New gas quantities and final temperature must
also satisfy the bounds. One step consumes 1 mol tritium and produces oxygen
plus water when plasma falls, otherwise BZ. Product amounts follow the generated
profile's volume scale. The declared energy and gas conversion are fictional
reaction accounting, not a mass-conservation claim.

The startup flag `dogmos_mixture_fusion` selects registration; absence leaves
fusion unregistered. Enabling against a non-Aphelion native build fails startup.
Priority is Meridian's pre-formation group, with existing catalog order otherwise
preserved. Hypernoblium suppression and immutable mixtures remain authoritative.

DM owns admission. Valid owners are a turf whose air is the mixture, a portable
or tank holding it, or a pipeline whose air is the mixture and that has a live
physical member. HFR fusion/moderator internals are marked excluded when created.
Anonymous scratch mixtures and unsupported contexts do not execute this feature.
Pipeline effects occur once at the first live physical member. Turf and pipeline
callbacks retain their existing generation guards; completion is synchronous on
the main thread after releasing numerical locks and rechecks owner/location.

One opportunity is admitted per mixture per 20 deciseconds. Processing deferral
does not accrue catch-up work. Repeated callbacks/aliases share the last admitted
time; a real new daughter mixture gets its own identity. Transfers do not copy
scheduler metadata and merges retain the destination's history. Existing owners
remain scheduled while eligible fusion is waiting; no new world scan is added.
This bounded cadence requires comparative qualification at altered subsystem
frequencies and under deferral before normal enablement.

The DM reference computes its own candidate and never invokes the native fusion
kernel. Runtime native dispatch selects only one implementation and uses the
shared DM completion path. Effects use existing radiation range/threshold and
turf hotspot APIs; no legacy `fusion_ball` strength is passed as a modern range.
Analyzer state is checked against current eligibility and recent completion.
Kennel reports present-state generic requirements, separate suppression/holder
status and loaded build/profile identity; it never executes a body as a preview.

Outstanding acceptance: differential one-step tolerances, productive and
nonproductive cases, endothermic/exothermic bounds, ordinary-chemistry controls,
HFR/supermatter interactions, owner lifetime and split/merge cadence, visible
feedback, and representative repeated Windows/WUFF memory/timing workloads.
The scripted explosion storm remains supplementary stress evidence only.
