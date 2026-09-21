# Dogmos verification

Use Meridian-MCP for DM analysis and diagnostics. Call `dm_parse_environment` first, use semantic discovery followed by exact symbol/reference inspection, and reparse after DM changes. Use Meridian-MCP for Tracy prepare/launch/capture/frame statistics/hotspots/comparison. Parser diagnostics are SpacemanDMM evidence, not DreamMaker results.

PowerShell owns DreamMaker, DreamDaemon, Rust, process memory sampling, Docker, and test runners. Inspect `$LASTEXITCODE` after native commands. Use the maintained checked-in entry points when they exist; extraction copies are baseline/reference material, not final shipped verification.

Run gates in order:

1. Focused Rust unit/property tests observed red before the change.
2. Exact locked i686 shim/protocol and x86_64 core/service tests plus supported feature matrix.
3. Generated binding/manifest/dependency-direction drift checks.
4. Focused DM tests for the changed contract.
5. Production DreamMaker compile and native-load boot probe.
6. Cross-process lifecycle/fault tests and repeated process-memory/Tracy workloads.
7. Full DM suite and Docker/two-process deployment probe when applicable.

No later gate substitutes for an earlier failure. A focused run must record at least the requested test paths and remains iteration evidence. Boot requires a fresh DMB, initialization marker, matching shim/service contract, no new runtime signatures, and clean service shutdown. Full suite status must be stated explicitly.

Performance reports separate DreamDaemon and `dogmosd`, include control noise, enforce numerical/event equivalence, and identify map/seed/revision/features/BYOND/duration. Fault injection runs only in a scratch environment and verifies no orphan processes.

Before handoff, reparse/check DM diagnostics, run `git diff --check`, inspect protected files separately, confirm exact revisions/hashes, and report commands, artifacts, warnings, runtime signatures, and unrun gates without committing.
