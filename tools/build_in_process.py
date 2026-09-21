"""Build a source-bound, unqualified i686 Dogmos bundle on Windows or Linux."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
from dogmos_source_snapshot import capture_snapshot, canonical_bytes, verify_snapshot

FEATURES = ['aphelion_reactions', 'katmos', 'katmos_slow_decompression', 'superconductivity', 'turf_processing']

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
    with (output / 'build.log').open('wb') as log:
        subprocess.run(['cargo', *arguments], cwd=root, env=environment, stdout=log, stderr=subprocess.STDOUT, check=True)
    release = root / 'target' / args.target / 'release'
    windows = args.target == 'i686-pc-windows-msvc'
    generator = release / 'examples' / ('generate_bindings.exe' if windows else 'generate_bindings')
    subprocess.run([generator], cwd=output, check=True)
    (output / 'bindings.dm').rename(output / 'dogmos_bindings.dm')
    if windows:
        native, symbols = 'dogmos.dll', 'dogmos.pdb'
        for name in (native, symbols): shutil.copyfile(release / name, output / name)
    else:
        native, symbols = 'libdogmos_in_process.so', 'libdogmos_in_process.so.debug'
        subprocess.run(['objcopy', '--only-keep-debug', release / 'libdogmos.so', output / symbols], check=True)
        subprocess.run(['objcopy', '--strip-debug', release / 'libdogmos.so', output / native], check=True)
    verify_snapshot(root, encoded)
    artifacts = {name: hashlib.sha256((output / name).read_bytes()).hexdigest() for name in (native, symbols, 'dogmos_bindings.dm', 'dogmos-source-snapshot.json')}
    manifest = dict(schema_version=1, kind='unqualified-in-process-playtest', backend='in-process', target=args.target, toolchain='1.98.0', source_revision=snapshot['source_revision'], source_sha256=digest, features=FEATURES, cargo_arguments=arguments, artifacts=artifacts, tests_run=False, runtime_qualified=False)
    (output / 'dogmos-playtest.json').write_text(json.dumps(manifest,indent=2,sort_keys=True)+'\n',encoding='utf-8',newline='\n')
    print(f'Built source-bound {args.target} bundle: {output}')

if __name__ == '__main__':
    main()
