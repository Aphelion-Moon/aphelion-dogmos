import fsSync from 'node:fs';
import fs from 'node:fs/promises';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import {
  type OwnedProcess,
  type ProcessHooks,
  type ProcessResult,
  type ProcessSpec,
  runProbeProcess,
  startOwnedProcess,
} from './process';
import {
  type ArtifactRecord,
  type EvidenceClass,
  hashArtifact,
  normalizeRuntimeSignature,
  RIFT_SCHEMA_VERSION,
  type RiftFailure,
  type RiftSummary,
  RunRecorder,
  readStoredRun,
  renderHumanSummary,
} from './report';

export type LogRule = {
  id: string;
  file: string;
  category: string | null;
  message_pattern: string;
  case_insensitive: boolean;
  max_occurrences: number;
};

export type ChildRule = {
  role: string;
  process_name: string;
  min_count: number;
  max_count: number;
  continuous_after_readiness: boolean;
};

export type RiftProfile = {
  config_source: 'repository' | 'ci';
  default_map: string | null;
  compile_defines: string[];
  dreamdaemon_flags: string[];
  readiness_rule: Omit<LogRule, 'max_occurrences'>;
  fatal_log_rules: LogRule[];
  required_children: ChildRule[];
  artifact_rules: Array<{
    id: string;
    path: string;
    required: boolean;
    nonempty: boolean;
  }>;
  default_timeouts: {
    wall_seconds: number;
    idle_seconds: number;
    readiness_seconds: number;
  };
  minimum_tests: number;
  resource_sample_seconds: number;
};

export type ProfileDocument = {
  schema_version: 1;
  profiles: Record<string, RiftProfile>;
};

export const MAX_WALL_TIMEOUT_SECONDS = 3600;
export const MAX_IDLE_TIMEOUT_SECONDS = 900;
export const MAX_READINESS_TIMEOUT_SECONDS = 900;
export const MAX_LOCK_WAIT_SECONDS = 300;

const PROFILE_KEYS = new Set([
  'config_source',
  'default_map',
  'compile_defines',
  'dreamdaemon_flags',
  'readiness_rule',
  'fatal_log_rules',
  'required_children',
  'artifact_rules',
  'default_timeouts',
  'minimum_tests',
  'resource_sample_seconds',
]);

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === 'object' && value !== null && !Array.isArray(value);

const assertRecord = (
  value: unknown,
  label: string,
): Record<string, unknown> => {
  if (!isRecord(value)) {
    throw new Error(`${label} must be an object`);
  }
  return value;
};

const assertKnownKeys = (
  value: Record<string, unknown>,
  allowed: Set<string>,
  label: string,
) => {
  for (const key of Object.keys(value)) {
    if (!allowed.has(key)) {
      throw new Error(`unknown ${label} property: ${key}`);
    }
  }
};

const requireString = (value: unknown, label: string): string => {
  if (typeof value !== 'string' || value.length === 0) {
    throw new Error(`${label} must be a nonempty string`);
  }
  return value;
};

const requireBoolean = (value: unknown, label: string): boolean => {
  if (typeof value !== 'boolean') {
    throw new Error(`${label} must be a boolean`);
  }
  return value;
};

const requireInteger = (
  value: unknown,
  label: string,
  minimum = 0,
  maximum?: number,
): number => {
  if (
    !Number.isInteger(value) ||
    (value as number) < minimum ||
    (maximum !== undefined && (value as number) > maximum)
  ) {
    const range =
      maximum === undefined
        ? `greater than or equal to ${minimum}`
        : `between ${minimum} and ${maximum}`;
    throw new Error(`${label} must be an integer ${range}`);
  }
  return value as number;
};

const requireStringArray = (value: unknown, label: string): string[] => {
  if (
    !Array.isArray(value) ||
    value.some((entry) => typeof entry !== 'string')
  ) {
    throw new Error(`${label} must be an array of strings`);
  }
  return value as string[];
};

const isSafeRelativePath = (value: string) => {
  const normalized = value.replaceAll('\\', '/');
  return (
    value.length > 0 &&
    !path.isAbsolute(value) &&
    !normalized.startsWith('../') &&
    !normalized.includes('/../') &&
    normalized !== '..'
  );
};

const requireSafePath = (value: unknown): string => {
  const candidate = requireString(value, 'profile path');
  if (!isSafeRelativePath(candidate)) {
    throw new Error(`unsafe profile path: ${candidate}`);
  }
  return candidate;
};

const assertNoDuplicateObjectKeys = (text: string) => {
  const scopes: Array<Set<string> | null> = [];
  for (let index = 0; index < text.length; index += 1) {
    const character = text[index];
    if (character === '{') {
      scopes.push(new Set());
      continue;
    }
    if (character === '[') {
      scopes.push(null);
      continue;
    }
    if (character === '}' || character === ']') {
      scopes.pop();
      continue;
    }
    if (character !== '"') {
      continue;
    }

    const start = index;
    index += 1;
    let escaped = false;
    while (index < text.length) {
      const stringCharacter = text[index];
      if (escaped) {
        escaped = false;
      } else if (stringCharacter === '\\') {
        escaped = true;
      } else if (stringCharacter === '"') {
        break;
      }
      index += 1;
    }
    if (index >= text.length) {
      return;
    }

    let following = index + 1;
    while (following < text.length && /\s/.test(text[following])) {
      following += 1;
    }
    const scope = scopes.at(-1);
    if (text[following] !== ':' || !scope) {
      continue;
    }

    const key = JSON.parse(text.slice(start, index + 1)) as string;
    if (scope.has(key)) {
      throw new Error(`duplicate JSON key: ${key}`);
    }
    scope.add(key);
  }
};

const validateLogRule = (value: unknown, includeMaximum: boolean): LogRule => {
  const rule = assertRecord(value, 'log rule');
  const keys = new Set([
    'id',
    'file',
    'category',
    'message_pattern',
    'case_insensitive',
    ...(includeMaximum ? ['max_occurrences'] : []),
  ]);
  assertKnownKeys(rule, keys, 'log rule');

  const id = requireString(rule.id, 'log rule id');
  const messagePattern = requireString(rule.message_pattern, 'log pattern');
  const caseInsensitive = requireBoolean(
    rule.case_insensitive,
    'case_insensitive',
  );
  try {
    new RegExp(messagePattern, caseInsensitive ? 'i' : undefined);
  } catch {
    throw new Error(`invalid log pattern: ${id}`);
  }

  return {
    id,
    file: requireSafePath(rule.file),
    category:
      rule.category === null
        ? null
        : requireString(rule.category, 'log rule category'),
    message_pattern: messagePattern,
    case_insensitive: caseInsensitive,
    max_occurrences: includeMaximum
      ? requireInteger(rule.max_occurrences, 'max_occurrences')
      : 0,
  };
};

const validateProfile = (value: unknown): RiftProfile => {
  const profile = assertRecord(value, 'profile');
  assertKnownKeys(profile, PROFILE_KEYS, 'profile');

  if (
    profile.config_source !== 'repository' &&
    profile.config_source !== 'ci'
  ) {
    throw new Error('config_source must be repository or ci');
  }
  if (profile.default_map !== null && typeof profile.default_map !== 'string') {
    throw new Error('default_map must be null or a relative path');
  }

  const readiness = validateLogRule(profile.readiness_rule, false);
  const fatalRules = Array.isArray(profile.fatal_log_rules)
    ? profile.fatal_log_rules.map((rule) => validateLogRule(rule, true))
    : (() => {
        throw new Error('fatal_log_rules must be an array');
      })();

  if (!Array.isArray(profile.required_children)) {
    throw new Error('required_children must be an array');
  }
  const requiredChildren = profile.required_children.map((entry) => {
    const child = assertRecord(entry, 'child rule');
    assertKnownKeys(
      child,
      new Set([
        'role',
        'process_name',
        'min_count',
        'max_count',
        'continuous_after_readiness',
      ]),
      'child rule',
    );
    const minCount = requireInteger(child.min_count, 'min_count');
    const maxCount = requireInteger(child.max_count, 'max_count');
    if (maxCount < minCount) {
      throw new Error('max_count must be greater than or equal to min_count');
    }
    return {
      role: requireString(child.role, 'child role'),
      process_name: requireString(child.process_name, 'child process name'),
      min_count: minCount,
      max_count: maxCount,
      continuous_after_readiness: requireBoolean(
        child.continuous_after_readiness,
        'continuous_after_readiness',
      ),
    };
  });

  if (!Array.isArray(profile.artifact_rules)) {
    throw new Error('artifact_rules must be an array');
  }
  const artifactRules = profile.artifact_rules.map((entry) => {
    const artifact = assertRecord(entry, 'artifact rule');
    assertKnownKeys(
      artifact,
      new Set(['id', 'path', 'required', 'nonempty']),
      'artifact rule',
    );
    return {
      id: requireString(artifact.id, 'artifact id'),
      path: requireSafePath(artifact.path),
      required: requireBoolean(artifact.required, 'artifact required'),
      nonempty: requireBoolean(artifact.nonempty, 'artifact nonempty'),
    };
  });

  const timeouts = assertRecord(profile.default_timeouts, 'default_timeouts');
  assertKnownKeys(
    timeouts,
    new Set(['wall_seconds', 'idle_seconds', 'readiness_seconds']),
    'default_timeouts',
  );

  return {
    config_source: profile.config_source,
    default_map:
      profile.default_map === null
        ? null
        : requireSafePath(profile.default_map),
    compile_defines: requireStringArray(
      profile.compile_defines,
      'compile_defines',
    ),
    dreamdaemon_flags: requireStringArray(
      profile.dreamdaemon_flags,
      'dreamdaemon_flags',
    ),
    readiness_rule: {
      id: readiness.id,
      file: readiness.file,
      category: readiness.category,
      message_pattern: readiness.message_pattern,
      case_insensitive: readiness.case_insensitive,
    },
    fatal_log_rules: fatalRules,
    required_children: requiredChildren,
    artifact_rules: artifactRules,
    default_timeouts: {
      wall_seconds: requireInteger(
        timeouts.wall_seconds,
        'wall_seconds',
        1,
        MAX_WALL_TIMEOUT_SECONDS,
      ),
      idle_seconds: requireInteger(
        timeouts.idle_seconds,
        'idle_seconds',
        1,
        MAX_IDLE_TIMEOUT_SECONDS,
      ),
      readiness_seconds: requireInteger(
        timeouts.readiness_seconds,
        'readiness_seconds',
        1,
        MAX_READINESS_TIMEOUT_SECONDS,
      ),
    },
    minimum_tests: requireInteger(profile.minimum_tests, 'minimum_tests', 1),
    resource_sample_seconds: requireInteger(
      profile.resource_sample_seconds,
      'resource_sample_seconds',
      1,
    ),
  };
};

export const parseProfileDocument = (text: string): ProfileDocument => {
  assertNoDuplicateObjectKeys(text);
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch (error) {
    throw new Error(
      `invalid profile JSON: ${error instanceof Error ? error.message : String(error)}`,
    );
  }

  const document = assertRecord(parsed, 'profile document');
  assertKnownKeys(
    document,
    new Set(['schema_version', 'profiles']),
    'document',
  );
  if (document.schema_version !== 1) {
    throw new Error(
      `unsupported profile schema: ${String(document.schema_version)}`,
    );
  }

  const profiles = assertRecord(document.profiles, 'profiles');
  const validatedProfiles: Record<string, RiftProfile> = {};
  for (const [name, value] of Object.entries(profiles)) {
    if (!/^[a-z][a-z0-9_-]*$/.test(name)) {
      throw new Error(`invalid profile name: ${name}`);
    }
    validatedProfiles[name] = validateProfile(value);
  }

  return { schema_version: 1, profiles: validatedProfiles };
};

export const loadProfiles = async (
  filePath: string,
): Promise<Map<string, RiftProfile>> => {
  const document = parseProfileDocument(await fs.readFile(filePath, 'utf8'));
  return new Map(Object.entries(document.profiles));
};

export type OutputFormat = 'human' | 'jsonl' | 'result';

type CommonOptions = {
  format: OutputFormat;
  networkMode: 'offline' | 'allow';
  profile: string;
  wallTimeoutSeconds: number | null;
  idleTimeoutSeconds: number | null;
  waitForLockSeconds: number;
  keepWorkspace: boolean;
};

type NativeOverlayOptions = {
  shim: string | null;
  service: string | null;
};

export type RiftCommand =
  | ({ command: 'doctor' } & CommonOptions)
  | ({
      command: 'compile';
      mode: 'fast' | 'full';
      force: boolean;
    } & CommonOptions &
      NativeOverlayOptions)
  | ({
      command: 'run';
      compileMode: 'fast' | 'full';
      map: string | null;
      port: number;
      readinessTimeoutSeconds: number | null;
      runSeconds: number | null;
    } & CommonOptions &
      NativeOverlayOptions)
  | ({
      command: 'test';
      focus: string[];
      map: string | null;
      minimumTests: number | null;
      readinessTimeoutSeconds: number | null;
    } & CommonOptions &
      NativeOverlayOptions)
  | ({
      command: 'soak';
      compileMode: 'fast' | 'full';
      map: string | null;
      runSeconds: number;
      readinessTimeoutSeconds: number | null;
      shim: string | null;
      service: string | null;
    } & CommonOptions)
  | ({ command: 'report'; runId: string } & Pick<CommonOptions, 'format'>);

const COMMANDS = new Set([
  'doctor',
  'compile',
  'run',
  'test',
  'soak',
  'report',
]);
const UNIT_TEST_TYPE = /^\/datum\/unit_test(?:\/[a-zA-Z_][a-zA-Z0-9_]*)+$/;

const parseInteger = (
  value: string,
  label: string,
  minimum: number,
  maximum?: number,
) => {
  if (!/^(?:0|[1-9]\d*)$/.test(value)) {
    throw new Error(`${label} must be a base-10 integer`);
  }
  const parsed = Number(value);
  if (
    !Number.isSafeInteger(parsed) ||
    parsed < minimum ||
    (maximum !== undefined && parsed > maximum)
  ) {
    const range =
      maximum === undefined ? `at least ${minimum}` : `${minimum}-${maximum}`;
    throw new Error(`${label} must be ${range}`);
  }
  return parsed;
};

export const validateFocusType = (value: string): string => {
  if (!UNIT_TEST_TYPE.test(value)) {
    throw new Error(`invalid unit-test type: ${value}`);
  }
  return value;
};

export const parseCli = (
  argv: string[],
  environment: NodeJS.ProcessEnv = process.env,
): RiftCommand => {
  const environmentNetwork =
    environment.MERIDIAN_RIFT_BUILD_NETWORK ?? 'offline';
  if (environmentNetwork !== 'offline' && environmentNetwork !== 'allow') {
    throw new Error('network mode must be offline or allow');
  }

  let format: CommonOptions['format'] = 'human';
  let networkMode: CommonOptions['networkMode'] = environmentNetwork;
  let profile: string | null = null;
  let wallTimeoutSeconds: number | null =
    environment.MERIDIAN_RIFT_WALL_TIMEOUT_SECONDS === undefined
      ? null
      : parseInteger(
          environment.MERIDIAN_RIFT_WALL_TIMEOUT_SECONDS,
          'wall timeout',
          1,
          MAX_WALL_TIMEOUT_SECONDS,
        );
  let idleTimeoutSeconds: number | null =
    environment.MERIDIAN_RIFT_IDLE_TIMEOUT_SECONDS === undefined
      ? null
      : parseInteger(
          environment.MERIDIAN_RIFT_IDLE_TIMEOUT_SECONDS,
          'idle timeout',
          1,
          MAX_IDLE_TIMEOUT_SECONDS,
        );
  let waitForLockSeconds = 0;
  let keepWorkspace = false;
  let command: string | null = null;
  let compileMode: 'fast' | 'full' | null = null;
  let force = false;
  let selectedMap: string | null = null;
  let port = 1337;
  let readinessTimeoutSeconds: number | null = null;
  let runSeconds: number | null = null;
  let minimumTests: number | null = null;
  let shim: string | null = null;
  let service: string | null = null;
  let reportRunId: string | null = null;
  const focus: string[] = [];
  const seenOptions = new Set<string>();
  const optionsWithValues = new Set([
    '--format',
    '--network',
    '--profile',
    '--wall-timeout-seconds',
    '--idle-timeout-seconds',
    '--wait-for-lock-seconds',
    '--mode',
    '--compile-mode',
    '--map',
    '--port',
    '--readiness-timeout-seconds',
    '--run-seconds',
    '--minimum-tests',
    '--focus',
    '--shim',
    '--service',
  ]);

  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (!token.startsWith('--')) {
      if (command === null) {
        if (!COMMANDS.has(token)) {
          throw new Error(`unknown command: ${token}`);
        }
        command = token;
        continue;
      }
      if (command === 'report' && reportRunId === null) {
        reportRunId = token;
        continue;
      }
      throw new Error(`unexpected positional argument: ${token}`);
    }

    const equalsIndex = token.indexOf('=');
    const option = equalsIndex === -1 ? token : token.slice(0, equalsIndex);
    let optionValue = equalsIndex === -1 ? null : token.slice(equalsIndex + 1);
    if (seenOptions.has(option) && option !== '--focus') {
      throw new Error(`duplicate option: ${option}`);
    }
    seenOptions.add(option);

    if (optionsWithValues.has(option)) {
      if (optionValue === null) {
        index += 1;
        optionValue = argv[index] ?? null;
      }
      if (
        optionValue === null ||
        optionValue.length === 0 ||
        optionValue.startsWith('--')
      ) {
        throw new Error(`missing value for ${option}`);
      }
    } else if (equalsIndex !== -1) {
      throw new Error(`option does not accept a value: ${option}`);
    }

    switch (option) {
      case '--format':
        if (
          optionValue !== 'human' &&
          optionValue !== 'jsonl' &&
          optionValue !== 'result'
        ) {
          throw new Error('format must be human, jsonl, or result');
        }
        format = optionValue;
        break;
      case '--network':
        if (optionValue !== 'offline' && optionValue !== 'allow') {
          throw new Error('network mode must be offline or allow');
        }
        networkMode = optionValue;
        break;
      case '--profile':
        if (!/^[a-z][a-z0-9_-]*$/.test(optionValue!)) {
          throw new Error(`invalid profile name: ${optionValue}`);
        }
        profile = optionValue!;
        break;
      case '--wall-timeout-seconds':
        wallTimeoutSeconds = parseInteger(
          optionValue!,
          'wall timeout',
          1,
          MAX_WALL_TIMEOUT_SECONDS,
        );
        break;
      case '--idle-timeout-seconds':
        idleTimeoutSeconds = parseInteger(
          optionValue!,
          'idle timeout',
          1,
          MAX_IDLE_TIMEOUT_SECONDS,
        );
        break;
      case '--wait-for-lock-seconds':
        waitForLockSeconds = parseInteger(
          optionValue!,
          'lock wait',
          0,
          MAX_LOCK_WAIT_SECONDS,
        );
        break;
      case '--keep-workspace':
        keepWorkspace = true;
        break;
      case '--mode':
        if (command !== 'compile') {
          throw new Error('--mode is valid only for compile');
        }
        if (optionValue !== 'fast' && optionValue !== 'full') {
          throw new Error('compile mode must be fast or full');
        }
        compileMode = optionValue;
        break;
      case '--compile-mode':
        if (command !== 'run' && command !== 'soak') {
          throw new Error('--compile-mode is valid only for run or soak');
        }
        if (optionValue !== 'fast' && optionValue !== 'full') {
          throw new Error('compile mode must be fast or full');
        }
        compileMode = optionValue;
        break;
      case '--force':
        if (command !== 'compile') {
          throw new Error('--force is valid only for compile');
        }
        force = true;
        break;
      case '--map':
        if (command !== 'run' && command !== 'test' && command !== 'soak') {
          throw new Error('--map is valid only for run, test, or soak');
        }
        selectedMap = optionValue!;
        break;
      case '--port':
        if (command !== 'run') {
          throw new Error('--port is valid only for run');
        }
        port = parseInteger(optionValue!, 'port', 1, 65535);
        break;
      case '--readiness-timeout-seconds':
        if (command !== 'run' && command !== 'test' && command !== 'soak') {
          throw new Error(
            '--readiness-timeout-seconds is valid only for run, test, or soak',
          );
        }
        readinessTimeoutSeconds = parseInteger(
          optionValue!,
          'readiness timeout',
          1,
          MAX_READINESS_TIMEOUT_SECONDS,
        );
        break;
      case '--run-seconds':
        if (command !== 'run' && command !== 'soak') {
          throw new Error('--run-seconds is valid only for run or soak');
        }
        runSeconds = parseInteger(
          optionValue!,
          'run duration',
          command === 'soak' ? 30 : 0,
          1800,
        );
        break;
      case '--minimum-tests':
        if (command !== 'test') {
          throw new Error('--minimum-tests is valid only for test');
        }
        minimumTests = parseInteger(optionValue!, 'minimum tests', 1);
        break;
      case '--focus':
        if (command !== 'test') {
          throw new Error('--focus is valid only for test');
        }
        if (!focus.includes(validateFocusType(optionValue!))) {
          focus.push(optionValue!);
        }
        break;
      case '--shim':
      case '--service':
        if (command !== 'run' && command !== 'test' && command !== 'soak') {
          throw new Error(`${option} is valid only for run, test, or soak`);
        }
        if (option === '--shim') {
          shim = optionValue!;
        } else {
          service = optionValue!;
        }
        break;
      default:
        throw new Error(`unknown option: ${option}`);
    }
  }

  if (command === null) {
    throw new Error('missing command');
  }
  if (command === 'report') {
    if (reportRunId === null) {
      throw new Error('report requires a run ID');
    }
    if (
      seenOptions.has('--network') ||
      seenOptions.has('--profile') ||
      seenOptions.has('--wall-timeout-seconds') ||
      seenOptions.has('--idle-timeout-seconds') ||
      seenOptions.has('--wait-for-lock-seconds') ||
      keepWorkspace
    ) {
      throw new Error('report accepts only --format');
    }
    return { command, runId: reportRunId, format };
  }

  const common: CommonOptions = {
    format,
    networkMode,
    profile: profile ?? (command === 'test' ? 'ci' : 'default'),
    wallTimeoutSeconds,
    idleTimeoutSeconds,
    waitForLockSeconds,
    keepWorkspace,
  };
  const overlays: NativeOverlayOptions = { shim, service };
  if ((shim === null) !== (service === null)) {
    throw new Error('--shim and --service must be supplied together');
  }
  if (
    (command === 'run' || command === 'test' || command === 'soak') &&
    common.profile.startsWith('dogmos') &&
    shim === null
  ) {
    throw new Error('Dogmos runtime profiles require --shim and --service');
  }
  switch (command) {
    case 'doctor':
      return { command, ...common };
    case 'compile':
      if (compileMode === null) {
        throw new Error('compile requires --mode fast or full');
      }
      if (compileMode === 'fast' && force) {
        throw new Error('--force is valid only for full compile');
      }
      return { command, mode: compileMode, force, ...common };
    case 'run':
      return {
        command,
        compileMode: compileMode ?? 'full',
        map: selectedMap,
        port,
        readinessTimeoutSeconds,
        runSeconds,
        ...overlays,
        ...common,
      };
    case 'test':
      return {
        command,
        focus,
        map: selectedMap,
        minimumTests,
        readinessTimeoutSeconds,
        ...overlays,
        ...common,
      };
    case 'soak':
      if (runSeconds === null) {
        throw new Error('soak requires --run-seconds');
      }
      return {
        command,
        compileMode: compileMode ?? 'full',
        map: selectedMap,
        runSeconds,
        readinessTimeoutSeconds,
        ...overlays,
        ...common,
      };
    default:
      throw new Error(`unknown command: ${command}`);
  }
};

export const resolveWorkflowPython = (
  environment: NodeJS.ProcessEnv,
  pinnedPython: string | null,
): string => pinnedPython ?? environment.PYTHON ?? 'python';

export type RepositoryPaths = {
  root: string;
  dme: string;
  buildCmd: string;
  buildDelegate: string;
  dependencies: string;
  runsRoot: string;
};

export type DependencyPins = {
  BYOND_MAJOR: string;
  BYOND_MINOR: string;
  BUN_VERSION: string;
  PYTHON_VERSION: string;
  CUTTER_VERSION: string;
};

const REQUIRED_REPOSITORY_PATHS = [
  'tgstation.dme',
  'dependencies.sh',
  'BUILD.cmd',
  'tools/build/build.bat',
  'tools/build/build.ts',
] as const;

const hasRepositoryMarkers = (candidate: string) =>
  REQUIRED_REPOSITORY_PATHS.every((entry) =>
    fsSync.existsSync(path.join(candidate, entry)),
  );

const assertBuildContract = async (buildCmd: string) => {
  const normalized = (await fs.readFile(buildCmd, 'utf8'))
    .split(/\r?\n/)
    .map((line) => line.trim().replaceAll('/', '\\'))
    .filter(Boolean);
  const expected = [
    '@echo off',
    'call "%~dp0\\tools\\build\\build.bat" --wait-on-error build %*',
  ];
  if (
    normalized.length !== expected.length ||
    normalized.some((line, index) => line !== expected[index])
  ) {
    throw new Error('build contract mismatch');
  }
};

export const qualifyRepository = async (
  start: string,
): Promise<RepositoryPaths> => {
  let candidate = path.resolve(start);
  const startStat = await fs.stat(candidate).catch(() => null);
  if (startStat?.isFile()) {
    candidate = path.dirname(candidate);
  }
  while (!hasRepositoryMarkers(candidate)) {
    const parent = path.dirname(candidate);
    if (parent === candidate) {
      throw new Error('repository root not found');
    }
    candidate = parent;
  }

  const root = await fs.realpath(candidate);
  const buildCmd = path.join(root, 'BUILD.cmd');
  await assertBuildContract(buildCmd);
  return {
    root,
    dme: path.join(root, 'tgstation.dme'),
    buildCmd,
    buildDelegate: path.join(root, 'tools', 'build', 'build.bat'),
    dependencies: path.join(root, 'dependencies.sh'),
    runsRoot: path.join(root, 'data', 'rift-runs'),
  };
};

export const parseDependencyPins = (text: string): DependencyPins => {
  const required = [
    'BYOND_MAJOR',
    'BYOND_MINOR',
    'BUN_VERSION',
    'PYTHON_VERSION',
    'CUTTER_VERSION',
  ] as const;
  const values = new Map<string, string>();
  for (const line of text.split(/\r?\n/)) {
    const match = /^export ([A-Z][A-Z0-9_]*)=(.*)$/.exec(line);
    if (!match || !required.includes(match[1] as (typeof required)[number])) {
      continue;
    }
    const [, name, value] = match;
    if (values.has(name) || !/^[A-Za-z0-9][A-Za-z0-9._+:/-]*$/.test(value)) {
      throw new Error(`invalid dependency pin: ${name}`);
    }
    values.set(name, value);
  }
  for (const name of required) {
    if (!values.has(name)) {
      throw new Error(`missing dependency pin: ${name}`);
    }
  }
  return Object.fromEntries(
    required.map((name) => [name, values.get(name)!]),
  ) as DependencyPins;
};

const isContainedPath = (parent: string, child: string) => {
  const relative = path.relative(parent, child);
  return (
    relative !== '..' &&
    !relative.startsWith(`..${path.sep}`) &&
    !path.isAbsolute(relative)
  );
};

export const validateMapPath = (
  repositoryRoot: string,
  value: string,
  completionEvidence = false,
): string => {
  const mapsRoot = fsSync.realpathSync(path.join(repositoryRoot, '_maps'));
  const candidate = path.resolve(repositoryRoot, value);
  if (!isContainedPath(mapsRoot.toLowerCase(), candidate.toLowerCase())) {
    throw new Error('map path escapes _maps');
  }
  if (path.extname(candidate).toLowerCase() !== '.json') {
    throw new Error('map path must name a JSON file');
  }
  let realCandidate: string;
  try {
    realCandidate = fsSync.realpathSync(candidate);
  } catch {
    throw new Error(`map file does not exist: ${value}`);
  }
  if (!isContainedPath(mapsRoot.toLowerCase(), realCandidate.toLowerCase())) {
    throw new Error('map path escapes _maps');
  }
  const relativePath = path
    .relative(repositoryRoot, realCandidate)
    .replaceAll('\\', '/');
  if (
    completionEvidence &&
    relativePath.toLowerCase() !== '_maps/metastation.json' &&
    relativePath.toLowerCase() !== '_maps/runtimestation.json'
  ) {
    throw new Error(
      'completion evidence requires a representative map: _maps/metastation.json or _maps/runtimestation.json',
    );
  }
  return relativePath;
};

export type ByondTools = {
  dm: string;
  dreamDaemon: string;
  version: string;
  source: 'DM_EXE' | 'named_version' | 'standard_path' | 'registry' | 'PATH';
};

export type ProbeResult = { exitCode: number; stdout: string; stderr: string };
export type RunProbe = (
  executable: string,
  args: string[],
  cwd: string,
  environment: Record<string, string>,
) => Promise<ProbeResult>;

const stringEnvironment = (
  environment: NodeJS.ProcessEnv,
): Record<string, string> =>
  Object.fromEntries(
    Object.entries(environment).filter(
      (entry): entry is [string, string] => entry[1] !== undefined,
    ),
  );

export const resolveByond = async (
  repository: RepositoryPaths,
  pins: DependencyPins,
  runProbe: RunProbe,
  environment: NodeJS.ProcessEnv = process.env,
): Promise<ByondTools> => {
  const candidates: Array<{ dm: string; source: ByondTools['source'] }> = [];
  for (const dm of environment.DM_EXE?.split(',') ?? []) {
    if (dm.trim()) {
      candidates.push({ dm: dm.trim(), source: 'DM_EXE' });
    }
  }
  const namedVersionFile = path.join(
    repository.root,
    'tools',
    'build',
    'dm_versions.json',
  );
  if (fsSync.existsSync(namedVersionFile)) {
    const document = (await Bun.file(namedVersionFile)
      .json()
      .catch(() => [])) as unknown;
    if (Array.isArray(document)) {
      const namedDefault = document.find(
        (entry): entry is { path: string; default: true } =>
          typeof entry === 'object' &&
          entry !== null &&
          'path' in entry &&
          typeof entry.path === 'string' &&
          'default' in entry &&
          entry.default === true,
      );
      if (namedDefault) {
        const configuredPath = path.isAbsolute(namedDefault.path)
          ? namedDefault.path
          : path.resolve(repository.root, namedDefault.path);
        const configuredStat = fsSync.statSync(configuredPath, {
          throwIfNoEntry: false,
        });
        const namedDm = configuredStat?.isDirectory()
          ? ([
              path.join(configuredPath, 'dm.exe'),
              path.join(configuredPath, 'bin', 'dm.exe'),
            ].find((candidate) => fsSync.existsSync(candidate)) ??
            configuredPath)
          : configuredPath;
        candidates.push({ dm: namedDm, source: 'named_version' });
      }
    }
  }
  candidates.push(
    { dm: 'C:\\Program Files\\BYOND\\bin\\dm.exe', source: 'standard_path' },
    {
      dm: 'C:\\Program Files (x86)\\BYOND\\bin\\dm.exe',
      source: 'standard_path',
    },
  );

  for (const registryKey of [
    'HKLM\\SOFTWARE\\Dantom\\BYOND',
    'HKLM\\SOFTWARE\\WOW6432Node\\Dantom\\BYOND',
  ]) {
    const result = await runProbe(
      'reg.exe',
      ['query', registryKey, '/ve'],
      repository.root,
      stringEnvironment(environment),
    ).catch(() => null);
    const installRoot = result
      ? /REG_SZ\s+(.+)$/m
          .exec(`${result.stdout}\n${result.stderr}`)?.[1]
          ?.trim()
      : null;
    if (installRoot) {
      candidates.push({
        dm: path.join(installRoot, 'bin', 'dm.exe'),
        source: 'registry',
      });
    }
  }

  const whereResult = await runProbe(
    'where.exe',
    ['dm.exe'],
    repository.root,
    stringEnvironment(environment),
  ).catch(() => null);
  if (whereResult?.exitCode === 0) {
    for (const dm of whereResult.stdout
      .split(/\r?\n/)
      .map((line) => line.trim())
      .filter(Boolean)) {
      candidates.push({ dm, source: 'PATH' });
    }
  }

  const expectedVersion = `${pins.BYOND_MAJOR}.${pins.BYOND_MINOR}`;
  const seen = new Set<string>();
  for (const candidate of candidates) {
    const key = path.resolve(candidate.dm).toLowerCase();
    if (seen.has(key) || !fsSync.existsSync(candidate.dm)) {
      continue;
    }
    seen.add(key);
    const result = await runProbe(
      candidate.dm,
      [],
      repository.root,
      stringEnvironment(environment),
    ).catch(() => null);
    const version = result
      ? /DM compiler version\s+(\d+\.\d+)/i.exec(
          `${result.stdout}\n${result.stderr}`,
        )?.[1]
      : null;
    if (version !== expectedVersion) {
      continue;
    }
    const dreamDaemon = path.join(
      path.dirname(candidate.dm),
      'dreamdaemon.exe',
    );
    if (!fsSync.existsSync(dreamDaemon)) {
      continue;
    }
    return { dm: candidate.dm, dreamDaemon, version, source: candidate.source };
  }
  throw new Error(`pinned BYOND ${expectedVersion} not found`);
};

export type OfflinePreflight = {
  environment: Record<string, string>;
  tools: { bun: string; python: string; pip: string; iconCutter: string };
  cleanup: () => Promise<void>;
};

const sha256File = async (filePath: string) => {
  const bytes = new Uint8Array(await Bun.file(filePath).arrayBuffer());
  return new Bun.CryptoHasher('sha256').update(bytes).digest('hex');
};

export const preflightOffline = async (
  repository: RepositoryPaths,
  pins: DependencyPins,
  environment: NodeJS.ProcessEnv,
  runProbe: RunProbe,
): Promise<OfflinePreflight> => {
  const configuredCache =
    environment.TG_BOOTSTRAP_CACHE ?? path.join('tools', 'bootstrap', '.cache');
  const cache = path.isAbsolute(configuredCache)
    ? path.resolve(configuredCache)
    : path.resolve(repository.root, configuredCache);
  const pythonRoot = path.join(cache, `python-${pins.PYTHON_VERSION}`);
  const cutterVersion = pins.CUTTER_VERSION.replaceAll('.', '-');
  const tools = {
    bun: path.join(cache, `bun-v${pins.BUN_VERSION}-x64`, 'bun.exe'),
    python: path.join(pythonRoot, 'python.exe'),
    pip: path.join(pythonRoot, 'Scripts', 'pip.exe'),
    iconCutter: path.join(
      repository.root,
      'tools',
      'icon_cutter',
      'cache',
      `hypnagogic${cutterVersion}.exe`,
    ),
  };
  const requirementsSource = path.join(
    repository.root,
    'tools',
    'requirements.txt',
  );
  const requirementsMarker = path.join(pythonRoot, 'requirements.txt');
  const requiredFiles = [
    tools.bun,
    tools.python,
    tools.pip,
    tools.iconCutter,
    requirementsSource,
    requirementsMarker,
    path.join(repository.root, 'bun.lock'),
    path.join(repository.root, 'tgui', 'bun.lock'),
  ];
  const missing = requiredFiles.filter(
    (filePath) => !fsSync.existsSync(filePath),
  );
  if (missing.length > 0) {
    throw new Error(`offline prerequisites missing: ${missing.length}`);
  }
  if (
    (await sha256File(requirementsSource)) !==
    (await sha256File(requirementsMarker))
  ) {
    throw new Error(
      'cached Python requirements marker does not match tools/requirements.txt',
    );
  }

  const temporaryRoot = await fs.mkdtemp(
    path.join(os.tmpdir(), 'rift-offline-'),
  );
  let cleaned = false;
  const cleanup = async () => {
    if (!cleaned) {
      cleaned = true;
      await fs.rm(temporaryRoot, { recursive: true, force: true });
    }
  };
  try {
    await fs.writeFile(
      path.join(temporaryRoot, '.bunfig.toml'),
      [
        'telemetry = false',
        'env = false',
        '',
        '[install]',
        'offline = true',
        'frozenLockfile = true',
        '',
      ].join('\n'),
      'ascii',
    );
    const childEnvironment = {
      ...stringEnvironment(environment),
      XDG_CONFIG_HOME: temporaryRoot,
      PIP_NO_INDEX: '1',
      PIP_DISABLE_PIP_VERSION_CHECK: '1',
      PIP_REQUIRE_VIRTUALENV: '0',
    };
    const version = await runProbe(
      tools.bun,
      ['--version'],
      repository.root,
      childEnvironment,
    );
    if (version.exitCode !== 0 || version.stdout.trim() !== pins.BUN_VERSION) {
      throw new Error(`pinned Bun ${pins.BUN_VERSION} is not executable`);
    }
    for (const cwd of [repository.root, path.join(repository.root, 'tgui')]) {
      const result = await runProbe(
        tools.bun,
        ['install', '--dry-run'],
        cwd,
        childEnvironment,
      );
      if (result.exitCode !== 0) {
        throw new Error(
          `offline dependency resolution failed: ${path.basename(cwd)}`,
        );
      }
    }
    return { environment: childEnvironment, tools, cleanup };
  } catch (error) {
    await cleanup();
    throw error;
  }
};

export type ProcessRunner = (
  spec: ProcessSpec,
  hooks: ProcessHooks,
) => OwnedProcess;

export const verifyDogmosInstalledContract = async (options: {
  repositoryRoot: string;
  python: string;
  environment: Record<string, string>;
  runner?: ProcessRunner;
  recorder?: RunRecorder;
}): Promise<ProcessResult> => {
  const verifier = path.join(
    options.repositoryRoot,
    'tools',
    'dogmos',
    'verify_contract.py',
  );
  const verifierStat = await fs.stat(verifier).catch(() => null);
  if (!verifierStat?.isFile()) {
    throw new Error(`Dogmos contract verifier is missing: ${verifier}`);
  }
  const output: string[] = [];
  const hooks = options.recorder
    ? compileHooks(options.recorder, 'dogmos-contract', output)
    : {
        onStart: async () => {},
        onOutput: async (_stream: 'stdout' | 'stderr', line: string) => {
          output.push(line);
        },
        onOwnedPids: async () => {},
        onSample: async () => {},
      };
  const owned = (options.runner ?? startOwnedProcess)(
    {
      role: 'dogmos-contract',
      executable: options.python,
      args: [verifier, 'verify-installed', '--root', options.repositoryRoot],
      cwd: options.repositoryRoot,
      env: options.environment,
      wallTimeoutMs: 300_000,
      idleTimeoutMs: 300_000,
    },
    hooks,
  );
  const result = await owned.result;
  if (result.termination !== 'natural' || result.exitCode !== 0) {
    throw new Error(
      `Dogmos contract verification failed: ${result.termination} ${String(result.exitCode)}${output.length > 0 ? `: ${output.at(-1)}` : ''}`,
    );
  }
  return result;
};

export const createCancellationController = (
  delegate: ProcessRunner = startOwnedProcess,
) => {
  const active = new Set<OwnedProcess>();
  let cancelled = false;
  const runner: ProcessRunner = (spec, hooks) => {
    if (cancelled) {
      throw new RiftError('cancelled', 'run', 'cancelled', 130);
    }
    const owned = delegate(spec, hooks);
    active.add(owned);
    void owned.result.then(
      () => active.delete(owned),
      () => active.delete(owned),
    );
    return owned;
  };
  return {
    runner,
    cancel: async () => {
      cancelled = true;
      await Promise.all([...active].map((owned) => owned.stop('cancelled')));
    },
    wasCancelled: () => cancelled,
  };
};

export type CompileRequest = {
  runId: string;
  repository: RepositoryPaths;
  byond: ByondTools;
  recorder: RunRecorder;
  environment: Record<string, string>;
  defines: string[];
  wallTimeoutMs: number;
  idleTimeoutMs: number;
  processRunner?: ProcessRunner;
  buildProcessRunner?: ProcessRunner;
};

export type CompileOutcome = {
  evidence: 'compiler' | 'full_build';
  dmb: string;
  rsc: string;
  artifacts: ArtifactRecord[];
  reused: boolean;
};

export type WorkflowContext = {
  repository: RepositoryPaths;
  pins: DependencyPins;
  byond: ByondTools;
  pinnedPython: string;
  profileName: string;
  profile: RiftProfile;
  profiles: Map<string, RiftProfile>;
  recorder: RunRecorder;
  lock: RunLock;
  runId: string;
  runDir: string;
  environment: Record<string, string>;
  networkMode: 'offline' | 'allow';
  processRunner?: ProcessRunner;
  buildProcessRunner?: ProcessRunner;
  serverPort?: number;
  now?: () => number;
  sleep?: (milliseconds: number) => Promise<void>;
  wasCancelled?: () => boolean;
};

export type ResourceSample = {
  timestamp: string;
  role: string;
  pid: number;
  private_bytes: number;
  working_set_bytes: number;
  alive: boolean;
};

export type ResourceMaximum = {
  role: string;
  private_bytes_max: number;
  working_set_bytes_max: number;
  samples: number;
};

export const summarizeResourceSamples = (
  samples: ResourceSample[],
): ResourceMaximum[] => {
  const maxima = new Map<string, ResourceMaximum>();
  for (const sample of samples) {
    const current = maxima.get(sample.role) ?? {
      role: sample.role,
      private_bytes_max: 0,
      working_set_bytes_max: 0,
      samples: 0,
    };
    current.private_bytes_max = Math.max(
      current.private_bytes_max,
      sample.private_bytes,
    );
    current.working_set_bytes_max = Math.max(
      current.working_set_bytes_max,
      sample.working_set_bytes,
    );
    current.samples += 1;
    maxima.set(sample.role, current);
  }
  return [...maxima.values()].sort((left, right) =>
    left.role.localeCompare(right.role),
  );
};

export const assertDmDiagnostics = (combinedOutput: string) => {
  const errorsMatch = /\b(\d+)\s+errors?\b/i.exec(combinedOutput);
  if (!errorsMatch) {
    throw new Error('compile_diagnostics_missing');
  }
  const errors = Number(errorsMatch[1]);
  const warnings = Number(
    /\b(\d+)\s+warnings?\b/i.exec(combinedOutput)?.[1] ?? 0,
  );
  if (errors > 0) {
    throw new Error(`compile_failed: ${errors} errors`);
  }
  return { errors, warnings };
};

const compileHooks = (
  recorder: RunRecorder,
  stage: string,
  output: string[],
): ProcessHooks => ({
  onStart: async (pid) => {
    await recorder.emit('process_started', stage, { role: stage, pid });
  },
  onOutput: async (stream, line) => {
    output.push(line);
    await recorder.appendOutput(stage, stage, stream, line);
  },
  onOwnedPids: async (pids) => {
    await recorder.emit('observation', stage, { owned_pids: pids });
  },
  onSample: async (samples) => {
    await recorder.emit('observation', stage, { resource_samples: samples });
  },
  onFinish: async (result) => {
    await recorder.addProcess(result);
  },
});

const requireFreshArtifact = async (filePath: string) => {
  const stat = await fs.stat(filePath).catch(() => null);
  if (!stat?.isFile() || stat.size === 0) {
    throw new Error(`compile_artifact_missing: ${path.basename(filePath)}`);
  }
};

const collectCompileArtifacts = async (
  sourceDmb: string,
  sourceRsc: string,
  request: CompileRequest,
  freshness: ArtifactRecord['freshness'],
) => {
  const artifactRoot = path.join(
    request.recorder.runDir,
    'artifacts',
    'compile',
  );
  await fs.mkdir(artifactRoot, { recursive: true });
  const dmb = path.join(artifactRoot, 'tgstation.dmb');
  const rsc = path.join(artifactRoot, 'tgstation.rsc');
  await fs.copyFile(sourceDmb, dmb);
  await fs.copyFile(sourceRsc, rsc);
  const artifacts = await Promise.all([
    hashArtifact(dmb, request.recorder.runDir, 'compile', freshness),
    hashArtifact(rsc, request.recorder.runDir, 'compile', freshness),
  ]);
  for (const artifact of artifacts) {
    await request.recorder.addArtifact(artifact);
  }
  return { dmb, rsc, artifacts };
};

export const compileFast = async (
  request: CompileRequest,
): Promise<CompileOutcome> => {
  const scratchBase = path.join(
    request.repository.root,
    `.rift-${request.runId}.test`,
  );
  const scratchDme = `${scratchBase}.dme`;
  const scratchDmb = `${scratchBase}.dmb`;
  const scratchRsc = `${scratchBase}.rsc`;
  for (const scratch of [scratchDme, scratchDmb, scratchRsc]) {
    if (fsSync.existsSync(scratch)) {
      throw new Error(
        `scratch artifact already exists: ${path.basename(scratch)}`,
      );
    }
  }

  await fs.copyFile(request.repository.dme, scratchDme);
  const output: string[] = [];
  try {
    const runner = request.processRunner ?? startOwnedProcess;
    const processResult = await runner(
      {
        role: 'dreammaker',
        executable: request.byond.dm,
        args: [
          '-DCBT',
          ...request.defines.map((value) => `-D${value}`),
          scratchDme,
        ],
        cwd: request.repository.root,
        env: request.environment,
        wallTimeoutMs: request.wallTimeoutMs,
        idleTimeoutMs: request.idleTimeoutMs,
      },
      compileHooks(request.recorder, 'compile', output),
    ).result;
    throwForProcessTermination(processResult, 'compile');
    if (processResult.exitCode !== 0) {
      throw new Error(
        `compile_process_failed: ${processResult.termination} ${String(processResult.exitCode)}`,
      );
    }
    assertDmDiagnostics(output.join('\n'));
    await requireFreshArtifact(scratchDmb);
    await requireFreshArtifact(scratchRsc);
    const collected = await collectCompileArtifacts(
      scratchDmb,
      scratchRsc,
      request,
      'new',
    );
    return { evidence: 'compiler', ...collected, reused: false };
  } finally {
    await Promise.all(
      [scratchDme, scratchDmb, scratchRsc].map((scratch) =>
        fs.rm(scratch, { force: true }),
      ),
    );
  }
};

const ALLOWED_BUILD_TARGETS = new Set([
  'build',
  'icon-cutter',
  'dm-maps-include',
  '--help',
]);

export const invokeBuildTarget = async (
  repository: RepositoryPaths,
  target: string,
  args: string[],
  processOptions: Omit<ProcessSpec, 'executable' | 'args' | 'cwd'>,
  hooks: ProcessHooks,
  processRunner: ProcessRunner = startOwnedProcess,
): Promise<ProcessResult> => {
  if (
    !ALLOWED_BUILD_TARGETS.has(target) ||
    args.some((value) => !/^[A-Za-z0-9_.:/=-]+$/.test(value))
  ) {
    throw new Error('invalid fixed build target');
  }
  const commandProcessor =
    processOptions.env.ComSpec ?? process.env.ComSpec ?? 'cmd.exe';
  return processRunner(
    {
      ...processOptions,
      executable: commandProcessor,
      args: ['/d', '/s', '/c', repository.buildDelegate, target, ...args],
      cwd: repository.root,
    },
    hooks,
  ).result;
};

const externalArtifactMetadata = async (filePath: string) => {
  const stat = await fs.stat(filePath).catch(() => null);
  if (!stat?.isFile() || stat.size === 0) {
    return null;
  }
  return {
    size: stat.size,
    mtimeMs: stat.mtimeMs,
    sha256: await sha256File(filePath),
  };
};

const canonicalArtifactPaths = (repository: RepositoryPaths) => {
  const dmb = path.resolve(repository.root, 'tgstation.dmb');
  const rsc = path.resolve(repository.root, 'tgstation.rsc');
  const root = path.resolve(repository.root);
  for (const [candidate, basename] of [
    [dmb, 'tgstation.dmb'],
    [rsc, 'tgstation.rsc'],
  ] as const) {
    if (
      path.dirname(candidate).toLowerCase() !== root.toLowerCase() ||
      path.basename(candidate) !== basename
    ) {
      throw new Error('canonical artifact path escaped repository root');
    }
  }
  return { dmb, rsc };
};

export const compileFull = async (
  request: CompileRequest & { force: boolean },
): Promise<CompileOutcome> => {
  const canonical = canonicalArtifactPaths(request.repository);
  const before = {
    dmb: await externalArtifactMetadata(canonical.dmb),
    rsc: await externalArtifactMetadata(canonical.rsc),
  };
  const removalBoundary = Date.now();
  if (request.force) {
    await Promise.all([
      fs.rm(canonical.dmb, { force: true }),
      fs.rm(canonical.rsc, { force: true }),
    ]);
  }

  const output: string[] = [];
  const result = await invokeBuildTarget(
    request.repository,
    'build',
    [],
    {
      role: 'full_build',
      env: request.environment,
      wallTimeoutMs: request.wallTimeoutMs,
      idleTimeoutMs: request.idleTimeoutMs,
    },
    compileHooks(request.recorder, 'compile', output),
    request.buildProcessRunner ?? request.processRunner ?? startOwnedProcess,
  );
  throwForProcessTermination(result, 'compile');
  if (result.exitCode !== 0) {
    throw new Error(
      `full_build_failed: ${result.termination} ${String(result.exitCode)}`,
    );
  }
  await requireFreshArtifact(canonical.dmb);
  await requireFreshArtifact(canonical.rsc);
  const after = {
    dmb: await externalArtifactMetadata(canonical.dmb),
    rsc: await externalArtifactMetadata(canonical.rsc),
  };
  if (
    request.force &&
    [after.dmb, after.rsc].some(
      (artifact) => !artifact || artifact.mtimeMs < removalBoundary,
    )
  ) {
    throw new Error('forced build produced stale artifacts');
  }
  const reused =
    before.dmb !== null &&
    before.rsc !== null &&
    before.dmb.sha256 === after.dmb?.sha256 &&
    before.rsc.sha256 === after.rsc?.sha256 &&
    before.dmb.mtimeMs === after.dmb?.mtimeMs &&
    before.rsc.mtimeMs === after.rsc?.mtimeMs;
  const collected = await collectCompileArtifacts(
    canonical.dmb,
    canonical.rsc,
    request,
    reused ? 'reused' : 'rebuilt',
  );
  return { evidence: 'full_build', ...collected, reused };
};

export type Deployment = {
  root: string;
  data: string;
  gameLogDir: string;
  dmb: string;
  rsc: string;
};

export type DeploymentRequest = {
  repository: RepositoryPaths;
  runDir: string;
  profile: RiftProfile;
  compile: CompileOutcome;
  selectedMap: string | null;
};

export const DEPLOY_TREES = [
  ['_maps', '_maps'],
  ['build/behavior_trees', 'build/behavior_trees'],
  ['code/datums/greyscale/json_configs', 'code/datums/greyscale/json_configs'],
  ['icons', 'icons'],
  ['sound/runtime', 'sound/runtime'],
  ['strings', 'strings'],
  ['tgui/public', 'tgui/public'],
  ['tgui/packages/tgfont/dist', 'tgui/packages/tgfont/dist'],
] as const;

const DEPLOY_GLOBS = [
  'modular_nova/**/*.dmm',
  'modular_aphelion/**/*.dmm',
  'modular_nova/**/*.dmi',
  'modular_nova/modules/GAGS/json_configs/**/*.json',
  'modular_nova/modules/GAGS/nsfw/json_configs/**/*.json',
  'modular_aphelion/**/*.dmi',
  'modular_aphelion/**/*.json',
  '*.dll',
] as const;

const copyRelativeFile = async (
  sourceRoot: string,
  destinationRoot: string,
  relativePath: string,
) => {
  const source = path.join(sourceRoot, relativePath);
  const destination = path.join(destinationRoot, relativePath);
  await fs.mkdir(path.dirname(destination), { recursive: true });
  await fs.copyFile(source, destination);
};

const copyDeployGlobs = async (sourceRoot: string, destinationRoot: string) => {
  const copied = new Set<string>();
  for (const pattern of DEPLOY_GLOBS) {
    for await (const relativePath of new Bun.Glob(pattern).scan({
      cwd: sourceRoot,
      onlyFiles: true,
    })) {
      const normalized = relativePath.replaceAll('\\', '/');
      if (!copied.has(normalized)) {
        copied.add(normalized);
        await copyRelativeFile(sourceRoot, destinationRoot, normalized);
      }
    }
  }
};

export const createDeployment = async (
  request: DeploymentRequest,
): Promise<Deployment> => {
  const runRoot = path.resolve(request.runDir);
  const root = path.join(runRoot, 'workspace');
  if (!isContainedPath(runRoot.toLowerCase(), root.toLowerCase())) {
    throw new Error('deployment path escaped run directory');
  }
  await requireFreshArtifact(request.compile.dmb);
  await requireFreshArtifact(request.compile.rsc);
  await fs.mkdir(root, { recursive: false });

  for (const [sourceRelative, destinationRelative] of DEPLOY_TREES) {
    const source = path.join(request.repository.root, sourceRelative);
    if (fsSync.existsSync(source)) {
      await fs.cp(source, path.join(root, destinationRelative), {
        recursive: true,
      });
    }
  }
  await copyDeployGlobs(request.repository.root, root);

  const dmb = path.join(root, 'tgstation.dmb');
  const rsc = path.join(root, 'tgstation.rsc');
  await Promise.all([
    fs.copyFile(request.compile.dmb, dmb),
    fs.copyFile(request.compile.rsc, rsc),
  ]);

  const configRoot = path.join(root, 'config');
  if (request.profile.config_source === 'repository') {
    const repositoryConfig = path.join(request.repository.root, 'config');
    if (fsSync.existsSync(repositoryConfig)) {
      await fs.cp(repositoryConfig, configRoot, { recursive: true });
    } else {
      await fs.mkdir(configRoot, { recursive: true });
    }
  } else {
    await fs.mkdir(configRoot, { recursive: true });
    await fs.copyFile(
      path.join(request.repository.root, 'tools', 'ci', 'ci_config.txt'),
      path.join(configRoot, 'config.txt'),
    );
  }

  const data = path.join(root, 'data');
  const gameLogDir = path.join(data, 'logs', 'rift');
  await fs.mkdir(gameLogDir, { recursive: true });
  const selectedMap = request.selectedMap ?? request.profile.default_map;
  if (selectedMap) {
    const map = validateMapPath(request.repository.root, selectedMap);
    await fs.copyFile(
      path.join(request.repository.root, map),
      path.join(data, 'next_map.json'),
    );
  }

  return { root, data, gameLogDir, dmb, rsc };
};

const COLLECTION_GLOBS = [
  'data/logs/rift/**/*',
  'data/unit_tests.json',
  'data/screenshots_new/**/*',
  'dogmos_panic.log',
] as const;

export const collectDeploymentArtifacts = async (
  deployment: Deployment,
  runDir: string,
  recorder: RunRecorder,
): Promise<ArtifactRecord[]> => {
  const artifacts: ArtifactRecord[] = [];
  const copied = new Set<string>();
  for (const pattern of COLLECTION_GLOBS) {
    for await (const relativePath of new Bun.Glob(pattern).scan({
      cwd: deployment.root,
      onlyFiles: true,
    })) {
      const normalized = relativePath.replaceAll('\\', '/');
      if (copied.has(normalized)) {
        continue;
      }
      copied.add(normalized);
      const destination = path.join(runDir, 'artifacts', normalized);
      await fs.mkdir(path.dirname(destination), { recursive: true });
      await fs.copyFile(path.join(deployment.root, normalized), destination);
      const artifact = await hashArtifact(
        destination,
        runDir,
        'collect',
        'collected',
      );
      artifacts.push(artifact);
      await recorder.addArtifact(artifact);
    }
  }
  artifacts.sort((left, right) => left.path.localeCompare(right.path));
  await fs.writeFile(
    path.join(runDir, 'artifacts', 'manifest.json'),
    `${JSON.stringify(artifacts, null, 2)}\n`,
    'utf8',
  );
  return artifacts;
};

type RemoveTree = (
  target: string,
  options: { recursive: true; force: true },
) => Promise<void>;

export const removeDeployment = async (
  deployment: Deployment,
  runDir: string,
  keepWorkspace: boolean,
  removeTree: RemoveTree = fs.rm,
): Promise<{ passed: boolean; leftovers: string[]; retained: string[] }> => {
  const runRoot = path.resolve(runDir);
  const deploymentRoot = path.resolve(deployment.root);
  if (
    !isContainedPath(runRoot.toLowerCase(), deploymentRoot.toLowerCase()) ||
    path.basename(deploymentRoot) !== 'workspace'
  ) {
    throw new Error('deployment cleanup path escaped run directory');
  }
  if (keepWorkspace) {
    return { passed: true, leftovers: [], retained: ['workspace'] };
  }
  try {
    await removeTree(deploymentRoot, { recursive: true, force: true });
  } catch {
    return {
      passed: false,
      leftovers: [path.relative(runRoot, deploymentRoot).replaceAll('\\', '/')],
      retained: [],
    };
  }
  return fsSync.existsSync(deploymentRoot)
    ? { passed: false, leftovers: ['workspace'], retained: [] }
    : { passed: true, leftovers: [], retained: [] };
};

export type StructuredLogRecord = {
  ts?: string;
  cat?: string;
  msg?: string;
  data?: unknown;
  's-ver'?: string;
};

export type LogObservation = {
  ready: boolean;
  fatalFailures: RiftFailure[];
  runtimeSignatures: Array<{
    signature: string;
    count: number;
    first_seen: string;
  }>;
};

export const matchesLogRule = (
  rule: Omit<LogRule, 'max_occurrences'>,
  record: StructuredLogRecord,
): boolean => {
  if (typeof record.msg !== 'string') {
    return false;
  }
  if (rule.category !== null && record.cat !== rule.category) {
    return false;
  }
  return new RegExp(
    rule.message_pattern,
    rule.case_insensitive ? 'i' : undefined,
  ).test(record.msg);
};

type WatchedLogRecord = {
  file: string;
  record: StructuredLogRecord;
  batchComplete: boolean;
};

type LogFileState = { offset: number; partial: string };
type LogMonitorCursor = {
  files: Map<string, LogFileState>;
  fatalCounts: Map<string, number>;
};

const observationCursors = new WeakMap<LogObservation, LogMonitorCursor>();

const readNewLogRecords = async (
  filePath: string,
  state: LogFileState,
  structured: boolean,
): Promise<StructuredLogRecord[]> => {
  const stat = await fs.stat(filePath).catch(() => null);
  if (!stat?.isFile()) {
    return [];
  }
  if (stat.size < state.offset) {
    state.offset = 0;
    state.partial = '';
  }
  if (stat.size === state.offset) {
    return [];
  }
  const handle = await fs.open(filePath, 'r');
  let bytes: Buffer;
  try {
    bytes = Buffer.alloc(stat.size - state.offset);
    await handle.read(bytes, 0, bytes.length, state.offset);
  } finally {
    await handle.close();
  }
  state.offset = stat.size;
  const text = state.partial + new TextDecoder().decode(bytes);
  const lines = text.split(/\r?\n/);
  state.partial = lines.pop() ?? '';
  const records: StructuredLogRecord[] = [];
  for (const line of lines) {
    if (!line.trim()) {
      continue;
    }
    if (!structured) {
      records.push({ cat: 'runtime', msg: line });
      continue;
    }
    try {
      const value: unknown = JSON.parse(line);
      if (isRecord(value)) {
        records.push(value as StructuredLogRecord);
      }
    } catch {
      // A complete malformed game-log line is not a readiness event.
    }
  }
  return records;
};

export async function* watchGameLogs(options: {
  deployment: Deployment;
  profile: RiftProfile;
  signal?: AbortSignal;
  pollMs?: number;
  startAtEnd?: boolean;
  states?: Map<string, LogFileState>;
}): AsyncGenerator<WatchedLogRecord> {
  const structuredRelative = options.profile.readiness_rule.file.replaceAll(
    '\\',
    '/',
  );
  const structuredPath = path.join(options.deployment.root, structuredRelative);
  const plainPath = path.join(options.deployment.gameLogDir, 'runtime.log');
  const fatalFiles = [
    ...new Set(
      options.profile.fatal_log_rules
        .map((rule) => rule.file.replaceAll('\\', '/'))
        .filter((file) => file !== structuredRelative),
    ),
  ];
  const states = options.states ?? new Map<string, LogFileState>();
  const stateFor = (filePath: string) => {
    let state = states.get(filePath);
    if (!state) {
      state = {
        offset: options.startAtEnd
          ? (fsSync.statSync(filePath, { throwIfNoEntry: false })?.size ?? 0)
          : 0,
        partial: '',
      };
      states.set(filePath, state);
    }
    return state;
  };

  while (!options.signal?.aborted) {
    const structuredExists = fsSync.existsSync(structuredPath);
    const plainExists = fsSync.existsSync(plainPath);
    const selected = structuredExists
      ? [{ path: structuredPath, file: structuredRelative, structured: true }]
      : plainExists && fsSync.existsSync(options.deployment.gameLogDir)
        ? [{ path: plainPath, file: structuredRelative, structured: false }]
        : [];
    for (const file of fatalFiles) {
      const filePath = path.join(options.deployment.root, file);
      if (fsSync.existsSync(filePath)) {
        selected.push({
          path: filePath,
          file,
          structured: file.toLowerCase().endsWith('.json'),
        });
      }
    }
    const pending: Array<{ file: string; record: StructuredLogRecord }> = [];
    for (const source of selected) {
      const records = await readNewLogRecords(
        source.path,
        stateFor(source.path),
        source.structured,
      );
      pending.push(...records.map((record) => ({ file: source.file, record })));
    }
    for (const [index, item] of pending.entries()) {
      yield {
        ...item,
        batchComplete: index === pending.length - 1,
      };
    }
    await Bun.sleep(options.pollMs ?? 25);
  }
}

const childRuleFailure = async (
  profile: RiftProfile,
  process: OwnedProcess,
  continuousOnly = false,
): Promise<RiftFailure | null> => {
  const rules = continuousOnly
    ? profile.required_children.filter(
        (rule) => rule.continuous_after_readiness,
      )
    : profile.required_children;
  if (rules.length === 0) {
    return null;
  }
  const snapshot = await process.snapshot();
  for (const rule of rules) {
    const count = snapshot.filter(
      (entry) =>
        path.basename(entry.name).toLowerCase() ===
        path.basename(rule.process_name).toLowerCase(),
    ).length;
    if (count < rule.min_count) {
      return {
        code: 'required_child_missing',
        stage: 'server',
        message: `${rule.role} count ${count} is below ${rule.min_count}`,
      };
    }
    if (count > rule.max_count) {
      return {
        code: 'required_child_count_mismatch',
        stage: 'server',
        message: `${rule.role} count ${count} exceeds ${rule.max_count}`,
      };
    }
  }
  return null;
};

const observeUntilReady = async (options: {
  deployment: Deployment;
  profile: RiftProfile;
  process: OwnedProcess;
  recorder: RunRecorder;
  signal: AbortSignal;
  cursor: LogMonitorCursor;
}): Promise<LogObservation> => {
  let readinessSeen = false;
  const signatures = new Map<
    string,
    { signature: string; count: number; first_seen: string }
  >();
  for await (const item of watchGameLogs({
    deployment: options.deployment,
    profile: options.profile,
    signal: options.signal,
    states: options.cursor.files,
  })) {
    const { record } = item;
    if (typeof record.msg === 'string' && /runtime error:/i.test(record.msg)) {
      const signature = normalizeRuntimeSignature(record.msg);
      const existing = signatures.get(signature);
      if (existing) {
        existing.count += 1;
      } else {
        signatures.set(signature, {
          signature,
          count: 1,
          first_seen: record.ts ?? new Date().toISOString(),
        });
      }
    }
    for (const rule of options.profile.fatal_log_rules) {
      if (rule.file.replaceAll('\\', '/') !== item.file) {
        continue;
      }
      if (matchesLogRule(rule, record)) {
        const count = (options.cursor.fatalCounts.get(rule.id) ?? 0) + 1;
        options.cursor.fatalCounts.set(rule.id, count);
        if (count > rule.max_occurrences) {
          const failure: RiftFailure = {
            code: rule.id,
            stage: 'server',
            message: `${rule.id} observed ${count} time(s)`,
          };
          await options.recorder.emit('failure', 'server', { ...failure });
          return {
            ready: false,
            fatalFailures: [failure],
            runtimeSignatures: [...signatures.values()],
          };
        }
      }
    }
    if (matchesLogRule(options.profile.readiness_rule, record)) {
      const childFailure = await childRuleFailure(
        options.profile,
        options.process,
      );
      if (childFailure) {
        return {
          ready: false,
          fatalFailures: [childFailure],
          runtimeSignatures: [...signatures.values()],
        };
      }
      await options.recorder.emit('observation', 'server', {
        readiness_rule: options.profile.readiness_rule.id,
        owned_pids: options.process.ownedPids(),
      });
      readinessSeen = true;
    }
    if (readinessSeen && item.batchComplete) {
      return {
        ready: true,
        fatalFailures: [],
        runtimeSignatures: [...signatures.values()],
      };
    }
  }
  throw new Error('readiness monitoring cancelled');
};

export const waitForReadiness = async (options: {
  deployment: Deployment;
  profile: RiftProfile;
  process: OwnedProcess;
  timeoutMs: number;
  recorder: RunRecorder;
}): Promise<LogObservation> => {
  const abort = new AbortController();
  const cursor: LogMonitorCursor = {
    files: new Map(),
    fatalCounts: new Map(),
  };
  let timeout: ReturnType<typeof setTimeout> | null = null;
  const timedOut = new Promise<never>((_resolve, reject) => {
    timeout = setTimeout(
      () =>
        reject(
          new RiftError(
            'readiness_timeout',
            'server',
            'readiness_timeout: deadline elapsed',
            6,
          ),
        ),
      options.timeoutMs,
    );
  });
  try {
    const observation = await Promise.race([
      observeUntilReady({ ...options, signal: abort.signal, cursor }),
      options.process.result.then((result) => {
        throwForProcessTermination(result, 'server');
        throw new Error(
          `process_exited_before_ready: ${result.termination} ${String(result.exitCode)}`,
        );
      }),
      timedOut,
    ]);
    observationCursors.set(observation, cursor);
    return observation;
  } finally {
    if (timeout !== null) {
      clearTimeout(timeout);
    }
    abort.abort();
  }
};

const serverHooks = (recorder: RunRecorder): ProcessHooks => ({
  onStart: async (pid) => {
    await recorder.emit('process_started', 'server', {
      role: 'dreamdaemon',
      pid,
    });
  },
  onOutput: async (stream, line) => {
    await recorder.appendOutput('server', 'dreamdaemon', stream, line);
  },
  onOwnedPids: async (pids) => {
    await recorder.emit('observation', 'server', { owned_pids: pids });
  },
  onSample: async (samples) => {
    await recorder.emit('observation', 'server', {
      resource_samples: samples,
    });
  },
  onFinish: async (result) => {
    await recorder.addProcess(result);
  },
});

export const runServerWorkflow = async (
  context: WorkflowContext,
  command: Extract<RiftCommand, { command: 'run' }>,
): Promise<RiftSummary> => {
  let deployment: Deployment | null = null;
  let server: OwnedProcess | null = null;
  const runtimeSignatures = new Map<
    string,
    { signature: string; count: number; first_seen: string }
  >();
  try {
    await context.recorder.emit('stage_started', 'compile', {
      mode: command.compileMode,
    });
    const request: CompileRequest = {
      runId: context.runId,
      repository: context.repository,
      byond: context.byond,
      recorder: context.recorder,
      environment: context.environment,
      defines: context.profile.compile_defines,
      wallTimeoutMs:
        (command.wallTimeoutSeconds ??
          context.profile.default_timeouts.wall_seconds) * 1000,
      idleTimeoutMs:
        (command.idleTimeoutSeconds ??
          context.profile.default_timeouts.idle_seconds) * 1000,
      processRunner: context.processRunner,
      buildProcessRunner: context.buildProcessRunner,
    };
    let compile: CompileOutcome;
    try {
      compile =
        command.compileMode === 'fast'
          ? await compileFast(request)
          : await compileFull({ ...request, force: false });
    } catch (error) {
      rethrowAsRiftError(error, 'compile_failed', 'compile', 4);
    }
    await context.recorder.emit(
      'stage_finished',
      'compile',
      { evidence: compile.evidence },
      'passed',
    );

    await context.recorder.emit('stage_started', 'deploy', {
      selected_map: command.map ?? context.profile.default_map,
    });
    deployment = await createDeployment({
      repository: context.repository,
      runDir: context.runDir,
      profile: context.profile,
      compile,
      selectedMap: command.map,
    });
    await applyNativeOverlays(
      context.repository.root,
      deployment,
      command.shim,
      command.service,
      context.profileName.startsWith('dogmos'),
    );
    await context.recorder.emit('stage_finished', 'deploy', {}, 'passed');
    await context.recorder.emit('stage_started', 'server', {
      port: command.port,
    });

    const runner = context.processRunner ?? startOwnedProcess;
    server = runner(
      {
        role: 'dreamdaemon',
        executable: context.byond.dreamDaemon,
        args: [
          'tgstation.dmb',
          String(command.port),
          ...context.profile.dreamdaemon_flags,
          '-params',
          'log-directory=rift',
        ],
        cwd: deployment.root,
        env: context.environment,
        wallTimeoutMs:
          (command.wallTimeoutSeconds ??
            context.profile.default_timeouts.wall_seconds) * 1000,
        idleTimeoutMs:
          (command.idleTimeoutSeconds ??
            context.profile.default_timeouts.idle_seconds) * 1000,
        activityPaths: [
          path.join(deployment.gameLogDir, 'runtime.log.json'),
          path.join(deployment.gameLogDir, 'runtime.log'),
        ],
      },
      serverHooks(context.recorder),
    );
    const observation = await waitForReadiness({
      deployment,
      profile: context.profile,
      process: server,
      timeoutMs:
        (command.readinessTimeoutSeconds ??
          context.profile.default_timeouts.readiness_seconds) * 1000,
      recorder: context.recorder,
    });
    if (!observation.ready) {
      for (const failure of observation.fatalFailures) {
        await context.recorder.addFailure(failure);
      }
      await server.stop('requested');
      await collectDeploymentArtifacts(
        deployment,
        context.runDir,
        context.recorder,
      );
      const cleanup = await removeDeployment(
        deployment,
        context.runDir,
        command.keepWorkspace,
      );
      await context.recorder.setCleanup(cleanup);
      return finishRunWithLock(context.recorder, context.lock, 'failed', 5);
    }
    for (const signature of observation.runtimeSignatures) {
      runtimeSignatures.set(signature.signature, { ...signature });
    }

    if (command.runSeconds !== null) {
      const monitorAbort = new AbortController();
      const logMonitor = monitorRuntimeLogs({
        deployment,
        profile: context.profile,
        stage: 'server',
        signal: monitorAbort.signal,
        signatures: runtimeSignatures,
        cursor: observationCursors.get(observation),
      });
      const duration = sleepUntilAborted(
        command.runSeconds * 1000,
        monitorAbort.signal,
      ).then((completed) => ({
        kind: completed ? ('duration' as const) : ('monitor_stopped' as const),
      }));
      const bounded = await Promise.race([
        duration,
        logMonitor.then((failure) => ({
          kind: 'monitor' as const,
          failure,
        })),
        server.result.then((result) => ({ kind: 'exit' as const, result })),
      ]);
      monitorAbort.abort();
      await Promise.allSettled([duration, logMonitor]);
      if (bounded.kind === 'monitor') {
        if (bounded.failure) {
          throw new RiftError(
            bounded.failure.code,
            'server',
            bounded.failure.message,
            5,
          );
        }
        throw new Error('server_monitor_stopped');
      }
      if (bounded.kind === 'exit') {
        throwForProcessTermination(bounded.result, 'server');
        throw new Error(
          `process_exited_before_requested_stop: ${bounded.result.termination} ${String(bounded.result.exitCode)}`,
        );
      }
      if (bounded.kind !== 'duration') {
        throw new Error('server_monitor_stopped');
      }
    }
    await context.recorder.setRuntimeSignatures([
      ...runtimeSignatures.values(),
    ]);
    await server.stop('requested');
    await context.recorder.emit(
      'stage_finished',
      'server',
      { ready: true },
      'ready_then_stopped',
    );
    await collectDeploymentArtifacts(
      deployment,
      context.runDir,
      context.recorder,
    );
    const cleanup = await removeDeployment(
      deployment,
      context.runDir,
      command.keepWorkspace,
    );
    await context.recorder.setCleanup(cleanup);
    if (!cleanup.passed) {
      await context.recorder.addFailure({
        code: 'cleanup_failed',
        stage: 'cleanup',
        message: `workspace cleanup left: ${cleanup.leftovers.join(', ')}`,
      });
      return finishRunWithLock(context.recorder, context.lock, 'failed', 5);
    }
    return finishRunWithLock(
      context.recorder,
      context.lock,
      'ready_then_stopped',
      0,
    );
  } catch (error) {
    await server?.stop('requested').catch(() => undefined);
    await context.recorder
      .setRuntimeSignatures([...runtimeSignatures.values()])
      .catch(() => undefined);
    if (deployment) {
      await collectDeploymentArtifacts(
        deployment,
        context.runDir,
        context.recorder,
      ).catch(() => undefined);
      const cleanup = await removeDeployment(
        deployment,
        context.runDir,
        command.keepWorkspace,
      ).catch(() => ({
        passed: false,
        leftovers: ['workspace'],
        retained: [],
      }));
      await context.recorder.setCleanup(cleanup).catch(() => undefined);
    }
    const message = error instanceof Error ? error.message : String(error);
    const failure = classifyWorkflowFailure(
      error,
      'server',
      'server_failed',
      context.wasCancelled?.() ?? false,
    );
    await context.recorder.addFailure({
      code: failure.code,
      stage: failure.stage,
      message,
    });
    return finishRunWithLock(
      context.recorder,
      context.lock,
      statusForExitCode(failure.exitCode),
      failure.exitCode,
    );
  }
};

const monitorRuntimeLogs = async (options: {
  deployment: Deployment;
  profile: RiftProfile;
  stage: 'server' | 'soak';
  signal: AbortSignal;
  signatures: Map<
    string,
    { signature: string; count: number; first_seen: string }
  >;
  cursor?: LogMonitorCursor;
}): Promise<RiftFailure | null> => {
  const counts = options.cursor?.fatalCounts ?? new Map<string, number>();
  for await (const item of watchGameLogs({
    deployment: options.deployment,
    profile: options.profile,
    signal: options.signal,
    startAtEnd: options.cursor === undefined,
    states: options.cursor?.files,
  })) {
    const { record } = item;
    if (typeof record.msg === 'string' && /runtime error:/i.test(record.msg)) {
      const signature = normalizeRuntimeSignature(record.msg);
      const existing = options.signatures.get(signature);
      if (existing) {
        existing.count += 1;
      } else {
        options.signatures.set(signature, {
          signature,
          count: 1,
          first_seen: record.ts ?? new Date().toISOString(),
        });
      }
    }
    for (const rule of options.profile.fatal_log_rules) {
      if (
        rule.file.replaceAll('\\', '/') !== item.file ||
        !matchesLogRule(rule, record)
      ) {
        continue;
      }
      const count = (counts.get(rule.id) ?? 0) + 1;
      counts.set(rule.id, count);
      if (count > rule.max_occurrences) {
        return {
          code: rule.id,
          stage: options.stage,
          message: `${rule.id} observed ${count} time(s) after readiness`,
        };
      }
    }
  }
  return null;
};

const captureSoakResources = async (options: {
  process: OwnedProcess;
  recorder: RunRecorder;
  samples: ResourceSample[];
  known: Map<number, { role: string; alive: boolean }>;
}) => {
  const timestamp = new Date().toISOString();
  const snapshot = await options.process.snapshot();
  const current = new Map(snapshot.map((entry) => [entry.pid, entry]));
  const observations: ResourceSample[] = [];
  for (const entry of current.values()) {
    const sample: ResourceSample = {
      timestamp,
      role: entry.role,
      pid: entry.pid,
      private_bytes: entry.privateBytes,
      working_set_bytes: entry.workingSetBytes,
      alive: true,
    };
    observations.push(sample);
    options.known.set(entry.pid, { role: entry.role, alive: true });
  }
  for (const [pid, known] of options.known) {
    if (!current.has(pid) && known.alive) {
      observations.push({
        timestamp,
        role: known.role,
        pid,
        private_bytes: 0,
        working_set_bytes: 0,
        alive: false,
      });
      options.known.set(pid, { ...known, alive: false });
    }
  }
  options.samples.push(...observations);
  await options.recorder.emit('observation', 'soak', {
    resource_samples: observations,
  });
};

export const applyNativeOverlays = async (
  repositoryRoot: string,
  deployment: Deployment,
  shim: string | null,
  service: string | null,
  enforceInstalledContract = false,
) => {
  if (shim === null || service === null) {
    return;
  }
  for (const [source, destination] of [
    [shim, 'dogmos.dll'],
    [service, 'dogmosd.exe'],
  ] as const) {
    const resolvedSource = path.isAbsolute(source)
      ? path.resolve(source)
      : path.resolve(repositoryRoot, source);
    const stat = await fs.stat(resolvedSource).catch(() => null);
    if (!stat?.isFile() || stat.size === 0) {
      throw new Error(`overlay_invalid: ${destination}`);
    }
    if (
      enforceInstalledContract &&
      (await sha256File(resolvedSource)) !==
        (await sha256File(path.join(repositoryRoot, destination)))
    ) {
      throw new Error(`dogmos_overlay_contract_mismatch: ${destination}`);
    }
    await fs.copyFile(resolvedSource, path.join(deployment.root, destination));
  }
};

const sleepUntilAborted = async (
  milliseconds: number,
  signal: AbortSignal,
  injectedSleep?: (milliseconds: number) => Promise<void>,
): Promise<boolean> => {
  if (signal.aborted) {
    return false;
  }
  return new Promise<boolean>((resolve, reject) => {
    let settled = false;
    let timeout: ReturnType<typeof setTimeout> | null = null;
    const settle = (completed: boolean) => {
      if (settled) {
        return;
      }
      settled = true;
      signal.removeEventListener('abort', onAbort);
      if (timeout !== null) {
        clearTimeout(timeout);
      }
      resolve(completed);
    };
    const onAbort = () => settle(false);
    signal.addEventListener('abort', onAbort, { once: true });
    if (injectedSleep) {
      void injectedSleep(milliseconds).then(
        () => settle(!signal.aborted),
        (error) => {
          signal.removeEventListener('abort', onAbort);
          reject(error);
        },
      );
      return;
    }
    timeout = setTimeout(() => settle(true), milliseconds);
  });
};

export const runSoakWorkflow = async (
  context: WorkflowContext,
  command: Extract<RiftCommand, { command: 'soak' }>,
): Promise<RiftSummary> => {
  if (command.runSeconds < 30 || command.runSeconds > 1800) {
    throw new Error('soak duration must be 30-1800 seconds');
  }
  let deployment: Deployment | null = null;
  let server: OwnedProcess | null = null;
  const resourceSamples: ResourceSample[] = [];
  const knownProcesses = new Map<number, { role: string; alive: boolean }>();
  const runtimeSignatures = new Map<
    string,
    { signature: string; count: number; first_seen: string }
  >();
  const persistObservations = async () => {
    await context.recorder.setRuntimeSignatures([
      ...runtimeSignatures.values(),
    ]);
    await context.recorder.setResourceMaxima(
      summarizeResourceSamples(resourceSamples),
    );
  };
  try {
    await context.recorder.emit('stage_started', 'compile', {
      mode: command.compileMode,
    });
    const request: CompileRequest = {
      runId: context.runId,
      repository: context.repository,
      byond: context.byond,
      recorder: context.recorder,
      environment: context.environment,
      defines: context.profile.compile_defines,
      wallTimeoutMs:
        (command.wallTimeoutSeconds ??
          context.profile.default_timeouts.wall_seconds) * 1000,
      idleTimeoutMs:
        (command.idleTimeoutSeconds ??
          context.profile.default_timeouts.idle_seconds) * 1000,
      processRunner: context.processRunner,
      buildProcessRunner: context.buildProcessRunner,
    };
    let compile: CompileOutcome;
    try {
      compile =
        command.compileMode === 'fast'
          ? await compileFast(request)
          : await compileFull({ ...request, force: false });
    } catch (error) {
      rethrowAsRiftError(error, 'compile_failed', 'compile', 4);
    }
    await context.recorder.emit(
      'stage_finished',
      'compile',
      { evidence: compile.evidence },
      'passed',
    );
    await context.recorder.emit('stage_started', 'deploy', {
      selected_map: command.map ?? context.profile.default_map,
    });
    deployment = await createDeployment({
      repository: context.repository,
      runDir: context.runDir,
      profile: context.profile,
      compile,
      selectedMap: command.map,
    });
    await applyNativeOverlays(
      context.repository.root,
      deployment,
      command.shim,
      command.service,
      context.profileName.startsWith('dogmos'),
    );
    await context.recorder.emit('stage_finished', 'deploy', {}, 'passed');
    await context.recorder.emit('stage_started', 'soak', {
      duration_seconds: command.runSeconds,
    });

    const serverPort = context.serverPort ?? (await findAvailableTcpPort());
    const runner = context.processRunner ?? startOwnedProcess;
    server = runner(
      {
        role: 'dreamdaemon',
        executable: context.byond.dreamDaemon,
        args: [
          'tgstation.dmb',
          String(serverPort),
          ...context.profile.dreamdaemon_flags,
          '-params',
          'log-directory=rift',
        ],
        cwd: deployment.root,
        env: context.environment,
        wallTimeoutMs:
          (command.wallTimeoutSeconds ??
            context.profile.default_timeouts.wall_seconds) * 1000,
        idleTimeoutMs:
          (command.idleTimeoutSeconds ??
            context.profile.default_timeouts.idle_seconds) * 1000,
        activityPaths: [
          path.join(deployment.gameLogDir, 'runtime.log.json'),
          path.join(deployment.gameLogDir, 'runtime.log'),
        ],
      },
      serverHooks(context.recorder),
    );
    const readiness = await waitForReadiness({
      deployment,
      profile: context.profile,
      process: server,
      timeoutMs:
        (command.readinessTimeoutSeconds ??
          context.profile.default_timeouts.readiness_seconds) * 1000,
      recorder: context.recorder,
    });
    for (const signature of readiness.runtimeSignatures) {
      runtimeSignatures.set(signature.signature, { ...signature });
    }
    if (!readiness.ready) {
      throw new Error(
        readiness.fatalFailures[0]?.code ?? 'process_exited_before_ready',
      );
    }

    const monitorAbort = new AbortController();
    const logMonitor = monitorRuntimeLogs({
      deployment,
      profile: context.profile,
      stage: 'soak',
      signal: monitorAbort.signal,
      signatures: runtimeSignatures,
      cursor: observationCursors.get(readiness),
    });
    const now = context.now ?? Date.now;
    const durationMs = command.runSeconds * 1000;
    const intervalMs = context.profile.resource_sample_seconds * 1000;
    const startedAt = now();
    const duration = (async () => {
      for (;;) {
        if (monitorAbort.signal.aborted) {
          return { kind: 'monitor_stopped' as const };
        }
        await captureSoakResources({
          process: server!,
          recorder: context.recorder,
          samples: resourceSamples,
          known: knownProcesses,
        });
        const childFailure = await childRuleFailure(
          context.profile,
          server!,
          true,
        );
        if (childFailure) {
          return { kind: 'failure' as const, failure: childFailure };
        }
        const remaining = durationMs - (now() - startedAt);
        if (remaining <= 0) {
          return { kind: 'duration' as const };
        }
        const completed = await sleepUntilAborted(
          Math.min(intervalMs, remaining),
          monitorAbort.signal,
          context.sleep,
        );
        if (!completed) {
          return { kind: 'monitor_stopped' as const };
        }
      }
    })();
    const outcome = await Promise.race([
      duration,
      logMonitor.then((failure) =>
        failure
          ? { kind: 'failure' as const, failure }
          : { kind: 'monitor_stopped' as const },
      ),
      server.result.then((result) => ({ kind: 'exit' as const, result })),
    ]);
    monitorAbort.abort();
    await Promise.allSettled([duration, logMonitor]);
    if (outcome.kind === 'failure') {
      throw new RiftError(
        outcome.failure.code,
        'soak',
        outcome.failure.message,
        5,
      );
    }
    if (outcome.kind === 'exit') {
      throwForProcessTermination(outcome.result, 'soak');
      throw new Error(
        `process_exited_before_requested_stop: ${outcome.result.termination} ${String(outcome.result.exitCode)}`,
      );
    }
    if (outcome.kind !== 'duration') {
      throw new Error('soak_monitor_stopped');
    }

    await server.stop('requested');
    await persistObservations();
    await context.recorder.emit(
      'stage_finished',
      'soak',
      { duration_seconds: command.runSeconds },
      'passed',
    );
    await collectDeploymentArtifacts(
      deployment,
      context.runDir,
      context.recorder,
    );
    const cleanup = await removeDeployment(
      deployment,
      context.runDir,
      command.keepWorkspace,
    );
    await context.recorder.setCleanup(cleanup);
    if (!cleanup.passed) {
      throw new Error(`cleanup_failed: ${cleanup.leftovers.join(', ')}`);
    }
    return finishRunWithLock(context.recorder, context.lock, 'passed', 0);
  } catch (error) {
    await server?.stop('requested').catch(() => undefined);
    await persistObservations().catch(() => undefined);
    if (deployment) {
      await collectDeploymentArtifacts(
        deployment,
        context.runDir,
        context.recorder,
      ).catch(() => undefined);
      const cleanup = await removeDeployment(
        deployment,
        context.runDir,
        command.keepWorkspace,
      ).catch(() => ({
        passed: false,
        leftovers: ['workspace'],
        retained: [],
      }));
      await context.recorder.setCleanup(cleanup).catch(() => undefined);
    }
    const message = error instanceof Error ? error.message : String(error);
    const failure = classifyWorkflowFailure(
      error,
      'soak',
      'soak_failed',
      context.wasCancelled?.() ?? false,
    );
    await context.recorder.addFailure({
      code: failure.code,
      stage: failure.stage,
      message,
    });
    return finishRunWithLock(
      context.recorder,
      context.lock,
      statusForExitCode(failure.exitCode),
      failure.exitCode,
    );
  }
};

export type UnitTestResult = {
  duration: number;
  name: string;
  message: string;
  runtimes: number;
  status: 0 | 1 | 2;
};

export const validateTestProfile = (profile: RiftProfile): void => {
  const requiredArtifacts = new Set(
    profile.artifact_rules
      .filter((rule) => rule.required && rule.nonempty)
      .map((rule) => rule.path.replaceAll('\\', '/').toLowerCase()),
  );
  if (
    profile.config_source !== 'ci' ||
    !profile.dreamdaemon_flags.some(
      (flag) => flag.toLowerCase() === '-close',
    ) ||
    !requiredArtifacts.has('data/unit_tests.json') ||
    !requiredArtifacts.has('data/logs/rift/clean_run.lk')
  ) {
    throw new Error(
      'test profile must use CI config, natural close, and required nonempty unit-test and clean-run artifacts',
    );
  }
};

export const waitForTestCompletion = async (options: {
  deployment: Deployment;
  profile: RiftProfile;
  process: OwnedProcess;
  recorder: RunRecorder;
  readiness: LogObservation;
}): Promise<{
  processResult: ProcessResult;
  runtimeSignatures: LogObservation['runtimeSignatures'];
}> => {
  const signatures = new Map(
    options.readiness.runtimeSignatures.map((signature) => [
      signature.signature,
      { ...signature },
    ]),
  );
  const abort = new AbortController();
  const monitor = monitorRuntimeLogs({
    deployment: options.deployment,
    profile: options.profile,
    stage: 'server',
    signal: abort.signal,
    signatures,
    cursor: observationCursors.get(options.readiness),
  });
  try {
    const outcome = await Promise.race([
      monitor.then((failure) => ({ kind: 'monitor' as const, failure })),
      options.process.result.then((result) => ({
        kind: 'exit' as const,
        result,
      })),
    ]);
    if (outcome.kind === 'monitor') {
      if (outcome.failure) {
        throw new RiftError(
          outcome.failure.code,
          'test',
          outcome.failure.message,
          5,
        );
      }
      throw new Error('unit_test_monitor_stopped');
    }
    const finalObservation = await Promise.race([
      monitor.then((failure) => ({ failure })),
      Bun.sleep(50).then(() => ({ failure: null })),
    ]);
    if (finalObservation.failure) {
      throw new RiftError(
        finalObservation.failure.code,
        'test',
        finalObservation.failure.message,
        5,
      );
    }
    throwForProcessTermination(outcome.result, 'test');
    return {
      processResult: outcome.result,
      runtimeSignatures: [...signatures.values()],
    };
  } finally {
    abort.abort();
    await monitor.catch(() => undefined);
  }
};

export type UnitTestSummary = {
  recorded: number;
  passed: number;
  failed: number;
  skipped: number;
  failures: UnitTestResult[];
};

export const parseUnitTestResults = (value: unknown): UnitTestSummary => {
  if (!isRecord(value) || Array.isArray(value)) {
    throw new Error('unit_test_result_invalid: expected result object');
  }
  const results: UnitTestResult[] = [];
  const names = new Set<string>();
  for (const result of Object.values(value)) {
    if (!isRecord(result) || Array.isArray(result)) {
      throw new Error('unit_test_result_invalid: expected test result');
    }
    const keys = Object.keys(result).sort();
    if (
      keys.length !== 5 ||
      keys[0] !== 'duration' ||
      keys[1] !== 'message' ||
      keys[2] !== 'name' ||
      keys[3] !== 'runtimes' ||
      keys[4] !== 'status' ||
      typeof result.duration !== 'number' ||
      !Number.isFinite(result.duration) ||
      result.duration < 0 ||
      typeof result.name !== 'string' ||
      result.name.length === 0 ||
      typeof result.message !== 'string' ||
      !Number.isInteger(result.runtimes) ||
      (result.runtimes as number) < 0 ||
      !Number.isInteger(result.status) ||
      ![0, 1, 2].includes(result.status as number) ||
      names.has(result.name)
    ) {
      throw new Error('unit_test_result_invalid: malformed test result');
    }
    names.add(result.name);
    results.push(result as UnitTestResult);
  }
  return {
    recorded: results.length,
    passed: results.filter((result) => result.status === 0).length,
    failed: results.filter((result) => result.status === 1).length,
    skipped: results.filter((result) => result.status === 2).length,
    failures: results.filter((result) => result.status === 1),
  };
};

const invokeTestBuildPrerequisites = async (request: CompileRequest) => {
  const output: string[] = [];
  const help = await invokeBuildTarget(
    request.repository,
    '--help',
    [],
    {
      role: 'build_contract',
      env: request.environment,
      wallTimeoutMs: request.wallTimeoutMs,
      idleTimeoutMs: request.idleTimeoutMs,
    },
    compileHooks(request.recorder, 'compile', output),
    request.buildProcessRunner ?? startOwnedProcess,
  );
  throwForProcessTermination(help, 'compile');
  if (
    ![0, 1].includes(help.exitCode ?? -1) ||
    !/(^|\s)icon-cutter($|\s)/m.test(output.join('\n'))
  ) {
    throw new Error('build_contract_mismatch: icon-cutter target missing');
  }
  const targets = ['icon-cutter'];
  if (request.defines.includes('ALL_MAPS')) {
    if (!/(^|\s)dm-maps-include($|\s)/m.test(output.join('\n'))) {
      throw new Error(
        'build_contract_mismatch: dm-maps-include target missing',
      );
    }
    targets.unshift('dm-maps-include');
  }
  for (const target of targets) {
    const result = await invokeBuildTarget(
      request.repository,
      target,
      [],
      {
        role: target,
        env: request.environment,
        wallTimeoutMs: request.wallTimeoutMs,
        idleTimeoutMs: request.idleTimeoutMs,
      },
      compileHooks(request.recorder, 'compile', []),
      request.buildProcessRunner ?? startOwnedProcess,
    );
    throwForProcessTermination(result, 'compile');
    if (result.exitCode !== 0) {
      throw new Error(`build_failed: ${target}`);
    }
  }
};

export const prepareUnitTestCompile = async (
  request: CompileRequest,
  focus: string[],
): Promise<CompileOutcome> => {
  await invokeTestBuildPrerequisites(request);
  const scratchBase = path.join(
    request.repository.root,
    `.rift-${request.runId}.test`,
  );
  const scratchDme = `${scratchBase}.dme`;
  const scratchDmb = `${scratchBase}.dmb`;
  const scratchRsc = `${scratchBase}.rsc`;
  for (const scratch of [scratchDme, scratchDmb, scratchRsc]) {
    if (fsSync.existsSync(scratch)) {
      throw new Error(
        `scratch artifact already exists: ${path.basename(scratch)}`,
      );
    }
  }
  await fs.copyFile(request.repository.dme, scratchDme);
  if (focus.length > 0) {
    await fs.appendFile(
      scratchDme,
      `${focus.map((value) => `TEST_FOCUS(${validateFocusType(value)})`).join('\n')}\n`,
      'utf8',
    );
  }
  const output: string[] = [];
  try {
    const runner = request.processRunner ?? startOwnedProcess;
    const processResult = await runner(
      {
        role: 'dreammaker',
        executable: request.byond.dm,
        args: [
          '-DCBT',
          '-DCIBUILDING',
          ...request.defines.map((value) => `-D${value}`),
          scratchDme,
        ],
        cwd: request.repository.root,
        env: request.environment,
        wallTimeoutMs: request.wallTimeoutMs,
        idleTimeoutMs: request.idleTimeoutMs,
      },
      compileHooks(request.recorder, 'compile', output),
    ).result;
    throwForProcessTermination(processResult, 'compile');
    if (processResult.exitCode !== 0) {
      throw new Error(
        `compile_process_failed: ${processResult.termination} ${String(processResult.exitCode)}`,
      );
    }
    assertDmDiagnostics(output.join('\n'));
    await requireFreshArtifact(scratchDmb);
    await requireFreshArtifact(scratchRsc);
    const collected = await collectCompileArtifacts(
      scratchDmb,
      scratchRsc,
      request,
      'new',
    );
    return { evidence: 'compiler', ...collected, reused: false };
  } finally {
    await Promise.all(
      [scratchDme, scratchDmb, scratchRsc].map((scratch) =>
        fs.rm(scratch, { force: true }),
      ),
    );
  }
};

const requireProfileArtifacts = async (
  deployment: Deployment,
  profile: RiftProfile,
) => {
  for (const rule of profile.artifact_rules) {
    const artifactPath = path.join(deployment.root, rule.path);
    const stat = await fs.stat(artifactPath).catch(() => null);
    if (rule.required && !stat?.isFile()) {
      throw new Error(`artifact_missing: ${rule.id}`);
    }
    if (rule.nonempty && stat?.isFile() && stat.size === 0) {
      throw new Error(`artifact_missing: ${rule.id} is empty`);
    }
  }
};

const findAvailableTcpPort = (): Promise<number> =>
  new Promise((resolve, reject) => {
    const listener = net.createServer();
    listener.once('error', reject);
    listener.listen(0, '127.0.0.1', () => {
      const address = listener.address();
      if (!address || typeof address === 'string') {
        listener.close();
        reject(new Error('tool_not_found: failed to allocate test port'));
        return;
      }
      listener.close((error) => {
        if (error) {
          reject(error);
        } else {
          resolve(address.port);
        }
      });
    });
  });

export const runTestWorkflow = async (
  context: WorkflowContext,
  command: Extract<RiftCommand, { command: 'test' }>,
): Promise<RiftSummary> => {
  let deployment: Deployment | null = null;
  let server: OwnedProcess | null = null;
  try {
    validateTestProfile(context.profile);
    await context.recorder.emit('stage_started', 'compile', {
      mode: 'unit_test',
    });
    let compile: CompileOutcome;
    try {
      compile = await prepareUnitTestCompile(
        {
          runId: context.runId,
          repository: context.repository,
          byond: context.byond,
          recorder: context.recorder,
          environment: context.environment,
          defines: context.profile.compile_defines,
          wallTimeoutMs:
            (command.wallTimeoutSeconds ??
              context.profile.default_timeouts.wall_seconds) * 1000,
          idleTimeoutMs:
            (command.idleTimeoutSeconds ??
              context.profile.default_timeouts.idle_seconds) * 1000,
          processRunner: context.processRunner,
          buildProcessRunner: context.buildProcessRunner,
        },
        command.focus,
      );
    } catch (error) {
      rethrowAsRiftError(error, 'compile_failed', 'compile', 4);
    }
    await context.recorder.emit(
      'stage_finished',
      'compile',
      { evidence: compile.evidence },
      'passed',
    );
    await context.recorder.emit('stage_started', 'deploy', {
      selected_map: command.map ?? context.profile.default_map,
    });
    deployment = await createDeployment({
      repository: context.repository,
      runDir: context.runDir,
      profile: context.profile,
      compile,
      selectedMap: command.map,
    });
    await applyNativeOverlays(
      context.repository.root,
      deployment,
      command.shim,
      command.service,
      context.profileName.startsWith('dogmos'),
    );
    await context.recorder.emit('stage_finished', 'deploy', {}, 'passed');
    await context.recorder.emit('stage_started', 'test', {
      focus: [...command.focus],
    });
    const serverPort = context.serverPort ?? (await findAvailableTcpPort());
    if (
      !Number.isInteger(serverPort) ||
      serverPort < 1 ||
      serverPort > 65_535
    ) {
      throw new Error('usage_error: invalid test server port');
    }
    const runner = context.processRunner ?? startOwnedProcess;
    server = runner(
      {
        role: 'dreamdaemon',
        executable: context.byond.dreamDaemon,
        args: [
          'tgstation.dmb',
          String(serverPort),
          ...context.profile.dreamdaemon_flags,
          '-params',
          'log-directory=rift',
        ],
        cwd: deployment.root,
        env: context.environment,
        wallTimeoutMs:
          (command.wallTimeoutSeconds ??
            context.profile.default_timeouts.wall_seconds) * 1000,
        idleTimeoutMs:
          (command.idleTimeoutSeconds ??
            context.profile.default_timeouts.idle_seconds) * 1000,
        activityPaths: [
          path.join(deployment.gameLogDir, 'runtime.log.json'),
          path.join(deployment.data, 'unit_tests.json'),
        ],
      },
      serverHooks(context.recorder),
    );
    const observation = await waitForReadiness({
      deployment,
      profile: context.profile,
      process: server,
      timeoutMs:
        (command.readinessTimeoutSeconds ??
          context.profile.default_timeouts.readiness_seconds) * 1000,
      recorder: context.recorder,
    });
    if (!observation.ready || observation.runtimeSignatures.length > 0) {
      throw new Error(observation.fatalFailures[0]?.code ?? 'runtime_error');
    }
    const completion = await waitForTestCompletion({
      deployment,
      profile: context.profile,
      process: server,
      recorder: context.recorder,
      readiness: observation,
    });
    await context.recorder.setRuntimeSignatures(completion.runtimeSignatures);
    const processResult = completion.processResult;
    if (processResult.termination !== 'natural') {
      throw new Error(
        `unit_test_process_failed: ${processResult.termination} ${String(processResult.exitCode)}`,
      );
    }
    const resultPath = path.join(deployment.data, 'unit_tests.json');
    const rawResults = await Bun.file(resultPath)
      .json()
      .catch(() => {
        throw new Error('unit_test_result_invalid: unreadable JSON');
      });
    const tests = parseUnitTestResults(rawResults);
    await context.recorder.setTests({
      recorded: tests.recorded,
      passed: tests.passed,
      failed: tests.failed,
      skipped: tests.skipped,
    });
    const minimum =
      command.minimumTests ??
      (command.focus.length > 0
        ? command.focus.length
        : context.profile.minimum_tests);
    if (tests.recorded < minimum) {
      throw new Error(
        `unit_test_count_below_minimum: ${tests.recorded} < ${minimum}`,
      );
    }
    if (tests.failed > 0) {
      throw new Error(
        `unit_test_failed: ${tests.failures[0]?.name ?? 'unknown test'}`,
      );
    }
    await requireProfileArtifacts(deployment, context.profile);
    await context.recorder.emit(
      'stage_finished',
      'test',
      { recorded: tests.recorded },
      'passed',
    );
    await collectDeploymentArtifacts(
      deployment,
      context.runDir,
      context.recorder,
    );
    const cleanup = await removeDeployment(
      deployment,
      context.runDir,
      command.keepWorkspace,
    );
    await context.recorder.setCleanup(cleanup);
    if (!cleanup.passed) {
      throw new Error(`cleanup_failed: ${cleanup.leftovers.join(', ')}`);
    }
    return finishRunWithLock(context.recorder, context.lock, 'passed', 0);
  } catch (error) {
    await server?.stop('requested').catch(() => undefined);
    if (deployment) {
      await collectDeploymentArtifacts(
        deployment,
        context.runDir,
        context.recorder,
      ).catch(() => undefined);
      const cleanup = await removeDeployment(
        deployment,
        context.runDir,
        command.keepWorkspace,
      ).catch(() => ({
        passed: false,
        leftovers: ['workspace'],
        retained: [],
      }));
      await context.recorder.setCleanup(cleanup).catch(() => undefined);
    }
    const message = error instanceof Error ? error.message : String(error);
    const failure = classifyWorkflowFailure(
      error,
      'test',
      'unit_test_failed',
      context.wasCancelled?.() ?? false,
    );
    await context.recorder.addFailure({
      code: failure.code,
      stage: failure.stage,
      message,
    });
    return finishRunWithLock(
      context.recorder,
      context.lock,
      statusForExitCode(failure.exitCode),
      failure.exitCode,
    );
  }
};

export const allocateRun = async (
  runsRoot: string,
): Promise<{ runId: string; runDir: string }> => {
  await fs.mkdir(runsRoot, { recursive: true });
  for (;;) {
    const timestamp = new Date()
      .toISOString()
      .replaceAll('-', '')
      .replaceAll(':', '')
      .replace(/\.\d{3}Z$/, 'Z');
    const suffix = crypto.getRandomValues(new Uint8Array(4)).toHex();
    const runId = `${timestamp}-${suffix}`;
    const runDir = path.join(runsRoot, runId);
    try {
      await fs.mkdir(runDir, { recursive: false });
      return { runId, runDir };
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'EEXIST') {
        throw error;
      }
    }
  }
};

export type LockRecord = {
  schema_version: 1;
  token: string;
  pid: number;
  command: string;
  run_id: string;
  started_at: string;
};

export type RunLock = {
  path: string;
  record: LockRecord;
  release: () => Promise<void>;
};

const defaultProcessExists = (pid: number) => {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return (error as NodeJS.ErrnoException).code === 'EPERM';
  }
};

const parseLockRecord = (raw: string): LockRecord => {
  let value: unknown;
  try {
    value = JSON.parse(raw);
  } catch {
    throw new Error('invalid RIFT workflow lock');
  }
  if (
    !isRecord(value) ||
    value.schema_version !== 1 ||
    typeof value.token !== 'string' ||
    !Number.isInteger(value.pid) ||
    typeof value.command !== 'string' ||
    typeof value.run_id !== 'string' ||
    typeof value.started_at !== 'string'
  ) {
    throw new Error('invalid RIFT workflow lock');
  }
  return value as LockRecord;
};

const readLockRecord = async (lockPath: string): Promise<LockRecord> =>
  parseLockRecord(await fs.readFile(lockPath, 'utf8'));

const tryReadLockSnapshot = async (
  lockPath: string,
): Promise<{ raw: string; record: LockRecord | null } | null> => {
  let raw: string;
  try {
    raw = await fs.readFile(lockPath, 'utf8');
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
      return null;
    }
    throw error;
  }
  try {
    return { raw, record: parseLockRecord(raw) };
  } catch {
    return { raw, record: null };
  }
};

const acquireReapGuard = async (
  guardPath: string,
): Promise<(() => Promise<void>) | null> => {
  const token = crypto.randomUUID().replaceAll('-', '');
  const guard = `${JSON.stringify({
    schema_version: 1,
    token,
    pid: process.pid,
    started_at: new Date().toISOString(),
  })}\n`;
  const candidatePath = `${guardPath}.${token}.tmp`;
  try {
    const handle = await fs.open(candidatePath, 'wx');
    try {
      await handle.writeFile(guard, 'utf8');
      await handle.sync();
    } finally {
      await handle.close();
    }
    await fs.link(candidatePath, guardPath);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'EEXIST') {
      return null;
    }
    throw error;
  } finally {
    await fs.rm(candidatePath, { force: true });
  }
  return async () => {
    const current = await fs.readFile(guardPath, 'utf8').catch(() => '');
    if (current === guard) {
      await fs.rm(guardPath, { force: true });
    }
  };
};

const clearAbandonedReapGuard = async (
  guardPath: string,
  processExists: (pid: number) => boolean,
): Promise<boolean> => {
  let raw: string;
  try {
    raw = await fs.readFile(guardPath, 'utf8');
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
      return true;
    }
    throw error;
  }
  let pid = 0;
  let startedAt = 0;
  try {
    const value = JSON.parse(raw) as Record<string, unknown>;
    if (value.schema_version === 1 && typeof value.token === 'string') {
      pid = Number(value.pid);
      startedAt = Date.parse(String(value.started_at));
    }
  } catch {
    // A published guard is complete, so malformed content is abandoned.
  }
  const guardExpired =
    !Number.isFinite(startedAt) || Date.now() - startedAt > 60_000;
  if (Number.isInteger(pid) && pid > 0 && processExists(pid) && !guardExpired) {
    return false;
  }
  const current = await fs.readFile(guardPath, 'utf8').catch(() => '');
  if (current !== raw) {
    return false;
  }
  await fs.rm(guardPath, { force: true });
  return true;
};

export const archiveStaleLock = async (
  runsRoot: string,
  lockPath: string,
  record: LockRecord,
): Promise<string> => {
  const archiveRoot = path.join(runsRoot, 'stale-locks');
  await fs.mkdir(archiveRoot, { recursive: true });
  const started =
    record.started_at.replaceAll(/\D/g, '').slice(0, 14) || 'unknown';
  const archivePath = path.join(archiveRoot, `${started}-${record.token}.json`);
  await fs.rename(lockPath, archivePath);
  return archivePath;
};

export const acquireRunLock = async (
  runsRoot: string,
  command: string,
  runId: string,
  waitSeconds: number,
  processExists: (pid: number) => boolean = defaultProcessExists,
): Promise<RunLock> => {
  await fs.mkdir(runsRoot, { recursive: true });
  const lockPath = path.join(runsRoot, '.active.lock');
  const guardPath = path.join(runsRoot, '.active.lock.reap');
  const deadline = Date.now() + waitSeconds * 1000;

  for (;;) {
    if (fsSync.existsSync(guardPath)) {
      if (await clearAbandonedReapGuard(guardPath, processExists)) {
        continue;
      }
      if (Date.now() >= deadline) {
        throw new Error('RIFT workflow lock maintenance is active');
      }
      await Bun.sleep(Math.min(25, Math.max(1, deadline - Date.now())));
      continue;
    }
    const record: LockRecord = {
      schema_version: 1,
      token: crypto.randomUUID().replaceAll('-', ''),
      pid: process.pid,
      command,
      run_id: runId,
      started_at: new Date().toISOString(),
    };
    try {
      const handle = await fs.open(lockPath, 'wx');
      try {
        await handle.writeFile(`${JSON.stringify(record)}\n`, 'utf8');
        await handle.sync();
      } finally {
        await handle.close();
      }
      if (fsSync.existsSync(guardPath)) {
        const current = await readLockRecord(lockPath).catch(() => null);
        if (current?.token === record.token) {
          await fs.rm(lockPath, { force: true });
        }
        if (Date.now() >= deadline) {
          throw new Error('RIFT workflow lock maintenance is active');
        }
        await Bun.sleep(Math.min(25, Math.max(1, deadline - Date.now())));
        continue;
      }
      return {
        path: lockPath,
        record,
        release: async () => {
          let current: LockRecord;
          try {
            current = await readLockRecord(lockPath);
          } catch (error) {
            if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
              return;
            }
            throw error;
          }
          if (current.token === record.token) {
            await fs.unlink(lockPath).catch((error) => {
              if ((error as NodeJS.ErrnoException).code !== 'ENOENT') {
                throw error;
              }
            });
          }
        },
      };
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== 'EEXIST') {
        throw error;
      }
    }

    const snapshot = await tryReadLockSnapshot(lockPath);
    if (snapshot === null) {
      continue;
    }
    const existing = snapshot.record;
    if (existing === null || !processExists(existing.pid)) {
      const releaseGuard = await acquireReapGuard(guardPath);
      if (!releaseGuard) {
        continue;
      }
      try {
        const guarded = await tryReadLockSnapshot(lockPath);
        if (guarded === null || guarded.raw !== snapshot.raw) {
          continue;
        }
        if (guarded.record && processExists(guarded.record.pid)) {
          continue;
        }
        const archivalRecord = guarded.record ?? {
          schema_version: 1,
          token: `malformed-${crypto.randomUUID().replaceAll('-', '')}`,
          pid: 0,
          command: 'unknown',
          run_id: 'unknown',
          started_at: new Date().toISOString(),
        };
        await archiveStaleLock(runsRoot, lockPath, archivalRecord);
      } finally {
        await releaseGuard();
      }
      continue;
    }
    if (Date.now() >= deadline) {
      throw new Error(
        `RIFT workflow lock is active: ${existing.command} ${existing.run_id}`,
      );
    }
    await Bun.sleep(Math.min(250, Math.max(1, deadline - Date.now())));
  }
};

export const finishRunWithLock = async (
  recorder: RunRecorder,
  lock: RunLock,
  status: Parameters<RunRecorder['finish']>[0],
  exitCode: number,
): Promise<RiftSummary> => {
  try {
    await lock.release();
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    await recorder.addCleanupLeftover('.active.lock');
    await recorder.addFailure({
      code: 'lock_release_failed',
      stage: 'cleanup',
      message,
    });
    return recorder.finish('failed', 5);
  }
  return recorder.finish(status, exitCode);
};

export type DoctorObservation = {
  repository_qualified: boolean;
  revision: string;
  dirty: boolean;
  pins: DependencyPins;
  bun_version: string;
  byond_version: string;
  build_contract: 'valid' | 'invalid';
  offline_ready: boolean;
  canonical_artifacts: ArtifactRecord[];
  lock: 'none' | 'active' | 'stale';
  stale_scratch: string[];
  platform: 'windows';
};

export type DoctorWorkflowContext = {
  repository: RepositoryPaths;
  pins: DependencyPins;
  byond: ByondTools;
  bunVersion: string;
  offlineReady: boolean;
  recorder: RunRecorder;
  runId: string;
  runDir: string;
  environment: Record<string, string>;
  processRunner?: ProcessRunner;
  processExists?: (pid: number) => boolean;
};

const runDoctorGit = async (
  context: DoctorWorkflowContext,
  role: string,
  args: string[],
): Promise<string> => {
  const output: string[] = [];
  const runner = context.processRunner ?? startOwnedProcess;
  const processHandle = runner(
    {
      role,
      executable: 'git.exe',
      args,
      cwd: context.repository.root,
      env: context.environment,
      wallTimeoutMs: 30_000,
      idleTimeoutMs: 30_000,
    },
    {
      onStart: async (pid) => {
        await context.recorder.emit('process_started', 'doctor', {
          role,
          pid,
        });
      },
      onOutput: async (stream, line) => {
        output.push(line);
        await context.recorder.appendOutput('doctor', role, stream, line);
      },
      onOwnedPids: async (pids) => {
        await context.recorder.emit('observation', 'doctor', {
          role,
          owned_pids: pids,
        });
      },
      onSample: async (samples) => {
        await context.recorder.emit('observation', 'doctor', {
          role,
          resource_samples: samples,
        });
      },
      onFinish: async (result) => {
        await context.recorder.addProcess(result);
      },
    },
  );
  const result = await processHandle.result;
  if (result.termination !== 'natural' || result.exitCode !== 0) {
    throw new Error(
      `repository_contract_mismatch: git ${args[0]} failed (${result.termination} ${String(result.exitCode)})`,
    );
  }
  return output.join('\n').trim();
};

const inspectCanonicalArtifacts = async (
  repository: RepositoryPaths,
): Promise<ArtifactRecord[]> => {
  const artifacts: ArtifactRecord[] = [];
  for (const name of ['tgstation.dmb', 'tgstation.rsc']) {
    const artifactPath = path.join(repository.root, name);
    const stat = await fs.stat(artifactPath).catch(() => null);
    if (!stat?.isFile()) {
      continue;
    }
    artifacts.push({
      path: `repository/${name}`,
      size: stat.size,
      sha256: await sha256File(artifactPath),
      stage: 'doctor',
      freshness: 'reused',
      modified_at: stat.mtime.toISOString(),
    });
  }
  return artifacts;
};

const inspectLockState = async (
  runsRoot: string,
  processExists: (pid: number) => boolean,
): Promise<DoctorObservation['lock']> => {
  const lockPath = path.join(runsRoot, '.active.lock');
  try {
    const record = await readLockRecord(lockPath);
    return processExists(record.pid) ? 'active' : 'stale';
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
      return 'none';
    }
    return fsSync.existsSync(lockPath) ? 'stale' : 'none';
  }
};

const inspectStaleScratch = async (repositoryRoot: string) =>
  (await fs.readdir(repositoryRoot, { withFileTypes: true }))
    .filter(
      (entry) =>
        entry.isFile() && /^\.rift-.+\.test\.(?:dme|dmb|rsc)$/.test(entry.name),
    )
    .map((entry) => entry.name)
    .sort();

export const runDoctorWorkflow = async (
  context: DoctorWorkflowContext,
): Promise<{ observation: DoctorObservation; summary: RiftSummary }> => {
  const revision = await runDoctorGit(context, 'git-revision', [
    'rev-parse',
    '--verify',
    'HEAD',
  ]);
  const status = await runDoctorGit(context, 'git-status', [
    'status',
    '--porcelain=v1',
    '--untracked-files=normal',
  ]);
  const canonicalArtifacts = await inspectCanonicalArtifacts(
    context.repository,
  );
  const observation: DoctorObservation = {
    repository_qualified: true,
    revision,
    dirty: status.length > 0,
    pins: { ...context.pins },
    bun_version: context.bunVersion,
    byond_version: context.byond.version,
    build_contract: 'valid',
    offline_ready: context.offlineReady,
    canonical_artifacts: canonicalArtifacts,
    lock: await inspectLockState(
      context.repository.runsRoot,
      context.processExists ?? defaultProcessExists,
    ),
    stale_scratch: await inspectStaleScratch(context.repository.root),
    platform: 'windows',
  };
  await context.recorder.setRepository(observation.revision, observation.dirty);
  await context.recorder.setToolVersions({
    bun: observation.bun_version,
    byond: observation.byond_version,
    byond_resolver: context.byond.source,
  });
  for (const artifact of canonicalArtifacts) {
    await context.recorder.addArtifact(artifact);
  }
  await context.recorder.addPhase({ stage: 'doctor', ...observation });
  await context.recorder.emit('observation', 'doctor', observation);

  const ready =
    observation.offline_ready &&
    observation.bun_version === context.pins.BUN_VERSION &&
    observation.byond_version ===
      `${context.pins.BYOND_MAJOR}.${context.pins.BYOND_MINOR}`;
  if (!ready) {
    await context.recorder.addFailure({
      code: 'offline_preflight_failed',
      stage: 'doctor',
      message: 'pinned offline toolchain is not ready',
    });
  }
  const summary = await context.recorder.finish(
    ready ? 'passed' : 'failed',
    ready ? 0 : 3,
  );
  return { observation, summary };
};

const RUN_ID = /^\d{8}T\d{6}Z-[0-9a-f]{8}$/;

export const runReportCommand = async (
  runsRoot: string,
  runId: string,
  format: OutputFormat,
): Promise<string> => {
  if (!RUN_ID.test(runId)) {
    throw new Error(`invalid run ID: ${runId}`);
  }
  const runDir = path.join(path.resolve(runsRoot), runId);
  const stored = await readStoredRun(runDir);
  if (format === 'human') {
    return `${renderHumanSummary(stored.summary)}\n`;
  }
  if (format === 'result') {
    return `${renderMachineResult(stored.summary)}\n`;
  }
  return stored.events.length > 0
    ? `${stored.events.map((event) => JSON.stringify(event)).join('\n')}\n`
    : '';
};

export class RiftError extends Error {
  constructor(
    readonly code: string,
    readonly stage: string,
    message: string,
    readonly exitCode: 2 | 3 | 4 | 5 | 6 | 7 | 130,
  ) {
    super(message);
  }
}

const throwForProcessTermination = (
  result: ProcessResult,
  stage: string,
): void => {
  switch (result.termination) {
    case 'wall_timeout':
      throw new RiftError(
        'wall_timeout',
        stage,
        `${stage} process exceeded its wall timeout`,
        6,
      );
    case 'idle_timeout':
      throw new RiftError(
        'idle_timeout',
        stage,
        `${stage} process exceeded its idle timeout`,
        6,
      );
    case 'cancelled':
      throw new RiftError(
        'cancelled',
        stage,
        `${stage} process cancelled`,
        130,
      );
    case 'natural':
    case 'requested':
      return;
  }
};

export const renderMachineResult = (summary: RiftSummary): string => {
  const compilePhase = summary.phases.findLast(
    (phase) => phase.stage === 'compile' && typeof phase.reused === 'boolean',
  );
  const artifacts = summary.artifacts
    .filter((artifact) => artifact.stage === 'compile')
    .map((artifact) => ({
      path: artifact.path,
      size: artifact.size,
      sha256: artifact.sha256,
      freshness: artifact.freshness,
    }));
  const resourceMaximum = (role: string) => {
    const maximum = summary.resource_maxima.find(
      (entry) => entry.role === role,
    );
    return maximum
      ? {
          private_bytes_max: maximum.private_bytes_max,
          working_set_bytes_max: maximum.working_set_bytes_max,
          samples: maximum.samples,
        }
      : null;
  };
  return `RIFT_RESULT ${JSON.stringify({
    schema_version: RIFT_SCHEMA_VERSION,
    run_id: summary.run_id,
    command: summary.command,
    status: summary.status,
    evidence: summary.evidence,
    exit_code: summary.exit_code,
    reused:
      summary.command === 'compile' && compilePhase
        ? compilePhase.reused
        : null,
    artifacts,
    ...(summary.profile.startsWith('dogmos')
      ? {
          dogmos: {
            dreamdaemon: resourceMaximum('dreamdaemon'),
            service: resourceMaximum('dogmosd'),
            runtime_signatures: summary.runtime_signatures,
          },
        }
      : {}),
  })}`;
};

const rethrowAsRiftError = (
  error: unknown,
  code: string,
  stage: string,
  exitCode: 2 | 3 | 4 | 5 | 6 | 7 | 130,
): never => {
  if (error instanceof RiftError) {
    throw error;
  }
  throw new RiftError(
    code,
    stage,
    error instanceof Error ? error.message : String(error),
    exitCode,
  );
};

const evidenceForCommand = (command: RiftCommand): EvidenceClass => {
  switch (command.command) {
    case 'doctor':
      return 'inspection';
    case 'compile':
      return command.mode === 'fast' ? 'compiler' : 'full_build';
    case 'run':
      return 'boot';
    case 'test':
      return command.focus.length > 0 ? 'focused_test' : 'full_test';
    case 'soak':
      return 'soak';
    case 'report':
      return 'inspection';
  }
};

export const classifyFailure = (
  error: unknown,
): { code: string; stage: string; exitCode: 2 | 3 | 4 | 5 | 6 | 7 | 130 } => {
  if (error instanceof RiftError) {
    return {
      code: error.code,
      stage: error.stage,
      exitCode: error.exitCode,
    };
  }
  return { code: 'workflow_failed', stage: 'run', exitCode: 5 };
};

const classifyWorkflowFailure = (
  error: unknown,
  stage: string,
  fallbackCode: string,
  cancelled: boolean,
): ReturnType<typeof classifyFailure> => {
  if (cancelled) {
    return { code: 'cancelled', stage, exitCode: 130 };
  }
  if (error instanceof RiftError) {
    return classifyFailure(error);
  }
  return { code: fallbackCode, stage, exitCode: 5 };
};

const statusForExitCode = (
  exitCode: ReturnType<typeof classifyFailure>['exitCode'],
): 'failed' | 'timed_out' | 'cancelled' => {
  if (exitCode === 6) {
    return 'timed_out';
  }
  if (exitCode === 130) {
    return 'cancelled';
  }
  return 'failed';
};

const readGitMetadata = async (
  repository: RepositoryPaths,
  environment: Record<string, string>,
) => {
  const revision = await runProbeProcess(
    'git.exe',
    ['rev-parse', '--verify', 'HEAD'],
    repository.root,
    environment,
  );
  const status = await runProbeProcess(
    'git.exe',
    ['status', '--porcelain=v1', '--untracked-files=normal'],
    repository.root,
    environment,
  );
  if (revision.exitCode !== 0 || status.exitCode !== 0) {
    throw new Error('repository_contract_mismatch: Git inspection failed');
  }
  return { revision: revision.stdout.trim(), dirty: status.stdout.length > 0 };
};

const printStoredResult = async (
  repository: RepositoryPaths,
  summary: RiftSummary,
  format: OutputFormat,
) => {
  if (format === 'human') {
    console.log(renderHumanSummary(summary));
    return;
  }
  if (format === 'result') {
    console.log(renderMachineResult(summary));
    return;
  }
  process.stdout.write(
    await runReportCommand(repository.runsRoot, summary.run_id, 'jsonl'),
  );
};

export const runMain = async (
  argv: string[],
  environment: NodeJS.ProcessEnv = process.env,
): Promise<number> => {
  let recorder: RunRecorder | null = null;
  let repository: RepositoryPaths | null = null;
  let lock: RunLock | null = null;
  let preflight: OfflinePreflight | null = null;
  let command: RiftCommand | null = null;
  const cancellation = createCancellationController();
  const handleInterrupt = () => {
    void cancellation.cancel();
  };
  process.once('SIGINT', handleInterrupt);
  process.once('SIGBREAK', handleInterrupt);
  try {
    try {
      command = parseCli(argv, environment);
    } catch (error) {
      throw new RiftError(
        'usage_error',
        'usage',
        error instanceof Error ? error.message : String(error),
        2,
      );
    }
    const moduleRepositoryRoot = path.resolve(import.meta.dir, '..', '..');
    if (command.command === 'report') {
      const output = await runReportCommand(
        path.join(moduleRepositoryRoot, 'data', 'rift-runs'),
        command.runId,
        command.format,
      ).catch((error) => rethrowAsRiftError(error, 'usage_error', 'usage', 2));
      process.stdout.write(output);
      return 0;
    }

    try {
      repository = await qualifyRepository(moduleRepositoryRoot);
    } catch (error) {
      rethrowAsRiftError(error, 'repository_contract_mismatch', 'preflight', 3);
    }
    let pins: DependencyPins;
    let profiles: Map<string, RiftProfile>;
    try {
      pins = parseDependencyPins(
        await fs.readFile(repository.dependencies, 'utf8'),
      );
      profiles = await loadProfiles(
        path.join(repository.root, 'tools', 'rift', 'profiles.json'),
      );
    } catch (error) {
      rethrowAsRiftError(error, 'repository_contract_mismatch', 'preflight', 3);
    }
    const profile = profiles.get(command.profile);
    if (!profile) {
      throw new RiftError(
        'usage_error',
        'usage',
        `profile not found: ${command.profile}`,
        2,
      );
    }
    if (command.command === 'test') {
      try {
        validateTestProfile(profile);
      } catch (error) {
        throw new RiftError(
          'usage_error',
          'usage',
          error instanceof Error ? error.message : String(error),
          2,
        );
      }
    }
    if (
      command.command === 'run' ||
      command.command === 'test' ||
      command.command === 'soak'
    ) {
      const selectedMap = command.map ?? profile.default_map;
      if (selectedMap === null) {
        throw new RiftError(
          'usage_error',
          'usage',
          `${command.command} requires --map or a profile default map`,
          2,
        );
      }
      try {
        command.map = validateMapPath(repository.root, selectedMap, true);
      } catch (error) {
        throw new RiftError(
          'usage_error',
          'usage',
          error instanceof Error ? error.message : String(error),
          2,
        );
      }
    }

    const { runId, runDir } = await allocateRun(repository.runsRoot);
    recorder = await RunRecorder.create({
      runDir,
      runId,
      command: command.command,
      profile: command.profile,
      evidence: evidenceForCommand(command),
      networkMode: command.networkMode,
    });

    let offlineReady = false;
    let childEnvironment = stringEnvironment(environment);
    let pinnedPython = resolveWorkflowPython(environment, null);
    if (command.networkMode === 'offline' || command.command === 'doctor') {
      try {
        preflight = await preflightOffline(
          repository,
          pins,
          environment,
          runProbeProcess,
        );
        offlineReady = true;
        childEnvironment = preflight.environment;
        pinnedPython = preflight.tools.python;
      } catch (error) {
        if (command.command !== 'doctor') {
          rethrowAsRiftError(error, 'offline_preflight_failed', 'preflight', 3);
        }
      }
    }
    let byond: ByondTools;
    let git: Awaited<ReturnType<typeof readGitMetadata>>;
    try {
      byond = await resolveByond(
        repository,
        pins,
        runProbeProcess,
        environment,
      );
      git = await readGitMetadata(repository, childEnvironment);
    } catch (error) {
      rethrowAsRiftError(error, 'toolchain_preflight_failed', 'preflight', 3);
    }
    if (cancellation.wasCancelled()) {
      throw new RiftError('cancelled', 'run', 'cancelled', 130);
    }
    await recorder.setRepository(git.revision, git.dirty);
    await recorder.setToolVersions({
      bun: Bun.version,
      byond: byond.version,
      byond_resolver: byond.source,
    });

    if (command.profile.startsWith('dogmos')) {
      await recorder.emit('stage_started', 'dogmos-contract', {});
      try {
        await verifyDogmosInstalledContract({
          repositoryRoot: repository.root,
          python: pinnedPython,
          environment: childEnvironment,
          runner: cancellation.runner,
          recorder,
        });
      } catch (error) {
        rethrowAsRiftError(
          error,
          'dogmos_contract_mismatch',
          'dogmos-contract',
          3,
        );
      }
      await recorder.emit('stage_finished', 'dogmos-contract', {}, 'passed');
    }

    if (command.command === 'doctor') {
      const result = await runDoctorWorkflow({
        repository,
        pins,
        byond,
        bunVersion: Bun.version,
        offlineReady,
        recorder,
        runId,
        runDir,
        environment: childEnvironment,
        processRunner: cancellation.runner,
      });
      await printStoredResult(repository, result.summary, command.format);
      return result.summary.exit_code;
    }

    try {
      lock = await acquireRunLock(
        repository.runsRoot,
        command.command,
        runId,
        command.waitForLockSeconds,
      );
    } catch (error) {
      rethrowAsRiftError(error, 'lock_busy', 'lock', 7);
    }
    const context: WorkflowContext = {
      repository,
      pins,
      byond,
      pinnedPython,
      profileName: command.profile,
      profile,
      profiles,
      recorder,
      lock,
      runId,
      runDir,
      environment: childEnvironment,
      networkMode: command.networkMode,
      processRunner: cancellation.runner,
      buildProcessRunner: cancellation.runner,
      wasCancelled: cancellation.wasCancelled,
    };
    let summary: RiftSummary;
    switch (command.command) {
      case 'compile': {
        await recorder.emit('stage_started', 'compile', {
          mode: command.mode,
          force: command.force,
        });
        const request: CompileRequest = {
          runId,
          repository,
          byond,
          recorder,
          environment: childEnvironment,
          defines: profile.compile_defines,
          wallTimeoutMs:
            (command.wallTimeoutSeconds ??
              profile.default_timeouts.wall_seconds) * 1000,
          idleTimeoutMs:
            (command.idleTimeoutSeconds ??
              profile.default_timeouts.idle_seconds) * 1000,
          processRunner: cancellation.runner,
          buildProcessRunner: cancellation.runner,
        };
        let result: CompileOutcome;
        try {
          result =
            command.mode === 'fast'
              ? await compileFast(request)
              : await compileFull({ ...request, force: command.force });
        } catch (error) {
          rethrowAsRiftError(error, 'compile_failed', 'compile', 4);
        }
        await recorder.emit(
          'stage_finished',
          'compile',
          { evidence: result.evidence, reused: result.reused },
          'passed',
        );
        summary = await finishRunWithLock(recorder, lock, 'passed', 0);
        break;
      }
      case 'run':
        summary = await runServerWorkflow(context, command);
        break;
      case 'test':
        summary = await runTestWorkflow(context, command);
        break;
      case 'soak':
        summary = await runSoakWorkflow(context, command);
        break;
      default:
        throw new RiftError(
          'workflow_failed',
          'run',
          `unknown command: ${String(command)}`,
          5,
        );
    }
    await printStoredResult(repository, summary, command.format);
    return summary.exit_code;
  } catch (error) {
    const failure = classifyFailure(error);
    const message = error instanceof Error ? error.message : String(error);
    if (recorder && repository) {
      await recorder.addFailure({
        code: failure.code,
        stage: failure.stage,
        message,
      });
      const status = statusForExitCode(failure.exitCode);
      const summary = lock
        ? await finishRunWithLock(recorder, lock, status, failure.exitCode)
        : await recorder.finish(status, failure.exitCode);
      await printStoredResult(repository, summary, command?.format ?? 'human');
    } else {
      console.error(`[${failure.code}] ${message}`);
      if (environment.RIFT_DEBUG === '1' && error instanceof Error) {
        console.error(error.stack);
      }
    }
    return failure.exitCode;
  } finally {
    process.off('SIGINT', handleInterrupt);
    process.off('SIGBREAK', handleInterrupt);
    await lock?.release().catch(() => undefined);
    await preflight?.cleanup().catch(() => undefined);
  }
};

if (import.meta.main) {
  process.exitCode = await runMain(Bun.argv.slice(2));
}
