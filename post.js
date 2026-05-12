const { spawnSync } = require('child_process');
const { buildEnv, getInput, getState, handleDeprecatedCleanupInput, pick } = require('./utils');

const POLICY_FAILURE_EXIT_CODE = 42;
const POLICY_FAILURE_MESSAGE = /InvisiRisk blocked this build because/i;

function run(spawn = spawnSync, stdout = process.stdout, stderr = process.stderr) {
  const apiUrl = pick(getState('api_url'), process.env.PSE_API_URL);
  const appToken = pick(getState('ir_app_token'), getState('app_token'), process.env.PSE_APP_TOKEN);
  const debug = pick(getState('debug'), process.env.DEBUG, 'false');
  const githubToken = pick(getState('github_token'), process.env.GITHUB_TOKEN);
  const sendJobStatus = pick(getState('send_job_status'), getInput('send_job_status'));

  const env = buildEnv({
    IR_URL: apiUrl,
    IR_APP_TOKEN: appToken,
    DEBUG: debug,
    GITHUB_TOKEN: githubToken,
    SEND_JOB_STATUS: sendJobStatus === 'true' ? 'true' : 'false',
  });

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
    const error = new Error('Command failed: pse-data-collector cleanup');
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

  const output = `${error?.stdout || ''}\n${error?.stderr || ''}`;
  return POLICY_FAILURE_MESSAGE.test(output);
}

function handleCleanupError(error, exit = process.exit) {
  console.error(`PSE cleanup failed: ${error.message}`);
  if (isPolicyFailure(error)) {
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
  POLICY_FAILURE_EXIT_CODE,
  POLICY_FAILURE_MESSAGE,
  handleCleanupError,
  isPolicyFailure,
  main,
  run,
};
