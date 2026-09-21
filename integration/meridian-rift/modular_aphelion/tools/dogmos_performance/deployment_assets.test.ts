import { expect, test } from 'bun:test';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { createDeployment, loadProfiles } from '../../../tools/rift/rift';

test('RIFT deployments retain module map templates required at shift start', async () => {
  const scratch = await fs.mkdtemp(path.join(os.tmpdir(), 'dogmos-deploy-assets-'));
  try {
    const root = path.join(scratch, 'repository');
    const runDir = path.join(scratch, 'run');
    const templates = [
      'modular_nova/modules/condos/_maps/fixture.dmm',
      'modular_aphelion/modules/fixture/_maps/fixture.dmm',
    ];
    for (const relative of templates) {
      await fs.mkdir(path.dirname(path.join(root, relative)), { recursive: true });
      await Bun.write(path.join(root, relative), 'module map fixture');
    }
    await fs.mkdir(runDir);
    const compile = {
      evidence: 'compiler' as const,
      dmb: path.join(scratch, 'tgstation.dmb'),
      rsc: path.join(scratch, 'tgstation.rsc'),
      artifacts: [],
      reused: false,
    };
    await Bun.write(compile.dmb, 'compiled fixture');
    await Bun.write(compile.rsc, 'resource fixture');
    const profiles = await loadProfiles(path.resolve(import.meta.dir, '../../../tools/rift/profiles.json'));
    const deployment = await createDeployment({
      repository: {
        root, dme: path.join(root, 'tgstation.dme'), buildCmd: path.join(root, 'BUILD.cmd'),
        buildDelegate: path.join(root, 'tools/build/build.bat'),
        dependencies: path.join(root, 'dependencies.sh'), runsRoot: path.join(root, 'data/rift-runs'),
      },
      runDir,
      profile: profiles.get('default')!,
      compile,
      selectedMap: null,
    });
    for (const relative of templates) {
      expect(await Bun.file(path.join(deployment.root, relative)).exists()).toBe(true);
      expect(await Bun.file(path.join(deployment.root, relative)).text()).toBe('module map fixture');
    }
  } finally {
    // mkdtemp owns this exact directory; guard containment before recursive cleanup.
    const parent = path.resolve(os.tmpdir()) + path.sep;
    if (!path.resolve(scratch).startsWith(parent)) throw new Error('Unsafe fixture cleanup path');
    await fs.rm(scratch, { recursive: true, force: true });
  }
});
