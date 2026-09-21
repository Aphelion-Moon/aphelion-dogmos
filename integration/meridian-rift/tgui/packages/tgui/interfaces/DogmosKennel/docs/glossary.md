# Dogmos Glossary

## Active Turf

An open turf currently retained for atmospheric flow or reaction processing. Active Turfs is a live
queue size, not the number processed in a cycle. A disturbed area may take several FDM passes to
settle and leave the queue.

## Atmospherics MC

The Master Controller subsystem that schedules atmospheric work in DreamDaemon. Its tick duration
includes Dream Maker processing, waits for dogmosd, and native work completed before control
returns.

## Auxmos

The Rust atmospheric project from which Dogmos descends. Dogmos changes the integration, service
boundary, scheduling, telemetry, and gameplay callbacks for Meridian Rift.

## Callback

A bounded message from dogmosd asking Dream Maker to apply a gameplay-side effect or continue a
reaction. Handles and generations are checked before a callback target is used.

## Component count

The amount of connected pressure or excited-group work reported by a native cycle. It is not
necessarily a count of unique turfs and should be read together with the current queue sizes.

## Dogmos

Meridian Rift's service-backed atmospheric implementation. It stores gas mixtures in a native arena
and runs numerical atmosphere stages while preserving Dream Maker's public mixture and gameplay
contracts.

## dogmosd

The 64-bit service process that owns the native world and performs Dogmos operations. Its memory and
CPU telemetry are separate from the 32-bit DreamDaemon host.

## DreamDaemon

BYOND's game-server process. Meridian Rift's DreamDaemon is 32-bit, so private bytes and virtual
address-space pressure are operational limits distinct from dogmosd RSS.

## EWMA

Exponentially weighted moving average. Stage and per-machine cost displays smooth recent samples so
one noisy tick has less influence than repeated expensive work.

## Excited Group

A connected low-pressure region maintained for bounded group processing. Excited-group work is
separate from the main FDM turf pass.

## FDM

Finite-difference method. Dogmos performs a configured number of bounded, resumable passes over the
active-turf frontier to converge gas composition and temperature.

## Frontier

The committed set of active turf handles for one Dogmos processing cycle. Its epoch prevents runtime
topology mutations from changing the graph while a stage is still using it.

## Gas overlay

Tile-local visual feedback for a turf's gas state. A hard visual edge may be correct when a wall,
door, firelock, or other boundary separates atmospheric networks.

## Hotspot

A Dream Maker fire datum on an open turf. Native reactions change the mixture; Dream Maker applies
fire growth, visuals, exposure, and other gameplay consequences.

## Katmos / Pressure Equalizer

Dogmos' bounded pressure redistribution stage. It processes pressure-connected components and emits
the Dream Maker callbacks required for decompression effects and firelock behavior.

## Kennel

The Dogmos operational and diagnostic interface. Its event histories are bounded, jump targets are
validated, and expensive reaction timing is opt-in.

## Negative timing sample

Invalid telemetry produced when a measured interval crosses an incompatible tick boundary or is
otherwise malformed. It means the instrumentation cannot report that sample; it never means that a
stage performed negative work.

## Pipenet

A connected atmospheric machinery network whose member gas mixtures are reconciled to a common
composition and temperature. Pipenet cost includes mixture snapshots, service IPC, and network
reaction work.

## Reaction event

A recorded reaction amount change at or above the event threshold. It answers what changed; it is
not a timing sample.

## Reaction profiling

Optional per-call reaction timing. Calls at or above the configured threshold are recorded as
high-cost samples. Profiling adds overhead and should be enabled only during a bounded investigation.

## Stage cost

A smoothed wall-clock duration measured around one Atmospherics controller stage. It may include
Dream Maker code, service IPC, and native execution. It is not a pure Rust benchmark.

## TIDI

Time dilation reported by the Master Controller. Rising TIDI means the server cannot execute its
scheduled work at real-time pace; it is an outcome metric, not an Atmospherics-only timing.

## TurfHeat

Dogmos' heat-conduction graph for blocked gas paths such as walls, windows, and doors. Gas adjacency
and heat adjacency are tracked separately.
