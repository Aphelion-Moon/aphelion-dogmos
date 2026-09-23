# FFI and generated bindings

Every BYOND export is a panic boundary. Validate types, arity and finite numeric inputs, preserve caller-legible errors, and never unwind into DreamDaemon. `auxmacros` routes exports through the guarded FFI boundary. BYOND callbacks run on the main thread.

The paired game requires `__turf_settled` and `__update_dogmos_visuals`. Settlement
uses the existing batched comparison contract and releases numerical locks before
waking neighbors. Scoped turf API reads adopt their owned results with
`OwnedByondValue`; the pinned BYOND 516 API makes these references persistent.
Never adopt borrowed binding arguments or copied cache entries. Repeated-call
reference accounting requires DreamDaemon verification.

Never hand-edit generated bindings, contract defines or artifact manifests. Regenerate with `tools/build_in_process.py` (or its Windows PowerShell wrapper), compare deterministic bytes and install the complete matching set through Meridian-Rift's synchronizer. The source snapshot identity identifies exact build inputs. Binding inventories do not substitute for a real i686 native-load test.
