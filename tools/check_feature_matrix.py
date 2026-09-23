"""Check supported i686 feature combinations with the pinned Rust toolchain."""
from __future__ import annotations

import argparse
from pathlib import Path
import subprocess
import sys

TARGETS = ("i686-pc-windows-msvc", "i686-unknown-linux-gnu")
CONFIGURATIONS = (
    ("no features", True, None),
    *((feature, True, feature) for feature in (
        "turf_processing", "fastmos", "katmos", "superconductivity",
        "reaction_hooks", "aphelion_reactions", "citadel_reactions",
        "yogs_reactions", "zas_hooks",
    )),
    ("default", False, None),
    ("default + tracy", False, "tracy"),
)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cargo", default="cargo")
    parser.add_argument("--target", choices=TARGETS, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    for name, no_default, features in CONFIGURATIONS:
        command = [args.cargo, "+1.98.0", "check", "--workspace", "--locked",
                   "--target", args.target, "--all-targets"]
        if no_default:
            command.append("--no-default-features")
        if features:
            command.extend(("--features", features))
        print(f"Checking Dogmos feature configuration: {name}", flush=True)
        result = subprocess.run(command, cwd=root, check=False)
        if result.returncode:
            print(f"Dogmos feature configuration '{name}' failed with exit code {result.returncode}.",
                  file=sys.stderr)
            return result.returncode
    print("All Dogmos feature configurations passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
