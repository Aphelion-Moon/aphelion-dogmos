# Linux startup hashing failure in Meridian-Rift PR 138

## Observed failure

Game PR head: `d637bd75912a62d36547db8f102daac41a831205`.
Native source and installed contract: `0bf856b37fb1d72f04ee0122c9c58bdc903ec254`.
CI: Ubuntu 24.04, BYOND 516.1687, workflow run `34140518368`.

The [completed first Blueshift attempt](https://github.com/AphelionDevelopment/Meridian-Rift/actions/runs/34140518368/job/101802141997?pr=138) records its first runtime at 15:57:25.497 UTC:

```text
Dogmos executable hashing currently requires Windows CNG
crates/dogmos-byond/src/session.rs:289:26
```

`start_service_session()` hashes the executable before spawning the service. The non-Windows implementation of `dogmos_identity::sha256_reader()` unconditionally returned `Unsupported`. The service also hashes its own executable before opening its listener, so both roles require working Linux hashing. Skipping the identity check would weaken the startup contract and is not a repair.

The first attempt contains 235 emitted runtime records across 13 file/line/message signatures. After the startup error, DM returns `SS_INIT_FAILURE` but continues mapping and atom initialization, producing unavailable-service, missing-gas-ID and null-list errors. Counts describe this cancelled first attempt, not the running second attempt or all maps.

The [user-linked second-attempt job](https://github.com/AphelionDevelopment/Meridian-Rift/actions/runs/34140518368/job/101810848048?pr=138) was still running when investigated; its downloadable log was not yet available. Both attempts use the same PR head. No CI job was cancelled, restarted or changed by this investigation.

## Source repair

- Retain the Windows CNG implementation.
- Replace the non-Windows stub with RustCrypto `sha2` 0.10.9, pinned for non-Windows targets only. Cargo added seven required packages without updating existing locked versions.
- Stream through a fixed 16 KiB buffer, include only bytes returned by each read, and propagate read errors instead of returning a partial digest.
- Enable the existing hash tests on all platforms. Add independent empty and million-byte vectors, short reads and a read failure after a valid prefix.

The implementation uses the [RustCrypto incremental digest API](https://docs.rs/sha2/0.10.9/sha2/). No protocol, source-identity comparison, authentication, numerical or gameplay behavior is changed.

## Verification

Pinned Rust: `rustc 1.98.0 (88d9e12ae 2026-08-18)`. Linux execution used the existing Ubuntu WSL distribution. Tests and builds used `--locked` after the intentional dependency resolution.

- Red: enabling the original two hash tests on Linux reproduced the exact CNG error. All six expanded regressions failed against the stub before the implementation change.
- Green: `cargo +1.98.0 test -p dogmos-identity --locked --target <target>` passed 10 tests (six hash, four metadata) on each of `i686-unknown-linux-gnu`, `x86_64-unknown-linux-gnu`, `i686-pc-windows-msvc` and `x86_64-pc-windows-msvc`.
- Strict Clippy for `dogmos-identity --all-targets` passed with `-D warnings` on all four targets.
- `cargo +1.98.0 test -p dogmos-byond --locked --target i686-unknown-linux-gnu` passed 44 executable tests. Windows-only bounded-I/O tests are not exercised on Linux.
- `cargo +1.98.0 test -p dogmos-core -p dogmos-protocol -p dogmos-server --locked --target x86_64-unknown-linux-gnu` passed. The server's Windows/x86-only integration test files run zero tests on this target; the separate process probe below supplies Linux process evidence.
- Built the i686 Linux shim library and cross-bitness probe and the x86_64 Linux service. The real Linux probe passed: two ordered reaction callbacks, 1,030 continuation lifecycle cycles, five replacement modes, no pending work, clean exit. Its five `UnknownContinuation` diagnostics are expected rejection cases.
- The maintained Windows `tools/test_cross_bitness_ipc.ps1` also passed those cross-bitness checks.
- Formatting, dependency-direction and agent-documentation checks passed.

Linux process probe reproduction, invoked through PowerShell/WSL:

```sh
export DOGMOS_SOURCE_REVISION=0bf856b37fb1d72f04ee0122c9c58bdc903ec254
export DOGMOS_FEATURE_FINGERPRINT=8691f3e1e88c5dba8ff06507bc1064823c18c09232b3000a5fc863893e35d1a0
cargo +1.98.0 build -p dogmos-server --bin dogmosd --locked --target x86_64-unknown-linux-gnu
cargo +1.98.0 build -p dogmos-byond --lib --example cross_bitness_probe --locked --target i686-unknown-linux-gnu
timeout 60s target/i686-unknown-linux-gnu/debug/examples/cross_bitness_probe target/x86_64-unknown-linux-gnu/debug/dogmosd
```

These are uncommitted candidate/debug artifacts with the baseline revision as a test identity, not a distributable release. The maintained Windows probe explicitly permits a dirty candidate. Production packaging requires a committed, clean source revision.

## Remaining integration gates

The user authorized the native source repair and requires separate approval before installing protected artifacts. No game binaries, generated bindings, lockfiles or workflows were changed. The user subsequently authorized committing the native fix and preparing the release; installation still requires separate approval.

1. Commit the six reviewed native source/test/dependency/documentation files under the subsequent user authorization.
2. Build and validate a complete paired release from that clean commit using the maintained release tooling; record fresh hashes and symbols.
3. Obtain separate approval to install the resulting seven-file game contract set: `dogmos.dll`, `dogmosd.exe`, `libdogmos.so`, `dogmosd`, `dogmos.lock.json`, `code/__DEFINES/dogmos_bindings.dm` and `code/__DEFINES/dogmos_contract.dm`. Use the maintained synchronizer; no hand-edited generated output or single-library replacement.
4. Rerun Linux BYOND initialization and the CI map suite on the updated PR. Native tests and the process probe do not establish hosted DM success.
5. Bring forward the DM startup-abort containment from game commit `7c6b5c78cae21c3080449e005d86306bedfc925a` under separately authorized Git integration. That commit is not an ancestor of PR head, and direct source comparison confirms its `abort_startup()` path is absent. The containment stops the secondary cascade but cannot implement native Linux hashing.

Full game CI remains unresolved until the new release is installed and exercised. No performance improvement is claimed.
