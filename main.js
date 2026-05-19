const { execFileSync } = require('child_process');
const { buildEnv, getInput, handleDeprecatedCleanupInput, pick } = require('./utils');

function runBootstrap(env, execFile = execFileSync) {
  const bootstrapUrl = new URL('/ingestionapi/v1/pse/bootstrap', env.IR_URL);
  bootstrapUrl.search = new URLSearchParams({
    api_key: env.IR_TOKEN,
    ir_token: env.IR_TOKEN,
    mode: env.MODE || 'native',
    runner: env.RUNNER || 'github',
  }).toString();

  execFile('bash', ['-lc', `curl -sSf "${bootstrapUrl.toString()}" | bash`], {
    stdio: 'inherit',
    env,
  });
}

function buildRuntimeEnv(inputReader = getInput, envSource = process.env) {
  const env = buildEnv({
    IR_URL: inputReader('api_url'),
    IR_TOKEN: pick(inputReader('app_token'), envSource.IR_TOKEN, envSource.APP_TOKEN),
  });

  const mode = pick(inputReader('mode'));
  if (mode) {
    env.MODE = mode;
  }

  if ((mode || 'native') === 'sidecar') {
    env.PSE_IMAGE_TAG = pick(inputReader('pse_image_tag'), 'latest');
  }

  const debug = pick(inputReader('debug'));
  if (debug === 'true') {
    env.DEBUG = 'true';
  }

  const collectDependencies = pick(inputReader('collect_dependencies'));
  if (collectDependencies) {
    env.COLLECT_DEPENDENCIES = collectDependencies;
  }

  const workdir = pick(inputReader('workdir'));
  if (workdir) {
    env.WORKDIR = workdir;
  }

  const githubToken = pick(inputReader('github_token'), envSource.GITHUB_TOKEN);
  if (githubToken) {
    env.GITHUB_TOKEN = githubToken;
  }

  return env;
}

function run({ execFile = execFileSync, inputReader = getInput, envSource = process.env } = {}) {
  const env = buildRuntimeEnv(inputReader, envSource);

  if (!env.IR_URL) {
    throw new Error('Missing required input: api_url');
  }
  if (!env.IR_TOKEN) {
    throw new Error('Missing required input: app_token (or IR_TOKEN/APP_TOKEN environment variable)');
  }

  console.log(`Running PSE setup in ${env.MODE || 'native'} mode...`);
  runBootstrap(env, execFile);
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
