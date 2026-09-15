# Startup observations requiring server confirmation

Scope: one busy-host MetaStation test build, run `20260914T161356Z-07d739f3`. This is a diagnostic breakdown, not startup performance acceptance. The installed source and artifact identities are in [the component correction evidence](2026-09-14-effect-free-component-evidence.json).

The runtime reported overall subsystem initialization of 259.087 seconds. Selected subsystem reports were:

| Subsystem | Reported seconds |
| --- | ---: |
| Library Loading | 132.65 |
| Atoms | 41.31 |
| Atmospherics | 17.65 |
| Shuttle | 9.43 |
| Early Assets | 9.37 |
| Map Previews | 7.57 |
| Dogmos | 0.04 |

These are the existing subsystem duration reports, not exclusive CPU attribution. Dogmos service loading and atmosphere world initialization are separate phases. Moving atmosphere work into a preparation job cannot by itself remove the observed Library Loading interval.

The local database refused connections. Between the preceding initialization report at `16:18:15.865 UTC` and Library Loading's completion at `16:20:28.521 UTC`, the debug log recorded 65 failed `Connect()` calls. Raw evidence is retained beneath the run's `artifacts/data/logs/rift/` directory, specifically `runtime.log` and `debug.log`. Do not extrapolate these local database failures to a healthy production server.

Fresh Meridian-MCP generation 18 confirmed these unchanged source paths:

- G `code/controllers/subsystem/library.dm`: `load_shelves()` starts bookshelf callbacks concurrently and joins all of them through `callback_select` before initialization completes.
- G `code/modules/library/bookcase.dm`: `load_shelf()` can request several category batches per shelf.
- G `code/modules/library/random_books.dm`: `create_random_books()` calls `SSdbcore.Connect()` for every request and returns early when it fails.

Repeated connection attempts are consistent with the long observed interval; the logs do not attribute each connection call to its caller. Library already uses asynchronous callbacks. Their shared completion barrier still holds startup until the slowest work finishes.

The next server capture should include healthy-database availability, these same subsystem reports, the initialization procedure profile, and separate Begin/preparation/join observations if overlap is introduced. Rank the server's measured critical path before changing global readiness. If repeated connection failures are reproduced there, design a bounded shared availability/retry policy with explicit book-loading recovery and failure semantics; do not silently skip library initialization or weaken the atmosphere readiness barrier. No library or database behavior changed in this work.
