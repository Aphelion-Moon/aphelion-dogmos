# In-process build contract

The production target is the root `dogmos` engine inside 32-bit DreamDaemon. DM owns object identity, public procs, scheduling and gameplay effects. Native code owns numerical state, graphs and workers; callbacks run on the main thread.

Build with Rust 1.98.0, locked dependencies and the platform's i686 target. The selected features are `turf_processing,katmos,superconductivity,katmos_slow_decompression,aphelion_reactions`. The shared builder is `tools/build_in_process.py`; `tools/build_in_process.ps1` is the Windows wrapper. It generates the native library, symbols, bindings and exact source snapshot. Install through the game repository's `tools/dogmos/sync_in_process.py`.

Generated bindings select `DOGMOS_IN_PROCESS`, embed the source identity and load `dogmos.dll` on Windows or `libdogmos_in_process.so` on Linux. A Windows playtest bundle does not qualify Linux. Whole DreamDaemon memory/headroom, simulation latency and preserved gameplay are the acceptance targets. Compilation, boot, focused/full tests, populated play and performance remain separate evidence.

## Linux native build

Use an x86 Linux environment with Python 3.10 or newer, Git, rustup, a 32-bit C/C++ linker and runtime, libclang, and GNU binutils. On Ubuntu:

```sh
sudo apt-get update
sudo apt-get install --yes python3 git g++-multilib libclang-dev binutils
rustup toolchain install 1.98.0 --profile minimal --component rustfmt --component clippy --target i686-unknown-linux-gnu
rustc +1.98.0 --version
python3 -B tools/build_in_process.py --target i686-unknown-linux-gnu --output target/linux-playtest
```

The output directory must be new and beneath this checkout's `target/`. Build on Linux (including WSL Ubuntu); the builder executes the target's 32-bit binding generator, so selecting a Linux target from Windows is not a complete cross-compilation setup. If bindgen cannot locate libclang, set `LIBCLANG_PATH` to the directory containing the installed `libclang.so`.

The bundle contains `libdogmos_in_process.so`, separate `.so.debug` symbols, generated bindings, the exact source snapshot, and `dogmos-playtest.json`. The manifest remains explicitly unqualified. Build on the oldest supported deployment distribution and check the resulting ELF's glibc requirements against the deployment host; building on a newer distribution does not qualify an older host.

## Install and verify

From the matching Meridian-Rift Dogmos checkout, using absolute paths for the bundle and native source checkout:

```sh
python3 -B tools/dogmos/sync_in_process.py --bundle /path/to/aphelion-dogmos/target/linux-playtest --native-root /path/to/aphelion-dogmos
python3 -B tools/dogmos/verify_contract.py verify-installed --root .
```

The installer checks source inventory, hashes, ELF/i686 architecture, and generated bindings before accepting the installation. Linux uses `dogmos-linux.lock.json`; Windows uses `dogmos.lock.json`. If both platforms are installed, both must have identical source snapshots and bindings. A mismatch is rejected; preserve the old platform bundle and update both platforms from the same source state. Never edit locks or bindings by hand to bypass this check.

On Windows, keep using `tools/build_in_process.ps1 -OutputDirectory target/windows-playtest`, or invoke the Python builder with `--target i686-pc-windows-msvc`. Native MSVC build tools and libclang must be available. Installation uses the same Python synchronizer.

Run [verification gates](verification.md) on each platform. RIFT's compile/test/soak controller remains Windows-only; the native Linux build and installation do not port that controller.
