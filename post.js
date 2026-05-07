const { execSync } = require('child_process');
const { buildEnv, getInput, getState, handleDeprecatedCleanupInput, pick } = require('./utils');

function run() {
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
  execSync('pse-data-collector cleanup', {
    stdio: 'inherit',
    env,
  });
}

try {
  if (handleDeprecatedCleanupInput(true)) {
    return;
  }
  run();
} catch (error) {
  console.error(`PSE cleanup failed: ${error.message}`);
  // Don't exit with error in post step — cleanup failures shouldn't fail the job
  process.exit(0);
}
