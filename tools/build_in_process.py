"""Build a source-bound, unqualified i686 Dogmos bundle on Windows or Linux."""
from __future__ import annotations
import argparse
import hashlib
import json
import ntpath
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
from dogmos_source_snapshot import capture_snapshot, canonical_bytes, verify_snapshot

FEATURES = ['aphelion_reactions', 'katmos', 'katmos_slow_decompression', 'superconductivity', 'turf_processing']

def package_linux_artifacts(release_library, output):
    native, symbols = 'libdogmos_in_process.so', 'libdogmos_in_process.so.debug'
    subprocess.run(['objcopy', '--only-keep-debug', release_library, output / symbols], check=True)
    subprocess.run(['objcopy', '--strip-debug', release_library, output / native], check=True)
    # GDB searches for this basename beside the library; objcopy also records its CRC.
    subprocess.run(['objcopy', f'--add-gnu-debuglink={symbols}', native], cwd=output, check=True)
    return native, symbols

def command_version(command):
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode:
        raise RuntimeError(f'version probe failed for {command[0]}: {result.returncode}')
    return next((line.strip() for line in (result.stdout + result.stderr).splitlines() if line.strip()), '')

def pe_linker_version(library):
    """Read the linker version recorded in a built PE image, without guessing its executable."""
    try:
        image = library.read_bytes()
        if image[:2] != b'MZ' or len(image) < 0x40:
            return None
        header = int.from_bytes(image[0x3c:0x40], 'little')
        if image[header:header + 4] != b'PE\0\0' or len(image) < header + 28:
            return None
        optional = header + 24
        if image[optional:optional + 2] not in (b'\x0b\x01', b'\x0b\x02'):
            return None
        return f'{image[optional + 2]}.{image[optional + 3]}'
    except OSError:
        return None

def build_provenance(environment, target, native_library):
    rustc = subprocess.run(['rustc', '+1.98.0', '--version', '--verbose'],
                           capture_output=True, text=True, check=True).stdout.strip()
    linker_key = f"CARGO_TARGET_{target.upper().replace('-', '_')}_LINKER"
    linker = environment.get(linker_key)
    linker_info = {
        'selection': linker_key if linker else 'cargo-rustc-configuration',
        'command': ntpath.basename(linker) if linker else None,
        'version': None,
    }
    if linker:
        try:
            linker_info['version'] = command_version(
                [linker, '/?'] if target.endswith('windows-msvc') else [linker, '--version'])
        except (OSError, RuntimeError) as error:
            # A successful Rust build is authoritative. The configured linker may be found by
            # rustc's environment even when this separate probe cannot execute it.
            linker_info['version_probe_error'] = type(error).__name__
    if target.endswith('windows-msvc'):
        linker_info['artifact_pe_linker_version'] = pe_linker_version(native_library)
    flag_keys = ('RUSTFLAGS', 'CARGO_ENCODED_RUSTFLAGS', 'CARGO_BUILD_RUSTFLAGS',
                 f"CARGO_TARGET_{target.upper().replace('-', '_')}_RUSTFLAGS")
    flags = {}
    cpu_requirements = []
    for key in flag_keys:
        raw = environment.get(key, '')
        if not raw:
            continue
        flags[key] = hashlib.sha256(raw.encode('utf-8')).hexdigest()
        for kind, value in re.findall(r'-C\s*(target-cpu|target-feature)=([^\s\x1f]+)', raw):
            cpu_requirements.append({'source': key, 'kind': kind, 'value': value})
    profile_overrides = {
        key: hashlib.sha256(value.encode('utf-8')).hexdigest()
        for key, value in sorted(environment.items())
        if key.startswith('CARGO_PROFILE_RELEASE_') and value
    }
    result = {
        'rustc_verbose': rustc,
        'cargo_version': command_version(['cargo', '+1.98.0', '--version']),
        # Cargo/rustc can locate MSVC outside PATH. The PE header identifies the actual
        # output's linker version; absent an override, its executable path is unverified.
        'linker': linker_info,
        'flag_sha256': flags,
        'profile_override_sha256': profile_overrides,
        'cpu_requirements': cpu_requirements,
    }
    if target.endswith('linux-gnu'):
        result['objcopy_version'] = command_version(['objcopy', '--version'])
    return result

def run_build(command, root, environment, log_path):
    """Retain compiler output and expose it when a CI build fails."""
    with log_path.open('wb') as log:
        result = subprocess.run(command, cwd=root, env=environment, stdout=log, stderr=subprocess.STDOUT, check=False)
    if result.returncode:
        print(log_path.read_text(encoding='utf-8', errors='replace'), file=sys.stderr)
        result.check_returncode()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target', choices=['i686-pc-windows-msvc', 'i686-unknown-linux-gnu'], required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    output = args.output.resolve()
    if not output.is_relative_to(root / 'target') or output.exists():
        parser.error('output must be a new directory beneath this repository target directory')
    output.mkdir(parents=True)
    encoded = canonical_bytes(capture_snapshot(root))
    snapshot = json.loads(encoded)
    digest = hashlib.sha256(encoded).hexdigest()
    (output / 'dogmos-source-snapshot.json').write_bytes(encoded)
    environment = dict(os.environ, DOGMOS_SOURCE_SHA256=digest, CARGO_TARGET_DIR=str(root / 'target'))
    arguments = ['+1.98.0', 'build', '-p', 'dogmos', '--lib', '--example', 'generate_bindings', '--release', '--locked', '--target', args.target, '--no-default-features', '--features', ','.join(FEATURES)]
    run_build(['cargo', *arguments], root, environment, output / 'build.log')
    release = root / 'target' / args.target / 'release'
    windows = args.target == 'i686-pc-windows-msvc'
    generator = release / 'examples' / ('generate_bindings.exe' if windows else 'generate_bindings')
    subprocess.run([generator], cwd=output, check=True)
    (output / 'bindings.dm').rename(output / 'dogmos_bindings.dm')
    if windows:
        native, symbols = 'dogmos.dll', 'dogmos.pdb'
        for name in (native, symbols): shutil.copyfile(release / name, output / name)
    else:
        native, symbols = package_linux_artifacts(release / 'libdogmos.so', output)
    verify_snapshot(root, encoded)
    artifacts = {name: hashlib.sha256((output / name).read_bytes()).hexdigest() for name in (native, symbols, 'dogmos_bindings.dm', 'dogmos-source-snapshot.json')}
    manifest = dict(schema_version=1, kind='unqualified-in-process-playtest', backend='in-process', target=args.target, toolchain='1.98.0', source_revision=snapshot['source_revision'], source_sha256=digest, features=FEATURES, cargo_arguments=arguments, build_provenance=build_provenance(environment, args.target, output / native), artifacts=artifacts, tests_run=False, runtime_qualified=False)
    (output / 'dogmos-playtest.json').write_text(json.dumps(manifest,indent=2,sort_keys=True)+'\n',encoding='utf-8',newline='\n')
    print(f'Built source-bound {args.target} bundle: {output}')

if __name__ == '__main__':
    main()
