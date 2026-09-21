// Reuse RIFT's maintained asset staging, then replace CI connectivity before launch.
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import fs from 'node:fs/promises';
const [game, output, dmb, rsc] = Bun.argv.slice(2);
const { createDeployment } = await import(pathToFileURL(path.join(game, 'tools/rift/rift.ts')).href);
const deployment = await createDeployment({
  repository: { root: game }, runDir: output,
  compile: { dmb, rsc }, profile: { config_source: 'ci' },
  selectedMap: '_maps/metastation.json',
});
// No repository config, saves, credentials, SQL, webhooks or external services.
await fs.writeFile(path.join(deployment.root, 'config/config.txt'), '');
console.log(JSON.stringify({ workspace: deployment.root }));
