# Native artifact contract

`dogmos.lock.json` is the game-side authority for one paired release. It identifies schema, ABI and protocol version, Rust crate/source/toolchain/byondapi revisions, sorted features/fingerprint, generated bindings digest, and platform artifact names/hashes.

Required release members are:

- Windows 32-bit shim `dogmos.dll` and 64-bit service `dogmosd.exe`, with symbols;
- Linux 32-bit shim `libdogmos.so` and 64-bit service `dogmosd`, with symbols;
- generated `code/__DEFINES/dogmos_bindings.dm`;
- generated `code/__DEFINES/dogmos_contract.dm` from the verified manifest.

The game validates ABI, protocol version, exact source revision, feature fingerprint, bindings digest, shim hash, and service hash before gas registration. The runtime handshake independently requires shim/service agreement. Missing, truncated, wrong-architecture, cross-revision, development, or hash-mismatched inputs reject the complete set; never load a partial pair.

Generated bindings/contract defines are never hand-edited. A maintained synchronizer verifies a scratch staging directory and installs the complete platform set atomically. Production Docker/TGS paths fetch an exact revision or verified release, never a mutable branch.

Rebuilding native artifacts, regenerating bindings, contract defines, manifests and artifact lock data, and synchronizing the complete verified pair into a local development or test checkout are included in authorized implementation and verification work. Do not request separate per-file approval because these outputs are protected. Necessary in-scope protocol, generator and synchronizer changes follow the same task authorization and required verification gates.

Use maintained tooling and preserve staging validation and atomic installation. Unrelated dependency, Docker, TGS, workflow or deployment changes remain subject to the infrastructure policy in `AGENTS.md`. Release publication, live deployment and production restarts retain their own authorization requirements.
