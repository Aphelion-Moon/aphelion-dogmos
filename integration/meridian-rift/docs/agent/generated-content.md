# Generated content

Generated artifacts have an external or programmatic authority. Never hand-edit a generated output to make a downstream check pass. Change the source/schema/generator, regenerate deterministically, and review the resulting diff.

Dogmos bindings and native contract defines are governed by [native artifacts](native-artifacts.md). `code/__DEFINES/dogmos_bindings.dm` and the planned `code/__DEFINES/dogmos_contract.dm` are downstream products of the reviewed Rust release. They must match the paired shim/service manifest and are installed atomically.

Aphelion Content Tools owns structured lore source, validation, browser workflow, and staged export. Meridian-Rift receives only the generated runtime DM artifact. Creative authorship remains human-owned; agents may maintain schemas, validation, review, export, and runtime integration without rewriting final creative substance.

Generation is not game acceptance. Validate manifest/schema/source hashes, inspect the generated diff, compile the game, and run affected runtime/AutoWiki paths. Catalog loading or a successful generator process alone is insufficient.
