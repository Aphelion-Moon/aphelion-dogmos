# Native stage-job observations

Protocol 16 appends a 112-byte stage-job block to ServiceTelemetry (480 bytes total). The exact-word shim list grows from 182 to 236 fields. Existing fields keep their positions. A protocol-15 pair remains a separate artifact set and must not be mixed with this candidate.

The service owns one fixed-size observation structure per world. It retains no samples, handles, DM references or per-job history. Counters saturate at u64 maximum. Timing uses monotonic wall-clock nanoseconds; it never changes simulation seconds, work limits or scheduling budgets.

The extension carries the latest job's exact u64 identity, status, and age; preparation and commit call counts, total/maximum/last elapsed durations; publication retry count; and completed/cancelled job counts. Status zero and job identity zero mean no admitted job. Age starts after successful admission, includes waiting for DM to authorize publication, and freezes on terminal completion/cancellation. Starting another job resets its age and preserves the world-lifetime counters.

Preparation measures the actual runnable controller/core call, including its cleanup. Poll and a call against already-ready work do not count as preparation. Commit measures the complete service method, including callback-capacity reservation, publication, event enqueue, rejected requests and exact receipt replay. A replay consumes control-call time but cannot increment completed jobs or enqueue callbacks twice. A failure after publication is recorded as cancellation rather than an acknowledged successful job.

`publication_retries` counts successful Commit replies with Retrying status. It is **not a revision-conflict counter**: publication can also be withheld by capacity/admission conditions. The R0 conflict observation remains unavailable until the underlying causes are separately counted. Completed jobs count native stages, not complete atmosphere cycles; use the MC's completed-cycle witness for the latter.

## Fixed layout

The first eight bytes are job identity, followed by status u16 and six reserved zero bytes. The remaining twelve u64 values are, in order: age; preparation count/total/max/last; commit count/total/max/last; publication retries; completed jobs; cancelled jobs. All values use explicit little-endian encoding. The decoder rejects nonzero reserved fields, unknown status, inconsistent job/status presence, and age without a job.

DM fields 183-186 carry the job identity, 187-188 carry status, and fields 189-236 carry those twelve u64 values as four exact 16-bit words each. Keep identity and cumulative counters in words for exact comparisons. Converting durations to milliseconds is suitable for display; retain raw words alongside exported observations.

The paired DM helper `dogmos_job_observations_snapshot()` acquires one telemetry reply on demand. Its validated result contains `job_words`, `status`, all 54 extension `raw_words`, the twelve named values suffixed `_words`, and seven display durations suffixed `_ms`. For example, `prepare_calls_words` is exact while `prepare_total_ms` is an approximate display conversion from nanoseconds. No recurring collector or RPC is added to the atmosphere tick by this helper. Malformed diagnostic replies are errors rather than zero-valued observations.

## Measurement limits

These counters supply bounded diagnostic observations, not a histogram or a complete per-call trace. A last-duration sample is a single observed call only when its counter advances by exactly one between observations; larger deltas mean intervening samples are unavailable. A lifetime maximum cannot be treated as a later window's maximum. Counter saturation also makes subsequent exact deltas unavailable.

Keep raw service observations, their acquisition times and applicability with the workload. Do not fabricate missing per-call distributions or label publication retries as conflicts. RPC queue/I/O wait, main-thread work, cycle age and separate process resources still need their own measurements. Performance acceptance remains governed by the runtime observation contract and matched server workloads.
