# Meridian-MCP workflow

Meridian-MCP is required for repository-scale DreamMaker navigation and diagnostics:

1. Call `dm_parse_environment` with `tgstation.dme`.
2. Use `dm_search_context` for behavior or `dm_search_symbols` for exact names.
3. Verify candidates with `dm_get_type`, `dm_get_proc`, `dm_get_var`, `dm_get_definition`, and reference tools.
4. Reparse after source changes; an older state generation is stale.
5. Use `dm_check_errors` as SpacemanDMM evidence and report it separately from DreamMaker.

Use PowerShell for DreamMaker, DreamDaemon, Rust, Docker, process-memory measurement, and test runners. MCP compiler/runtime tools remain useful for contained diagnosis but do not replace the repository's PowerShell gates.

Tracy work also begins with a parsed environment. Prepare, launch, capture, summarize frame statistics/hotspots, compare like-for-like traces, and stop the MCP-owned process. Keep trace paths contained and record map, seed, revision, BYOND version, duration, and workload identity.

If MCP rejects an isolated worktree path, use a source-identical snapshot under a configured root only after recording hashes for the DME and every inspected/changed Dogmos file. Never silently inspect a different checkout.

Follow [verification](verification.md) and [Dogmos verification](dogmos-verification.md); distinguish source evidence, diagnostics, compiler results, runtime results, and performance traces.
