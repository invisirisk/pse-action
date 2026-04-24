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

  // Map action inputs to environment variables expected by setup.sh
  const sendJobStatus = getInput('send_job_status');
  const apiUrl = getInput('api_url');
  const appToken = getInput('app_token');
  const portalUrl = getInput('portal_url') || apiUrl;
  const debug = getInput('debug');

  const env = {
    ...process.env,
    API_URL: apiUrl,
    APP_TOKEN: appToken,
    PORTAL_URL: portalUrl,
    SCAN_ID: getInput('scan_id'),
    DEBUG: debug,
    TEST_MODE: getInput('test_mode'),
    GITHUB_TOKEN: getInput('github_token') || process.env.GITHUB_TOKEN,
    MODE: getInput('mode'),
    PROXY_IP: getInput('proxy_ip'),
    PROXY_HOSTNAME: getInput('proxy_hostname'),
    COLLECT_DEPENDENCIES: getInput('collect_dependencies'),
    WORKDIR: getInput('workdir'),
  };

  console.log(`Running PSE setup in ${env.MODE || 'all'} mode...`);
  execSync(`bash ${path.join(actionPath, 'setup.sh')}`, {
    stdio: 'inherit',
    env,
  });

  // Save inputs to state for the post step (cleanup/job-status)
  saveState('api_url', apiUrl);
  saveState('app_token', appToken);
  saveState('portal_url', portalUrl);
  saveState('debug', debug);
  saveState('send_job_status', sendJobStatus);
  saveState('github_token', env.GITHUB_TOKEN);
}

try {
  run();
} catch (error) {
  console.error(`PSE setup failed: ${error.message}`);
  process.exit(1);
}
