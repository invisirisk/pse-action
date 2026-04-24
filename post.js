const { execSync } = require('child_process');
const path = require('path');

function getInput(name) {
  const key = `INPUT_${name.replace(/ /g, '_').replace(/-/g, '_').toUpperCase()}`;
  return (process.env[key] || '').trim();
}

function getState(name) {
  return (process.env[`STATE_${name}`] || '').trim();
}

function run() {
  const actionPath = __dirname;

  // Resolve env vars: prefer state saved from main step, fall back to PSE_* from GITHUB_ENV
  const apiUrl = getState('api_url') || process.env.PSE_API_URL || '';
  const appToken = getState('app_token') || process.env.PSE_APP_TOKEN || '';
  const portalUrl = getState('portal_url') || process.env.PSE_PORTAL_URL || apiUrl;
  const debug = getState('debug') || process.env.DEBUG || 'false';
  const githubToken = getState('github_token') || process.env.GITHUB_TOKEN || '';

  const env = {
    ...process.env,
    // Ensure GITHUB_ACTION_PATH points to this action's directory.
    // In node20 actions the runner may not set this automatically (unlike composite actions).
    GITHUB_ACTION_PATH: process.env.GITHUB_ACTION_PATH || actionPath,
    API_URL: apiUrl,
    APP_TOKEN: appToken,
    PORTAL_URL: portalUrl,
    DEBUG: debug,
    GITHUB_TOKEN: githubToken,
  };

  // Step 1: Send job status if enabled
  const sendJobStatus = getState('send_job_status') || getInput('send_job_status');
  if (sendJobStatus === 'true') {
    console.log('Running PSE send job status...');
    try {
      execSync(`bash ${path.join(actionPath, 'get_jobs_status.sh')}`, {
        stdio: 'inherit',
        env,
      });
    } catch (error) {
      console.error(`Warning: Failed to send job status: ${error.message}`);
      // Continue with cleanup even if job status fails
    }
  }

  // Step 2: Run cleanup
  console.log('Running PSE cleanup...');
  execSync(`bash ${path.join(actionPath, 'cleanup.sh')}`, {
    stdio: 'inherit',
    env,
  });
}

try {
  run();
} catch (error) {
  console.error(`PSE cleanup failed: ${error.message}`);
  // Don't exit with error in post step — cleanup failures shouldn't fail the job
  process.exit(0);
}
