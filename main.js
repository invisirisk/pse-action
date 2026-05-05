const { execSync } = require('child_process');
const path = require('path');
const fs = require('fs');
const os = require('os');

function getInput(name) {
  const key = `INPUT_${name.replace(/ /g, '_').replace(/-/g, '_').toUpperCase()}`;
  return (process.env[key] || '').trim();
}

function saveState(name, value) {
  const stateFile = process.env.GITHUB_STATE;
  if (stateFile) {
    fs.appendFileSync(stateFile, `${name}=${value}${os.EOL}`, 'utf8');
  }
}

function run() {
  const actionPath = __dirname;

  const sendJobStatus = getInput('send_job_status');
  const apiUrl = getInput('api_url');
  const appToken = getInput('app_token');
  const debug = getInput('debug');
  const githubToken = getInput('github_token') || process.env.GITHUB_TOKEN || '';

  const env = {
    ...process.env,
    // Ensure GITHUB_ACTION_PATH points to this action's directory.
    // In node20 actions the runner may not set this automatically (unlike composite actions).
    GITHUB_ACTION_PATH: process.env.GITHUB_ACTION_PATH || actionPath,
    IR_URL: apiUrl,
    IR_APP_TOKEN: appToken,
    DEBUG: debug,
    TEST_MODE: getInput('test_mode'),
    MODE: getInput('mode'),
    RUNNER: 'github',
    COLLECT_DEPENDENCIES: getInput('collect_dependencies'),
    WORKDIR: getInput('workdir'),
    GITHUB_TOKEN: githubToken,
  };

  console.log(`Running PSE setup in ${env.MODE || 'native'} mode...`);
  execSync(`bash ${path.join(actionPath, 'setup.sh')}`, {
    stdio: 'inherit',
    env,
  });

  // Save inputs to state for the post step (cleanup/job-status)
  saveState('api_url', apiUrl);
  saveState('ir_app_token', appToken);
  saveState('debug', debug);
  saveState('send_job_status', sendJobStatus);
  saveState('runner', env.RUNNER);
  saveState('github_token', githubToken);
}

function isDeprecatedCleanupInput() {
  if (getInput('cleanup') === 'true') {
    console.warn('Warning: The "cleanup" input is deprecated. Cleanup is now handled automatically by the setup step. Please remove the cleanup step from your workflow.');
    saveState('skip_post', 'true');
    return true;
  }
  return false;
}
try {
  if (isDeprecatedCleanupInput()) {
    return;
  }
  run();
} catch (error) {
  console.error(`PSE setup failed: ${error.message}`);
  process.exit(1);
}
