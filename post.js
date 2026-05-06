const { execSync } = require('child_process');

function getInput(name) {
  const key = `INPUT_${name.replace(/ /g, '_').replace(/-/g, '_').toUpperCase()}`;
  return (process.env[key] || '').trim();
}

function getState(name) {
  return (process.env[`STATE_${name}`] || '').trim();
}

function run() {
  // Resolve env vars: prefer state saved from main step, fall back to PSE_* from GITHUB_ENV
  const apiUrl = getState('api_url') || process.env.PSE_API_URL || '';
  const appToken = getState('ir_app_token') || getState('app_token') || process.env.PSE_APP_TOKEN || '';
  const debug = getState('debug') || process.env.DEBUG || 'false';
  const githubToken = getState('github_token') || process.env.GITHUB_TOKEN || '';
  const sendJobStatus = getState('send_job_status') || getInput('send_job_status');

  const env = {
    ...process.env,
    IR_URL: apiUrl,
    IR_APP_TOKEN: appToken,
    DEBUG: debug,
    RUNNER: 'github',
    GITHUB_TOKEN: githubToken,
    SEND_JOB_STATUS: sendJobStatus === 'true' ? 'true' : 'false',
  };

  console.log('Running PSE cleanup...');
  execSync('pse-data-collector cleanup', {
    stdio: 'inherit',
    env,
  });
}

try {
  if (getState('skip_post') === 'true') {
    console.warn('Warning: The "cleanup" input is deprecated. Cleanup is now handled automatically by the setup step\'s post hook. Please remove the cleanup step from your workflow.');
  } else {
    run();
  }
} catch (error) {
  console.error(`PSE cleanup failed: ${error.message}`);
  // Don't exit with error in post step — cleanup failures shouldn't fail the job
  process.exit(0);
}
