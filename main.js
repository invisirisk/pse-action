const { execFileSync } = require('child_process');
const { buildEnv, getInput, handleDeprecatedCleanupInput, pick, saveState } = require('./utils');

function runBootstrap(env, execFile = execFileSync) {
  const bootstrapUrl = new URL('/ingestionapi/v1/pse/bootstrap', env.IR_URL);
  bootstrapUrl.search = new URLSearchParams({
    api_key: env.IR_TOKEN,
    ir_token: env.IR_TOKEN,
    mode: env.MODE || 'native',
    runner: env.RUNNER || 'github',
  }).toString();

  execFile('bash', ['-lc', 'curl -sSf "$BOOTSTRAP_URL" | bash'], {
    stdio: 'inherit',
    env: {
      ...env,
      API_KEY: env.IR_TOKEN,
      APP_TOKEN: env.IR_TOKEN,
      IR_TOKEN: env.IR_TOKEN,
      API_URL: env.IR_URL,
      BOOTSTRAP_URL: bootstrapUrl.toString(),
    },
  });
}

function buildRuntimeEnv(inputReader = getInput, envSource = process.env) {
  const irToken = pick(inputReader('app_token'), envSource.IR_TOKEN, envSource.APP_TOKEN);
  const githubToken = pick(inputReader('github_token'), envSource.GITHUB_TOKEN);

  return buildEnv({
    IR_URL: inputReader('api_url'),
    IR_TOKEN: irToken,
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

  if (!env.IR_URL) {
    throw new Error('Missing required input: api_url');
  }
  if (!env.IR_TOKEN) {
    throw new Error('Missing required input: app_token (or IR_TOKEN/APP_TOKEN environment variable)');
  }

  console.log(`Running PSE setup in ${env.MODE || 'native'} mode...`);
  runBootstrap(env, execFile);

  // Save inputs to state for the post step (cleanup/job-status)
  stateWriter('api_url', apiUrl);
  stateWriter('ir_token', appToken);
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
