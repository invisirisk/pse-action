const { execFileSync } = require('child_process');
const { buildEnv, getInput, handleDeprecatedCleanupInput, pick, saveState } = require('./utils');

function runBootstrap(env, execFile = execFileSync) {
  const bootstrapUrl = new URL('/ingestionapi/v1/pse/bootstrap', env.IR_URL);
  bootstrapUrl.search = new URLSearchParams({
    api_key: env.IR_APP_TOKEN,
    mode: env.MODE || 'native',
    runner: env.RUNNER || 'github',
  }).toString();

  execFile('bash', ['-lc', 'curl -sSf "$BOOTSTRAP_URL" | bash'], {
    stdio: 'inherit',
    env: {
      ...env,
      API_KEY: env.IR_APP_TOKEN,
      API_URL: env.IR_URL,
      BOOTSTRAP_URL: bootstrapUrl.toString(),
    },
  });
}

function buildRuntimeEnv(inputReader = getInput, envSource = process.env) {
  const githubToken = pick(inputReader('github_token'), envSource.GITHUB_TOKEN);

  return buildEnv({
    IR_URL: inputReader('api_url'),
    IR_APP_TOKEN: inputReader('app_token'),
    DEBUG: inputReader('debug'),
    TEST_MODE: inputReader('test_mode'),
    MODE: inputReader('mode'),
    PSE_IMAGE_TAG: pick(inputReader('pse_image_tag'), 'latest'),
    COLLECT_DEPENDENCIES: inputReader('collect_dependencies'),
    WORKDIR: inputReader('workdir'),
    GITHUB_TOKEN: githubToken,
  });
}

function run({ execFile = execFileSync, inputReader = getInput, stateWriter = saveState, envSource = process.env } = {}) {
  const sendJobStatus = inputReader('send_job_status');
  const apiUrl = inputReader('api_url');
  const appToken = inputReader('app_token');
  const debug = inputReader('debug');

  const env = buildRuntimeEnv(inputReader, envSource);

  console.log(`Running PSE setup in ${env.MODE || 'native'} mode...`);
  runBootstrap(env, execFile);

  // Save inputs to state for the post step (cleanup/job-status)
  stateWriter('api_url', apiUrl);
  stateWriter('ir_app_token', appToken);
  stateWriter('debug', debug);
  stateWriter('send_job_status', sendJobStatus);
  stateWriter('runner', env.RUNNER);
  stateWriter('github_token', env.GITHUB_TOKEN);
}

if (require.main === module) {
  try {
    if (!handleDeprecatedCleanupInput()) {
      run();
    }
  } catch (error) {
    console.error(`PSE setup failed: ${error.message}`);
    process.exit(1);
  }
}

module.exports = {
  buildRuntimeEnv,
  runBootstrap,
  run,
};
