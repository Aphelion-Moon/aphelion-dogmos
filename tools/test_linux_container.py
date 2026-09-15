"""Qualify a matching Linux service with the maintained i686 IPC probe in isolated Docker.

Run with Linux Python (including WSL). Build the probe from the bundle's exact source
identity first. This tests real Linux cross-bitness IPC/cleanup, not DreamDaemon loading.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import time


def run(arguments: list[str], *, timeout: int = 180) -> subprocess.CompletedProcess[str]:
    return subprocess.run(arguments, capture_output=True, text=True, encoding="utf-8", timeout=timeout, check=True)


def elf_class(path: Path) -> int:
    with path.open("rb") as stream:
        header = stream.read(20)
    if header[:4] != b"\x7fELF" or header[5] != 1:
        raise ValueError(f"Expected little-endian ELF: {path}")
    machine = struct.unpack_from("<H", header, 18)[0]
    expected = {1: 3, 2: 62}
    if expected.get(header[4]) != machine:
        raise ValueError(f"Unexpected ELF machine: {path}")
    return header[4]


def qualify(bundle: Path, probe: Path, output: Path, image_id: str) -> None:
    if not image_id.startswith("sha256:") or len(image_id) != 71:
        raise ValueError("Use the immutable sha256 image ID produced by docker build --iidfile")
    output.mkdir(parents=True, exist_ok=False)
    repository = Path(__file__).resolve().parents[1]
    verifier = repository / "tools/dogmos_contract.py"
    manifest = bundle / "dogmos-release-manifest.json"
    verify = ["python3", "-B", str(verifier), "verify", "--manifest", str(manifest), "--bundle-root", str(bundle)]
    run(verify)
    if (elf_class(bundle / "linux/libdogmos.so"), elf_class(bundle / "linux/dogmosd"), elf_class(probe)) != (1, 2, 1):
        raise ValueError("Expected i686 shim/probe and x64 service")
    identity = json.loads(manifest.read_text(encoding="utf-8"))
    report = {"source_revision": identity["source_revision"], "image_id": image_id,
              "probe_sha256": hashlib.sha256(probe.read_bytes()).hexdigest(),
              "manifest_sha256": hashlib.sha256(manifest.read_bytes()).hexdigest(),
              "platform": "linux", "probe_bits": 32, "shim_bits": 32, "service_bits": 64,
              "dreamdaemon_loaded": False, "network": "none", "read_only": True, "passed": False}
    container = None
    started = time.monotonic()
    try:
        container = run(["docker", "create", "--init", "--network", "none", "--read-only",
                         "--tmpfs", "/tmp:rw,exec,nosuid,size=64m",
                         "--mount", f"type=bind,src={bundle},dst=/contract,readonly",
                         "--mount", f"type=bind,src={probe},dst=/probe,readonly",
                         "--entrypoint", "/probe", image_id, "/contract/linux/dogmosd"]).stdout.strip()
        report["container_id"] = container
        completed = run(["docker", "start", "--attach", container])
        (output / "stdout.log").write_text(completed.stdout, encoding="utf-8")
        (output / "stderr.log").write_text(completed.stderr, encoding="utf-8")
        inspected = json.loads(run(["docker", "inspect", container]).stdout)[0]
        report["state"] = inspected["State"]
        if inspected["State"]["Running"] or inspected["State"]["ExitCode"] != 0:
            raise RuntimeError("Container did not exit successfully")
        run(verify)
        report["passed"] = True
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        for name in ("stdout", "stderr"):
            content = getattr(error, name, "") or ""
            if isinstance(content, bytes): content = content.decode("utf-8", errors="replace")
            (output / (name + ".log")).write_text(content, encoding="utf-8")
        report["passed"] = False
        raise
    finally:
        if container:
            run(["docker", "rm", "--force", container])
            remaining = run(["docker", "ps", "--all", "--quiet", "--filter", f"id={container}"]).stdout.strip()
            report["container_removed"] = not remaining
            if remaining: raise RuntimeError("Owned qualification container remains")
        report["elapsed_seconds"] = time.monotonic() - started
        (output / "result.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, required=True)
    parser.add_argument("--probe", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--image-id", required=True)
    args = parser.parse_args()
    qualify(args.bundle.resolve(), args.probe.resolve(), args.output.resolve(), args.image_id)
