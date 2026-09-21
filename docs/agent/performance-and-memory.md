# Performance and memory

Measure whole DreamDaemon private committed bytes, working set, virtual size, largest free address-space region, CPU and tick latency. Native DLL allocations are in-process DreamDaemon allocations. Do not infer memory savings from code moving into Rust.

Compare at least three identical controls and candidates with the same map, workload, seed where controllable, features, BYOND version and duration. Report noise and numerical/event equivalence. Procedure inclusive costs overlap; never sum them as independent costs. Keep expensive memory scans behind diagnostic sampling and report their cadence.
