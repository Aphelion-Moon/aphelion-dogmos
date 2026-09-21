"""Validate the resolved in-process workspace dependency boundary."""
import argparse
import json
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target', default='i686-pc-windows-msvc')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    graph = json.loads(subprocess.check_output([
        'cargo', '+1.98.0', 'metadata', '--locked', '--format-version', '1',
        '--filter-platform', args.target
    ], cwd=root))
    packages = {p['id']: p for p in graph['packages']}
    nodes = {n['id']: n for n in graph['resolve']['nodes']}
    allowed = {'dogmos', 'auxcallback', 'auxmacros'}
    for ident in graph['workspace_members']:
        if packages[ident]['name'] in allowed:
            continue
        pending, visited = [ident], set()
        while pending:
            current = pending.pop()
            if current in visited:
                continue
            visited.add(current)
            if packages[current]['name'].startswith('byondapi'):
                raise SystemExit('BYOND dependency crossed the pure-kernel/telemetry boundary')
            pending.extend(d['pkg'] for d in nodes[current]['deps'])
    print('Resolved in-process dependency boundary passed.')

if __name__ == '__main__':
    main()
