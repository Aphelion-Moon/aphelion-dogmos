# Dogmos Tech Memo

Status: active development; the 64-bit service is not yet the default game backend.

Last verified: 2026-08-27 against Meridian-Rift revision
`8bc58b68b17637def5b968ee1c30aef3c0927cba`. Current source uses Dogmos wire protocol version 4;
the latest repeated callback-pressure memory evidence below was collected with protocol version 3.

This memo is for players, server operators, and contributors who are comfortable with concepts such
as processes, memory limits, and application interfaces but do not need to read the implementation.
It explains what Dogmos changes, what is already working, and what remains experimental.

## Short version

Dogmos is a Rust implementation and redesign of Meridian-Rift's atmospheric simulation boundary.
Atmospherics tracks the gas mixture in rooms, pipes, tanks, lungs, fires, and breaches. It calculates
pressure, temperature, gas transfer, reactions, and heat movement, then tells Dream Maker when those
results should cause gameplay effects.

The current Dogmos game branch moves much of this calculation into a Rust DLL, but that DLL still
runs *inside* DreamDaemon. This can improve implementation safety and computation, but its memory
still counts against DreamDaemon's 32-bit address space.

The target architecture keeps a small 32-bit bridge inside DreamDaemon and moves growing atmosphere
state and computation into a separate 64-bit process named `dogmosd`. This is the part intended to
reduce DreamDaemon memory pressure. It has passed focused transport, process-isolation, bounded-queue,
and partial-compute tests, but it does not yet implement the complete game atmosphere workload.

## What atmospherics does

A running SS13 world contains many gas mixtures. A mixture can belong to a turf, pipe network,
canister, portable device, mob, or temporary calculation. The simulation repeatedly performs work
such as:

- tracking moles of each gas, mixture volume, and temperature;
- calculating pressure and exchanging gas between connected spaces;
- running combustion and other gas reactions;
- conducting heat between turfs and structures;
- detecting dangerous pressure differences and decompression;
- producing results that open firelocks, damage floors, update overlays, or create other gameplay.

In a non-Dogmos Meridian-Rift installation, the gas data and most of this work live in Dream Maker.
In the current Dogmos branch, the public `/datum/gas_mixture` interface remains familiar to the rest
of the game, while many operations call an in-process Rust library through BYOND's `load_ext()` and
`call_ext()` interface. BYOND documents these calls as its mechanism for invoking third-party native
libraries, including the richer Byondapi calling convention.

## Three configurations that should not be confused

| Configuration | Atmosphere state and computation | DreamDaemon memory effect | Current status |
| --- | --- | --- | --- |
| Non-Dogmos Meridian-Rift | Primarily Dream Maker datums, lists, and subsystem processing | Atmosphere state shares DreamDaemon's constrained address space | Normal comparison installation |
| Current Dogmos game branch | Much of the gas-mixture and atmosphere implementation is an in-process 32-bit Rust DLL | DLL allocations are still DreamDaemon allocations | Playtested development baseline |
| Target Dogmos service | A bounded 32-bit shim communicates with 64-bit `dogmosd`, which owns growing arenas, graphs, work buffers, and queues | DreamDaemon retains only handles and bounded exchange data; service memory is separate | Validated migration foundation, incomplete gameplay integration |

The current branch and target service are stages of one project, not interchangeable descriptions
of the same finished system. Installing the current branch does not automatically start `dogmosd`
or deliver the target memory reduction.

## Current game architecture

The current game-facing API deliberately resembles the normal Meridian-Rift API. Code can still ask
a gas mixture for pressure, temperature, volume, gas contents, or reaction results. Dogmos bindings
redirect many of those calls into Rust without requiring every machine, mob, and item to learn a new
atmosphere API.

```text
Meridian-Rift gameplay and atmos machinery
                  |
                  | /datum/gas_mixture calls
                  v
       BYOND load_ext()/call_ext()
                  |
                  v
      dogmos.dll inside DreamDaemon
```

This compatibility layer is valuable, but it is not a process boundary. DreamDaemon and the DLL use
the same process address space. Moving a list or graph from DM into this DLL may change its layout,
but does not move it outside the memory-constrained process.

## Target service architecture

The target is a split-process design:

```text
Dream Maker gameplay policy and presentation
                    |
                    | coarse typed commands and bounded event drains
                    v
       32-bit BYOND shim inside DreamDaemon
                    |
                    | authenticated local named pipe
                    v
       64-bit dogmosd atmosphere service
       - mixture slots and gas vectors
       - turf adjacency and heat graphs
       - reusable simulation work buffers
       - reactions and atmosphere stages
       - bounded result/event queue
```

The shim verifies the service executable and performs a versioned handshake. The handshake includes
the source revision, ABI and protocol versions, feature identity, process identity, world generation,
and capacity limits. Commands use fixed or explicitly counted binary records rather than free-form
text. Mixtures use stable slot-and-generation handles so a delayed result cannot silently refer to a
new object that reused an old slot.

On Windows, the prototype uses a local named pipe. It is not a network service and does not expose a
gameplay API to the internet. The selected Rust transport maps its local-socket abstraction to
Windows named pipes and to local Unix socket mechanisms on supported Unix systems.

### Why the boundary is coarse

A service call has a fixed wake-up and synchronization cost. Remotely asking for every temperature,
pressure, or gas value one at a time would spend more time crossing the process boundary than doing
useful simulation work.

One captured settled-idle game window made about 5,478 Dogmos calls per atmosphere cycle, including
about 4,694 scalar reads. The measured real DreamDaemon path took approximately 43.7-47.7
microseconds per serialized scalar getter. A direct conversion of every getter into IPC would
therefore predict roughly 239-261 milliseconds of boundary time per 500-millisecond atmosphere
interval, before any service computation.

Dogmos instead groups work into commands such as bulk lifecycle updates, adjacency updates, mixture
snapshots, and complete simulation stages. In the same research, four coarse stage round trips were
estimated at about 0.34 milliseconds using the measured worst p95 transport latency. These figures
explain the architecture; they are not a production performance guarantee.

## Memory goals and measurement rules

The memory goal is specifically to reduce memory retained by DreamDaemon. The service is 64-bit and
does not have DreamDaemon's 32-bit address-space constraint, so moving a large graph or queue from
DreamDaemon to `dogmosd` is useful even if the combined byte total stays similar or grows slightly.

DreamDaemon and `dogmosd` memory must therefore be reported separately. Adding the two numbers and
calling the sum a Dogmos result would hide whether the BYOND process actually gained headroom.
Microsoft's Windows documentation describes a 32-bit process as having a 4 GiB virtual address
range, with the usable process portion also depending on platform and executable configuration.
Dogmos does not assume that all 4 GiB is available for game data.

The current acceptance target is at least 70% lower *Dogmos-attributable DreamDaemon peak private
bytes* on an agreed full-map stress workload. That target also requires equivalent simulation and
event results, bounded latency, and repeatable control-versus-candidate runs. It has not yet been
met by a complete game candidate.

### Focused process-isolation evidence

The service prototype has demonstrated the intended ownership boundary in contained tests:

| Test | DreamDaemon result | `dogmosd` result | Meaning |
| --- | ---: | ---: | --- |
| Service-only 512 MiB allocation, two runs | Private bytes rose by 151,552 bytes in each run; virtual size rose by 4,718,592 bytes | Private bytes rose to about 539.73 MiB | A large service arena was not mapped into DreamDaemon |
| Protocol-v3 queue filled with 65,536 64-byte events, three runs | Private-byte delta was 167,936-172,032 bytes; virtual delta was 4,718,592 bytes | Private-byte delta was 4,202,496-4,214,784 bytes | The growing backlog stayed in the service while the shim allocation remained fixed |

Every protocol-v3 queue run accepted exactly 65,536 events, rejected the next complete event
atomically, drained in sequence, and ended empty. The fixed 64 KiB shim response buffer carries at
most 1,023 complete 64-byte event records plus its header per drain.

These are boundary tests, not a before-and-after production benchmark. They do not yet include the
complete set of atmosphere reactions, turf heat, visual updates, and gameplay consequences.

The standalone service core now also owns validated, immutable gas and reaction metadata with
fixed-width numeric identities. Its reaction-condition scan preserves the current temperature,
energy, gas-quantity, and burnability thresholds, walks reactions in explicit priority order, and
can reuse caller-owned output storage. This removes a legacy failure mode in which equal priorities
could silently discard a reaction. It is a tested core capability, but it is not yet connected to
the game registration protocol or reaction execution path and therefore does not change current
DreamDaemon memory use.

## Gameplay ownership

The intended division is:

- `dogmosd` owns atmosphere facts and computation: gas quantities, temperatures, graphs, stage
  results, and other state that scales with the world;
- Dream Maker owns gameplay policy and presentation: resolving live objects, applying damage,
  opening or closing machinery, changing floors, updating overlays, logging, and administrator UI;
- the shim owns only the checked conversion between BYOND values and the bounded wire protocol.

When Rust determines that a reaction completed or a pressure threshold was crossed, it emits a
typed result. Dream Maker validates the handle and generation, resolves the current object on its
main thread, and applies the appropriate game behavior. Rust must not retain raw Dream Maker object
references across the service boundary.

Protocol version 3 introduced a fixed 64-byte event envelope and typed event families for reaction
completion, pressure differences, decompression floor-rip checks, firelock consideration, and turf
destruction requests. These definitions and queue behavior are foundations. Most production event
producers and their complete DM dispatch paths remain to be implemented. Visual-state events are
deliberately deferred until a complete bounded payload can be specified.

Protocol version 4 retains that event envelope and adds an atomic mixture-state batch. Each record
provides one generation-checked handle, expected state revision, temperature, volume, and all 32 gas
slots. This lets the service receive complete nonzero state without turning initialization into
hundreds of individual setter calls. The complete batch is rejected on a stale revision, duplicate
target, invalid value, or malformed record; partial state is not committed.

## Reliability and failure behavior

Atmosphere state cannot be silently replaced halfway through a round. If an authoritative service
dies, times out, or returns a corrupt or mismatched response, the target policy is to fail closed and
start the approved controlled server-shutdown path. It must not start an empty replacement service
or quietly fall back to a second atmosphere implementation.

The prototype already provides:

- exact build and protocol identity checks;
- one authenticated client per service;
- bounded command and event sizes;
- atomic rejection when a complete event batch cannot fit;
- request deadlines and cancellation checks in the extracted diffusion stage;
- a dedicated shim I/O worker that poisons and terminates a stalled session;
- child-process containment so closing DreamDaemon also terminates its exact service process;
- idempotent shutdown behavior.

Startup connection and handshake work still needs the same complete DreamMaker-facing deadline
qualification as normal requests. Every future simulation stage also needs cancellation checkpoints
before it can become authoritative.

## What players and operators should expect

The compatibility goal is the same observable atmosphere behavior as the reviewed Meridian-Rift
installation: the same gases, machinery interactions, reaction ordering, temperatures, pressures,
and gameplay consequences within defined numerical tolerances. Dogmos is not intended to make fires
or breaches easier or harder as an accidental side effect of optimization.

The current in-process branch has completed a useful single-player stress playtest involving
tritium and plasma fires. It recorded 540 profiled reaction calls and found no Dogmos- or atmosphere-
named runtime error during the tested fire workload. That run did not include `dogmosd`, did not
capture an exact-PID memory series, and was not a repeated control/candidate experiment. It is a
development smoke test, not proof of service parity.

Operators should not deploy the service migration as an authoritative backend until the documented
full-game gates pass. During development, logs and profiling must identify the exact game revision,
BYOND version, native binaries, protocol, feature set, map, seed, workload, and process IDs.

## Remaining work

The major open items are:

1. Move the complete gas metadata and mixture behavior behind service-owned state.
2. Port and verify all reaction families, turf heat, environmental processing, and Katmos behavior.
3. Produce and dispatch every required typed gameplay result without retaining unbounded DM lists.
4. Bound startup connection and handshake waits from Dream Maker's point of view.
5. Repeat equivalent idle, breach, fire, heat, machinery-heavy, recovery, and shutdown scenarios.
6. Compare numerical state, event order, gameplay results, stage latency, and exact-PID memory across
   at least three clean non-service controls and three service candidates.
7. Meet the DreamDaemon memory-reduction target with adequate atmosphere-cycle headroom before
   enabling the service by default.

## Frequently asked questions

### Is Dogmos an AI system?

No. Dogmos is a deterministic atmosphere simulation and integration project. “Agent” documents in
the repositories are instructions for software-development assistants, not game-controlled AI.

### Is Rust automatically outside BYOND's memory limit?

No. Rust code compiled into `dogmos.dll` runs inside DreamDaemon and shares its address space. Only
state owned by the separate `dogmosd` process is outside DreamDaemon.

### Does the service run on another computer?

No. The current design uses local inter-process communication on the game host. On Windows that is
a named pipe, not an internet-facing socket.

### Why not use shared memory?

Current measurements show that coarse named-pipe commands meet the prototype latency budget. A
shared-memory window would consume additional DreamDaemon address space and introduce more complex
synchronization and corruption failure modes. It can be reconsidered if representative coarse-stage
measurements show a need.

### Can Dogmos restart itself after a crash?

Not while its state is authoritative. Restarting an empty service would discard the atmosphere.
Safe mid-round recovery would require a separately designed and verified snapshot or journal system.

### Does Dogmos change what Dream Maker is responsible for?

Yes, but narrowly. The service should own scalable atmosphere state and computation. Dream Maker
continues to own live game objects, player-visible behavior, and presentation.

## Maintainer notes

Update this memo when any of the following changes:

- the default backend or deployment status;
- process or data ownership;
- wire protocol or event families;
- failure and recovery policy;
- acceptance targets or newly accepted evidence;
- the list of remaining migration gates.

Keep “current game branch,” “target service,” and “accepted production behavior” separate. Report
DreamDaemon and `dogmosd` memory independently. Change the Last verified line whenever the status or
quantitative evidence is re-audited.

Repository details for contributors are maintained in the [Dogmos integration guide](../agent/dogmos-integration.md),
[service lifecycle guide](../agent/dogmos-service-lifecycle.md),
[gameplay event contract](../agent/dogmos-gameplay-events.md),
[performance and memory guide](../agent/dogmos-performance-and-memory.md), and
[verification guide](../agent/dogmos-verification.md). The project sources are the
[Meridian-Rift Dogmos branch](https://github.com/AphelionDevelopment/Meridian-Rift/tree/dogmos) and
[standalone aphelion-dogmos branch](https://github.com/AphelionDevelopment/aphelion-dogmos/tree/dogmos).
External background is available in the [BYOND `call_ext()` and `load_ext()` reference](https://www.byond.com/docs/ref/info.html),
[Microsoft's virtual-address-space documentation](https://learn.microsoft.com/en-us/windows/win32/memory/virtual-address-space),
and the [`interprocess` local-socket documentation](https://docs.rs/interprocess/2.4.3/interprocess/local_socket/index.html).
