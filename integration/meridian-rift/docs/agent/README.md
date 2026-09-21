# Agent guide index

| Work                                                 | Read                                                                                                                               |
| ---------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| DM style, correctness, security                      | [STYLE](../../.github/guides/STYLE.md), [AUTODOC](../../.github/guides/AUTODOC.md), [STANDARDS](../../.github/guides/STANDARDS.md) |
| Reference lifecycle or `Destroy()`                   | [HARDDELETES](../../.github/guides/HARDDELETES.md)                                                                                 |
| Planes, layers, filters, overlays                    | [VISUALS](../../.github/guides/VISUALS.md)                                                                                         |
| Source conflicts and lineage                         | [Source authority](source-authority.md)                                                                                            |
| Aphelion/Nova placement and markers                  | [Placement and markers](placement-and-markers.md), [Nova handbook](../../modular_nova/readme.md)                                   |
| General verification                                 | [Verification](verification.md)                                                                                                    |
| Agent compile, boot, test, and soak control          | [RIFT controller](rift-controller.md)                                                                                              |
| DreamMaker navigation                                | [Meridian-MCP](meridian-mcp.md)                                                                                                    |
| Lore and generated artifacts                         | [Generated content](generated-content.md)                                                                                          |
| tg/Nova merge review                                 | [Upstream drift](upstream-drift.md)                                                                                                |
| Dogmos DM/Rust ownership                             | [Dogmos integration](dogmos-integration.md)                                                                                        |
| Rust-to-DM gameplay effects and callback replacement | [Dogmos gameplay events](dogmos-gameplay-events.md)                                                                                |
| Service startup, failure, recovery, shutdown         | [Dogmos service lifecycle](dogmos-service-lifecycle.md)                                                                            |
| Dogmos memory and performance                        | [Dogmos performance and memory](dogmos-performance-and-memory.md)                                                                  |
| Dogmos compile, boot, and tests                      | [Dogmos verification](dogmos-verification.md)                                                                                      |
| Shim/service/bindings contract                       | [Native artifacts](native-artifacts.md)                                                                                            |
| Public Dogmos architecture and status                | [Dogmos Tech Memo](../tech-memos/dogmos.md)                                                                                        |

The root [AGENTS.md](../../AGENTS.md) is the concise mandatory entry point. These guides add Meridian and Dogmos decisions without replacing inherited tgstation, Nova, Rust, or BYOND documentation.

Generated Dogmos plans, reports and verification artifacts are stored centrally under `GitHub/.agent_docs/meridian-rift/dogmos/`. The archive index maps their original repository paths.
