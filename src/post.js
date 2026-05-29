const { spawnSync } = require('child_process');
const { buildEnv, error: annotateError, getInput, handleDeprecatedCleanupInput, pick } = require('./utils');

const POLICY_FAILURE_EXIT_CODE = 42;
const END_SIGNAL_FAILURE_EXIT_CODE = 43;
const POLICY_FAILURE_MESSAGE = /InvisiRisk blocked this build because/i;
const END_SIGNAL_FAILURE_MESSAGE = /InvisiRisk could not complete build finalization because the \/end (request failed|response could not be parsed)\./i;
const WORKFLOW_ERROR_COMMAND = /^::error\b/m;

function getCleanupMessage(error) {
  return `${error?.stdout || ''}${error?.stderr || ''}`.trim() || error?.message || '';
}

function splitNonEmptyLines(value) {
  return `${value || ''}`
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean);
}

function stripWorkflowCommands(value) {
  return splitNonEmptyLines(value)
    .filter((line) => !line.startsWith('::'))
    .join('\n')
    .trim();
}

function normalizeAnnotationLine(line) {
  return line
    .replace(/^\[[^\]]+\]\s*/, '')
    .replace(/^Policy gate failed:\s*/i, '')
    .replace(/^ERROR:\s*/i, '')
    .trim();
}

function getAnnotationMessage(error) {
  const combined = stripWorkflowCommands(getCleanupMessage(error));
  if (!combined) {
    return error?.message || '';
  }

  const lines = splitNonEmptyLines(combined).map(normalizeAnnotationLine).filter(Boolean);
  const priorityMatchers = [
    /InvisiRisk blocked this build because/i,
    /InvisiRisk could not complete build finalization because the \/end/i,
    /Failed to send end signal/i,
    /cleanup failed/i,
    /^failed to /i,
  ];

  for (const matcher of priorityMatchers) {
    const match = [...lines].reverse().find((line) => matcher.test(line));
    if (match) {
      return match;
    }
  }

  return lines[lines.length - 1] || combined;
}

function hasExistingErrorAnnotation(error) {
  return WORKFLOW_ERROR_COMMAND.test(`${error?.stdout || ''}\n${error?.stderr || ''}`);
}

function isPolicyFailure(error) {
  if (Number(error?.status) === POLICY_FAILURE_EXIT_CODE) {
    return true;
  }

  return POLICY_FAILURE_MESSAGE.test(getCleanupMessage(error));
}

function isEndSignalFailure(error) {
  if (Number(error?.status) === END_SIGNAL_FAILURE_EXIT_CODE) {
    return true;
  }

  return END_SIGNAL_FAILURE_MESSAGE.test(getCleanupMessage(error));
}

function handleCleanupError(error, exit = process.exit, emitAnnotation = annotateError) {
  const annotationMessage = getAnnotationMessage(error) || error?.message || 'PSE cleanup failed';
  const existingAnnotation = hasExistingErrorAnnotation(error);

  if (isPolicyFailure(error)) {
    if (!existingAnnotation) {
      emitAnnotation(annotationMessage, 'Policy gate failed');
    }
    exit(1);
    return;
  }

  if (isEndSignalFailure(error)) {
    if (!existingAnnotation) {
      emitAnnotation(annotationMessage, 'InvisiRisk /end failed');
    }
    exit(1);
    return;
  }

  if (!existingAnnotation) {
    emitAnnotation(annotationMessage, 'PSE cleanup failed');
  }

  exit(1);
}

function run(spawn = spawnSync, stdout = process.stdout, stderr = process.stderr) {
  const env = buildEnv({
    IR_URL: pick(getInput('api_url'), process.env.PSE_API_URL),
    IR_TOKEN: pick(getInput('app_token'), process.env.PSE_APP_TOKEN),
    SEND_JOB_STATUS: getInput('send_job_status') === 'false' ? 'false' : 'true',
  });

  const debug = pick(getInput('debug'), process.env.DEBUG);
  if (debug === 'true') {
    env.DEBUG = 'true';
  }

  const githubToken = pick(getInput('github_token'), process.env.GITHUB_TOKEN);
  if (githubToken) {
    env.GITHUB_TOKEN = githubToken;
  }

  console.log('Running PSE cleanup...');
  const result = spawn('pse-data-collector', ['cleanup'], {
    encoding: 'utf8',
    env,
  });

  if (result.stdout) {
    stdout.write(result.stdout);
  }
  if (result.stderr) {
    stderr.write(result.stderr);
  }

  if (result.error) {
    throw result.error;
  }

  if (result.status !== 0) {
    const error = new Error(getCleanupMessage(result) || 'pse-data-collector cleanup failed');
    error.status = result.status;
    error.stdout = result.stdout || '';
    error.stderr = result.stderr || '';
    throw error;
  }
}

function main(spawn = spawnSync, exit = process.exit) {
  try {
    if (handleDeprecatedCleanupInput(true)) {
      return;
    }
    run(spawn);
  } catch (error) {
    handleCleanupError(error, exit);
  }
}

if (require.main === module) {
  main();
}

module.exports = {
  END_SIGNAL_FAILURE_EXIT_CODE,
  END_SIGNAL_FAILURE_MESSAGE,
  POLICY_FAILURE_EXIT_CODE,
  POLICY_FAILURE_MESSAGE,
  getAnnotationMessage,
  handleCleanupError,
  hasExistingErrorAnnotation,
  isEndSignalFailure,
  isPolicyFailure,
  main,
  run,
};
