# Build artifacts

`tools/build_in_process.py` builds a Windows i686 DLL or Linux i686 shared library with symbols, runs the binding generator, captures the exact source inventory and writes `dogmos-playtest.json`. `tools/build_in_process.ps1` remains a Windows wrapper. This manifest deliberately identifies an unqualified local playtest, even when separate verification gates have passed.

Synchronize the complete bundle with Meridian-Rift's `tools/dogmos/sync_in_process.py`. Verify hashes, target architecture, source inventory and generated bindings/defines before use. Never hand-edit generated artifacts. Linux builds use the same engine and i686 target; the game loads `libdogmos_in_process.so`.

Builds and local synchronization are within authorized implementation work. Publication, live deployment and production restarts require their own authorization. Do not publish local playtest manifests as qualified releases. Generated evidence belongs in the central archive; maintained build tools and required runtime artifacts stay with source.
