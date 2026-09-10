# Atomic mixture creation

Ordinary DM gas recipe copies currently register an empty destination and issue a
separate CopyFrom command, with an additional volume command for custom volumes.
This change adds one atomic create-from-source request. Core publishes a new
identity only after validation and reservation succeed; the shim retains its
fixed-size request and response buffers.

The control is the constructor sequence in native revision
`58430a71192060150ee1d2a04c42ce871b0d57d6`. The new operation does not replace that
sequence for arbitrary DM subtypes. The paired DM change is staged separately for
exact `/datum/gas_mixture` and `/datum/gas_mixture/turf` copies. Custom constructor
and copy hooks, immutable/planetary construction, and reaction-result ownership
must retain their existing behavior.

## Core ownership and numerical contract

`world/mixture_creation.rs` owns validation and publication. The destination must
be unoccupied and use a newer generation than any retired identity. A source
sharing its slot is rejected. Exact source generation, finite nonnegative volume,
world capacity and arena reservation are checked before logical mutation.

An empty slot is either unused or has passed through Unregister. Unregister clears
its versioned state, continuations, mixture edges and turf ownership; it cannot run
during an active stage. Creation therefore needs no replacement cleanup or growing
ownership index. Its one arena reservation precedes resizing and publication.
Creation into a free slot remains permitted during a stage, as registration is.

The new record starts with ordinary defaults. It copies only source gases and
temperature, retaining constructor volume, zero minimum heat capacity and mutable
state. Revision increments match the old changed-volume and changed-copy operations
independently, including a default cold vacuum at revision zero and signed-zero
volume at revision one. Existing trace canonicalization is retained. Reading the
source respects publication visibility without invalidating a pending stage, and
an exhausted source revision does not prevent a read-only copy.

Protocol 14 adds command kind 37 to the existing 56-byte mixture-command payload.
The destination is primary, the source secondary, and scalar one is volume; unused
fields are zero. Success returns Applied with one created record, including an
empty cold copy. Occupied destination, a shared source/destination slot, and
invalid volume return InvalidRequest;
unknown and stale identities retain their specific error codes. ABI 2, exported
DM proc paths and generated binding contents are unchanged.

The hand-maintained capability input `dogmos-build-manifest.toml` also advances
to protocol 14. Its raw-byte SHA-256 becomes
`4022c9394310396648824592cdaa641b8fbca8aaaab2a35fa5ed4fa54e05a33a`, despite unchanged
feature names. Generated release manifests and game defines must be regenerated
from one clean source revision, and the complete pair must be installed together.

## Matched core probe

Run the maintained probe with the repository-pinned compiler:

```powershell
cargo +1.98.0 run --release --locked --offline --target x86_64-pc-windows-msvc -p dogmos-perf --example mixture_creation -- --output target/mixture-creation.csv
```

[Raw results](../performance/2026-09-10-mixture-creation/matched-core.csv) contain
72 matched cases: four source configurations, fresh/recycled destinations, 1,000,
10,000 and 100,000 copies, and three rounds. Each pair uses the same inputs and
alternates execution order. Setup and witnesses are outside measurement. Every
complete destination snapshot agrees with the old sequence, with separate literal
revision, signed-volume, temperature and gas checks. Source snapshots remain
unchanged and both event queues remain empty.

For 100,000 warm-gas copies, all three rounds report:

| Destination storage | Sequence allocations | Atomic allocations | Sequence requested bytes | Atomic requested bytes |
| --- | ---: | ---: | ---: | ---: |
| Fresh arena growth | 200,015 | 15 | 117,483,520 | 83,883,520 |
| Retired slots reused | 200,000 | 0 | 33,600,000 | 0 |

These are service-core allocation requests, including full reallocation sizes;
they are not retained memory or DreamDaemon savings. Timing includes allocator
counter overhead and was collected while an unrelated game qualification was
active. The CSV preserves those local timings, but no production speedup is claimed.

The maintained cross-bitness probe separately exercises the production numeric
encoder and actual client calls. Its creation module compares 16/64-copy sequences
and counts successful construction round trips at the call boundary, excluding
setup and snapshot reads. Running that probe is a separate gate from compiling it.

## Verification status

The new core API was first absent at compile time; this is not a runtime failing
test claim. Its subsequent focused coverage includes 24 literal old-sequence cases
across all 32 gas slots, rejected inputs with retry, capacity and forced allocator
failure, allocation-free slot reuse, active-stage continuity, publication visibility,
source revision exhaustion, and retirement of edges/turf ownership/continuations.

The contract gate was observed rejecting the initially mismatched protocol-13
capability input. After updating the input and fixtures, all 13 contract/dependency
tests passed. The new canonical manifest fixture was checked by reconstructing the
old protocol number and capability digest and recovering the prior golden hash.

The production i686 control-plane test also reproduced an incorrect Internal
response for aliased source/destination slots. The create handler now classifies
that input as InvalidRequest. Equal and different generations on the same slot,
occupied destinations, overflowing volume and stale source identities are tested
through one real service session, followed by successful creation in that session.

All native commands use Rust 1.98.0 (`88d9e12ae`, 2026-08-18), `--locked` and
offline dependency resolution. Completed local evidence:

| Gate | Result |
| --- | --- |
| Windows x64 core/server/protocol/perf tests | 358 passed, zero failed/ignored |
| Windows i686 workspace tests | 488 passed, zero failed, two existing ignored examples |
| Linux x64 core/server/protocol/perf tests | 357 passed, zero failed/ignored |
| Linux i686 workspace tests | 474 passed, zero failed, two existing ignored examples |
| Final i686 Windows create-rejection regression | Passed after the observed failure |
| Windows strict i686 workspace/all-target Clippy | Passed after the final correction |
| Linux strict i686 workspace/all-target Clippy | Passed after the final correction |
| Windows supported feature matrix | 12 configurations passed |
| Linux supported feature matrix | All 12 maintained configurations passed with pinned offline commands |
| Linux i686 service library after final correction | 38 passed, zero failed/ignored |
| Contract and dependency-direction tests | 13 passed |
| Build-identity and agent-document tests | 13 passed; live agent-document check passed |
| Exact generated-binding drift | One test passed; generated contents unchanged |
| Maintained i686 client/x64 service IPC | Passed, including all eight copy workloads and 1,030 continuation cycles |
| Formatting and whitespace | Passed |

Platform counts differ because target-specific tests are conditionally compiled;
the production control-plane tests execute on Windows i686. The final aliased-slot
correction was followed by its focused production test and strict Windows Clippy,
rather than treating earlier broad runs as executions of the later test cases.
Linux final Clippy and the 38-test service library run also include that correction.
The Linux feature gate used the twelve exact configurations from the maintained
PowerShell matrix, expanded into pinned, locked, offline Cargo commands. An initial
adapter invocation rejected an empty argument before checking a configuration; its
failed log is retained separately from the completed twelve-case run.
Logs are retained locally under `target/audit-20260910-initialization/`; the earlier
Windows feature-matrix log is under `target/audit-20260909-frontier/` with an
`initialization-` prefix.

The real transport witnesses reduce successful construction requests from two to
one for default/empty copies, and three to one for custom/recycled copies. The
16-copy runs measured 32/48 requests becoming 16; 64-copy runs measured 128/192
becoming 64. Complete snapshots agree. Deliberate stale/occupied rejections and
later successful requests also pass; those diagnostic service errors are expected.

Source review, native gates and a core microprobe do not establish paired DM
qualification or matched startup improvement. The generated protocol-14 bundle,
paired DM compile/focus/full suite, production boot/soak and three matched startup
controls/candidates are separate pending gates. Hosted CI, Linux BYOND native
loading, human playtesting and production Tracy remain separate unrun gates.
