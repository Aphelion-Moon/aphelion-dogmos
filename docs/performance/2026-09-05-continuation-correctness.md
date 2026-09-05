# Reaction continuation and response-boundary repairs

This source checkpoint follows component-storage commit `7d99b78` and the fresh Meridian-Rift
investigation committed as `ebcf380e3b1`. Historical performance reports were used only to identify
the scope of existing work; the regressions below were reproduced against current source.

## Changes

- The chunked React stage previously stopped after its first DM fallback and discarded every
  remaining target. It now stages each target's native events and DM continuation in target order.
  Numeric state and the complete event batch publish together, after every continuation is reserved.
  Capacity rejection or concurrent-write conflict releases prepared continuations. Cancellation
  before publication leaves all target snapshots and event queues unchanged.
- Continuation allocation checks arena capacity directly when no reusable slots exist, avoiding
  a growing full-arena count for each continuation in a multi-target batch.
- Service continuation records track whether their callback is still queued. Completing a delivered
  continuation performs no callback-queue scan. An undelivered continuation is removed only from its
  owning queue, and the pending count changes by the actual number removed. Expiration, cancellation,
  transaction ownership, and unrelated queue order remain covered by executable checks.
- The production snapshot and pipenet request encoders now limit compact responses to the negotiated
  64 KiB session window. Both allow 381 records and reject 382 before sending a request. The protocol's
  theoretical 1 MiB limit is unchanged. Public proc paths, wire types, coefficients, and dependencies
  are unchanged.

## Fresh regression evidence

Evidence is under ignored `tmp/continuation-repair/`; retain it when handing off this checkout.

- `coverage-red.log`: both new three-target cases failed, observing `[0]` instead of `[0, 1, 2]`,
  at work limits 1 and 4096. `coverage-expanded.log`: all six final cases passed, including mixed
  native/DM event order, event-capacity rejection, partial continuation reservation rollback, and
  every cancellation checkpoint in the bounded fixture.
- `server-ownership.log`: the new service test exercises two scopes, delivered/undelivered callbacks,
  and four completion operations. All 16 combinations preserve unrelated event transcripts and
  exact pending counts. The full service library target passed.
- `shim-capacity-red.log`: both production encoders incorrectly accepted 382 records. The final
  i686 suite includes passing checks for both sides of that response boundary.
- `x64-tests.log`: 284 tests passed for core, protocol, and server. `i686-tests-final.log`: the
  workspace suite passed after the response-boundary change; two documentation examples are ignored.
- `clippy-final.log`: strict i686 workspace/all-target Clippy passed. Formatting and whitespace checks
  passed. The supported 12-configuration feature matrix passed before the final encoder bounds;
  the paired build phase will recheck applicable final-source gates.

Pinned compiler: `rustc 1.98.0 (88d9e12ae 2026-08-18)`. Cargo commands use `--locked --offline`.

The release example `crates/dogmos-server/examples/callback_resume.rs` measures the actual service
state implementation with setup excluded. Each execution includes three trials of 101 resumes
at queue depths 0, 1024, and 16384, and checks continuation ownership and remaining callback counts.
`queue-control.exe` was saved before the production edits; `queue-candidate.exe` is a separate
candidate. Repeated comparisons belong in the subsequent integration evidence. These are native
microbenchmarks, not DreamDaemon/IPC measurements or a production speedup claim.

## Reproduction and remaining qualification

```powershell
cargo +1.98.0 test --locked --offline --target x86_64-pc-windows-msvc -p dogmos-core --test reaction_frontier_continuations
cargo +1.98.0 test --locked --offline --target x86_64-pc-windows-msvc -p dogmos-server --lib
cargo +1.98.0 test --workspace --locked --offline --target i686-pc-windows-msvc --no-fail-fast
cargo +1.98.0 clippy --locked --offline --target i686-pc-windows-msvc --workspace --all-targets -- -D warnings
cargo +1.98.0 run --locked --offline --release --target x86_64-pc-windows-msvc -p dogmos-server --example callback_resume
```

At this checkpoint, paired Windows/Linux release builds, generated-binding/manifest verification,
cross-process gates, updated-pair DreamDaemon execution, full DM suite, and matched live performance
qualification are pending. The game-side recovery, callback scheduling, idle pipeline, and profiling
fixes are being verified separately against the existing installed pair. They do not qualify this
native candidate. The release bundle must be generated from an exact clean source commit, and the
game's protected installed artifact/contract set requires its documented approval before replacement.
