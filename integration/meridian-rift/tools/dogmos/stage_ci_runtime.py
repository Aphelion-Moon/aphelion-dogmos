"""Stage the pinned Linux Dogmos pair before the CI launcher starts DreamDaemon."""

import argparse
from pathlib import Path
import shutil
import sys

if __package__:
    from . import verify_contract as contract
else:
    import verify_contract as contract


def stage_runtime(root: Path, destination: Path) -> None:
    """Fail closed on invalid input or I/O; destination must already exist.

    The source uses the complete installed-contract gate, including both platforms
    and generated DM inputs. Only the Linux runtime pair is copied. This is not
    an atomic directory update: the launcher must honor failure before launch.
    """
    root = Path(root)
    destination = Path(destination)
    manifest = contract.verify_installed(root)
    for artifact in manifest["artifacts"]:
        if artifact["platform"] != "linux":
            continue
        name = contract.INSTALLED_ARTIFACTS["linux", artifact["role"]]
        shutil.copyfile(root / name, destination / name)
        contract._verify_record({**artifact, "file": name}, destination, "staged Linux artifact")
    service = destination / contract.INSTALLED_ARTIFACTS["linux", "service"]
    service.chmod(service.stat().st_mode | 0o111)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    arguments = parser.parse_args()
    try:
        stage_runtime(arguments.root, arguments.destination)
    except (contract.ContractError, OSError) as error:
        print(f"Dogmos runtime staging failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
