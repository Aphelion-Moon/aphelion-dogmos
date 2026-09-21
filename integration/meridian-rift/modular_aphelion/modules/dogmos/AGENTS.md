# Dogmos module agent instructions

Read the repository-root `AGENTS.md` and every Dogmos guide linked from `docs/agent/README.md` before
changing this module, its fork-owned atmosphere implementation, generated bindings, or native
artifacts. The gameplay-event boundary is specified in `docs/agent/dogmos-gameplay-events.md`.

Use Meridian-MCP after `dm_parse_environment` for DreamMaker discovery and inspection. Use PowerShell
for builds, tests, DreamDaemon, Rust, and process measurement. Reparse after DM source changes.

The selected in-process play-test follows [the in-process contract](../../../docs/agent/dogmos-in-process.md).
Its native root engine owns numerical state within DreamDaemon; preserve main-thread gameplay callbacks.
The following service-specific ownership rules apply only when selecting that retained backend.

Optimize only DreamDaemon memory as a footprint goal. Keep service-owned state and event history in
64-bit `dogmosd`; the 32-bit shim stays fixed and bounded. Do not retain DM refs in Rust, introduce a
generic remote proc call, silently drop gameplay events, or add a persistent DM-side event queue.

Preserve public DM behavior and event order. Changes to event payloads, handle generations, queue
capacity, lifecycle recovery, or generated artifacts require the verification gates in the linked
guides. Leave changes uncommitted unless the user explicitly requests otherwise.
