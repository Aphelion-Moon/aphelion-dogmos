"""Install a matching, explicitly unqualified native bundle into a development checkout."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

from verify_contract import (ContractError, _duplicate_guard, render_contract_defines,
                             validate_in_process_manifest, verify_in_process_bytes, verify_installed)


def atomic_write(path: Path, data: bytes) -> None:
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".dogmos-install-", delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(data)
        os.replace(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, required=True)
    parser.add_argument("--native-root", type=Path, required=True)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    args = parser.parse_args()
    bundle, root = args.bundle.resolve(), args.root.resolve()
    manifest = json.loads((bundle / "dogmos-playtest.json").read_text(encoding="utf-8-sig"),
                          object_pairs_hook=_duplicate_guard)
    validate_in_process_manifest(manifest)
    artifacts = {name: (bundle / name).read_bytes() for name in manifest["artifacts"]}
    for name, data in artifacts.items():
        if hashlib.sha256(data).hexdigest() != manifest["artifacts"][name]:
            raise ContractError(f"bundle hash mismatch: {name}")
    verify_in_process_bytes(manifest, artifacts["dogmos.dll"], artifacts["dogmos_bindings.dm"])
    # Validate against the actual source checkout, not merely a self-consistent manifest.
    import sys
    subprocess.run([sys.executable, "-B", str(args.native_root / "tools/dogmos_source_snapshot.py"),
                    "verify", "--repository-root", str(args.native_root),
                    "--snapshot", str(bundle / "dogmos-source-snapshot.json")], check=True)
    if not (root / "tgstation.dme").is_file():
        raise ContractError("destination is not a Meridian-Rift checkout")
    replacements = {
        root / "dogmos.dll": artifacts["dogmos.dll"],
        root / "code/__DEFINES/dogmos_bindings.dm": artifacts["dogmos_bindings.dm"],
        root / "code/__DEFINES/dogmos_contract.dm": render_contract_defines(manifest),
        root / "dogmos.lock.json": (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode(),
    }
    previous = {path: path.read_bytes() if path.exists() else None for path in replacements}
    try:
        for path, data in replacements.items():
            atomic_write(path, data)
        verify_installed(root)
    except BaseException:
        for path, data in previous.items():
            if data is None:
                path.unlink(missing_ok=True)
            else:
                atomic_write(path, data)
        raise
    print(f"Installed Windows in-process candidate {manifest['source_sha256']}; runtime qualification deferred.")


if __name__ == "__main__":
    main()
