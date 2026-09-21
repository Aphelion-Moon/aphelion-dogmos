# Dogmos performance and memory

Only DreamDaemon memory is the footprint optimization target. Measure DreamDaemon private committed bytes, virtual size, working set/peak, committed/reserved/free regions, largest contiguous free region, and allocation failures. Report `dogmosd` memory separately and never combine the processes when judging the BYOND limit.

The current Rust DLL is loaded in-process, so every DLL allocation is a DreamDaemon allocation. Moving code to Rust alone does not save BYOND address space. The target 64-bit service owns all arenas, graphs, scratch buffers, reaction tables, workers, and queues whose size grows with turfs or mixtures. The shim and mapped IPC windows stay fixed at no more than 32 MiB and flat across world sizes.

The qualification target is at least 70% lower Dogmos-attributable DreamDaemon peak private bytes on the agreed full-map stress workload. Service RSS is not a pass/fail footprint metric except for leaks, unbounded queues, or lifecycle failure. Do not trade DreamDaemon latency for cosmetic service-memory savings.

Use identical map, seed, features, BYOND version, scenario, and duration. Run at least three clean controls and three candidates. Capture separate process samples at 250 ms, low-overhead Dogmos counters/high-water marks, and Meridian-MCP Tracy p50/p95/p99/hotspots. Record operation counts, read-after-write barriers, IPC latency, batch size, queue depth/age, callback pressure, and SSair budget overruns.

DM-specific savings include lazy per-mixture lists, cleanup of stale profiling indexes, and producer-side bounded Kennel pages. Do not add full-world scans to production telemetry. Measure object/list counts at lifecycle checkpoints and correlate them with DreamDaemon samples.

Accept an optimization only with numerical/event equivalence and a result larger than measured noise, or when it removes an unbounded/O(n-squared) path. Keep expensive histograms, allocator scans, and address-space walks behind explicit diagnostic sampling.

Use `modular_aphelion/tools/dogmos_ipc_benchmark/` for the process-boundary spike. It is a separate
minimal DME because its 512 MiB service-only diagnostic allocation must never enter `tgstation.dme`
or the normal unit-test suite. Prepare artifacts with its PowerShell entry point, then use
Meridian-MCP for parsing, marker-delimited DreamDaemon execution, and shutdown. The generated
benchmark binding is diagnostic-only and does not establish production handshake identity.
Its typed command loops now exercise service-owned mixture slots, adjacency, snapshots, the
extracted 32-gas diffusion kernel, and a 65,536-event bounded service queue. The callback phase
requires atomic overflow rejection and ordered drain through a fixed 64 KiB shim buffer. Those are
diagnostic events, not gameplay callbacks; complete atmosphere behavior and event equivalence are
still required before this becomes product-acceptance evidence.
