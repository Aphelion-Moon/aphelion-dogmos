# Architecture and ownership

The root `dogmos` engine runs in-process inside 32-bit DreamDaemon. It owns gas arenas, gas and heat graphs, numerical workers, scratch storage and callback queues. Every allocation contributes to DreamDaemon memory pressure.

DM owns datum identity, scheduling, machinery, gameplay effects and UI. Native numerical workers enqueue callbacks; only the main thread may use `byondapi` or resolve game objects. `auxcallback` and `auxmacros` implement the guarded callback/export boundary. `dogmos-core` contains pure diffusion and conduction kernels, `dogmos-perf` contains telemetry, and `dogmos-process-metrics` samples the host.

Keep public DM proc paths stable. Do not duplicate numerical state in DM. Never call into DM while holding a numerical lock. Source, selected features and runtime qualification are separate facts.
