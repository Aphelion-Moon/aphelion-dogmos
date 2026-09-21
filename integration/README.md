# Preserved Meridian integration

The native repository at this branch retains the retired service implementation, its tests, build/release tooling and local repairs before extraction. `meridian-rift/` contains exact working-tree files for the matching game integration. `manifest.json` records the game base revision and byte hashes.

To restore for future work, start from that Meridian revision and overlay these files at their recorded relative paths. The snapshot includes the in-process selection; regenerate and synchronize service artifacts using the preserved tooling before selecting that backend. Do not treat the included binaries or local changes as a qualified service release.
