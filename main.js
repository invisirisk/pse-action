const { execFileSync } = require('child_process');
const { buildEnv, getInput, handleDeprecatedCleanupInput, pick, saveState } = require('./utils');

function runBootstrap(env) {
  const bootstrapUrl = new URL('/ingestionapi/v1/pse/bootstrap', env.IR_URL);
  bootstrapUrl.search = new URLSearchParams({
    api_key: env.IR_APP_TOKEN,
    mode: env.MODE || 'native',
    runner: env.RUNNER || 'github',
  }).toString();

  execFileSync('bash', ['-lc', 'curl -sSf "$BOOTSTRAP_URL" | bash'], {
    stdio: 'inherit',
    env: {
      ...env,
      API_KEY: env.IR_APP_TOKEN,
      API_URL: env.IR_URL,
      BOOTSTRAP_URL: bootstrapUrl.toString(),
    },
  });
}

function run() {
  const sendJobStatus = getInput('send_job_status');
  const apiUrl = getInput('api_url');
  const appToken = getInput('app_token');
  const debug = getInput('debug');
  const githubToken = pick(getInput('github_token'), process.env.GITHUB_TOKEN);

  const env = buildEnv({
    IR_URL: apiUrl,
    IR_APP_TOKEN: appToken,
    DEBUG: debug,
    TEST_MODE: getInput('test_mode'),
    MODE: getInput('mode'),
    COLLECT_DEPENDENCIES: getInput('collect_dependencies'),
    WORKDIR: getInput('workdir'),
    GITHUB_TOKEN: githubToken,
  });

  console.log(`Running PSE setup in ${env.MODE || 'native'} mode...`);
  runBootstrap(env);

  // Save inputs to state for the post step (cleanup/job-status)
  saveState('api_url', apiUrl);
  saveState('ir_app_token', appToken);
  saveState('debug', debug);
  saveState('send_job_status', sendJobStatus);
  saveState('runner', env.RUNNER);
  saveState('github_token', githubToken);
}

try {
  if (handleDeprecatedCleanupInput()) {
    return;
  }
  run();
} catch (error) {
  console.error(`PSE setup failed: ${error.message}`);
  process.exit(1);
}
