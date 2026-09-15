# Bounded frontier upload correction

Status: local qualification passed: eighteen focused tests, 670 full-suite tests, fresh async progress and the 300-second soak. The preceding full-suite run `20260914T162454Z-acd7ce6f` failed on `FrontierAppend` at offset 512; it did not recur in the repeat. Controlled server playtesting and matched performance remain outstanding. Native protocol-16 bundle 05 is unchanged.

## Contract mismatch

Full reconciliation captures `length(active_turfs)` as its declared wire count and advances offsets by source entries visited. Preparation returns an associative turf-to-handle map. Duplicate source turfs collapse within that map, so source positions are not wire positions. Duplicates within a slice leave holes; duplicates across slices violate the native unique-handle contract. The existing bloat fixture deliberately constructs repeated turfs, and the public list remains a legacy scheduling input.

The full-run service diagnostic collapses distinct frontier errors to `FrontierConflict`. The count/uniqueness bug is independently reproducible; it is not yet established as the cause of that particular live-MC failure.

## Correction and invariants

Collect the unique candidate before declaring its native size. Collection visits at most 512 source entries per call. A separate cursor then uploads at most 512 candidate members per call using contiguous accepted offsets. First occurrence defines order, matching the previous associative full snapshot. The original active list is not normalized or replaced.

Retain the exact revision fence across collection, upload and commit. A changed revision retires the unpublished candidate in bounded tail slices; a subsequent Begin uses an epoch above every previous attempt. Recovery retains that epoch high-water mark and deliberately invalidates unfinished collection/upload. A rejected receipt does not advance an accepted cursor, frontier or epoch. No incomplete candidate becomes available to a simulation stage.

This adds a bounded pass over the unique candidate on a full rescan. Steady-state journal publication remains unchanged. No linear deduplication is added to activation, deletion or signal handlers; native Begin/Commit and registration-flush costs retain their existing limits.

## Qualification

- Strict transport oracle: Begin count, contiguous ranges, no repeated handles and atomic rejection.
- Regression: zero, one and 513 unique turfs with repeated entries within/across slices; exact order and unchanged source list.
- Membership change during collection and after the first accepted upload slice; bounded retirement and strictly newer restart epoch.
- Rejected Begin/Append/Commit, recovery invalidation and native shim/service receipts.
- Focused DM gate, fresh async observation, full suite and 300-second soak against a separately frozen game-source archive.

Compiler, parser, local runtime progress and main-server performance remain distinct evidence. Preserve the failed run and earlier qualified source archives.

## Recorded evidence

Regression run `20260914T165426Z-2a4f9bc4` compiled with zero errors and two existing warnings, then failed the intended assertion for one unique turf plus a duplicate. It recorded one failed test, zero runtimes and clean owned-process shutdown. The exact twelve-file source archive is `target/r6-frontier-red-dm-source.zip`, SHA-256 `3e892605263fbe9ae5bd98896dd74e6d3737af83d1dad6ad6dcc556594c7fccd`.

The corrected twelve-file candidate is frozen in `target/r6-frontier-candidate-dm-source.zip`, SHA-256 `640e5ac8acc575e3244a31ba259e8a5843a0c331ab31e4373f175a647dbc5559`, with a cumulative [game patch](../patches/2026-09-14-meridian-frontier-candidate.patch). The correction itself changes the uploader, one SSair cursor field and regression/recovery tests; earlier R1/R2/R5 and observer changes remain in the cumulative archive. Focused run `20260914T170332Z-f597a431` requests eighteen tests against this source and the unchanged bundle-05 pair.

Meridian-MCP generation 20 retains the existing 127 error and three warning totals. The uploader and recovery fixture have no diagnostics; the transport fixture retains three existing static-type warnings, and `air.dm` has a redefinition hint. Parser evidence is retained in `target/r6-frontier-mcp.json`. These diagnostics are separate from DreamMaker and runtime gates. Completed run evidence is accumulated per source archive in [the qualification record](2026-09-14-frontier-upload-evidence.json).

Focused run `20260914T170332Z-f597a431` compiled with zero errors and two existing warnings, passed all eighteen tests with zero failures/skips/runtimes, shut down naturally and left no owned survivors. DMB SHA-256: `33e86a056ed372621de827d8ea8b14363104b1b826254bb398beed5bfdafca4d`; RSC: `dbd22e6de8895d3370da219480d1ff31ccc1171ad33b959427f970d02b9ad6fb`. This is focused correctness evidence, not full-suite or performance acceptance.

Full run `20260914T171331Z-53228d78` compiled with zero errors and two existing warnings, passed all 670 tests with zero failures/skips/runtimes, shut down naturally and left no owned survivors. Both `firedoor_regions` and `fish_rescue_hook` passed, followed by the remaining gameplay and create/destroy tests. DMB SHA-256: `a13238a45ccf8a1ea0c1e41ef64376e61d54dd9ab2afba24532ff7292c8e0159`; RSC: `dcac55501b722ff7aea2591b39303fdd652b824760d5aa541bfbf4c6b9e596bd`. This suite used ordinary configuration with async stages disabled; opt-in observation and soak are separate gates.

Async observation `20260914T173512Z-99791005` passed all progress criteria over 180.087 seconds of gameplay: 52 completed atmosphere cycles, 421 completed native stage jobs, 3,643 prepare calls, 1,349 commit calls and zero publication retries/cancellations. Both recorded tests passed with zero runtimes and clean owned-process shutdown. The exact original CI configuration was restored; both configuration byte sets are retained. [The observation record](2026-09-14-async-frontier-observation.json) binds 134 samples and their raw hash. This is a single busy-host functional progress observation, not a matched performance improvement claim.

Soak `20260914T174619Z-086e1c0b` passed a full production build with zero errors/warnings, initialized full RuntimeStation, and completed its 300-second bounded window with async mode configured and no runtimes or fatal signatures. The runner then requested termination and verified no owned survivors; this is intentional soak shutdown, not a naturally exiting unit-test run. The exact original game configuration was restored. DMB SHA-256: `fa9dd86d1f58cf5764818bbf66aa16f955b29344f23625ddbc8def7b7ad4ffae`; RSC: `9aa3aab79f22fae25b2aa84c045aacb3cc85bbcc8662e8e713305cb57c9303d5`. Separately sampled private-byte maxima were 1,891,516,416 for DreamDaemon and 137,940,992 for the service. These are one-run observations without a matched control; do not combine them into a DreamDaemon footprint claim.
