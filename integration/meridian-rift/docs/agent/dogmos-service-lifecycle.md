# Dogmos service lifecycle

The paired Dogmos build selects a thin 32-bit shim and an adjacent 64-bit `dogmosd` service. The retained root Rust crate is a separate legacy in-process implementation. The [Rust architecture guide](https://github.com/Aphelion-Moon/aphelion-dogmos/blob/e947d849e93ac5891d42d3cc472c93e260116d29/docs/agent/architecture-and-ownership.md) owns the component/state map and contract glossary; this guide owns the DM lifecycle contract.

Source implementation, installed artifact selection and runtime qualification are distinct. Read the generated contract and [native artifact guidance](native-artifacts.md) to identify the selected pair. Use [Dogmos verification](dogmos-verification.md) for qualification evidence. Optional asynchronous SSair stages default off pending controlled qualification; the presence of service code does not enable them.

Initialization is atomic:

1. Resolve the manifest-pinned service beside the shim.
2. Create an unpredictable per-world local endpoint and launch the child without a visible window.
3. Validate source revision, ABI, protocol, feature fingerprint, executable identity, process IDs, world nonce, and capacity limits.
4. Only after success register gases, reactions, mixtures, turfs, and adjacency.

A startup mismatch returns exact expected/actual diagnostics, cleans the child/transport, and fails `SSdogmos.Initialize()` before partial gas state exists. Startup retry is allowed only before registration.

After initialization, `dogmosd` is authoritative for atmosphere state. Timeout, corrupt response, service death, or protocol mismatch fails closed and initiates the approved controlled server-shutdown path. Never restart an empty service mid-round or fall back to an in-process arena. Safe restart requires a separately reviewed checksummed snapshot/journal design.

DreamDaemon shutdown closes the client and terminates the exact owned service and its contained
processes. Windows releases its owned kill-on-close job on forced, clean, health-observed and
partial-start cleanup paths. Job assignment precedes delivery of the real dogmosd startup
handshake; the service blocks on that payload before creating listeners or workers and has no
process-spawn path. The job cannot retroactively contain descendants created by an arbitrary
executable before assignment.

Linux starts the service in an owned process group. Cleanup observes leader exit without reaping
it, terminates the group, then reaps the exact child; it never signals a stored group identity
after leader reap. This covers descendants remaining in that group, including inherited
stderr writers. Descendants that deliberately leave the group remain outside the contract.
The production shim is not a subreaper: it reaps its direct child while the OS reaper handles
other descendants. Service parent-death signaling and parent PID/start-identity validation remain
separate lifetime protections. Repeated shutdown is idempotent. Scratch fault tests must check
for remaining owned processes and workers explicitly.

Normal shutdown allows one second for an acknowledged service to exit before owned-process termination and direct-child reaping. Diagnostic capture stops without requiring writer EOF, and request-worker cancellation retains ownership until the worker joins. OS termination/reaping and exceptional failed I/O cancellation can exceed normal deadlines; this is not an unconditional total wall-time guarantee.

Master-controller recovery transfers DM-owned settings, histories, bounded queues, pins/weakrefs, counters, reaction ordering, and healthy service-session metadata. Rebuild derived overlays/cursors. Rebind to the same service PID/world generation; do not initialize a second world. An unhealthy session remains fatal.

### Dogmos controller ownership transfer

`dogmos_service_state.dm` owns the service-facing controller fields and their explicit
`adopt_runtime_state` / `release_runtime_state` contract. `Recover()` adopts from the old
`SSdogmos` before `NEW_SS_GLOBAL` deletes it and installs the replacement. Adoption cannot yield
or call native code: it transfers the exact references first, then revokes the old controller.
Only a fresh inactive destination may adopt from an unreleased source. Failure and intentional
shutdown flags survive recovery; adoption never reopens a failed session.

| State group | Authority and lifetime | Recovery and retirement |
| --- | --- | --- |
| Registration, readiness, failure and shutdown flags | DM admission for one native session | Preserve the destination state; close old-owner admission permanently. Only global `SSdogmos` may invoke native shutdown. |
| Mixture slots, generations, free slots and pending unregisters | DM identity translation within negotiated slot capacity | Transfer exact tables and pending retirements; null old references without clearing contents. |
| Gas/reaction tables and holder slots/generations/free slots | DM registry ordering and bounded weak holder identities | Transfer exact references; never re-register the native world. |
| Callback sequence, retained batch, cursor and pending counts | DM consumption of bounded service event batches | Preserve exact order and partial consumption; null old lists and clear old cursors. |
| Lifecycle, gas/heat adjacency queues, reverse indexes and retry turfs | DM publication state bounded by registered topology | Transfer queues together with indexes and batching depth; no flush or replay during adoption. |
| Snapshot cache and epoch | Derived bounded DM cache of service state | Preserve the cache with its invalidation epoch; never revive an invalidated snapshot. |
| Health, stale-callback, topology and cache counters | DM diagnostics for the session lifetime | Preserve counters; retirement does not alter the replacement's measurements. |

Release assigns null to transferred references; it must never `Cut()` or delete shared lists.
It has no native or SSair side effects, and repeated release is harmless. It must not call
`begin_service_shutdown()`, which intentionally also clears live SSair prefetch state.
SSair's frontier journal, pending stage job and publication receipts retain their separate owner.
The focused recovery tests cover actual Master-owned replacement, old-owner shutdown, inert
partial callback/topology/cache state, SSair receipts, service PID/world identity and sentinel gas.

Typed service events carry stable handles, generations, sequence order, and bounded payloads. Resolve them on DreamDaemon's main thread, reject stale targets, and drain within the remaining SSair budget. A DM reaction continuation is single-use and resumes only after the service released simulation locks.
