import fs from 'node:fs/promises';
import path from 'node:path';
import {
  acquireRunLock,
  allocateRun,
  createCancellationController,
  finishRunWithLock,
  loadProfiles,
  parseDependencyPins,
  preflightOffline,
  qualifyRepository,
  resolveByond,
  runTestWorkflow,
  validateMapPath,
  verifyDogmosInstalledContract,
  type RiftProfile,
  type RiftCommand,
} from '../../../tools/rift/rift';
import { runProbeProcess } from '../../../tools/rift/process';
import { hashArtifact, RunRecorder } from '../../../tools/rift/report';

const OBSERVER_FOCUS = '/datum/unit_test/dogmos_shared_baseline_observer';
const DEFAULT_MAP = '_maps/metastation.json';
const ALLOWED_MAPS = new Set([
  '_maps/metastation.json',
  '_maps/runtimestation.json',
]);
const OBSERVER_FILE = path.resolve(
  import.meta.dir,
  'shared_baseline_observer.dm',
);
const WRAPPER_FILE = path.resolve(import.meta.dir, 'compare-repository.ts');
const RIFT_PROFILE_FILE = path.resolve(
  import.meta.dir,
  '../../../tools/rift/profiles.json',
);

type Arguments = {
  repository: string;
  map: string;
  cacheMode: 'shared-pinned' | 'cold-isolated';
  cacheRoot: string | null;
};

const usage = () =>
  'usage: bun compare-repository.ts --repository <root> [--map _maps/metastation.json|_maps/runtimestation.json] [--cache-mode shared-pinned|cold-isolated] [--cache-root <path>]';

const parseArguments = (argv: string[]): Arguments => {
  let repository: string | null = null;
  let map = DEFAULT_MAP;
  let cacheMode: Arguments['cacheMode'] = 'shared-pinned';
  let cacheRoot: string | null = null;
  for (let index = 0; index < argv.length; index += 1) {
    const option = argv[index];
    if (option === '--repository') {
      repository = argv[++index] ?? null;
      continue;
    }
    if (option === '--map') {
      map = argv[++index] ?? '';
      continue;
    }
    if (option === '--cache-mode') {
      const value = argv[++index] as Arguments['cacheMode'] | undefined;
      if (value !== 'shared-pinned' && value !== 'cold-isolated') {
        throw new Error(`${usage()}\ncache mode must be shared-pinned or cold-isolated`);
      }
      cacheMode = value;
      continue;
    }
    if (option === '--cache-root') {
      cacheRoot = argv[++index] ?? null;
      continue;
    }
    throw new Error(`${usage()}\nunknown option: ${option}`);
  }
  if (repository === null) {
    throw new Error(usage());
  }
  if (!ALLOWED_MAPS.has(map)) {
    throw new Error(`map must be one of: ${[...ALLOWED_MAPS].join(', ')}`);
  }
  if (cacheMode === 'cold-isolated' && cacheRoot === null) {
    throw new Error(`${usage()}\ncold-isolated mode requires --cache-root`);
  }
  if (cacheMode === 'shared-pinned' && cacheRoot !== null) {
    throw new Error(`${usage()}\n--cache-root requires --cache-mode cold-isolated`);
  }
  return { repository: path.resolve(repository), map, cacheMode, cacheRoot };
};

const environmentFromProcess = (): Record<string, string> =>
  Object.fromEntries(
    Object.entries(process.env).filter(
      (entry): entry is [string, string] => entry[1] !== undefined,
    ),
  );

const readGitMetadata = async (
  repositoryRoot: string,
  environment: Record<string, string>,
  runProbe: (
    executable: string,
    args: string[],
    cwd: string,
    environment: Record<string, string>,
  ) => Promise<{ exitCode: number; stdout: string; stderr: string }>,
) => {
  const revision = await runProbe(
    'git.exe',
    ['rev-parse', '--verify', 'HEAD'],
    repositoryRoot,
    environment,
  );
  const status = await runProbe(
    'git.exe',
    ['status', '--porcelain=v1', '--untracked-files=normal'],
    repositoryRoot,
    environment,
  );
  if (revision.exitCode !== 0 || status.exitCode !== 0) {
    throw new Error('repository metadata inspection failed');
  }
  return { revision: revision.stdout.trim(), dirty: status.stdout.length > 0 };
};

const fileIsNonempty = async (filePath: string) => {
  const stat = await fs.stat(filePath).catch(() => null);
  return Boolean(stat?.isFile() && stat.size > 0);
};

type NativePair = { shim: string; service: string };

const detectDogmosPair = async (repositoryRoot: string): Promise<NativePair | null> => {
  const verifier = path.join(repositoryRoot, 'tools', 'dogmos', 'verify_contract.py');
  const lock = path.join(repositoryRoot, 'dogmos.lock.json');
  const marker = (await fileIsNonempty(verifier)) || (await fileIsNonempty(lock));
  const pairs: NativePair[] = process.platform === 'win32'
    ? [{ shim: path.join(repositoryRoot, 'dogmos.dll'), service: path.join(repositoryRoot, 'dogmosd.exe') }]
    : [{ shim: path.join(repositoryRoot, 'libdogmos.so'), service: path.join(repositoryRoot, 'dogmosd') }];
  const present = await Promise.all(pairs.map(async (pair) => ({
    pair,
    shim: await fileIsNonempty(pair.shim),
    service: await fileIsNonempty(pair.service),
  })));
  const complete = present.filter((entry) => entry.shim && entry.service);
  const anyNative = present.some((entry) => entry.shim || entry.service);
  if (!marker && !anyNative) {
    return null;
  }
  if (complete.length !== 1 || !marker) {
    throw new Error('Dogmos markers or native files are incomplete; refusing to treat the checkout as a no-Dogmos baseline.');
  }
  return complete[0].pair;
};

const mergeById = <T extends { id: string }>(...groups: T[][]): T[] => {
  const merged = new Map<string, T>();
  for (const group of groups) {
    for (const item of group) {
      if (!merged.has(item.id)) {
        merged.set(item.id, structuredClone(item));
      }
    }
  }
  return [...merged.values()];
};

const makeDogmosComparisonProfile = (
  ci: RiftProfile,
  dogmosCi: RiftProfile,
): RiftProfile => ({
  ...structuredClone(ci),
  fatal_log_rules: mergeById(ci.fatal_log_rules, dogmosCi.fatal_log_rules),
  required_children: structuredClone(dogmosCi.required_children),
});

const copyAndRecordArtifact = async (
  recorder: RunRecorder,
  runDir: string,
  source: string,
  name: string,
) => {
  const destination = path.join(runDir, 'comparison-inputs', name);
  await fs.mkdir(path.dirname(destination), { recursive: true });
  await fs.copyFile(source, destination);
  await recorder.addArtifact(
    await hashArtifact(destination, runDir, 'comparison-input', 'collected'),
  );
};

const writeScratchDme = async (
  repositoryRoot: string,
  runId: string,
): Promise<string> => {
  const scratch = path.join(repositoryRoot, `.rift-${runId}.observer.dme`);
  if (await Bun.file(scratch).exists()) {
    throw new Error(`observer scratch already exists: ${path.basename(scratch)}`);
  }
  const source = await Bun.file(path.join(repositoryRoot, 'tgstation.dme')).text();
  const includePath = OBSERVER_FILE.replaceAll('\\', '/');
  let handle: Awaited<ReturnType<typeof fs.open>> | null = null;
  let created = false;
  let writeFailure: unknown = null;
  try {
    handle = await fs.open(scratch, 'wx');
    created = true;
    await handle.writeFile(`${source}\n#include "${includePath}"\n`, 'utf8');
  } catch (error) {
    writeFailure = error;
  } finally {
    await handle?.close().catch(() => undefined);
  }
  if (writeFailure) {
    if (created) {
      await fs.rm(scratch, { force: true });
    }
    throw writeFailure;
  }
  return scratch;
};

const removeScratchDme = async (repositoryRoot: string, runId: string) => {
  const scratch = path.join(repositoryRoot, `.rift-${runId}.observer.dme`);
  const relative = path.relative(repositoryRoot, scratch);
  if (
    relative.startsWith('..') ||
    path.basename(scratch) !== `.rift-${runId}.observer.dme`
  ) {
    throw new Error('observer scratch cleanup escaped repository root');
  }
  await fs.rm(scratch, { force: true });
};

const makeCommand = (
  map: string,
  profileName: string,
  shim: string | null,
  service: string | null,
): Extract<RiftCommand, { command: 'test' }> => ({
  command: 'test',
  focus: [OBSERVER_FOCUS],
  map,
  minimumTests: 1,
  readinessTimeoutSeconds: 900,
  format: 'result',
  networkMode: 'offline',
  profile: profileName,
  wallTimeoutSeconds: 1800,
  idleTimeoutSeconds: 300,
  waitForLockSeconds: 0,
  keepWorkspace: false,
  shim,
  service,
});

export const runComparison = async (argv: string[]): Promise<number> => {
  const args = parseArguments(argv);
  const baseRepository = await qualifyRepository(args.repository);
  const pins = parseDependencyPins(
    await fs.readFile(baseRepository.dependencies, 'utf8'),
  );
  const profiles = await loadProfiles(
    RIFT_PROFILE_FILE,
  );
  const ciProfile = profiles.get('ci');
  const dogmosCiProfile = profiles.get('dogmos-ci');
  if (!ciProfile || !dogmosCiProfile) {
    throw new Error('RIFT ci profile is missing');
  }
  const selectedMap = validateMapPath(baseRepository.root, args.map, true);
  const nativePair = await detectDogmosPair(baseRepository.root);
  const profileName = nativePair ? 'dogmos-comparison' : 'ci';
  const profile = nativePair
    ? makeDogmosComparisonProfile(ciProfile, dogmosCiProfile)
    : ciProfile;
  profiles.set(profileName, profile);
  const { runId, runDir } = await allocateRun(baseRepository.runsRoot);
  const recorder = await RunRecorder.create({
    runDir,
    runId,
    command: 'test',
    profile: profileName,
    evidence: 'focused_test',
    networkMode: 'offline',
  });
  let lock: Awaited<ReturnType<typeof acquireRunLock>> | null = null;
  let preflight: Awaited<ReturnType<typeof preflightOffline>> | null = null;
  let scratchDme: string | null = null;
  let workflowFinished = false;
  const cancellation = createCancellationController();
  const onInterrupt = () => {
    void cancellation.cancel();
  };
  process.once('SIGINT', onInterrupt);
  process.once('SIGBREAK', onInterrupt);
  try {
    const inheritedEnvironment = environmentFromProcess();
    if (args.cacheMode === 'cold-isolated') {
      inheritedEnvironment.TG_BOOTSTRAP_CACHE = path.resolve(args.cacheRoot!);
    }
    const runProbe = async (
      executable: string,
      probeArgs: string[],
      cwd: string,
      environment: Record<string, string>,
    ) => {
      if (cancellation.wasCancelled()) {
        throw new Error('comparison cancelled during preflight');
      }
      const result = await runProbeProcess(executable, probeArgs, cwd, environment);
      if (cancellation.wasCancelled()) {
        throw new Error('comparison cancelled during preflight');
      }
      return result;
    };
    preflight = await preflightOffline(
      baseRepository,
      pins,
      inheritedEnvironment,
      runProbe,
    );
    if (cancellation.wasCancelled()) {
      throw new Error('comparison cancelled during preflight');
    }
    const environment = preflight.environment;
    const byond = await resolveByond(
      baseRepository,
      pins,
      runProbe,
      environment,
    );
    if (cancellation.wasCancelled()) {
      throw new Error('comparison cancelled during preflight');
    }
    const git = await readGitMetadata(baseRepository.root, environment, runProbe);
    if (cancellation.wasCancelled()) {
      throw new Error('comparison cancelled during preflight');
    }
    await recorder.setRepository(git.revision, git.dirty);
    await recorder.setToolVersions({
      bun: Bun.version,
      byond: byond.version,
      byond_resolver: byond.source,
      comparison_mode: nativePair ? 'dogmos-candidate' : 'no-dogmos-baseline',
      cache_mode: args.cacheMode,
    });
    await copyAndRecordArtifact(
      recorder,
      runDir,
      OBSERVER_FILE,
      'shared_baseline_observer.dm',
    );
    await copyAndRecordArtifact(
      recorder,
      runDir,
      WRAPPER_FILE,
      'compare-repository.ts',
    );
    await copyAndRecordArtifact(
      recorder,
      runDir,
      path.join(baseRepository.root, selectedMap),
      path.basename(selectedMap),
    );
    if (nativePair) {
      await copyAndRecordArtifact(
        recorder,
        runDir,
        nativePair.shim,
        path.basename(nativePair.shim),
      );
      await copyAndRecordArtifact(
        recorder,
        runDir,
        nativePair.service,
        path.basename(nativePair.service),
      );
      await recorder.emit('stage_started', 'dogmos-contract', {});
      await verifyDogmosInstalledContract({
        repositoryRoot: baseRepository.root,
        python: preflight.tools.python,
        environment,
        runner: cancellation.runner,
        recorder,
      });
      await recorder.emit('stage_finished', 'dogmos-contract', {}, 'passed');
    }
    await recorder.emit('observation', 'comparison', {
      repository_root: baseRepository.root,
      source_revision: git.revision,
      source_dirty: git.dirty,
      source_confound:
        'Source revisions are recorded verbatim; no post-base source normalization is performed.',
      selected_map: selectedMap,
      profile: profileName,
      comparison_mode: nativePair ? 'dogmos-candidate' : 'no-dogmos-baseline',
      observer: OBSERVER_FOCUS,
      observer_window_seconds: 180,
      seed_source: 'Master.random_seed recorded by the observer',
      procedure_profiling: null,
      diagnostic_procedure_profiling: false,
      cache_mode: args.cacheMode,
      runtime_cache: 'fresh run-owned deployment; no existing data or condo previews copied',
      cache_provenance: {
        requested_mode: args.cacheMode,
        cold_isolated: args.cacheMode === 'cold-isolated',
        root: args.cacheRoot ?? inheritedEnvironment.TG_BOOTSTRAP_CACHE ?? 'repository-relative tools/bootstrap/.cache',
        note: 'Dependency cache is recorded as configured; no cache warming or normalization is performed by this wrapper.',
      },
    });
    lock = await acquireRunLock(baseRepository.runsRoot, 'test', runId, 0);
    scratchDme = await writeScratchDme(baseRepository.root, runId);
    const repository = { ...baseRepository, dme: scratchDme };
    const summary = await runTestWorkflow(
      {
        repository,
        pins,
        byond,
        pinnedPython: preflight.tools.python,
        profileName,
        profile,
        profiles,
        recorder,
        lock,
        runId,
        runDir,
        environment,
        networkMode: 'offline',
        processRunner: cancellation.runner,
        buildProcessRunner: cancellation.runner,
        wasCancelled: cancellation.wasCancelled,
      },
      makeCommand(
        selectedMap,
        profileName,
        nativePair?.shim ?? null,
        nativePair?.service ?? null,
      ),
    );
    workflowFinished = true;
    process.stdout.write(`${JSON.stringify(summary)}\n`);
    return summary.exit_code;
  } catch (error) {
    if (!workflowFinished) {
      const message = error instanceof Error ? error.message : String(error);
      await recorder.addFailure({
        code: 'comparison_setup_failed',
        stage: 'comparison',
        message,
      });
      if (lock) {
        await finishRunWithLock(recorder, lock, 'failed', 5);
        lock = null;
      } else {
        await recorder.finish('failed', 3);
      }
    }
    throw error;
  } finally {
    process.off('SIGINT', onInterrupt);
    process.off('SIGBREAK', onInterrupt);
    const cleanupResults = await Promise.allSettled([
      scratchDme
        ? removeScratchDme(baseRepository.root, runId)
        : Promise.resolve(),
      lock?.release() ?? Promise.resolve(),
      preflight?.cleanup() ?? Promise.resolve(),
    ]);
    const cleanupErrors = cleanupResults
      .filter((result): result is PromiseRejectedResult => result.status === 'rejected')
      .map((result) => result.reason instanceof Error ? result.reason.message : String(result.reason));
    if (cleanupErrors.length > 0) {
      throw new Error(`comparison cleanup failed: ${cleanupErrors.join('; ')}`);
    }
  }
};

if (import.meta.main) {
  try {
    process.exitCode = await runComparison(Bun.argv.slice(2));
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 3;
  }
}
