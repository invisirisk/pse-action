const { spawnSync } = require('child_process');
const { buildEnv, error: annotateError, getInput, handleDeprecatedCleanupInput, pick } = require('./utils');


const POLICY_FAILURE_EXIT_CODE = 42;
const END_SIGNAL_FAILURE_EXIT_CODE = 43;
const POLICY_FAILURE_MESSAGE = /InvisiRisk blocked this build because/i;
const END_SIGNAL_FAILURE_MESSAGE = /InvisiRisk could not complete build finalization because the \/end request failed\./i;

function getCleanupMessage(error) {
  return `${error?.stdout || ''}${error?.stderr || ''}`.trim() || error?.message || '';
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
  const message = getCleanupMessage(error);
  console.error(`PSE cleanup failed: ${message || error.message}`);
  if (isPolicyFailure(error)) {
    emitAnnotation(message || error.message, 'Policy gate failed');
    exit(1);
    return;
  }

  if (isEndSignalFailure(error)) {
    emitAnnotation(message || error.message, 'InvisiRisk /end failed');
    exit(1);
    return;
  }

  // Don't exit with error in post step — cleanup failures shouldn't fail the job
  exit(0);
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
  handleCleanupError,
  isEndSignalFailure,
  isPolicyFailure,
  main,
  run,
};
