import hashlib
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest

from tools.dogmos.verify_contract import (
    ContractError,
    render_contract_defines,
    validate_release,
)


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
SYNC_SCRIPT = REPOSITORY_ROOT / "tools" / "dogmos" / "sync_contract.ps1"


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def pe(machine: int) -> bytes:
    binary = bytearray(128)
    binary[:2] = b"MZ"
    struct.pack_into("<I", binary, 0x3C, 64)
    binary[64:68] = b"PE\0\0"
    struct.pack_into("<H", binary, 68, machine)
    return bytes(binary)


def elf(elf_class: int, machine: int) -> bytes:
    binary = bytearray(64)
    binary[:4] = b"\x7fELF"
    binary[4] = elf_class
    binary[5] = 1
    struct.pack_into("<H", binary, 18, machine)
    return bytes(binary)


class ContractFixture:
    def __init__(self, root: Path) -> None:
        self.repository = root / "dogmos"
        self.destination = root / "game"
        self.bundle = self.repository / "release-bundle"
        self.repository.mkdir()
        self.destination.mkdir()
        subprocess.run(
            ["git", "init", "-b", "master"],
            cwd=self.repository,
            check=True,
            capture_output=True,
        )
        subprocess.run(
            ["git", "config", "user.email", "contract-test@example.invalid"],
            cwd=self.repository,
            check=True,
        )
        subprocess.run(
            ["git", "config", "user.name", "Contract Test"],
            cwd=self.repository,
            check=True,
        )
        (self.repository / ".gitignore").write_text(
            "dogmos-release-manifest.json\nrelease-bundle/\n", encoding="utf-8"
        )
        (self.repository / "source.txt").write_text("source\n", encoding="utf-8")
        subprocess.run(["git", "add", "."], cwd=self.repository, check=True)
        subprocess.run(
            ["git", "commit", "-m", "fixture"],
            cwd=self.repository,
            check=True,
            capture_output=True,
        )
        self.revision = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=self.repository,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        self._write_bundle()

    def _record(self, name: str, data: bytes) -> dict:
        path = self.bundle / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return {"file": name, "sha256": sha256(data), "size": len(data)}

    def _write_bundle(self) -> None:
        bindings = self._record(
            "dogmos_bindings.dm", b"#define DOGMOS_BYOND \"dogmos\"\n"
        )
        artifacts = []
        fixtures = (
            ("linux", "service", "x86_64-unknown-linux-gnu", "x86_64", "elf", elf(2, 62)),
            ("linux", "shim", "i686-unknown-linux-gnu", "i686", "elf", elf(1, 3)),
            ("windows", "service", "x86_64-pc-windows-msvc", "x86_64", "pe", pe(0x8664)),
            ("windows", "shim", "i686-pc-windows-msvc", "i686", "pe", pe(0x014C)),
        )
        for platform, role, target, architecture, artifact_format, binary in fixtures:
            extension = ".exe" if platform == "windows" and role == "service" else ".bin"
            file_record = self._record(f"{platform}/{role}{extension}", binary)
            symbol_record = self._record(
                f"{platform}/{role}.symbols", f"{target} symbols".encode()
            )
            artifacts.append(
                {
                    "architecture": architecture,
                    **file_record,
                    "format": artifact_format,
                    "platform": platform,
                    "role": role,
                    "symbols": symbol_record,
                    "target": target,
                }
            )
        manifest = {
            "artifacts": artifacts,
            "bindings": bindings,
            "build_profile": "release",
            "capabilities": {
                "feature_fingerprint": "2" * 64,
                "features": [
                    "aphelion_reactions",
                    "katmos",
                    "katmos_slow_decompression",
                    "superconductivity",
                    "turf_processing",
                ],
            },
            "schema_version": 1,
            "source_revision": self.revision,
            "toolchain": {
                "byond": "516.1687",
                "byondapi_revision": "1" * 40,
                "rust": "1.98.0",
            },
            "versions": {
                "abi": 1,
                "dogmos-byond": "2.3.0",
                "dogmos-server": "2.3.0",
                "protocol": 5,
                "workspace": "2.3.0",
            },
        }
        self.manifest = manifest
        self.manifest_path = self.repository / "dogmos-release-manifest.json"
        self.manifest_path.write_bytes(
            (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode()
        )

    def sync(self, *extra: str) -> subprocess.CompletedProcess[str]:
        command = (
            f"& '{SYNC_SCRIPT}' -DogmosRepository '{self.repository}' "
            f"-DestinationRoot '{self.destination}' {' '.join(extra)}"
        )
        return subprocess.run(
            ["powershell", "-NoProfile", "-Command", command],
            capture_output=True,
            text=True,
        )

    def qualify_local(self):
        # Literal inventory is an oracle independent of the installer's scanner.
        snapshot_path = self.bundle / "dogmos-source-snapshot.json"
        snapshot = {"schema_version": 1, "source_revision": self.revision, "files": []}
        for name in (".gitignore", "source.txt"):
            data = (self.repository / name).read_bytes()
            snapshot["files"].append({"path": name, "size": len(data), "sha256": sha256(data)})
        encoded = (json.dumps(snapshot, indent=2, sort_keys=True) + "\n").encode()
        snapshot_path.write_bytes(encoded)
        self.manifest["qualification"] = {
            "kind": "local-source-snapshot-v1",
            "source_snapshot": {"file": "dogmos-source-snapshot.json", "sha256": sha256(encoded), "size": len(encoded)},
        }
        self.manifest["capabilities"]["feature_fingerprint"] = sha256(b"dogmos-local-qualification-v1\0" + hashlib.sha256(encoded).digest())
        self.manifest_path.write_bytes((json.dumps(self.manifest, indent=2, sort_keys=True) + "\n").encode())


class GameContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.fixture = ContractFixture(Path(self.temporary.name))

    def test_valid_release_renders_exact_dm_identity_constants(self) -> None:
        manifest = validate_release(
            self.fixture.manifest_path.read_bytes(), self.fixture.bundle
        )
        defines = render_contract_defines(manifest).decode()
        self.assertIn("#define DOGMOS_CONTRACT_ABI_VERSION 1", defines)
        self.assertIn("#define DOGMOS_CONTRACT_PROTOCOL_VERSION 5", defines)
        self.assertIn(
            f'#define DOGMOS_CONTRACT_SOURCE_REVISION "{self.fixture.revision}"',
            defines,
        )
        self.assertIn(
            '#define DOGMOS_CONTRACT_FEATURE_FINGERPRINT "' + "2" * 64 + '"',
            defines,
        )
        self.assertNotIn("\r", defines)
        self.assertTrue(defines.endswith("\n"))
        self.assertFalse(defines.endswith("\n\n"))

    def test_verifier_rejects_partial_pair_path_traversal_and_hash_drift(self) -> None:
        for mutate in (
            lambda manifest: manifest["artifacts"].pop(),
            lambda manifest: manifest["bindings"].update(file="../escape.dm"),
            lambda manifest: manifest["artifacts"][0].update(sha256="0" * 64),
        ):
            with self.subTest(mutate=mutate):
                manifest = json.loads(json.dumps(self.fixture.manifest))
                mutate(manifest)
                encoded = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode()
                with self.assertRaises(ContractError):
                    validate_release(encoded, self.fixture.bundle)

    def test_sync_is_atomic_idempotent_and_verify_only_detects_drift(self) -> None:
        first = self.fixture.sync()
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        installed = {
            path.relative_to(self.fixture.destination).as_posix(): path.read_bytes()
            for path in self.fixture.destination.rglob("*")
            if path.is_file()
        }
        second = self.fixture.sync()
        self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
        self.assertEqual(
            installed,
            {
                path.relative_to(self.fixture.destination).as_posix(): path.read_bytes()
                for path in self.fixture.destination.rglob("*")
                if path.is_file()
            },
        )
        verify = self.fixture.sync("-VerifyOnly")
        self.assertEqual(verify.returncode, 0, verify.stdout + verify.stderr)
        installed_dll = self.fixture.destination / "dogmos.dll"
        installed_dll.write_bytes(b"drift")
        drift = self.fixture.sync("-VerifyOnly")
        self.assertNotEqual(drift.returncode, 0, drift.stdout + drift.stderr)
        installed_dll.write_bytes(installed["dogmos.dll"])

        (self.fixture.bundle / "windows" / "shim.bin").write_bytes(b"corrupt")
        failed = self.fixture.sync()
        self.assertNotEqual(failed.returncode, 0, failed.stdout + failed.stderr)
        self.assertEqual(
            installed,
            {
                path.relative_to(self.fixture.destination).as_posix(): path.read_bytes()
                for path in self.fixture.destination.rglob("*")
                if path.is_file()
            },
        )

    def test_sync_rejects_dirty_source_before_writing(self) -> None:
        (self.fixture.repository / "source.txt").write_text("dirty\n", encoding="utf-8")
        failed = self.fixture.sync()
        self.assertNotEqual(failed.returncode, 0, failed.stdout + failed.stderr)
        self.assertEqual(list(self.fixture.destination.rglob("*")), [])

    def test_local_sync_requires_opt_in_and_exact_snapshot_then_remains_idempotent(self):
        self.fixture.qualify_local()
        with self.assertRaisesRegex(ContractError, "local qualification"):
            validate_release(self.fixture.manifest_path.read_bytes(), self.fixture.bundle)
        rejected = self.fixture.sync()
        self.assertNotEqual(rejected.returncode, 0)
        self.assertEqual(list(self.fixture.destination.rglob("*")), [])
        installed = self.fixture.sync("-AllowLocalQualification")
        self.assertEqual(installed.returncode, 0, installed.stdout + installed.stderr)
        defines = (self.fixture.destination / "code/__DEFINES/dogmos_contract.dm").read_text()
        self.assertIn("#define DOGMOS_CONTRACT_LOCAL_QUALIFICATION 1", defines)
        verified = self.fixture.sync("-AllowLocalQualification", "-VerifyOnly")
        self.assertEqual(verified.returncode, 0, verified.stdout + verified.stderr)
        (self.fixture.repository / "source.txt").write_bytes(b"changed after build")
        stale = self.fixture.sync("-AllowLocalQualification")
        self.assertNotEqual(stale.returncode, 0, stale.stdout + stale.stderr)
        self.assertIn("changed", stale.stdout + stale.stderr)

    def test_local_marker_cannot_bypass_release_cleanliness_or_identity(self):
        (self.fixture.repository / "source.txt").write_bytes(b"dirty")
        failed = self.fixture.sync("-AllowLocalQualification")
        self.assertNotEqual(failed.returncode, 0)
        self.assertEqual(list(self.fixture.destination.rglob("*")), [])

    def test_local_sync_rejects_added_deleted_and_corrupt_snapshot_inputs(self):
        self.fixture.qualify_local()
        for mutation in ("add", "delete", "snapshot"):
            with self.subTest(mutation=mutation):
                source = self.fixture.repository / "source.txt"
                original = source.read_bytes()
                extra = self.fixture.repository / "untracked.rs"
                snapshot = self.fixture.bundle / "dogmos-source-snapshot.json"
                original_snapshot = snapshot.read_bytes()
                if mutation == "add":
                    extra.write_bytes(b"new source")
                elif mutation == "delete":
                    source.unlink()
                else:
                    snapshot.write_bytes(original_snapshot + b" ")
                failed = self.fixture.sync("-AllowLocalQualification")
                self.assertNotEqual(failed.returncode, 0, failed.stdout + failed.stderr)
                self.assertEqual(list(self.fixture.destination.rglob("*")), [])
                if extra.exists():
                    extra.unlink()
                source.write_bytes(original)
                snapshot.write_bytes(original_snapshot)
        self.fixture.qualify_local()
        self.fixture.manifest["capabilities"]["feature_fingerprint"] = "0" * 64
        self.fixture.manifest_path.write_bytes((json.dumps(self.fixture.manifest, indent=2, sort_keys=True) + "\n").encode())
        failed = self.fixture.sync("-AllowLocalQualification")
        self.assertNotEqual(failed.returncode, 0)
        self.assertEqual(list(self.fixture.destination.rglob("*")), [])


if __name__ == "__main__":
    unittest.main()
