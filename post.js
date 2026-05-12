const { execSync } = require('child_process');
const { buildEnv, getInput, getState, handleDeprecatedCleanupInput, pick } = require('./utils');

const POLICY_FAILURE_EXIT_CODE = 42;

function run(exec = execSync) {
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
  exec('pse-data-collector cleanup', {
    stdio: 'inherit',
    env,
  });
}

function isPolicyFailure(error) {
  return Number(error?.status) === POLICY_FAILURE_EXIT_CODE;
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

function main(exec = execSync, exit = process.exit) {
  try {
    if (handleDeprecatedCleanupInput(true)) {
      return;
    }
    run(exec);
  } catch (error) {
    handleCleanupError(error, exit);
  }
}

if (require.main === module) {
  main();
}

module.exports = {
  POLICY_FAILURE_EXIT_CODE,
  handleCleanupError,
  isPolicyFailure,
  main,
  run,
};
