# Placement and edit markers

New Meridian-owned content uses the flat `modular_aphelion/modules/<module_id>/{code,icons,sound}/` layout. Overrides mirror the core path under `modular_aphelion/master_files/`. Do not mirror the core tree inside a module or mix file types. Non-trivial modules follow [the checked-in module template](../../modular_nova/module_template.md) with Aphelion ownership. Preserve inherited `modular_nova` paths and `NOVA EDIT` ownership.

Unavoidable edits to inherited core use exact `SCREAMING_SNAKE_CASE` module IDs:

```dm
// APHELION EDIT ADDITION START - MODULE_ID
new_code()
// APHELION EDIT ADDITION END

/* // APHELION EDIT REMOVAL START - MODULE_ID
old_code()
*/ // APHELION EDIT REMOVAL END

changed_line() // APHELION EDIT CHANGE - MODULE_ID - ORIGINAL: complete original line
```

Multi-line changes use a removal plus addition pair. A narrow marked edit is preferable to copying a large upstream proc whose future changes would silently diverge. New Nova markers are allowed only during an explicit reviewed Nova synchronization; they do not transfer ownership.

Dogmos' forced atmosphere fork has a narrow exception because the Rust-backed gas representation replaces the inherited implementation across that subtree. Read [Dogmos integration](dogmos-integration.md) before relying on it. The exception is path-based, does not cover unrelated gameplay/machinery/UI, and does not authorize hand-editing generated files.

Fixes applicable to tgstation should be prepared upstream. If urgency requires a local patch, document its upstream issue/PR and removal condition.
