# Source authority and lineage

Reviewed game revision: `1623a76079a6617598498eaf7f5778f8564ed314`

Reviewed Nova revision: `c4846461cc82bce6a87e6efe6ea0c08e440838c6`

Reviewed Rust revision: `e0405c0398aba8851dca507cfcd27d4a898dff4c`

Reviewed agent-guide revision: `fe1f9c4729291c30370927f341be548c372815f6`

Reviewed on: `2026-08-26`

| Question | Authority |
| --- | --- |
| Deliberate Meridian policy and placement | Checked-in Meridian-Rift guidance and implementation. |
| Dogmos DM contract and scheduling | This game revision plus generated native contract inputs. |
| Dogmos Rust behavior | The reviewed `aphelion-dogmos` revision, its tests, and paired release manifest. |
| DreamMaker syntax/runtime | Official BYOND behavior and reproducible DreamMaker/DreamDaemon gates. |
| Inherited tgstation systems | Current checked-in tg guides and implementation unless a downstream delta is documented. |
| Nova modularization/lineage | [Local Nova handbook](../../modular_nova/readme.md), preserved markers, and the reviewed Nova revision. |
| Parser/DreamChecker/Tracy evidence | Meridian-MCP analysis; never a substitute for compiler or runtime gates. |

The reviewed game revision is a source baseline and must remain an ancestor of current `HEAD`; a document cannot contain the hash of the commit that contains itself. Update the anchor only after reviewing a new baseline.

When authorities disagree, identify the contract first. A tg bugfix should normally go upstream. A deliberate Meridian behavior belongs in Aphelion-owned code. Compiler behavior outranks parser acceptance. The repository's complete build/test path outranks a direct compile or focused-test claim. A generated binding or native artifact is authoritative only as part of the verified paired contract in [native artifacts](native-artifacts.md).

Do not invent remote identity or infer parity from branch names. Record exact revisions and paths. Preserve human-authored creative content and protected critical infrastructure as required by the root guidance.
