"""Read-only Dogmos source, installed contract and optional bundle/runtime diagnosis.

Uses the paired game's existing contract verifier; never loads a library, starts a
world, downloads artifacts, changes a manifest or asserts runtime qualification.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True
from dogmos_source_snapshot import canonical_bytes, capture_snapshot


def revision(root: Path) -> str:
    return subprocess.check_output(
        ["git", "-c", f"safe.directory={root.as_posix()}", "-C", str(root), "rev-parse", "HEAD"],
        text=True, stderr=subprocess.PIPE,
    ).strip()


def diagnose(game: Path, native: Path, target: str, bundle: Path | None = None,
             runtime_report: Path | None = None) -> dict:
    report = {"mode": "offline", "errors": [], "runtime": "not checked",
              "symbols": "not checked; provide --bundle", "qualification": "not checked"}
    try:
        # This is the same maintained verifier used by installation, not a second contract.
        spec = importlib.util.spec_from_file_location("dogmos_installed_contract", game / "tools/dogmos/verify_contract.py")
        verifier = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(verifier)
        manifest = verifier.verify_installed(game, target=target)
        report.update(installed_contract="verified", native_revision=revision(native),
                      game_revision=revision(game), target=manifest["target"],
                      toolchain=manifest["toolchain"], features=manifest["features"],
                      installed_source_revision=manifest["source_revision"],
                      installed_source_sha256=manifest["source_sha256"],
                      artifacts=manifest["artifacts"],
                      qualification={"kind": manifest["kind"], "tests_run": manifest["tests_run"],
                                     "runtime_qualified": manifest["runtime_qualified"]},
                      build_provenance=manifest.get("build_provenance", "not recorded"))
        current_digest = hashlib.sha256(canonical_bytes(capture_snapshot(native))).hexdigest()
        report["current_source_sha256"] = current_digest
        if current_digest != manifest["source_sha256"]:
            report["errors"].append("Installed bundle differs from current native source; build and synchronize a reviewed matching bundle.")
        if bundle is not None:
            for name, digest in manifest["artifacts"].items():
                path = bundle / name
                if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
                    report["errors"].append(f"Bundle artifact missing or mismatched: {name}")
            symbol = verifier.native_files(manifest)[1]
            report["symbols"] = "matching" if (bundle / symbol).is_file() and hashlib.sha256((bundle / symbol).read_bytes()).hexdigest() == manifest["artifacts"][symbol] else "missing or mismatched"
        if runtime_report is not None:
            if runtime_report.stat().st_size > 65536:
                raise ValueError("Runtime report exceeds 64 KiB")
            runtime = json.loads(runtime_report.read_text(encoding="utf-8"))
            if not isinstance(runtime, dict):
                raise ValueError("Runtime report must be a JSON object")
            report["runtime"] = {"evidence": "supplied main-thread report; freshness not independently checked", "report": runtime}
            if runtime.get("identity") != f'in-process:{manifest["source_sha256"]}':
                report["errors"].append("Reported loaded library differs from installed disk contract; inspect the running world's matched bundle.")
    except (OSError, ValueError, subprocess.SubprocessError, RuntimeError) as error:
        report["errors"].append(str(error))
    report["ok"] = not report["errors"]
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--game-root", required=True, type=Path)
    parser.add_argument("--native-root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--target", choices=["i686-pc-windows-msvc", "i686-unknown-linux-gnu"], required=True)
    parser.add_argument("--bundle", type=Path)
    parser.add_argument("--runtime-report", type=Path, help="Saved JSON from dogmos_in_process_capabilities(), never an automatic live query")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    report = diagnose(args.game_root.resolve(), args.native_root.resolve(), args.target, args.bundle, args.runtime_report)
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print("Dogmos offline inspection: " + ("matched" if report["ok"] else "mismatch or unavailable"))
        for key, value in report.items():
            if key not in ("ok", "errors", "artifacts"):
                print(f"{key}: {value}")
        for error in report["errors"]:
            print(f"ERROR: {error}")
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
