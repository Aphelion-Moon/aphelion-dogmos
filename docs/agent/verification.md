# Verification matrix

Use Rust 1.98.0 and `--locked`. Run `cargo +1.98.0 fmt --all -- --check`, strict workspace Clippy, workspace tests and `tools/check_feature_matrix.ps1` for the supported i686 target. Run `python -B -m unittest discover -s tools/tests -v`, documentation and dependency checks. Windows uses `i686-pc-windows-msvc`; Linux uses `i686-unknown-linux-gnu`.

Regenerate bindings and compare exact output. In Meridian-Rift, run its maintained DreamMaker compile, focused integration fixtures, native-load boot and full unit-test suite. Use Meridian-MCP for source analysis and reparse after changes. Parser diagnostics are separate from compiler/runtime evidence.

Report each gate and its limits separately. A focused fixture, host-only build or process still being alive is not complete qualification. Bound test lifetimes, identify owned processes and inspect fresh logs/results. Performance claims require repeated equivalent workloads. Record source/artifact hashes and run `git diff --check` before handoff.
