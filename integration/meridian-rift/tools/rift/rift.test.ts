import { describe, expect, test } from 'bun:test';
import fsSync from 'node:fs';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import {
  type OwnedProcess,
  type ProcessHooks,
  type ProcessResult,
  type ProcessSpec,
  runProbeProcess,
  startOwnedProcess,
} from './process';
import {
  hashArtifact,
  normalizeRuntimeSignature,
  RIFT_SCHEMA_VERSION,
  type RiftEvent,
  RunRecorder,
  readStoredRun,
  renderHumanSummary,
} from './report';
import {
  acquireRunLock,
  allocateRun,
  applyNativeOverlays,
  assertDmDiagnostics,
  classifyFailure,
  collectDeploymentArtifacts,
  compileFast,
  compileFull,
  createCancellationController,
  createDeployment,
  loadProfiles,
  matchesLogRule,
  parseCli,
  parseDependencyPins,
  parseProfileDocument,
  parseUnitTestResults,
  preflightOffline,
  prepareUnitTestCompile,
  qualifyRepository,
  RiftError,
  removeDeployment,
  renderMachineResult,
  resolveByond,
  resolveWorkflowPython,
  runDoctorWorkflow,
  runMain,
  runReportCommand,
  runServerWorkflow,
  runSoakWorkflow,
  runTestWorkflow,
  summarizeResourceSamples,
  validateFocusType,
  validateMapPath,
  verifyDogmosInstalledContract,
  waitForReadiness,
} from './rift';

const withTempDirectory = async <T>(
  action: (root: string) => Promise<T>,
): Promise<T> => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'rift-test-'));
  try {
    return await action(root);
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
};

const readNdjson = async (filePath: string): Promise<RiftEvent[]> =>
  (await Bun.file(filePath).text())
    .trim()
    .split('\n')
    .map((line) => JSON.parse(line) as RiftEvent);

const createRepositoryFixture = async (root: string) => {
  await fs.mkdir(path.join(root, 'tools', 'build'), { recursive: true });
  await fs.mkdir(path.join(root, '_maps'), { recursive: true });
  await Bun.write(path.join(root, 'tgstation.dme'), '#include "code.dm"\n');
  await Bun.write(
    path.join(root, 'dependencies.sh'),
    [
      'export BYOND_MAJOR=516',
      'export BYOND_MINOR=1687',
      'export BUN_VERSION=1.3.5',
      'export PYTHON_VERSION=3.11.0',
      'export CUTTER_VERSION=v5.0.1',
      '',
    ].join('\n'),
  );
  await Bun.write(
    path.join(root, 'BUILD.cmd'),
    '@echo off\ncall "%~dp0\\tools\\build\\build.bat" --wait-on-error build %*\n',
  );
  await Bun.write(
    path.join(root, 'tools', 'build', 'build.bat'),
    '@echo off\nexit /b 0\n',
  );
  await Bun.write(
    path.join(root, 'tools', 'build', 'build.ts'),
    'export {};\n',
  );
  await Bun.write(path.join(root, '_maps', 'fixture.json'), '{}\n');
};

const processHooks = (lines: string[] = []): ProcessHooks => ({
  onStart: async () => {},
  onOutput: async (stream, line) => {
    lines.push(`${stream}:${line}`);
  },
  onOwnedPids: async () => {},
  onSample: async () => {},
});

const processSpec = (
  script: string,
  overrides: Partial<ProcessSpec> = {},
): ProcessSpec => ({
  role: 'fixture',
  executable: process.execPath,
  args: [script],
  cwd: path.dirname(script),
  env: Object.fromEntries(
    Object.entries(process.env).filter(
      (entry): entry is [string, string] => entry[1] !== undefined,
    ),
  ),
  wallTimeoutMs: 5_000,
  idleTimeoutMs: 5_000,
  ...overrides,
});

const fakeCompileProcess =
  (
    writeArtifacts: boolean,
  ): ((spec: ProcessSpec, hooks: ProcessHooks) => OwnedProcess) =>
  (spec, hooks) => {
    const rootPid = 987_654;
    const result = (async () => {
      const started = Date.now();
      await hooks.onStart(rootPid);
      if (writeArtifacts) {
        const scratchDme = spec.args.at(-1)!;
        const base = scratchDme.slice(0, -'.dme'.length);
        await Bun.write(`${base}.dmb`, 'fixture dmb');
        await Bun.write(`${base}.rsc`, 'fixture rsc');
      }
      await hooks.onOutput('stdout', '0 errors, 0 warnings');
      return {
        role: spec.role,
        rootPid,
        ownedPids: [rootPid],
        exitCode: 0,
        signal: null,
        termination: 'natural' as const,
        startedAt: new Date(started).toISOString(),
        finishedAt: new Date().toISOString(),
        durationMs: Date.now() - started,
      };
    })();
    return {
      rootPid,
      result,
      stop: async () => result,
      snapshot: async () => [],
      ownedPids: () => [rootPid],
    };
  };

const fakeTerminatedProcess =
  (
    termination: ProcessResult['termination'],
    exitCode: number | null = null,
  ): ((spec: ProcessSpec, hooks: ProcessHooks) => OwnedProcess) =>
  (spec, hooks) => {
    const rootPid = 987_655;
    const result = (async (): Promise<ProcessResult> => {
      const startedAt = new Date().toISOString();
      await hooks.onStart(rootPid);
      const processResult = {
        role: spec.role,
        rootPid,
        ownedPids: [rootPid],
        exitCode,
        signal: null,
        termination,
        startedAt,
        finishedAt: new Date().toISOString(),
        durationMs: 1,
      };
      await hooks.onFinish?.(processResult);
      return processResult;
    })();
    return {
      rootPid,
      result,
      stop: async () => result,
      snapshot: async () => [],
      ownedPids: () => [rootPid],
    };
  };

const validProfile = () => ({
  config_source: 'repository',
  default_map: null,
  compile_defines: [],
  dreamdaemon_flags: ['-trusted', '-verbose'],
  readiness_rule: {
    id: 'initialization_complete',
    file: 'data/logs/rift/runtime.log.json',
    category: 'runtime',
    message_pattern: '^Initializations complete within ',
    case_insensitive: false,
  },
  fatal_log_rules: [
    {
      id: 'runtime_error',
      file: 'data/logs/rift/runtime.log.json',
      category: 'runtime',
      message_pattern: 'runtime error:',
      case_insensitive: true,
      max_occurrences: 0,
    },
  ],
  required_children: [],
  artifact_rules: [],
  default_timeouts: {
    wall_seconds: 1800,
    idle_seconds: 300,
    readiness_seconds: 600,
  },
  minimum_tests: 1,
  resource_sample_seconds: 5,
});

const profileDocument = (profile = validProfile()) =>
  JSON.stringify({ schema_version: 1, profiles: { default: profile } });

describe('profile document', () => {
  test('loads strict general and Dogmos profiles', async () => {
    const profiles = await loadProfiles('tools/rift/profiles.json');

    expect([...profiles.keys()]).toEqual([
      'default',
      'ci',
      'dogmos',
      'dogmos-ci',
    ]);
    expect(profiles.get('default')?.minimum_tests).toBe(1);
    expect(profiles.get('dogmos')).toMatchObject({
      config_source: 'repository',
      default_map: '_maps/runtimestation.json',
      required_children: [
        {
          role: 'dogmosd',
          process_name: 'dogmosd.exe',
          min_count: 1,
          max_count: 1,
          continuous_after_readiness: true,
        },
      ],
    });
    expect(profiles.get('dogmos-ci')).toMatchObject({
      config_source: 'ci',
      default_map: '_maps/metastation.json',
    });
    // The minimal base is only compatible with runtimestation_minimal. It clips
    // MetaStation during centering and omits the Mafia arena used by the suite.
    expect(profiles.get('dogmos-ci')?.compile_defines).not.toContain(
      'MINIMAL_CENTCOM',
    );
    expect(
      profiles
        .get('dogmos')
        ?.fatal_log_rules.map(({ id }) => id)
        .sort(),
    ).toEqual([
      'dogmos_lifecycle_rejection',
      'dogmos_malformed_stage',
      'dogmos_panic',
      'dogmos_pending_stage',
      'dogmos_stage_conflict',
      'runtime_error',
    ]);
    expect(RIFT_SCHEMA_VERSION).toBe(1);
  });

  test('rejects duplicate object keys before JSON parsing', () => {
    const text = '{"schema_version":1,"profiles":{"default":{},"default":{}}}';

    expect(() => parseProfileDocument(text)).toThrow(
      'duplicate JSON key: default',
    );
  });

  test('rejects unknown profile properties', () => {
    const profile = { ...validProfile(), unexpected: true };

    expect(() => parseProfileDocument(profileDocument(profile))).toThrow(
      'unknown profile property: unexpected',
    );
  });

  test('rejects profile timeouts above the supported controller limits', () => {
    for (const [field, value] of [
      ['wall_seconds', 3601],
      ['idle_seconds', 901],
      ['readiness_seconds', 901],
    ] as const) {
      const profile = validProfile();
      profile.default_timeouts[field] = value;

      expect(() => parseProfileDocument(profileDocument(profile))).toThrow(
        `${field} must be an integer between`,
      );
    }
  });

  test('rejects unsupported schema versions', () => {
    const text = JSON.stringify({
      schema_version: 2,
      profiles: { default: validProfile() },
    });

    expect(() => parseProfileDocument(text)).toThrow(
      'unsupported profile schema: 2',
    );
  });

  test('rejects paths that escape the repository', () => {
    const profile = { ...validProfile(), default_map: '../secret.json' };

    expect(() => parseProfileDocument(profileDocument(profile))).toThrow(
      'unsafe profile path: ../secret.json',
    );
  });

  test('rejects invalid log regular expressions', () => {
    const profile = validProfile();
    profile.readiness_rule.message_pattern = '[';

    expect(() => parseProfileDocument(profileDocument(profile))).toThrow(
      'invalid log pattern: initialization_complete',
    );
  });
});

describe('doctor and stored reports', () => {
  test('records stable read-only repository, artifact, lock, and scratch observations', async () => {
    await withTempDirectory(async (root) => {
      await createRepositoryFixture(root);
      await Bun.write(path.join(root, 'tgstation.dmb'), 'canonical dmb');
      await Bun.write(path.join(root, 'tgstation.rsc'), 'canonical rsc');
      const scratch = path.join(
        root,
        '.rift-20260831T000000Z-abcd1234.test.dme',
      );
      await Bun.write(scratch, 'stale scratch');
      const repository = await qualifyRepository(root);
      const pins = parseDependencyPins(
        await Bun.file(repository.dependencies).text(),
      );
      const { runId, runDir } = await allocateRun(repository.runsRoot);
      await Bun.write(
        path.join(repository.runsRoot, '.active.lock'),
        `${JSON.stringify({
          schema_version: 1,
          token: 'active-doctor-fixture',
          pid: process.pid,
          command: 'compile',
          run_id: '20260831T000000Z-11223344',
          started_at: new Date().toISOString(),
        })}\n`,
      );
      const recorder = await RunRecorder.create({
        runDir,
        runId,
        command: 'doctor',
        profile: 'default',
        evidence: 'inspection',
        networkMode: 'offline',
      });
      const gitRunner = (
        spec: ProcessSpec,
        hooks: ProcessHooks,
      ): OwnedProcess => {
        const result = (async () => {
          const started = Date.now();
          await hooks.onStart(44_001);
          await hooks.onOwnedPids([44_001]);
          await hooks.onOutput(
            'stdout',
            spec.args[0] === 'rev-parse'
              ? '0123456789abcdef0123456789abcdef01234567'
              : ' M tools/rift/rift.ts',
          );
          return {
            role: spec.role,
            rootPid: 44_001,
            ownedPids: [44_001],
            exitCode: 0,
            signal: null,
            termination: 'natural' as const,
            startedAt: new Date(started).toISOString(),
            finishedAt: new Date().toISOString(),
            durationMs: Date.now() - started,
          };
        })();
        return {
          rootPid: 44_001,
          result,
          stop: async () => result,
          snapshot: async () => [],
          ownedPids: () => [44_001],
        };
      };

      const { observation, summary } = await runDoctorWorkflow({
        repository,
        pins,
        byond: {
          dm: 'fixture-dm.exe',
          dreamDaemon: 'fixture-dreamdaemon.exe',
          version: '516.1687',
          source: 'DM_EXE',
        },
        bunVersion: '1.3.5',
        offlineReady: true,
        recorder,
        runId,
        runDir,
        environment: processSpec(path.join(root, 'unused.ts')).env,
        processRunner: gitRunner,
        processExists: (pid) => pid === process.pid,
      });

      expect(summary.status).toBe('passed');
      expect(observation).toMatchObject({
        repository_qualified: true,
        revision: '0123456789abcdef0123456789abcdef01234567',
        dirty: true,
        bun_version: '1.3.5',
        byond_version: '516.1687',
        build_contract: 'valid',
        offline_ready: true,
        lock: 'active',
        platform: 'windows',
      });
      expect(
        observation.canonical_artifacts.map((entry) => entry.path),
      ).toEqual(['repository/tgstation.dmb', 'repository/tgstation.rsc']);
      expect(observation.canonical_artifacts[0]).toMatchObject({
        size: 13,
        stage: 'doctor',
        freshness: 'reused',
      });
      expect(observation.canonical_artifacts[0].sha256).toHaveLength(64);
      expect(observation.canonical_artifacts[0].modified_at).toMatch(
        /^\d{4}-\d{2}-\d{2}T/,
      );
      expect(observation.stale_scratch).toEqual([path.basename(scratch)]);
      expect(Bun.file(scratch).exists()).resolves.toBe(true);
      expect(JSON.stringify(summary)).not.toContain(root);
      const humanDoctor = renderHumanSummary(summary);
      expect(humanDoctor).toContain('doctor: offline_ready=true lock=active');
      expect(humanDoctor).toContain(`stale_scratch: ${path.basename(scratch)}`);

      await Bun.write(
        path.join(repository.runsRoot, '.active.lock'),
        `${JSON.stringify({
          schema_version: 1,
          token: 'stale-doctor-fixture',
          pid: 45_001,
          command: 'run',
          run_id: '20260831T000000Z-55667788',
          started_at: new Date().toISOString(),
        })}\n`,
      );
      const secondRun = await allocateRun(repository.runsRoot);
      const secondRecorder = await RunRecorder.create({
        runDir: secondRun.runDir,
        runId: secondRun.runId,
        command: 'doctor',
        profile: 'default',
        evidence: 'inspection',
        networkMode: 'offline',
      });
      const second = await runDoctorWorkflow({
        repository,
        pins,
        byond: {
          dm: 'fixture-dm.exe',
          dreamDaemon: 'fixture-dreamdaemon.exe',
          version: '516.1687',
          source: 'DM_EXE',
        },
        bunVersion: '1.3.5',
        offlineReady: false,
        recorder: secondRecorder,
        runId: secondRun.runId,
        runDir: secondRun.runDir,
        environment: processSpec(path.join(root, 'unused.ts')).env,
        processRunner: gitRunner,
        processExists: () => false,
      });
      expect(second.observation.lock).toBe('stale');
      expect(second.summary.status).toBe('failed');
      expect(second.summary.exit_code).toBe(3);
      expect(Bun.file(scratch).exists()).resolves.toBe(true);
    });
  });

  test('renders a stored human report and replays JSONL without allocating a run', async () => {
    await withTempDirectory(async (runsRoot) => {
      const runId = '20260831T000000Z-a1b2c3d4';
      const runDir = path.join(runsRoot, runId);
      const recorder = await RunRecorder.create({
        runDir,
        runId,
        command: 'test',
        profile: 'ci',
        evidence: 'focused_test',
        networkMode: 'offline',
      });
      await recorder.setTests({
        recorded: 1,
        passed: 1,
        failed: 0,
        skipped: 0,
      });
      await recorder.addArtifact({
        path: 'artifacts/data/unit_tests.json',
        size: 10,
        sha256: 'a'.repeat(64),
        stage: 'collect',
        freshness: 'collected',
      });
      await recorder.finish('passed', 0);
      const before = (await fs.readdir(runsRoot)).sort();

      const human = await runReportCommand(runsRoot, runId, 'human');
      const jsonl = await runReportCommand(runsRoot, runId, 'jsonl');

      expect(human).toContain('RIFT test passed');
      expect(human).toContain('tests: recorded=1 passed=1 failed=0 skipped=0');
      expect(human).toContain('artifact: artifacts/data/unit_tests.json');
      expect(jsonl.trim()).toBe(
        (await Bun.file(path.join(runDir, 'events.ndjson')).text()).trim(),
      );
      expect((await fs.readdir(runsRoot)).sort()).toEqual(before);
      expect(
        runReportCommand(runsRoot, '../summary.json', 'human'),
      ).rejects.toThrow('invalid run ID');
    });
  });
});

describe('run report', () => {
  test('writes contiguous events before final summary publication', async () => {
    await withTempDirectory(async (root) => {
      const recorder = await RunRecorder.create({
        runDir: root,
        runId: '20260831T120000Z-0123abcd',
        command: 'doctor',
        profile: 'default',
        evidence: 'inspection',
        networkMode: 'offline',
      });
      await recorder.emit('stage_started', 'preflight', {});

      expect(
        (await readNdjson(path.join(root, 'events.ndjson'))).map(
          ({ sequence }) => sequence,
        ),
      ).toEqual([1, 2]);

      await recorder.finish('passed', 0);
      const events = await readNdjson(path.join(root, 'events.ndjson'));
      expect(events.map(({ sequence }) => sequence)).toEqual([1, 2, 3]);
      expect(
        (await Bun.file(path.join(root, 'summary.json')).json()).status,
      ).toBe('passed');
    });
  });

  test('summarizes completed phases and supervised processes', async () => {
    await withTempDirectory(async (root) => {
      const recorder = await RunRecorder.create({
        runDir: root,
        runId: '20260831T120000Z-0123abcd',
        command: 'compile',
        profile: 'default',
        evidence: 'compiler',
        networkMode: 'offline',
      });
      const fixture = path.join(root, 'process.ts');
      await Bun.write(fixture, "console.log('done');\n");
      await recorder.emit('stage_started', 'compile', { mode: 'fast' });
      const result = await startOwnedProcess(processSpec(fixture), {
        onStart: async (pid) => {
          await recorder.emit('process_started', 'compile', {
            role: 'dreammaker',
            pid,
          });
        },
        onOutput: async (stream, line) => {
          await recorder.appendOutput('compile', 'dreammaker', stream, line);
        },
        onOwnedPids: async () => {},
        onSample: async () => {},
        onFinish: async (processResult) => {
          await recorder.addProcess(processResult);
        },
      }).result;
      await recorder.emit(
        'stage_finished',
        'compile',
        { evidence: 'compiler' },
        'passed',
      );
      const summary = await recorder.finish('passed', 0);

      expect(result.exitCode).toBe(0);
      expect(summary.phases).toHaveLength(1);
      expect(summary.phases[0]).toMatchObject({
        stage: 'compile',
        status: 'passed',
        mode: 'fast',
        evidence: 'compiler',
      });
      expect(summary.phases[0].duration_ms).toBeNumber();
      expect(summary.processes).toHaveLength(1);
      expect(summary.processes[0]).toMatchObject({
        role: 'fixture',
        root_pid: result.rootPid,
        exit_code: 0,
        termination: 'natural',
      });
      expect(renderHumanSummary(summary)).toContain(
        'process: role=fixture termination=natural exit=0',
      );
    });
  });

  test('bounds artifact detail in human output without dropping stored records', async () => {
    await withTempDirectory(async (root) => {
      const recorder = await RunRecorder.create({
        runDir: root,
        runId: '20260831T120000Z-0123abcd',
        command: 'run',
        profile: 'default',
        evidence: 'boot',
        networkMode: 'offline',
      });
      for (let index = 0; index < 12; index += 1) {
        await recorder.addArtifact({
          path: `artifacts/log-${String(index).padStart(2, '0')}.json`,
          size: index + 1,
          sha256: String(index).padStart(64, '0'),
          stage: 'collect',
          freshness: 'collected',
        });
      }
      const summary = await recorder.finish('passed', 0);
      const human = renderHumanSummary(summary);

      expect(summary.artifacts).toHaveLength(12);
      expect(human).toContain('artifacts: 12 total, 4 omitted');
      expect(human).not.toContain('artifacts/log-11.json');
    });
  });

  test('persists failure details in the final summary', async () => {
    await withTempDirectory(async (root) => {
      const recorder = await RunRecorder.create({
        runDir: root,
        runId: '20260831T120000Z-0123abcd',
        command: 'compile',
        profile: 'default',
        evidence: 'compiler',
        networkMode: 'offline',
      });
      await recorder.addFailure({
        code: 'compile_failed',
        stage: 'compile',
        message: 'bad output',
      });
      const summary = await recorder.finish('failed', 4);

      expect(summary.failures).toEqual([
        { code: 'compile_failed', stage: 'compile', message: 'bad output' },
      ]);
      expect(summary.exit_code).toBe(4);
    });
  });

  test('hashes only artifacts contained by the run directory', async () => {
    await withTempDirectory(async (root) => {
      const artifactPath = path.join(root, 'artifacts', 'hello.txt');
      await fs.mkdir(path.dirname(artifactPath), { recursive: true });
      await Bun.write(artifactPath, 'hello');

      expect(
        await hashArtifact(artifactPath, root, 'collect', 'collected'),
      ).toEqual({
        path: 'artifacts/hello.txt',
        size: 5,
        sha256:
          '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824',
        stage: 'collect',
        freshness: 'collected',
      });
      expect(
        hashArtifact(
          path.join(root, '..', 'outside.txt'),
          root,
          'collect',
          'collected',
        ),
      ).rejects.toThrow('artifact path escapes run directory');
    });
  });

  test('normalizes unstable runtime references and numbers', () => {
    expect(
      normalizeRuntimeSignature('runtime error: bad [0x200001f] at 123'),
    ).toBe('runtime error: bad [ref] at N');
  });

  test('rejects unsupported stored report schemas', async () => {
    await withTempDirectory(async (root) => {
      await Bun.write(
        path.join(root, 'summary.json'),
        JSON.stringify({ schema_version: 2 }),
      );
      await Bun.write(path.join(root, 'events.ndjson'), '');

      expect(readStoredRun(root)).rejects.toThrow(
        'unsupported report schema: 2',
      );
    });
  });

  test('redacts user-profile segments in human output', async () => {
    await withTempDirectory(async (root) => {
      const recorder = await RunRecorder.create({
        runDir: root,
        runId: '20260831T120000Z-0123abcd',
        command: 'doctor',
        profile: 'default',
        evidence: 'inspection',
        networkMode: 'offline',
      });
      await recorder.addFailure({
        code: 'private_path',
        stage: 'preflight',
        message: 'C:\\Users\\ExampleUser\\secret.txt',
      });
      const summary = await recorder.finish('failed', 3);

      expect(renderHumanSummary(summary)).toContain(
        'C:\\Users\\<profile>\\secret.txt',
      );
      expect(renderHumanSummary(summary)).not.toContain('ExampleUser');
    });
  });

  test('renders one versioned compact compile result with canonical evidence', async () => {
    await withTempDirectory(async (root) => {
      const recorder = await RunRecorder.create({
        runDir: root,
        runId: '20260831T120000Z-0123abce',
        command: 'compile',
        profile: 'default',
        evidence: 'full_build',
        networkMode: 'offline',
      });
      await recorder.emit('stage_started', 'compile', { mode: 'full' });
      for (const [artifactPath, sha256] of [
        ['artifacts/tgstation.dmb', 'a'.repeat(64)],
        ['artifacts/tgstation.rsc', 'b'.repeat(64)],
      ]) {
        await recorder.addArtifact({
          path: artifactPath,
          size: 12,
          sha256,
          stage: 'compile',
          freshness: 'reused',
        });
      }
      await recorder.emit(
        'stage_finished',
        'compile',
        { evidence: 'full_build', reused: true },
        'passed',
      );
      const summary = await recorder.finish('passed', 0);

      const line = renderMachineResult(summary);
      expect(line.startsWith('RIFT_RESULT ')).toBe(true);
      expect(line.split('\n')).toHaveLength(1);
      expect(JSON.parse(line.slice('RIFT_RESULT '.length))).toEqual({
        schema_version: 1,
        run_id: summary.run_id,
        command: 'compile',
        status: 'passed',
        evidence: 'full_build',
        exit_code: 0,
        reused: true,
        artifacts: [
          {
            path: 'artifacts/tgstation.dmb',
            size: 12,
            sha256: 'a'.repeat(64),
            freshness: 'reused',
          },
          {
            path: 'artifacts/tgstation.rsc',
            size: 12,
            sha256: 'b'.repeat(64),
            freshness: 'reused',
          },
        ],
      });
    });
  });

  test('keeps DreamDaemon and dogmosd memory separate in Dogmos results', async () => {
    await withTempDirectory(async (root) => {
      const recorder = await RunRecorder.create({
        runDir: root,
        runId: '20260831T120000Z-0123abcf',
        command: 'soak',
        profile: 'dogmos',
        evidence: 'soak',
        networkMode: 'offline',
      });
      await recorder.setResourceMaxima([
        {
          role: 'dreamdaemon',
          private_bytes_max: 100,
          working_set_bytes_max: 200,
          samples: 3,
        },
        {
          role: 'dogmosd',
          private_bytes_max: 300,
          working_set_bytes_max: 400,
          samples: 3,
        },
      ]);
      const summary = await recorder.finish('passed', 0);

      const result = JSON.parse(
        renderMachineResult(summary).slice('RIFT_RESULT '.length),
      );
      expect(result.dogmos).toEqual({
        dreamdaemon: {
          private_bytes_max: 100,
          working_set_bytes_max: 200,
          samples: 3,
        },
        service: {
          private_bytes_max: 300,
          working_set_bytes_max: 400,
          samples: 3,
        },
        runtime_signatures: [],
      });
    });
  });

  test('redacts profile paths before structured report serialization', async () => {
    await withTempDirectory(async (root) => {
      const recorder = await RunRecorder.create({
        runDir: root,
        runId: '20260831T120000Z-0123abcd',
        command: 'doctor',
        profile: 'default',
        evidence: 'inspection',
        networkMode: 'offline',
      });
      await recorder.appendOutput(
        'preflight',
        'fixture',
        'stderr',
        'C:\\Users\\SensitiveProfile\\secret.txt',
      );
      await recorder.addFailure({
        code: 'private_path',
        stage: 'preflight',
        message: '/Users/SensitiveProfile/secret.txt',
      });
      await recorder.finish('failed', 3);

      const structured = [
        await Bun.file(path.join(root, 'summary.json')).text(),
        await Bun.file(path.join(root, 'events.ndjson')).text(),
      ].join('\n');
      expect(structured).not.toContain('SensitiveProfile');
      expect(structured).toContain('<profile>');
    });
  });

  test('rejects event writes after the final summary is published', async () => {
    await withTempDirectory(async (root) => {
      const recorder = await RunRecorder.create({
        runDir: root,
        runId: '20260831T120000Z-0123abcd',
        command: 'doctor',
        profile: 'default',
        evidence: 'inspection',
        networkMode: 'offline',
      });
      await recorder.finish('passed', 0);

      await expect(
        recorder.emit('observation', 'doctor', { late: true }),
      ).rejects.toThrow('run recorder is finished');
      expect(await readNdjson(path.join(root, 'events.ndjson'))).toHaveLength(
        2,
      );
    });
  });

  test('publishes one terminal event for concurrent finalization', async () => {
    await withTempDirectory(async (root) => {
      const recorder = await RunRecorder.create({
        runDir: root,
        runId: '20260831T120000Z-abcdef12',
        command: 'doctor',
        profile: 'default',
        evidence: 'inspection',
        networkMode: 'offline',
      });

      const [first, second] = await Promise.all([
        recorder.finish('passed', 0),
        recorder.finish('passed', 0),
      ]);

      expect(second).toEqual(first);
      expect(
        (await readNdjson(path.join(root, 'events.ndjson'))).filter(
          ({ kind }) => kind === 'run_finished',
        ),
      ).toHaveLength(1);
    });
  });

  test('rejects inconsistent stored event streams', async () => {
    await withTempDirectory(async (root) => {
      const recorder = await RunRecorder.create({
        runDir: root,
        runId: '20260831T120000Z-0123abcd',
        command: 'doctor',
        profile: 'default',
        evidence: 'inspection',
        networkMode: 'offline',
      });
      await recorder.finish('passed', 0);
      const events = await readNdjson(path.join(root, 'events.ndjson'));
      events[1].sequence = 7;
      await Bun.write(
        path.join(root, 'events.ndjson'),
        `${events.map((event) => JSON.stringify(event)).join('\n')}\n`,
      );

      await expect(readStoredRun(root)).rejects.toThrow('event sequence');
    });
  });
});

describe('CLI and preflight qualification', () => {
  test('classifies failures by type rather than message text', () => {
    expect(
      classifyFailure(new Error('compile timeout in a harmless filename')),
    ).toEqual({
      code: 'workflow_failed',
      stage: 'run',
      exitCode: 5,
    });
    expect(
      classifyFailure(
        new RiftError('readiness_timeout', 'server', 'deadline elapsed', 6),
      ),
    ).toEqual({
      code: 'readiness_timeout',
      stage: 'server',
      exitCode: 6,
    });
  });

  test('parses global and compile options without reading developer environment', () => {
    expect(
      parseCli(['--network=allow', 'compile', '--mode', 'full', '--force'], {}),
    ).toMatchObject({
      command: 'compile',
      networkMode: 'allow',
      mode: 'full',
      force: true,
      profile: 'default',
      format: 'human',
    });
  });

  test('uses the validated network environment default', () => {
    expect(
      parseCli(['doctor'], { MERIDIAN_RIFT_BUILD_NETWORK: 'allow' }),
    ).toMatchObject({
      command: 'doctor',
      networkMode: 'allow',
    });
    expect(() =>
      parseCli(['doctor'], { MERIDIAN_RIFT_BUILD_NETWORK: 'internet' }),
    ).toThrow('network mode must be offline or allow');
  });

  test('selects pinned or explicit Python without an unresolved placeholder', () => {
    expect(resolveWorkflowPython({}, null)).toBe('python');
    expect(
      resolveWorkflowPython({ PYTHON: 'candidate-python.exe' }, null),
    ).toBe('candidate-python.exe');
    expect(
      resolveWorkflowPython({ PYTHON: 'candidate-python.exe' }, 'pinned.exe'),
    ).toBe('pinned.exe');
  });

  test('uses the CI profile by default for unit tests', () => {
    expect(parseCli(['test'], {})).toMatchObject({
      command: 'test',
      profile: 'ci',
    });
  });

  test('accepts paired native overlays for every runtime workflow', () => {
    for (const argv of [
      ['run', '--shim', 'shim.dll', '--service', 'service.exe'],
      ['test', '--shim', 'shim.dll', '--service', 'service.exe'],
      [
        'soak',
        '--run-seconds',
        '30',
        '--shim',
        'shim.dll',
        '--service',
        'service.exe',
      ],
    ]) {
      expect(parseCli(argv, {})).toMatchObject({
        shim: 'shim.dll',
        service: 'service.exe',
      });
    }
    for (const command of ['run', 'test', 'soak']) {
      const argv =
        command === 'soak'
          ? [command, '--run-seconds', '30', '--shim', 'shim.dll']
          : [command, '--shim', 'shim.dll'];
      expect(() => parseCli(argv, {})).toThrow(
        '--shim and --service must be supplied together',
      );
    }
  });

  test('requires explicit native overlays for Dogmos runtime workflows', () => {
    for (const argv of [
      ['run', '--profile', 'dogmos'],
      ['test', '--profile', 'dogmos-ci'],
      ['soak', '--profile', 'dogmos', '--run-seconds', '30'],
    ]) {
      expect(() => parseCli(argv, {})).toThrow(
        'Dogmos runtime profiles require --shim and --service',
      );
    }
    expect(() =>
      parseCli(
        [
          'run',
          '--profile',
          'dogmos',
          '--shim',
          'dogmos.dll',
          '--service',
          'dogmosd.exe',
        ],
        {},
      ),
    ).not.toThrow();
  });

  test('runs the installed Dogmos contract verifier as a supervised preflight', async () => {
    await withTempDirectory(async (root) => {
      const repository = path.join(root, 'game');
      await fs.mkdir(path.join(repository, 'tools', 'dogmos'), {
        recursive: true,
      });
      await Bun.write(
        path.join(repository, 'tools', 'dogmos', 'verify_contract.py'),
        'fixture',
      );
      const specs: ProcessSpec[] = [];
      const runner = (spec: ProcessSpec, hooks: ProcessHooks) => {
        specs.push(spec);
        return fakeTerminatedProcess('natural', 0)(spec, hooks);
      };
      await verifyDogmosInstalledContract({
        repositoryRoot: repository,
        python: 'pinned-python.exe',
        environment: {},
        runner,
      });
      expect(specs).toHaveLength(1);
      expect(specs[0]).toMatchObject({
        role: 'dogmos-contract',
        executable: 'pinned-python.exe',
        cwd: repository,
        args: [
          path.join(repository, 'tools', 'dogmos', 'verify_contract.py'),
          'verify-installed',
          '--root',
          repository,
        ],
      });
    });
  });

  test('returns usage exit codes for malformed CLI input', async () => {
    expect(
      await runMain(['doctor', '--wall-timeout-seconds', 'nope'], {}),
    ).toBe(2);
    expect(await runMain(['doctor', '--mystery'], {})).toBe(2);
  });

  test('rejects duplicate, missing, unknown, and fractional options', () => {
    expect(() =>
      parseCli(['compile', '--mode', 'fast', '--mode', 'full'], {}),
    ).toThrow('duplicate option: --mode');
    expect(() => parseCli(['run', '--port'], {})).toThrow(
      'missing value for --port',
    );
    expect(() => parseCli(['doctor', '--mystery'], {})).toThrow(
      'unknown option: --mystery',
    );
    expect(() =>
      parseCli(['run', '--wall-timeout-seconds', '1.5'], {}),
    ).toThrow('wall timeout must be a base-10 integer');
  });

  test('rejects CLI timeouts above the supported controller limits', () => {
    expect(() =>
      parseCli(
        ['compile', '--mode', 'full', '--wall-timeout-seconds', '3601'],
        {},
      ),
    ).toThrow('wall timeout must be 1-3600');
    expect(() =>
      parseCli(
        ['compile', '--mode', 'full', '--idle-timeout-seconds', '901'],
        {},
      ),
    ).toThrow('idle timeout must be 1-900');
    expect(() =>
      parseCli(['doctor', '--wait-for-lock-seconds', '301'], {}),
    ).toThrow('lock wait must be 0-300');
    expect(() =>
      parseCli(['run', '--readiness-timeout-seconds', '901'], {}),
    ).toThrow('readiness timeout must be 1-900');
  });

  test('uses validated timeout environment defaults and CLI precedence', () => {
    const environment = {
      MERIDIAN_RIFT_WALL_TIMEOUT_SECONDS: '1700',
      MERIDIAN_RIFT_IDLE_TIMEOUT_SECONDS: '110',
    };

    expect(parseCli(['compile', '--mode', 'full'], environment)).toMatchObject({
      wallTimeoutSeconds: 1700,
      idleTimeoutSeconds: 110,
    });
    expect(
      parseCli(
        ['compile', '--mode', 'full', '--wall-timeout-seconds', '2000'],
        environment,
      ),
    ).toMatchObject({ wallTimeoutSeconds: 2000, idleTimeoutSeconds: 110 });
    expect(() =>
      parseCli(['compile', '--mode', 'full'], {
        MERIDIAN_RIFT_WALL_TIMEOUT_SECONDS: '3601',
      }),
    ).toThrow('wall timeout must be 1-3600');
  });

  test('deduplicates valid unit-test focus paths and rejects executable text', () => {
    const command = parseCli(
      [
        'test',
        '--focus',
        '/datum/unit_test/example',
        '--focus',
        '/datum/unit_test/example',
      ],
      {},
    );
    expect(command.command === 'test' ? command.focus : []).toEqual([
      '/datum/unit_test/example',
    ]);
    expect(() => validateFocusType('/datum/unit_test/foo;shutdown()')).toThrow(
      'invalid unit-test type',
    );
  });

  test('parses only literal required dependency pins', () => {
    expect(
      parseDependencyPins(
        [
          'export BYOND_MAJOR=516',
          'export BYOND_MINOR=1687',
          'export BUN_VERSION=1.3.5',
          'export PYTHON_VERSION=3.11.0',
          'export CUTTER_VERSION=v5.0.1',
        ].join('\n'),
      ),
    ).toEqual({
      BYOND_MAJOR: '516',
      BYOND_MINOR: '1687',
      BUN_VERSION: '1.3.5',
      PYTHON_VERSION: '3.11.0',
      CUTTER_VERSION: 'v5.0.1',
    });
    expect(() =>
      parseDependencyPins('export BUN_VERSION=$' + '{CHANNEL}\n'),
    ).toThrow('invalid dependency pin: BUN_VERSION');
  });

  test('qualifies the nearest repository and scopes map paths', async () => {
    await withTempDirectory(async (root) => {
      await createRepositoryFixture(root);
      const nested = path.join(root, 'tools', 'rift');
      await fs.mkdir(nested, { recursive: true });

      const repository = await qualifyRepository(nested);
      expect(repository.root).toBe(await fs.realpath(root));
      expect(validateMapPath(repository.root, '_maps/fixture.json')).toBe(
        '_maps/fixture.json',
      );
      expect(() => validateMapPath(repository.root, '../fixture.json')).toThrow(
        'map path escapes _maps',
      );
      await Bun.write(
        path.join(root, '_maps', 'runtimestation_minimal.json'),
        '{}\n',
      );
      expect(() =>
        (
          validateMapPath as (
            repositoryRoot: string,
            selectedMap: string,
            completionEvidence: boolean,
          ) => string
        )(repository.root, '_maps/runtimestation_minimal.json', true),
      ).toThrow('representative map');
    });
  });

  test('rejects a drifted protected build contract before execution', async () => {
    await withTempDirectory(async (root) => {
      await createRepositoryFixture(root);
      await Bun.write(
        path.join(root, 'BUILD.cmd'),
        '@echo off\ncall "%~dp0\\tools\\build\\build.bat" --wait-on-error lint %*\n',
      );

      expect(qualifyRepository(root)).rejects.toThrow(
        'build contract mismatch',
      );
    });
  });

  test('requires the exact pinned DreamMaker version and sibling daemon', async () => {
    await withTempDirectory(async (root) => {
      await createRepositoryFixture(root);
      const dm = path.join(root, 'fake-byond', 'dm.exe');
      const daemon = path.join(root, 'fake-byond', 'dreamdaemon.exe');
      await fs.mkdir(path.dirname(dm), { recursive: true });
      await Bun.write(dm, 'fixture');
      await Bun.write(daemon, 'fixture');
      const previous = process.env.DM_EXE;
      process.env.DM_EXE = dm;
      try {
        const repository = await qualifyRepository(root);
        const pins = parseDependencyPins(
          await Bun.file(repository.dependencies).text(),
        );
        const byond = await resolveByond(
          repository,
          pins,
          async (executable) => ({
            exitCode: 1,
            stdout: executable === dm ? 'DM compiler version 516.1687\n' : '',
            stderr: '',
          }),
        );
        expect(byond).toEqual({
          dm,
          dreamDaemon: daemon,
          version: '516.1687',
          source: 'DM_EXE',
        });
      } finally {
        if (previous === undefined) {
          delete process.env.DM_EXE;
        } else {
          process.env.DM_EXE = previous;
        }
      }
    });
  });

  test('uses the default named BYOND version before machine-wide installs', async () => {
    await withTempDirectory(async (root) => {
      await createRepositoryFixture(root);
      const dm = path.join(root, 'named-byond', 'dm.exe');
      const daemon = path.join(root, 'named-byond', 'dreamdaemon.exe');
      await fs.mkdir(path.dirname(dm), { recursive: true });
      await Bun.write(dm, 'fixture');
      await Bun.write(daemon, 'fixture');
      await Bun.write(
        path.join(root, 'tools', 'build', 'dm_versions.json'),
        `${JSON.stringify([{ name: 'pinned', path: dm, default: true }])}\n`,
      );
      const repository = await qualifyRepository(root);
      const pins = parseDependencyPins(
        await Bun.file(repository.dependencies).text(),
      );

      const byond = await resolveByond(
        repository,
        pins,
        async (executable) => ({
          exitCode: executable === dm ? 0 : 1,
          stdout: executable === dm ? 'DM compiler version 516.1687\n' : '',
          stderr: '',
        }),
        {},
      );

      expect(byond).toEqual({
        dm,
        dreamDaemon: daemon,
        version: '516.1687',
        source: 'named_version',
      });
    });
  });

  test('offline preflight fails before probing when cache files are absent', async () => {
    await withTempDirectory(async (root) => {
      await createRepositoryFixture(root);
      const repository = await qualifyRepository(root);
      const pins = parseDependencyPins(
        await Bun.file(repository.dependencies).text(),
      );
      let probes = 0;

      expect(
        preflightOffline(
          repository,
          pins,
          { TG_BOOTSTRAP_CACHE: path.join(root, 'missing') },
          async () => {
            probes += 1;
            return { exitCode: 0, stdout: '', stderr: '' };
          },
        ),
      ).rejects.toThrow('offline prerequisites missing');
      expect(probes).toBe(0);
    });
  });

  test('installs inherited offline policy through the Bun global config', async () => {
    await withTempDirectory(async (root) => {
      await createRepositoryFixture(root);
      const repository = await qualifyRepository(root);
      const pins = parseDependencyPins(
        await Bun.file(repository.dependencies).text(),
      );
      const cache = path.join(root, 'cache');
      const pythonRoot = path.join(cache, `python-${pins.PYTHON_VERSION}`);
      const required = [
        path.join(cache, `bun-v${pins.BUN_VERSION}-x64`, 'bun.exe'),
        path.join(pythonRoot, 'python.exe'),
        path.join(pythonRoot, 'Scripts', 'pip.exe'),
        path.join(
          root,
          'tools',
          'icon_cutter',
          'cache',
          `hypnagogic${pins.CUTTER_VERSION.replaceAll('.', '-')}.exe`,
        ),
        path.join(root, 'bun.lock'),
        path.join(root, 'tgui', 'bun.lock'),
      ];
      const requirements = path.join(root, 'tools', 'requirements.txt');
      const marker = path.join(pythonRoot, 'requirements.txt');
      for (const filePath of [...required, requirements, marker]) {
        await fs.mkdir(path.dirname(filePath), { recursive: true });
        await Bun.write(
          filePath,
          filePath === requirements || filePath === marker
            ? 'pin\n'
            : 'fixture',
        );
      }
      let installProbes = 0;
      const preflight = await preflightOffline(
        repository,
        pins,
        { TG_BOOTSTRAP_CACHE: cache },
        async (_executable, args, _cwd, environment) => {
          if (args[0] === '--version') {
            return { exitCode: 0, stdout: `${pins.BUN_VERSION}\n`, stderr: '' };
          }
          installProbes += 1;
          expect(args).toEqual(['install', '--dry-run']);
          const configPath = path.join(
            environment.XDG_CONFIG_HOME,
            '.bunfig.toml',
          );
          expect(await Bun.file(configPath).text()).toContain('offline = true');
          return { exitCode: 0, stdout: '', stderr: '' };
        },
      );

      expect(installProbes).toBe(2);
      await preflight.cleanup();
    });
  });
});

describe('Windows launchers', () => {
  const runLauncher = async (
    root: string,
    launcher: string,
    args: string[],
    environment: Record<string, string> = {},
  ) => {
    return runProbeProcess(
      'cmd.exe',
      ['/d', '/s', '/c', launcher, ...args],
      root,
      {
        ...processSpec(path.join(root, 'unused.ts')).env,
        // Launcher tests own their cache; an inherited development cache must
        // not make the deliberately missing-Bun case find the real executable.
        TG_BOOTSTRAP_CACHE: path.join(root, 'tools', 'bootstrap', '.cache'),
        ...environment,
      },
    );
  };

  const createLauncherFixture = async (parent: string) => {
    const root = path.join(parent, 'RIFT fixture & checkout');
    await fs.mkdir(path.join(root, 'tools', 'rift'), { recursive: true });
    await fs.mkdir(path.join(root, 'tools', 'bootstrap', '.cache'), {
      recursive: true,
    });
    await fs.copyFile('RIFT.cmd', path.join(root, 'RIFT.cmd'));
    await fs.copyFile('RIFT_BUILD.cmd', path.join(root, 'RIFT_BUILD.cmd'));
    await Bun.write(
      path.join(root, 'dependencies.sh'),
      'export BUN_VERSION=1.3.5\n',
    );
    await Bun.write(
      path.join(root, 'tools', 'rift', 'rift.ts'),
      'console.log(JSON.stringify({ args: Bun.argv.slice(2), network: process.env.MERIDIAN_RIFT_BUILD_NETWORK ?? null }));\n',
    );
    const bunRoot = path.join(
      root,
      'tools',
      'bootstrap',
      '.cache',
      'bun-v1.3.5-x64',
    );
    await fs.mkdir(bunRoot, { recursive: true });
    await fs.link(process.execPath, path.join(bunRoot, 'bun.exe'));
    await Bun.write(
      path.join(root, 'tools', 'bootstrap', 'javascript.bat'),
      [
        '@echo off',
        '"%~dp0.cache\\bun-v1.3.5-x64\\bun.exe" %*',
        'exit /b %ERRORLEVEL%',
        '',
      ].join('\n'),
    );
    return root;
  };

  test('selects offline before Bun and preserves quoted arguments', async () => {
    await withTempDirectory(async (parent) => {
      const root = await createLauncherFixture(parent);
      const result = await runLauncher(root, 'RIFT.cmd', [
        'run',
        '--map',
        '_maps/Meta & Station.json',
      ]);

      expect(result.exitCode).toBe(0);
      expect(JSON.parse(result.stdout.trim())).toEqual({
        args: ['run', '--map', '_maps/Meta & Station.json'],
        network: null,
      });
    });
  });

  test('supports both network forms and fails offline before bootstrap when Bun is absent', async () => {
    await withTempDirectory(async (parent) => {
      const root = await createLauncherFixture(parent);
      const allow = await runLauncher(root, 'RIFT.cmd', [
        'doctor',
        '--network',
        'allow',
      ]);
      const explicitOffline = await runLauncher(root, 'RIFT.cmd', [
        'doctor',
        '--network=offline',
      ]);
      await fs.rm(
        path.join(
          root,
          'tools',
          'bootstrap',
          '.cache',
          'bun-v1.3.5-x64',
          'bun.exe',
        ),
      );
      const missing = await runLauncher(root, 'RIFT.cmd', ['doctor']);

      expect(allow.exitCode).toBe(0);
      expect(JSON.parse(allow.stdout.trim()).args).toEqual([
        'doctor',
        '--network',
        'allow',
      ]);
      expect(explicitOffline.exitCode).toBe(0);
      expect(missing.exitCode).toBe(3);
      expect(missing.stderr).toContain('pinned Bun is absent');
    });
  });

  test('validates launcher and compatibility environments and maps force exactly', async () => {
    await withTempDirectory(async (parent) => {
      const root = await createLauncherFixture(parent);
      const invalidNetwork = await runLauncher(root, 'RIFT.cmd', ['doctor'], {
        MERIDIAN_RIFT_BUILD_NETWORK: 'maybe',
      });
      const unexpected = await runLauncher(root, 'RIFT_BUILD.cmd', ['extra']);
      const invalidForce = await runLauncher(root, 'RIFT_BUILD.cmd', [], {
        MERIDIAN_RIFT_FORCE_REBUILD: 'yes',
      });
      const normal = await runLauncher(root, 'RIFT_BUILD.cmd', []);
      const forced = await runLauncher(root, 'RIFT_BUILD.cmd', [], {
        MERIDIAN_RIFT_FORCE_REBUILD: '1',
      });

      expect(invalidNetwork.exitCode).toBe(2);
      expect(unexpected.exitCode).toBe(2);
      expect(invalidForce.exitCode).toBe(2);
      expect(JSON.parse(normal.stdout.trim()).args).toEqual([
        'compile',
        '--mode',
        'full',
        '--format',
        'result',
      ]);
      expect(JSON.parse(forced.stdout.trim()).args).toEqual([
        'compile',
        '--mode',
        'full',
        '--force',
        '--format',
        'result',
      ]);
    });
  });
});

describe('run allocation and locking', () => {
  test('allocates unique schema-shaped run directories', async () => {
    await withTempDirectory(async (root) => {
      const first = await allocateRun(root);
      const second = await allocateRun(root);

      expect(first.runId).toMatch(/^\d{8}T\d{6}Z-[0-9a-f]{8}$/);
      expect(second.runId).not.toBe(first.runId);
      expect((await fs.stat(first.runDir)).isDirectory()).toBe(true);
      expect((await fs.stat(second.runDir)).isDirectory()).toBe(true);
    });
  });

  test('refuses a lock owned by a live process without waiting', async () => {
    await withTempDirectory(async (root) => {
      const first = await acquireRunLock(
        root,
        'compile',
        'run-a',
        0,
        () => true,
      );

      expect(
        acquireRunLock(root, 'test', 'run-b', 0, () => true),
      ).rejects.toThrow('RIFT workflow lock is active');
      await first.release();
    });
  });

  test('archives a stale lock before acquiring a replacement', async () => {
    await withTempDirectory(async (root) => {
      await fs.mkdir(root, { recursive: true });
      await Bun.write(
        path.join(root, '.active.lock'),
        JSON.stringify({
          schema_version: 1,
          token: 'stale-token',
          pid: 424242,
          command: 'compile',
          run_id: 'stale-run',
          started_at: '2026-08-31T12:00:00.000Z',
        }),
      );

      const lock = await acquireRunLock(
        root,
        'test',
        'new-run',
        0,
        () => false,
      );
      const archived = await fs.readdir(path.join(root, 'stale-locks'));
      expect(archived).toHaveLength(1);
      expect(JSON.parse(await Bun.file(lock.path).text()).run_id).toBe(
        'new-run',
      );
      await lock.release();
    });
  });

  test('does not archive a replacement lock that appeared during stale detection', async () => {
    await withTempDirectory(async (root) => {
      const lockPath = path.join(root, '.active.lock');
      const stale = {
        schema_version: 1,
        token: 'stale-token',
        pid: 424_242,
        command: 'compile',
        run_id: 'stale-run',
        started_at: '2026-08-31T12:00:00.000Z',
      };
      const replacement = {
        ...stale,
        token: 'live-token',
        pid: 525_252,
        command: 'test',
        run_id: 'live-run',
      };
      await Bun.write(lockPath, JSON.stringify(stale));
      let replaced = false;

      await expect(
        acquireRunLock(root, 'soak', 'contender', 0, (pid) => {
          if (pid === stale.pid && !replaced) {
            replaced = true;
            fsSync.writeFileSync(lockPath, JSON.stringify(replacement));
            return false;
          }
          return pid === replacement.pid;
        }),
      ).rejects.toThrow('RIFT workflow lock is active');
      expect(JSON.parse(await Bun.file(lockPath).text()).token).toBe(
        'live-token',
      );
    });
  });

  test('archives malformed stale locks instead of blocking permanently', async () => {
    await withTempDirectory(async (root) => {
      await Bun.write(path.join(root, '.active.lock'), '{partial');

      const lock = await acquireRunLock(
        root,
        'test',
        'new-run',
        0,
        () => false,
      );

      expect(lock.record.run_id).toBe('new-run');
      expect(await fs.readdir(path.join(root, 'stale-locks'))).toHaveLength(1);
      await lock.release();
    });
  });

  test('recovers a reap guard abandoned by a dead controller', async () => {
    await withTempDirectory(async (root) => {
      await Bun.write(
        path.join(root, '.active.lock.reap'),
        JSON.stringify({
          schema_version: 1,
          token: 'abandoned-guard',
          pid: 424_242,
          started_at: '2026-08-31T12:00:00.000Z',
        }),
      );

      const lock = await acquireRunLock(
        root,
        'test',
        'new-run',
        0,
        () => false,
      );

      expect(lock.record.run_id).toBe('new-run');
      expect(
        await Bun.file(path.join(root, '.active.lock.reap')).exists(),
      ).toBe(false);
      await lock.release();
    });
  });

  test('turns lock-release failure into final cleanup failure', async () => {
    await withTempDirectory(async (root) => {
      const rift = (await import('./rift')) as typeof import('./rift') & {
        finishRunWithLock: (
          recorder: RunRecorder,
          lock: Awaited<ReturnType<typeof acquireRunLock>>,
          status: 'passed',
          exitCode: number,
        ) => Promise<Awaited<ReturnType<RunRecorder['finish']>>>;
      };
      const recorder = await RunRecorder.create({
        runDir: root,
        runId: '20260831T120000Z-fedcba98',
        command: 'compile',
        profile: 'default',
        evidence: 'compiler',
        networkMode: 'offline',
      });
      const lock = {
        path: path.join(root, '.active.lock'),
        record: {
          schema_version: 1 as const,
          token: 'fixture',
          pid: process.pid,
          command: 'compile',
          run_id: 'fixture',
          started_at: new Date().toISOString(),
        },
        release: async () => {
          throw new Error('fixture release failure');
        },
      };

      const summary = await rift.finishRunWithLock(recorder, lock, 'passed', 0);

      expect(summary).toMatchObject({
        status: 'failed',
        exit_code: 5,
        cleanup: { passed: false, leftovers: ['.active.lock'] },
        failures: [{ code: 'lock_release_failed', stage: 'cleanup' }],
      });
    });
  });

  test('release refuses to remove a replaced lock', async () => {
    await withTempDirectory(async (root) => {
      const lock = await acquireRunLock(
        root,
        'compile',
        'run-a',
        0,
        () => true,
      );
      await Bun.write(
        lock.path,
        JSON.stringify({ ...lock.record, token: 'replacement' }),
      );

      await lock.release();

      expect(await Bun.file(lock.path).exists()).toBe(true);
    });
  });

  test('bounded waiting acquires a lock released before the deadline', async () => {
    await withTempDirectory(async (root) => {
      const first = await acquireRunLock(
        root,
        'compile',
        'run-a',
        0,
        () => true,
      );
      setTimeout(() => void first.release(), 50);

      const second = await acquireRunLock(root, 'test', 'run-b', 1, () => true);
      expect(second.record.run_id).toBe('run-b');
      await second.release();
    });
  });
});

describe('Windows process supervision', () => {
  test('distinguishes a reused PID from the owned process instance', async () => {
    const processModule = (await import(
      './process'
    )) as typeof import('./process') & {
      sameProcessInstance: (
        expected: {
          pid: number;
          parentPid: number | null;
          name: string;
          creationTime: string;
        },
        current: {
          pid: number;
          parentPid: number | null;
          name: string;
          creationTime: string;
        },
      ) => boolean;
    };
    const owned = {
      pid: 1200,
      parentPid: 1100,
      name: 'dreamdaemon.exe',
      creationTime: '2026-08-31T12:00:00.000Z',
    };

    expect(processModule.sameProcessInstance(owned, { ...owned })).toBe(true);
    expect(
      processModule.sameProcessInstance(owned, {
        ...owned,
        creationTime: '2026-08-31T12:01:00.000Z',
      }),
    ).toBe(false);
  });

  test('cancellation stops every active owned process and rejects new work', async () => {
    await withTempDirectory(async (root) => {
      const fixture = path.join(root, 'cancel-controller.ts');
      await Bun.write(fixture, 'await Bun.sleep(30_000);\n');
      const cancellation = createCancellationController();
      const owned = cancellation.runner(processSpec(fixture), processHooks());

      await cancellation.cancel();
      const result = await owned.result;

      expect(result.termination).toBe('cancelled');
      expect(cancellation.wasCancelled()).toBe(true);
      expect(() =>
        cancellation.runner(processSpec(fixture), processHooks()),
      ).toThrow('cancelled');
      expect(() => process.kill(result.rootPid, 0)).toThrow();
    });
  });

  test('streams interleaved output and preserves a natural nonzero exit', async () => {
    await withTempDirectory(async (root) => {
      const fixture = path.join(root, 'output.ts');
      await Bun.write(
        fixture,
        [
          "process.stdout.write('first\\n');",
          "process.stderr.write('second\\n');",
          "process.stdout.write('partial');",
          'process.exit(7);',
        ].join('\n'),
      );
      const lines: string[] = [];

      const result = await startOwnedProcess(
        processSpec(fixture),
        processHooks(lines),
      ).result;

      expect(result.termination).toBe('natural');
      expect(result.exitCode).toBe(7);
      expect(lines).toContain('stdout:first');
      expect(lines).toContain('stderr:second');
      expect(lines).toContain('stdout:partial');
    });
  });

  test('idle timeout terminates a silent child', async () => {
    await withTempDirectory(async (root) => {
      const fixture = path.join(root, 'silent.ts');
      await Bun.write(fixture, 'await Bun.sleep(30_000);\n');

      const result = await startOwnedProcess(
        processSpec(fixture, { wallTimeoutMs: 5_000, idleTimeoutMs: 200 }),
        processHooks(),
      ).result;

      expect(result.termination).toBe('idle_timeout');
      expect(() => process.kill(result.rootPid, 0)).toThrow();
    });
  });

  test('wall timeout removes descendants but preserves an unrelated process', async () => {
    await withTempDirectory(async (root) => {
      const childFixture = path.join(root, 'child.ts');
      const parentFixture = path.join(root, 'parent.ts');
      const unrelatedFixture = path.join(root, 'unrelated.ts');
      await Bun.write(childFixture, 'await Bun.sleep(30_000);\n');
      await Bun.write(
        parentFixture,
        [
          `const child = Bun.spawn([process.execPath, ${JSON.stringify(childFixture)}]);`,
          "console.log('child=' + child.pid);",
          'await Bun.sleep(30_000);',
        ].join('\n'),
      );
      await Bun.write(unrelatedFixture, 'await Bun.sleep(30_000);\n');
      const unrelated = Bun.spawn([process.execPath, unrelatedFixture]);
      try {
        const samples: Array<{ at: number; pids: number[] }> = [];
        const started = Date.now();
        const hooks = processHooks();
        hooks.onSample = async (batch) => {
          samples.push({
            at: Date.now() - started,
            pids: batch.map(({ pid }) => pid),
          });
        };
        const owned = startOwnedProcess(
          processSpec(parentFixture, {
            wallTimeoutMs: 800,
            idleTimeoutMs: 5_000,
          }),
          hooks,
        );
        const result = await owned.result;

        expect(result.termination).toBe('wall_timeout');
        expect(result.ownedPids.length).toBeGreaterThanOrEqual(2);
        expect(process.kill(unrelated.pid, 0)).toBe(true);
        for (const pid of result.ownedPids) {
          expect(() => process.kill(pid, 0)).toThrow();
        }
      } finally {
        unrelated.kill();
        await unrelated.exited;
      }
    });
  });

  test('explicit cancellation returns cancelled after exact cleanup', async () => {
    await withTempDirectory(async (root) => {
      const fixture = path.join(root, 'cancel.ts');
      await Bun.write(
        fixture,
        "console.log('ready');\nawait Bun.sleep(30_000);\n",
      );
      const owned = startOwnedProcess(processSpec(fixture), processHooks());
      await Bun.sleep(100);

      const result = await owned.stop('cancelled');

      expect(result.termination).toBe('cancelled');
      expect(() => process.kill(result.rootPid, 0)).toThrow();
    });
  });

  test('bounded probes capture both streams without a shell', async () => {
    await withTempDirectory(async (root) => {
      const fixture = path.join(root, 'probe.ts');
      await Bun.write(
        fixture,
        "console.log('probe-out');\nconsole.error('probe-err');\n",
      );

      const result = await runProbeProcess(
        process.execPath,
        [fixture],
        root,
        processSpec(fixture).env,
      );

      expect(result).toEqual({
        exitCode: 0,
        stdout: 'probe-out\n',
        stderr: 'probe-err\n',
      });
    });
  });
});

describe('compile workflows', () => {
  test('requires explicit zero-error DreamMaker diagnostics', () => {
    expect(assertDmDiagnostics('0 errors, 3 warnings')).toEqual({
      errors: 0,
      warnings: 3,
    });
    expect(() => assertDmDiagnostics('compiler exited')).toThrow(
      'compile_diagnostics_missing',
    );
    expect(() => assertDmDiagnostics('1 error, 0 warnings')).toThrow(
      'compile_failed',
    );
  });

  test('fast compile copies fresh artifacts and removes exact scratch files', async () => {
    await withTempDirectory(async (root) => {
      await createRepositoryFixture(root);
      const repository = await qualifyRepository(root);
      const { runId, runDir } = await allocateRun(repository.runsRoot);
      const recorder = await RunRecorder.create({
        runDir,
        runId,
        command: 'compile',
        profile: 'default',
        evidence: 'compiler',
        networkMode: 'offline',
      });

      const outcome = await compileFast({
        runId,
        repository,
        byond: {
          dm: 'fixture-dm.exe',
          dreamDaemon: 'fixture-dreamdaemon.exe',
          version: '516.1687',
          source: 'DM_EXE',
        },
        recorder,
        environment: {},
        defines: ['FIXTURE'],
        wallTimeoutMs: 5_000,
        idleTimeoutMs: 5_000,
        processRunner: fakeCompileProcess(true),
      });

      expect(outcome.evidence).toBe('compiler');
      expect(await Bun.file(outcome.dmb).text()).toBe('fixture dmb');
      expect(await Bun.file(outcome.rsc).text()).toBe('fixture rsc');
      expect(
        await Array.fromAsync(
          new Bun.Glob('.rift-*.test.*').scan({ cwd: root }),
        ),
      ).toEqual([]);
    });
  });

  test('fast compile rejects exit-zero output without fresh artifacts', async () => {
    await withTempDirectory(async (root) => {
      await createRepositoryFixture(root);
      const repository = await qualifyRepository(root);
      const { runId, runDir } = await allocateRun(repository.runsRoot);
      const recorder = await RunRecorder.create({
        runDir,
        runId,
        command: 'compile',
        profile: 'default',
        evidence: 'compiler',
        networkMode: 'offline',
      });

      expect(
        compileFast({
          runId,
          repository,
          byond: {
            dm: 'fixture-dm.exe',
            dreamDaemon: 'fixture-dreamdaemon.exe',
            version: '516.1687',
            source: 'DM_EXE',
          },
          recorder,
          environment: {},
          defines: [],
          wallTimeoutMs: 5_000,
          idleTimeoutMs: 5_000,
          processRunner: fakeCompileProcess(false),
        }),
      ).rejects.toThrow('compile_artifact_missing');
    });
  });

  test('full compile delegates to the fixed build target and records rebuilt artifacts', async () => {
    await withTempDirectory(async (root) => {
      await createRepositoryFixture(root);
      await Bun.write(
        path.join(root, 'tools', 'build', 'build.bat'),
        [
          '@echo off',
          'echo full dmb>tgstation.dmb',
          'echo full rsc>tgstation.rsc',
          'exit /b 0',
          '',
        ].join('\n'),
      );
      const repository = await qualifyRepository(root);
      const { runId, runDir } = await allocateRun(repository.runsRoot);
      const recorder = await RunRecorder.create({
        runDir,
        runId,
        command: 'compile',
        profile: 'default',
        evidence: 'full_build',
        networkMode: 'offline',
      });

      const outcome = await compileFull({
        runId,
        repository,
        byond: {
          dm: 'fixture-dm.exe',
          dreamDaemon: 'fixture-dreamdaemon.exe',
          version: '516.1687',
          source: 'DM_EXE',
        },
        recorder,
        environment: processSpec(path.join(root, 'unused.ts')).env,
        defines: [],
        wallTimeoutMs: 10_000,
        idleTimeoutMs: 10_000,
        force: false,
      });

      expect(outcome.evidence).toBe('full_build');
      expect(outcome.reused).toBe(false);
      expect(await Bun.file(outcome.dmb).text()).toContain('full dmb');
      expect(await Bun.file(outcome.rsc).text()).toContain('full rsc');
    });
  });

  test('preserves full compile timeout and cancellation classifications', async () => {
    await withTempDirectory(async (root) => {
      await createRepositoryFixture(root);
      const repository = await qualifyRepository(root);
      const { runId, runDir } = await allocateRun(repository.runsRoot);
      const recorder = await RunRecorder.create({
        runDir,
        runId,
        command: 'compile',
        profile: 'default',
        evidence: 'full_build',
        networkMode: 'offline',
      });
      const request = {
        runId,
        repository,
        byond: {
          dm: 'fixture-dm.exe',
          dreamDaemon: 'fixture-dreamdaemon.exe',
          version: '516.1687',
          source: 'DM_EXE' as const,
        },
        recorder,
        environment: {},
        defines: [],
        wallTimeoutMs: 10_000,
        idleTimeoutMs: 10_000,
        force: false,
      };

      await expect(
        compileFull({
          ...request,
          buildProcessRunner: fakeTerminatedProcess('wall_timeout'),
        }),
      ).rejects.toMatchObject({ code: 'wall_timeout', exitCode: 6 });
      await expect(
        compileFull({
          ...request,
          buildProcessRunner: fakeTerminatedProcess('cancelled'),
        }),
      ).rejects.toMatchObject({ code: 'cancelled', exitCode: 130 });
    });
  });
});

describe('isolated deployment', () => {
  test('copies paired native overlays only into the isolated workspace', async () => {
    await withTempDirectory(async (root) => {
      const rift = (await import('./rift')) as typeof import('./rift') & {
        applyNativeOverlays?: (
          repositoryRoot: string,
          deployment: { root: string },
          shim: string | null,
          service: string | null,
          enforceInstalledContract?: boolean,
        ) => Promise<void>;
      };
      expect(typeof rift.applyNativeOverlays).toBe('function');
      if (!rift.applyNativeOverlays) {
        return;
      }
      const deployment = { root: path.join(root, 'workspace') };
      await fs.mkdir(deployment.root);
      await Bun.write(path.join(root, 'candidate.dll'), 'shim-v2');
      await Bun.write(path.join(root, 'candidate.exe'), 'service-v2');

      await rift.applyNativeOverlays(
        root,
        deployment,
        'candidate.dll',
        'candidate.exe',
      );

      expect(
        await Bun.file(path.join(deployment.root, 'dogmos.dll')).text(),
      ).toBe('shim-v2');
      expect(
        await Bun.file(path.join(deployment.root, 'dogmosd.exe')).text(),
      ).toBe('service-v2');
      expect(await Bun.file(path.join(root, 'dogmos.dll')).exists()).toBe(
        false,
      );
      expect(await Bun.file(path.join(root, 'dogmosd.exe')).exists()).toBe(
        false,
      );
    });
  });

  test('rejects Dogmos overlays that differ from verified installed artifacts', async () => {
    await withTempDirectory(async (root) => {
      const deployment = { root: path.join(root, 'workspace') };
      await fs.mkdir(deployment.root);
      await Bun.write(path.join(root, 'dogmos.dll'), 'installed-shim');
      await Bun.write(path.join(root, 'dogmosd.exe'), 'installed-service');
      await Bun.write(path.join(root, 'candidate.dll'), 'different-shim');
      await Bun.write(path.join(root, 'candidate.exe'), 'installed-service');

      await expect(
        applyNativeOverlays(
          root,
          deployment,
          'candidate.dll',
          'candidate.exe',
          true,
        ),
      ).rejects.toThrow('dogmos_overlay_contract_mismatch: dogmos.dll');
    });
  });

  test('copies the fixed runtime manifest and isolates repository config and map selection', async () => {
    await withTempDirectory(async (root) => {
      await createRepositoryFixture(root);
      const files = new Map([
        ['config/config.txt', 'repository config'],
        ['tools/ci/ci_config.txt', 'ci config'],
        ['build/behavior_trees/fixture.json', '{}'],
        ['code/datums/greyscale/json_configs/fixture.json', '{}'],
        ['icons/fixture.dmi', 'icon'],
        ['sound/runtime/fixture.ogg', 'sound'],
        ['strings/fixture.json', '{}'],
        ['tgui/public/fixture.txt', 'public'],
        ['tgui/packages/tgfont/dist/fixture.woff2', 'font'],
        ['modular_nova/modules/fixture/icons/fixture.dmi', 'nova icon'],
        ['modular_nova/modules/GAGS/json_configs/fixture.json', '{}'],
        ['modular_nova/modules/GAGS/nsfw/json_configs/fixture.json', '{}'],
        ['modular_aphelion/modules/fixture/icons/fixture.dmi', 'aphelion icon'],
        ['modular_aphelion/modules/fixture/data/fixture.json', '{}'],
        ['fixture.dll', 'dll'],
      ]);
      for (const [relativePath, contents] of files) {
        const absolutePath = path.join(root, relativePath);
        await fs.mkdir(path.dirname(absolutePath), { recursive: true });
        await Bun.write(absolutePath, contents);
      }
      const repository = await qualifyRepository(root);
      const { runDir } = await allocateRun(repository.runsRoot);
      const compileRoot = path.join(runDir, 'artifacts', 'compile');
      await fs.mkdir(compileRoot, { recursive: true });
      const compile = {
        evidence: 'compiler' as const,
        dmb: path.join(compileRoot, 'tgstation.dmb'),
        rsc: path.join(compileRoot, 'tgstation.rsc'),
        artifacts: [],
        reused: false,
      };
      await Bun.write(compile.dmb, 'dmb');
      await Bun.write(compile.rsc, 'rsc');

      const deployment = await createDeployment({
        repository,
        runDir,
        profile: validProfile(),
        compile,
        selectedMap: '_maps/fixture.json',
      });

      expect(await Bun.file(deployment.dmb).text()).toBe('dmb');
      expect(await Bun.file(deployment.rsc).text()).toBe('rsc');
      expect(
        await Bun.file(
          path.join(deployment.root, 'config', 'config.txt'),
        ).text(),
      ).toBe('repository config');
      expect(
        await Bun.file(path.join(deployment.data, 'next_map.json')).text(),
      ).toBe('{}\n');
      for (const relativePath of [
        'build/behavior_trees/fixture.json',
        'icons/fixture.dmi',
        'modular_nova/modules/fixture/icons/fixture.dmi',
        'modular_nova/modules/GAGS/json_configs/fixture.json',
        'modular_nova/modules/GAGS/nsfw/json_configs/fixture.json',
        'modular_aphelion/modules/fixture/icons/fixture.dmi',
        'modular_aphelion/modules/fixture/data/fixture.json',
        'fixture.dll',
      ]) {
        expect(
          await Bun.file(path.join(deployment.root, relativePath)).exists(),
        ).toBe(true);
      }
      expect(
        Bun.file(path.join(root, 'data', 'next_map.json')).exists(),
      ).resolves.toBe(false);
    });
  });

  test('uses the CI config without copying repository configuration', async () => {
    await withTempDirectory(async (root) => {
      await createRepositoryFixture(root);
      await fs.mkdir(path.join(root, 'config'), { recursive: true });
      await fs.mkdir(path.join(root, 'tools', 'ci'), { recursive: true });
      await Bun.write(path.join(root, 'config', 'secret.txt'), 'not deployed');
      await Bun.write(
        path.join(root, 'tools', 'ci', 'ci_config.txt'),
        'ci only',
      );
      const repository = await qualifyRepository(root);
      const { runDir } = await allocateRun(repository.runsRoot);
      const compileRoot = path.join(runDir, 'artifacts', 'compile');
      await fs.mkdir(compileRoot, { recursive: true });
      const compile = {
        evidence: 'compiler' as const,
        dmb: path.join(compileRoot, 'tgstation.dmb'),
        rsc: path.join(compileRoot, 'tgstation.rsc'),
        artifacts: [],
        reused: false,
      };
      await Bun.write(compile.dmb, 'dmb');
      await Bun.write(compile.rsc, 'rsc');

      const deployment = await createDeployment({
        repository,
        runDir,
        profile: { ...validProfile(), config_source: 'ci' as const },
        compile,
        selectedMap: null,
      });

      expect(
        await Bun.file(
          path.join(deployment.root, 'config', 'config.txt'),
        ).text(),
      ).toBe('ci only');
      expect(
        Bun.file(path.join(deployment.root, 'config', 'secret.txt')).exists(),
      ).resolves.toBe(false);
    });
  });

  test('rejects deployment map traversal', async () => {
    await withTempDirectory(async (root) => {
      await createRepositoryFixture(root);
      const repository = await qualifyRepository(root);
      const { runDir } = await allocateRun(repository.runsRoot);
      const compileRoot = path.join(runDir, 'artifacts', 'compile');
      await fs.mkdir(compileRoot, { recursive: true });
      const dmb = path.join(compileRoot, 'tgstation.dmb');
      const rsc = path.join(compileRoot, 'tgstation.rsc');
      await Bun.write(dmb, 'dmb');
      await Bun.write(rsc, 'rsc');

      expect(
        createDeployment({
          repository,
          runDir,
          profile: validProfile(),
          compile: {
            evidence: 'compiler',
            dmb,
            rsc,
            artifacts: [],
            reused: false,
          },
          selectedMap: '../outside.json',
        }),
      ).rejects.toThrow('map path escapes _maps');
    });
  });

  test('collects hashed evidence and reports cleanup failures with run-relative leftovers', async () => {
    await withTempDirectory(async (root) => {
      await createRepositoryFixture(root);
      const repository = await qualifyRepository(root);
      const { runId, runDir } = await allocateRun(repository.runsRoot);
      const compileRoot = path.join(runDir, 'artifacts', 'compile');
      await fs.mkdir(compileRoot, { recursive: true });
      const compile = {
        evidence: 'compiler' as const,
        dmb: path.join(compileRoot, 'tgstation.dmb'),
        rsc: path.join(compileRoot, 'tgstation.rsc'),
        artifacts: [],
        reused: false,
      };
      await Bun.write(compile.dmb, 'dmb');
      await Bun.write(compile.rsc, 'rsc');
      const deployment = await createDeployment({
        repository,
        runDir,
        profile: validProfile(),
        compile,
        selectedMap: null,
      });
      await fs.mkdir(path.join(deployment.gameLogDir, 'nested'), {
        recursive: true,
      });
      await Bun.write(
        path.join(deployment.gameLogDir, 'nested', 'runtime.log.json'),
        '{"msg":"ready"}\n',
      );
      await Bun.write(path.join(deployment.data, 'unit_tests.json'), '{}\n');
      await Bun.write(path.join(deployment.root, 'dogmos_panic.log'), 'panic');
      const recorder = await RunRecorder.create({
        runDir,
        runId,
        command: 'run',
        profile: 'default',
        evidence: 'boot',
        networkMode: 'offline',
      });

      const artifacts = await collectDeploymentArtifacts(
        deployment,
        runDir,
        recorder,
      );

      expect(artifacts.map((artifact) => artifact.path).sort()).toEqual([
        'artifacts/data/logs/rift/nested/runtime.log.json',
        'artifacts/data/unit_tests.json',
        'artifacts/dogmos_panic.log',
      ]);
      expect(artifacts.every((artifact) => artifact.sha256.length === 64)).toBe(
        true,
      );
      expect(
        await Bun.file(path.join(runDir, 'artifacts', 'manifest.json')).json(),
      ).toEqual(artifacts);

      const failedCleanup = await removeDeployment(
        deployment,
        runDir,
        false,
        async () => {
          throw new Error('fixture removal failure');
        },
      );
      expect(failedCleanup).toEqual({
        passed: false,
        leftovers: ['workspace'],
        retained: [],
      });
      expect(await Bun.file(deployment.dmb).exists()).toBe(true);
      expect(await removeDeployment(deployment, runDir, false)).toEqual({
        passed: true,
        leftovers: [],
        retained: [],
      });
      expect(await Bun.file(deployment.dmb).exists()).toBe(false);
    });
  });

  test('reports an intentionally retained workspace explicitly', async () => {
    await withTempDirectory(async (root) => {
      await createRepositoryFixture(root);
      const repository = await qualifyRepository(root);
      const { runDir } = await allocateRun(repository.runsRoot);
      const deployment = {
        root: path.join(runDir, 'workspace'),
      } as Parameters<typeof removeDeployment>[0];
      await fs.mkdir(deployment.root, { recursive: true });

      expect(await removeDeployment(deployment, runDir, true)).toEqual({
        passed: true,
        leftovers: [],
        retained: ['workspace'],
      });
      expect((await fs.stat(deployment.root)).isDirectory()).toBe(true);
    });
  });
});

describe('structured readiness and run lifecycle', () => {
  test('matches structured readiness by category and message', () => {
    const profile = validProfile();
    expect(
      matchesLogRule(profile.readiness_rule, {
        ts: '2026-08-31 00:22:08.470',
        cat: 'runtime',
        msg: 'Initializations complete within 88.7562 seconds!',
        's-ver': '1.0.0',
      }),
    ).toBe(true);
    expect(
      matchesLogRule(profile.readiness_rule, {
        cat: 'admin',
        msg: 'Initializations complete within 1 second!',
      }),
    ).toBe(false);
  });

  test('waits through a late file, header, and partial structured line', async () => {
    await withTempDirectory(async (root) => {
      const recorder = await RunRecorder.create({
        runDir: root,
        runId: '20260831T000000Z-0123abcd',
        command: 'run',
        profile: 'default',
        evidence: 'boot',
        networkMode: 'offline',
      });
      const deployment = {
        root: path.join(root, 'workspace'),
        data: path.join(root, 'workspace', 'data'),
        gameLogDir: path.join(root, 'workspace', 'data', 'logs', 'rift'),
        dmb: path.join(root, 'workspace', 'tgstation.dmb'),
        rsc: path.join(root, 'workspace', 'tgstation.rsc'),
      };
      await fs.mkdir(deployment.gameLogDir, { recursive: true });
      const processResult = new Promise<never>(() => {});
      const owned: OwnedProcess = {
        rootPid: 100,
        result: processResult,
        stop: async () => processResult,
        snapshot: async () => [],
        ownedPids: () => [100],
      };
      const readiness = waitForReadiness({
        deployment,
        profile: validProfile(),
        process: owned,
        timeoutMs: 2_000,
        recorder,
      });
      await Bun.sleep(25);
      const logPath = path.join(deployment.gameLogDir, 'runtime.log.json');
      await Bun.write(
        logPath,
        '{"s-ver":"1.0.0"}\n{"cat":"runtime","msg":"Initial',
      );
      await Bun.sleep(25);
      await fs.appendFile(
        logPath,
        'izations complete within 1.25 seconds!","ts":"now"}\n',
      );

      expect(await readiness).toEqual({
        ready: true,
        fatalFailures: [],
        runtimeSignatures: [],
      });
    });
  });

  test('does not lose a fatal record in the readiness batch', async () => {
    await withTempDirectory(async (root) => {
      const recorder = await RunRecorder.create({
        runDir: root,
        runId: '20260831T000000Z-0123abcd',
        command: 'run',
        profile: 'default',
        evidence: 'boot',
        networkMode: 'offline',
      });
      const deployment = {
        root: path.join(root, 'workspace'),
        data: path.join(root, 'workspace', 'data'),
        gameLogDir: path.join(root, 'workspace', 'data', 'logs', 'rift'),
        dmb: path.join(root, 'workspace', 'tgstation.dmb'),
        rsc: path.join(root, 'workspace', 'tgstation.rsc'),
      };
      await fs.mkdir(deployment.gameLogDir, { recursive: true });
      await Bun.write(
        path.join(deployment.gameLogDir, 'runtime.log.json'),
        [
          '{"cat":"runtime","msg":"Initializations complete within 1 second!"}',
          '{"cat":"runtime","msg":"runtime error: same batch [0x200001f] at 42"}',
          '',
        ].join('\n'),
      );
      const pending = new Promise<never>(() => {});
      const owned: OwnedProcess = {
        rootPid: 102,
        result: pending,
        stop: async () => pending,
        snapshot: async () => [],
        ownedPids: () => [102],
      };

      expect(
        await waitForReadiness({
          deployment,
          profile: validProfile(),
          process: owned,
          timeoutMs: 1_000,
          recorder,
        }),
      ).toMatchObject({
        ready: false,
        fatalFailures: [{ code: 'runtime_error' }],
      });
    });
  });

  test('fails readiness when a nonempty Dogmos panic file exists', async () => {
    await withTempDirectory(async (root) => {
      const recorder = await RunRecorder.create({
        runDir: root,
        runId: '20260831T000000Z-1234abcf',
        command: 'run',
        profile: 'dogmos',
        evidence: 'boot',
        networkMode: 'offline',
      });
      const deployment = {
        root: path.join(root, 'workspace'),
        data: path.join(root, 'workspace', 'data'),
        gameLogDir: path.join(root, 'workspace', 'data', 'logs', 'rift'),
        dmb: path.join(root, 'workspace', 'tgstation.dmb'),
        rsc: path.join(root, 'workspace', 'tgstation.rsc'),
      };
      await fs.mkdir(deployment.gameLogDir, { recursive: true });
      await Bun.write(
        path.join(deployment.gameLogDir, 'runtime.log.json'),
        '{"cat":"runtime","msg":"Initializations complete within 1 second!"}\n',
      );
      await Bun.write(
        path.join(deployment.root, 'dogmos_panic.log'),
        'panic\n',
      );
      const profile = validProfile();
      profile.fatal_log_rules.push({
        id: 'dogmos_panic',
        file: 'dogmos_panic.log',
        category: null,
        message_pattern: '.+',
        case_insensitive: false,
        max_occurrences: 0,
      });
      const pending = new Promise<never>(() => {});
      const owned: OwnedProcess = {
        rootPid: 77_701,
        result: pending,
        stop: async () => pending,
        snapshot: async () => [],
        ownedPids: () => [77_701],
      };

      const observation = await waitForReadiness({
        deployment,
        profile,
        process: owned,
        timeoutMs: 1_000,
        recorder,
      });

      expect(observation.ready).toBe(false);
      expect(observation.fatalFailures).toEqual([
        {
          code: 'dogmos_panic',
          stage: 'server',
          message: 'dogmos_panic observed 1 time(s)',
        },
      ]);
    });
  });

  test('does not keep the controller alive on the losing readiness timeout', async () => {
    await withTempDirectory(async (root) => {
      const fixture = path.join(root, 'readiness-exit.ts');
      const riftModule = pathToFileURL(path.resolve('tools/rift/rift.ts')).href;
      const reportModule = pathToFileURL(
        path.resolve('tools/rift/report.ts'),
      ).href;
      await Bun.write(
        fixture,
        `
import fs from 'node:fs/promises';
import path from 'node:path';
import { waitForReadiness } from ${JSON.stringify(riftModule)};
import { RunRecorder } from ${JSON.stringify(reportModule)};
const root = process.argv[2];
const gameLogDir = path.join(root, 'workspace', 'data', 'logs', 'rift');
await fs.mkdir(gameLogDir, { recursive: true });
await Bun.write(path.join(gameLogDir, 'runtime.log.json'), '{"cat":"runtime","msg":"Initializations complete within 1 second!"}\\n');
const recorder = await RunRecorder.create({ runDir: root, runId: '20260831T000000Z-abcd1234', command: 'run', profile: 'default', evidence: 'boot', networkMode: 'offline' });
const pending = new Promise(() => {});
await waitForReadiness({
  deployment: { root: path.join(root, 'workspace'), data: path.join(root, 'workspace', 'data'), gameLogDir, dmb: '', rsc: '' },
  profile: ${JSON.stringify(validProfile())},
  process: { rootPid: 1, result: pending, stop: async () => pending, snapshot: async () => [], ownedPids: () => [1] },
  timeoutMs: 5_000,
  recorder,
});
console.log('ready-and-returned');
`,
      );
      const owned = startOwnedProcess(
        processSpec(fixture, {
          args: [fixture, root],
          wallTimeoutMs: 1_500,
          idleTimeoutMs: 1_500,
        }),
        processHooks(),
      );

      const result = await owned.result;

      expect(result.termination).toBe('natural');
      expect(result.exitCode).toBe(0);
    });
  });

  test('uses plain runtime fallback and classifies fatal and timeout states', async () => {
    await withTempDirectory(async (root) => {
      const deployment = {
        root: path.join(root, 'workspace'),
        data: path.join(root, 'workspace', 'data'),
        gameLogDir: path.join(root, 'workspace', 'data', 'logs', 'rift'),
        dmb: path.join(root, 'workspace', 'tgstation.dmb'),
        rsc: path.join(root, 'workspace', 'tgstation.rsc'),
      };
      await fs.mkdir(deployment.gameLogDir, { recursive: true });
      const recorder = await RunRecorder.create({
        runDir: root,
        runId: '20260831T000000Z-1234abcd',
        command: 'run',
        profile: 'default',
        evidence: 'boot',
        networkMode: 'offline',
      });
      const pending = new Promise<never>(() => {});
      const owned: OwnedProcess = {
        rootPid: 101,
        result: pending,
        stop: async () => pending,
        snapshot: async () => [],
        ownedPids: () => [101],
      };
      await Bun.write(
        path.join(deployment.gameLogDir, 'runtime.log'),
        'Initializations complete within 2 seconds!\n',
      );
      expect(
        await waitForReadiness({
          deployment,
          profile: validProfile(),
          process: owned,
          timeoutMs: 1_000,
          recorder,
        }),
      ).toMatchObject({ ready: true });

      await fs.rm(path.join(deployment.gameLogDir, 'runtime.log'));
      await Bun.write(
        path.join(deployment.gameLogDir, 'runtime.log.json'),
        '{"cat":"runtime","msg":"runtime error: fixture [0x200001f] at 42"}\n',
      );
      expect(
        await waitForReadiness({
          deployment,
          profile: validProfile(),
          process: owned,
          timeoutMs: 1_000,
          recorder,
        }),
      ).toMatchObject({
        ready: false,
        fatalFailures: [{ code: 'runtime_error' }],
        runtimeSignatures: [
          { signature: 'runtime error: fixture [ref] at N', count: 1 },
        ],
      });

      await fs.rm(path.join(deployment.gameLogDir, 'runtime.log.json'));
      expect(
        waitForReadiness({
          deployment,
          profile: validProfile(),
          process: owned,
          timeoutMs: 30,
          recorder,
        }),
      ).rejects.toThrow('readiness_timeout');
    });
  });

  test('preserves process timeout classification before readiness', async () => {
    await withTempDirectory(async (root) => {
      const recorder = await RunRecorder.create({
        runDir: root,
        runId: '20260831T000000Z-1234abce',
        command: 'run',
        profile: 'default',
        evidence: 'boot',
        networkMode: 'offline',
      });
      const deployment = {
        root: path.join(root, 'workspace'),
        data: path.join(root, 'workspace', 'data'),
        gameLogDir: path.join(root, 'workspace', 'data', 'logs', 'rift'),
        dmb: path.join(root, 'workspace', 'tgstation.dmb'),
        rsc: path.join(root, 'workspace', 'tgstation.rsc'),
      };
      await fs.mkdir(deployment.gameLogDir, { recursive: true });
      const owned = fakeTerminatedProcess('idle_timeout')(
        processSpec(path.join(root, 'unused.ts')),
        processHooks(),
      );

      await expect(
        waitForReadiness({
          deployment,
          profile: validProfile(),
          process: owned,
          timeoutMs: 1_000,
          recorder,
        }),
      ).rejects.toMatchObject({ code: 'idle_timeout', exitCode: 6 });
    });
  });

  test('runs a compiled server to readiness and cleans an immediate requested stop', async () => {
    await withTempDirectory(async (root) => {
      await createRepositoryFixture(root);
      const repository = await qualifyRepository(root);
      const { runId, runDir } = await allocateRun(repository.runsRoot);
      const recorder = await RunRecorder.create({
        runDir,
        runId,
        command: 'run',
        profile: 'default',
        evidence: 'boot',
        networkMode: 'offline',
      });
      const serverSpecs: ProcessSpec[] = [];
      const runner = (spec: ProcessSpec, hooks: ProcessHooks): OwnedProcess => {
        if (spec.role === 'dreammaker') {
          return fakeCompileProcess(true)(spec, hooks);
        }
        serverSpecs.push(spec);
        let resolveResult!: (result: Awaited<OwnedProcess['result']>) => void;
        const started = Date.now();
        const result = new Promise<Awaited<OwnedProcess['result']>>(
          (resolve) => {
            resolveResult = resolve;
          },
        );
        void hooks.onStart(4321);
        void (async () => {
          const logDir = path.join(spec.cwd, 'data', 'logs', 'rift');
          await fs.mkdir(logDir, { recursive: true });
          await Bun.write(
            path.join(logDir, 'runtime.log.json'),
            '{"s-ver":"1.0.0"}\n{"cat":"runtime","msg":"Initializations complete within 1 second!"}\n',
          );
        })();
        return {
          rootPid: 4321,
          result,
          stop: async (reason) => {
            const finished = {
              role: spec.role,
              rootPid: 4321,
              ownedPids: [4321],
              exitCode: 0,
              signal: null,
              termination: reason,
              startedAt: new Date(started).toISOString(),
              finishedAt: new Date().toISOString(),
              durationMs: Date.now() - started,
            };
            resolveResult(finished);
            return finished;
          },
          snapshot: async () => [],
          ownedPids: () => [4321],
        };
      };
      const profile = validProfile();
      const command = parseCli([
        'run',
        '--compile-mode',
        'fast',
        '--map',
        '_maps/fixture.json',
        '--port',
        '1339',
      ]);
      if (command.command !== 'run') {
        throw new Error('fixture command did not parse as run');
      }

      const summary = await runServerWorkflow(
        {
          repository,
          pins: {
            BYOND_MAJOR: '516',
            BYOND_MINOR: '1687',
            BUN_VERSION: '1.3.5',
            PYTHON_VERSION: '3.11.0',
            CUTTER_VERSION: 'v5.0.1',
          },
          byond: {
            dm: 'fixture-dm.exe',
            dreamDaemon: 'fixture-dreamdaemon.exe',
            version: '516.1687',
            source: 'DM_EXE',
          },
          pinnedPython: 'fixture-python.exe',
          profileName: 'default',
          profile,
          profiles: new Map([['default', profile]]),
          recorder,
          lock: {
            path: path.join(repository.runsRoot, '.active.lock'),
            record: {
              schema_version: 1,
              token: 'fixture',
              pid: process.pid,
              command: 'run',
              run_id: runId,
              started_at: new Date().toISOString(),
            },
            release: async () => {},
          },
          runId,
          runDir,
          environment: {},
          networkMode: 'offline',
          processRunner: runner,
        },
        command,
      );

      expect(summary.status).toBe('ready_then_stopped');
      expect(summary.exit_code).toBe(0);
      expect(serverSpecs).toHaveLength(1);
      expect(serverSpecs[0].args).toEqual([
        'tgstation.dmb',
        '1339',
        '-trusted',
        '-verbose',
        '-params',
        'log-directory=rift',
      ]);
      const deployEvent = (
        await readNdjson(path.join(runDir, 'events.ndjson'))
      ).find(
        (event) => event.kind === 'stage_started' && event.stage === 'deploy',
      );
      expect(deployEvent?.data.selected_map).toBe('_maps/fixture.json');
      expect(Bun.file(path.join(runDir, 'workspace')).exists()).resolves.toBe(
        false,
      );
    });
  });
});

describe('bounded soak workflow', () => {
  test('summarizes duplicate-PID and disappeared-process samples by stable role', () => {
    expect(
      summarizeResourceSamples([
        {
          timestamp: '2026-08-31T00:00:00.000Z',
          role: 'dreamdaemon',
          pid: 100,
          private_bytes: 100,
          working_set_bytes: 200,
          alive: true,
        },
        {
          timestamp: '2026-08-31T00:00:01.000Z',
          role: 'dreamdaemon',
          pid: 100,
          private_bytes: 150,
          working_set_bytes: 180,
          alive: true,
        },
        {
          timestamp: '2026-08-31T00:00:02.000Z',
          role: 'dreamdaemon',
          pid: 100,
          private_bytes: 0,
          working_set_bytes: 0,
          alive: false,
        },
        {
          timestamp: '2026-08-31T00:00:00.000Z',
          role: 'dogmosd',
          pid: 200,
          private_bytes: 300,
          working_set_bytes: 400,
          alive: true,
        },
      ]),
    ).toEqual([
      {
        role: 'dogmosd',
        private_bytes_max: 300,
        working_set_bytes_max: 400,
        samples: 1,
      },
      {
        role: 'dreamdaemon',
        private_bytes_max: 150,
        working_set_bytes_max: 200,
        samples: 3,
      },
    ]);
  });

  const executeFixture = async (
    fatalAfterReadiness: boolean,
    requireContinuousChild = false,
  ) =>
    withTempDirectory(async (root) => {
      await createRepositoryFixture(root);
      const repository = await qualifyRepository(root);
      const { runId, runDir } = await allocateRun(repository.runsRoot);
      const recorder = await RunRecorder.create({
        runDir,
        runId,
        command: 'soak',
        profile: 'default',
        evidence: 'soak',
        networkMode: 'offline',
      });
      const profile = {
        ...validProfile(),
        resource_sample_seconds: 1,
        required_children: requireContinuousChild
          ? [
              {
                role: 'fixture-helper',
                process_name: 'fixture-helper.exe',
                min_count: 1,
                max_count: 1,
                continuous_after_readiness: true,
              },
            ]
          : [],
      };
      let stopped = false;
      let snapshotCount = 0;
      let virtualNow = 0;
      let logPath = '';
      const runner = (spec: ProcessSpec, hooks: ProcessHooks): OwnedProcess => {
        if (spec.role === 'dreammaker') {
          return fakeCompileProcess(true)(spec, hooks);
        }
        let resolveResult!: (result: Awaited<OwnedProcess['result']>) => void;
        const started = Date.now();
        const result = new Promise<Awaited<OwnedProcess['result']>>(
          (resolve) => {
            resolveResult = resolve;
          },
        );
        void hooks.onStart(77_001);
        void (async () => {
          const logDir = path.join(spec.cwd, 'data', 'logs', 'rift');
          await fs.mkdir(logDir, { recursive: true });
          logPath = path.join(logDir, 'runtime.log.json');
          await Bun.write(
            logPath,
            '{"cat":"runtime","msg":"Initializations complete within 1 second!"}\n',
          );
        })();
        return {
          rootPid: 77_001,
          result,
          stop: async (reason) => {
            stopped = true;
            const finished = {
              role: spec.role,
              rootPid: 77_001,
              ownedPids: [77_001, 77_002],
              exitCode: 0,
              signal: null,
              termination: reason,
              startedAt: new Date(started).toISOString(),
              finishedAt: new Date().toISOString(),
              durationMs: Date.now() - started,
            };
            resolveResult(finished);
            return finished;
          },
          snapshot: async () => {
            snapshotCount += 1;
            return [
              {
                pid: 77_001,
                parentPid: null,
                name: 'dreamdaemon.exe',
                role: 'dreamdaemon',
                privateBytes: 100 + snapshotCount,
                workingSetBytes: 200 + snapshotCount,
              },
              ...(snapshotCount === 1
                ? [
                    {
                      pid: 77_002,
                      parentPid: 77_001,
                      name: 'fixture-helper.exe',
                      role: 'fixture-helper',
                      privateBytes: 50,
                      workingSetBytes: 75,
                    },
                  ]
                : []),
            ];
          },
          ownedPids: () => [77_001, 77_002],
        };
      };
      const command = parseCli([
        'soak',
        '--compile-mode',
        'fast',
        '--map',
        '_maps/fixture.json',
        '--run-seconds',
        '30',
      ]);
      if (command.command !== 'soak') {
        throw new Error('fixture command did not parse as soak');
      }
      const context = {
        repository,
        pins: {
          BYOND_MAJOR: '516',
          BYOND_MINOR: '1687',
          BUN_VERSION: '1.3.5',
          PYTHON_VERSION: '3.11.0',
          CUTTER_VERSION: 'v5.0.1',
        },
        byond: {
          dm: 'fixture-dm.exe',
          dreamDaemon: 'fixture-dreamdaemon.exe',
          version: '516.1687',
          source: 'DM_EXE' as const,
        },
        pinnedPython: 'fixture-python.exe',
        profileName: 'default',
        profile,
        profiles: new Map([['default', profile]]),
        recorder,
        lock: {
          path: path.join(repository.runsRoot, '.active.lock'),
          record: {
            schema_version: 1 as const,
            token: 'fixture',
            pid: process.pid,
            command: 'soak',
            run_id: runId,
            started_at: new Date().toISOString(),
          },
          release: async () => {},
        },
        runId,
        runDir,
        environment: {},
        networkMode: 'offline' as const,
        processRunner: runner,
        now: () => virtualNow,
        sleep: async (milliseconds: number) => {
          if (fatalAfterReadiness && virtualNow === 0) {
            await fs.appendFile(
              logPath,
              '{"cat":"runtime","msg":"runtime error: soak fixture [0x200001f] at 42"}\n',
            );
            await Bun.sleep(75);
          }
          virtualNow += milliseconds;
        },
      };

      expect(
        runSoakWorkflow(context, { ...command, runSeconds: 29 }),
      ).rejects.toThrow('soak duration must be 30-1800 seconds');
      const summary = await runSoakWorkflow(context, command);
      const eventPath = path.join(runDir, 'events.ndjson');
      const eventCount = (await readNdjson(eventPath)).length;
      const snapshotsAtReturn = snapshotCount;
      await Bun.sleep(75);
      return {
        summary,
        stopped,
        virtualNow,
        eventCountStable: (await readNdjson(eventPath)).length === eventCount,
        snapshotCountStable: snapshotCount === snapshotsAtReturn,
        workspaceExists: await Bun.file(
          path.join(runDir, 'workspace'),
        ).exists(),
      };
    });

  test('completes the full bounded duration, records role maxima, and cleans', async () => {
    const result = await executeFixture(false);

    expect(result.summary.status).toBe('passed');
    expect(result.summary.exit_code).toBe(0);
    expect(result.summary.resource_maxima).toEqual(
      expect.arrayContaining([
        expect.objectContaining({
          role: 'dreamdaemon',
          private_bytes_max: expect.any(Number),
          working_set_bytes_max: expect.any(Number),
        }),
        expect.objectContaining({ role: 'fixture-helper' }),
      ]),
    );
    expect(result.stopped).toBe(true);
    expect(result.workspaceExists).toBe(false);
  });

  test('fails a post-readiness runtime rule before the bounded duration', async () => {
    const result = await executeFixture(true);

    expect(result.summary.status).toBe('failed');
    expect(result.summary.failures[0]).toMatchObject({
      code: 'runtime_error',
      stage: 'soak',
    });
    expect(result.virtualNow).toBeLessThan(30_000);
    expect(result.eventCountStable).toBe(true);
    expect(result.snapshotCountStable).toBe(true);
    expect(result.stopped).toBe(true);
    expect(result.workspaceExists).toBe(false);
  });

  test('fails when a continuously required child disappears after readiness', async () => {
    const result = await executeFixture(false, true);

    expect(result.summary.status).toBe('failed');
    expect(result.summary.failures[0]).toMatchObject({
      code: 'required_child_missing',
      stage: 'soak',
    });
    expect(result.stopped).toBe(true);
  });
});

describe('isolated unit-test workflow', () => {
  test('rejects profiles without the unit-test completion contract', async () => {
    const rift = (await import('./rift')) as typeof import('./rift') & {
      validateTestProfile: (profile: ReturnType<typeof validProfile>) => void;
    };

    expect(() => rift.validateTestProfile(validProfile())).toThrow(
      'test profile',
    );
  });

  test('fails when a fatal runtime appears after test readiness', async () => {
    await withTempDirectory(async (root) => {
      const rift = (await import('./rift')) as typeof import('./rift') & {
        waitForTestCompletion: (options: {
          deployment: {
            root: string;
            data: string;
            gameLogDir: string;
            dmb: string;
            rsc: string;
          };
          profile: ReturnType<typeof validProfile>;
          process: OwnedProcess;
          recorder: RunRecorder;
          readiness: Awaited<ReturnType<typeof waitForReadiness>>;
        }) => Promise<unknown>;
      };
      const recorder = await RunRecorder.create({
        runDir: root,
        runId: '20260831T000000Z-4567abcd',
        command: 'test',
        profile: 'ci',
        evidence: 'focused_test',
        networkMode: 'offline',
      });
      const deployment = {
        root: path.join(root, 'workspace'),
        data: path.join(root, 'workspace', 'data'),
        gameLogDir: path.join(root, 'workspace', 'data', 'logs', 'rift'),
        dmb: path.join(root, 'workspace', 'tgstation.dmb'),
        rsc: path.join(root, 'workspace', 'tgstation.rsc'),
      };
      await fs.mkdir(deployment.gameLogDir, { recursive: true });
      const started = Date.now();
      let resolveResult!: (result: Awaited<OwnedProcess['result']>) => void;
      const result = new Promise<Awaited<OwnedProcess['result']>>((resolve) => {
        resolveResult = resolve;
      });
      const owned: OwnedProcess = {
        rootPid: 103,
        result,
        stop: async (reason) => {
          const stopped = {
            role: 'dreamdaemon',
            rootPid: 103,
            ownedPids: [103],
            exitCode: 0,
            signal: null,
            termination: reason,
            startedAt: new Date(started).toISOString(),
            finishedAt: new Date().toISOString(),
            durationMs: Date.now() - started,
          };
          resolveResult(stopped);
          return stopped;
        },
        snapshot: async () => [],
        ownedPids: () => [103],
      };
      const logPath = path.join(deployment.gameLogDir, 'runtime.log.json');
      await Bun.write(
        logPath,
        '{"cat":"runtime","msg":"Initializations complete within 1 second!"}\n',
      );
      const profile = validProfile();
      const readiness = await waitForReadiness({
        deployment,
        profile,
        process: owned,
        timeoutMs: 1_000,
        recorder,
      });
      const completion = Promise.resolve().then(() =>
        rift.waitForTestCompletion({
          deployment,
          profile,
          process: owned,
          recorder,
          readiness,
        }),
      );
      await fs.appendFile(
        logPath,
        '{"cat":"runtime","msg":"runtime error: after readiness"}\n',
      );

      await expect(completion).rejects.toThrow('runtime_error');
      await owned.stop('requested');
    });
  });

  test('parses pass, failure, and skip results without losing failure messages', () => {
    expect(
      parseUnitTestResults({
        '/datum/unit_test/pass': {
          duration: 0.28125,
          name: '/datum/unit_test/pass',
          message: '',
          runtimes: 0,
          status: 0,
        },
        '/datum/unit_test/fail': {
          duration: 1.5,
          name: '/datum/unit_test/fail',
          message: 'fixture failure',
          runtimes: 1,
          status: 1,
        },
        '/datum/unit_test/skip': {
          duration: 0,
          name: '/datum/unit_test/skip',
          message: 'not applicable',
          runtimes: 0,
          status: 2,
        },
      }),
    ).toEqual({
      recorded: 3,
      passed: 1,
      failed: 1,
      skipped: 1,
      failures: [
        {
          duration: 1.5,
          name: '/datum/unit_test/fail',
          message: 'fixture failure',
          runtimes: 1,
          status: 1,
        },
      ],
    });
  });

  test('rejects malformed, extra, duplicate-name, and invalid-status results', () => {
    for (const value of [
      null,
      [],
      '',
      { test: { name: 'test', message: '', status: 0 } },
    ]) {
      expect(() => parseUnitTestResults(value)).toThrow(
        'unit_test_result_invalid',
      );
    }
    expect(() =>
      parseUnitTestResults({
        first: {
          duration: 1,
          message: '',
          name: 'same',
          runtimes: 0,
          status: 0,
        },
        second: {
          duration: 1,
          message: '',
          name: 'same',
          runtimes: 0,
          status: 0,
        },
      }),
    ).toThrow('unit_test_result_invalid');
    expect(() =>
      parseUnitTestResults({
        test: {
          duration: 1,
          message: '',
          name: 'test',
          runtimes: 0,
          status: 3,
        },
      }),
    ).toThrow('unit_test_result_invalid');
    expect(() =>
      parseUnitTestResults({
        test: {
          duration: 1,
          message: '',
          name: 'test',
          runtimes: 0,
          status: 0,
          extra: true,
        },
      }),
    ).toThrow('unit_test_result_invalid');
  });

  test('prepares a focused CIBUILDING compile after fixed Juke prerequisites', async () => {
    await withTempDirectory(async (root) => {
      await createRepositoryFixture(root);
      await Bun.write(
        path.join(root, 'tools', 'build', 'build.bat'),
        [
          '@echo off',
          'if /I "%~1"=="--help" (',
          '  echo icon-cutter',
          '  echo dm-maps-include',
          '  exit /b 1',
          ')',
          'if /I "%~1"=="icon-cutter" exit /b 0',
          'if /I "%~1"=="dm-maps-include" exit /b 0',
          'exit /b 9',
          '',
        ].join('\n'),
      );
      const repository = await qualifyRepository(root);
      const { runId, runDir } = await allocateRun(repository.runsRoot);
      const recorder = await RunRecorder.create({
        runDir,
        runId,
        command: 'test',
        profile: 'ci',
        evidence: 'focused_test',
        networkMode: 'offline',
      });
      const compilerSpecs: ProcessSpec[] = [];
      const runner = (spec: ProcessSpec, hooks: ProcessHooks) => {
        compilerSpecs.push(spec);
        return fakeCompileProcess(true)(spec, hooks);
      };

      const outcome = await prepareUnitTestCompile(
        {
          runId,
          repository,
          byond: {
            dm: 'fixture-dm.exe',
            dreamDaemon: 'fixture-dreamdaemon.exe',
            version: '516.1687',
            source: 'DM_EXE',
          },
          recorder,
          environment: processSpec(path.join(root, 'unused.ts')).env,
          defines: [],
          wallTimeoutMs: 10_000,
          idleTimeoutMs: 10_000,
          processRunner: runner,
        },
        ['/datum/unit_test/simple_animal_freeze'],
      );

      expect(await Bun.file(outcome.dmb).text()).toBe('fixture dmb');
      expect(compilerSpecs).toHaveLength(1);
      expect(compilerSpecs[0].args.slice(0, 2)).toEqual([
        '-DCBT',
        '-DCIBUILDING',
      ]);
      expect(
        await Array.fromAsync(
          new Bun.Glob('.rift-*.test.*').scan({ cwd: root }),
        ),
      ).toEqual([]);
    });
  });

  test('accepts unstable native DreamDaemon close codes only after focused MetaStation evidence passes', async () => {
    await withTempDirectory(async (root) => {
      await createRepositoryFixture(root);
      await fs.mkdir(path.join(root, 'tools', 'ci'), { recursive: true });
      await Bun.write(
        path.join(root, 'tools', 'ci', 'ci_config.txt'),
        'CI config',
      );
      await Bun.write(
        path.join(root, 'tools', 'build', 'build.bat'),
        [
          '@echo off',
          'if /I "%~1"=="--help" (',
          '  echo icon-cutter',
          '  echo dm-maps-include',
          '  exit /b 1',
          ')',
          'if /I "%~1"=="icon-cutter" exit /b 0',
          'exit /b 9',
          '',
        ].join('\n'),
      );
      const repository = await qualifyRepository(root);
      const { runId, runDir } = await allocateRun(repository.runsRoot);
      const recorder = await RunRecorder.create({
        runDir,
        runId,
        command: 'test',
        profile: 'ci',
        evidence: 'focused_test',
        networkMode: 'offline',
      });
      const profile = {
        ...validProfile(),
        config_source: 'ci' as const,
        dreamdaemon_flags: ['-close', '-trusted', '-verbose'],
        artifact_rules: [
          {
            id: 'clean_run',
            path: 'data/logs/rift/clean_run.lk',
            required: true,
            nonempty: true,
          },
          {
            id: 'unit_tests',
            path: 'data/unit_tests.json',
            required: true,
            nonempty: true,
          },
        ],
      };
      const serverSpecs: ProcessSpec[] = [];
      const runner = (spec: ProcessSpec, hooks: ProcessHooks): OwnedProcess => {
        if (spec.role === 'dreammaker') {
          return fakeCompileProcess(true)(spec, hooks);
        }
        serverSpecs.push(spec);
        const started = Date.now();
        let resolveResult!: (result: Awaited<OwnedProcess['result']>) => void;
        const result = new Promise<Awaited<OwnedProcess['result']>>(
          (resolve) => {
            resolveResult = resolve;
          },
        );
        void hooks.onStart(5432);
        void (async () => {
          const data = path.join(spec.cwd, 'data');
          const logs = path.join(data, 'logs', 'rift');
          await fs.mkdir(logs, { recursive: true });
          await Bun.write(
            path.join(logs, 'runtime.log.json'),
            '{"cat":"runtime","msg":"Initializations complete within 1 second!"}\n',
          );
          await Bun.write(
            path.join(data, 'unit_tests.json'),
            JSON.stringify({
              '/datum/unit_test/simple_animal_freeze': {
                duration: 0.25,
                name: '/datum/unit_test/simple_animal_freeze',
                message: '',
                runtimes: 0,
                status: 0,
              },
            }),
          );
          await Bun.write(path.join(logs, 'clean_run.lk'), 'clean');
          await Bun.sleep(150);
          resolveResult({
            role: spec.role,
            rootPid: 5432,
            ownedPids: [5432],
            exitCode: 176,
            signal: null,
            termination: 'natural',
            startedAt: new Date(started).toISOString(),
            finishedAt: new Date().toISOString(),
            durationMs: Date.now() - started,
          });
        })();
        return {
          rootPid: 5432,
          result,
          stop: async (reason) => {
            const stopped = {
              role: spec.role,
              rootPid: 5432,
              ownedPids: [5432],
              exitCode: 0,
              signal: null,
              termination: reason,
              startedAt: new Date(started).toISOString(),
              finishedAt: new Date().toISOString(),
              durationMs: Date.now() - started,
            };
            resolveResult(stopped);
            return stopped;
          },
          snapshot: async () => [],
          ownedPids: () => [5432],
        };
      };
      const command = parseCli([
        'test',
        '--profile',
        'ci',
        '--map',
        '_maps/fixture.json',
        '--focus',
        '/datum/unit_test/simple_animal_freeze',
      ]);
      if (command.command !== 'test') throw new Error('fixture is not a test');

      const summary = await runTestWorkflow(
        {
          repository,
          pins: {
            BYOND_MAJOR: '516',
            BYOND_MINOR: '1687',
            BUN_VERSION: '1.3.5',
            PYTHON_VERSION: '3.11.0',
            CUTTER_VERSION: 'v5.0.1',
          },
          byond: {
            dm: 'fixture-dm.exe',
            dreamDaemon: 'fixture-dreamdaemon.exe',
            version: '516.1687',
            source: 'DM_EXE',
          },
          pinnedPython: 'fixture-python.exe',
          profileName: 'ci',
          profile,
          profiles: new Map([['ci', profile]]),
          recorder,
          lock: {
            path: '',
            record: {
              schema_version: 1,
              token: 'fixture',
              pid: process.pid,
              command: 'test',
              run_id: runId,
              started_at: new Date().toISOString(),
            },
            release: async () => {},
          },
          runId,
          runDir,
          environment: processSpec(path.join(root, 'unused.ts')).env,
          networkMode: 'offline',
          processRunner: runner,
          serverPort: 1444,
        },
        command,
      );

      expect(summary.status).toBe('passed');
      expect(summary.exit_code).toBe(0);
      expect(summary.tests).toEqual({
        recorded: 1,
        passed: 1,
        failed: 0,
        skipped: 0,
      });
      expect(serverSpecs[0].args[1]).toBe('1444');
      expect(serverSpecs[0].args).toContain('-close');
      expect(Bun.file(path.join(runDir, 'workspace')).exists()).resolves.toBe(
        false,
      );
      expect(
        await Array.fromAsync(
          new Bun.Glob('.rift-*.test.*').scan({ cwd: root }),
        ),
      ).toEqual([]);
    });
  });
});
