# Gameplay callbacks

Native workers enqueue bounded main-thread callback work through `auxcallback`. DM owns pressure movement, floor ripping, firelocks, turf destruction, reaction signals and visuals. Preserve callback order, validate live targets and avoid duplicate settlement. Reaction callbacks must finish before retirement or follow-up effects use their results.

No panic may unwind across the BYOND boundary. Never call DM from numerical workers or while holding locks needed by the callback. Track queue depth and settlement cost without adding whole-world scans. Verify the real DreamDaemon path as well as Rust tests.
