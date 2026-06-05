const { execFileSync } = require('child_process');
const { buildEnv, getInput, handleDeprecatedCleanupInput, pick } = require('./utils');

function runBootstrap(env, execFile = execFileSync) {
  const bootstrapUrl = new URL('/ingestionapi/v1/pse/bootstrap', env.IR_URL);
  bootstrapUrl.search = new URLSearchParams({
    //? for backwards compatibility, if MODE is `docker-intercept`, we want to use native mode for the bootstrap script
    mode: !env.MODE || env.MODE === "docker-intercept" ? "native" : env.MODE,
    runner: env.RUNNER || 'github',
  }).toString();

  env.BOOTSTRAP_URL = bootstrapUrl.toString();

  const bootstrapCommand = `
set -euo pipefail
response_file=$(mktemp)
http_status=$(curl -sS -o "$response_file" -w "%{http_code}" -H "x-api-key: $IR_TOKEN" "$BOOTSTRAP_URL")
if [ "$http_status" = "401" ]; then
  echo "::error title=PSE bootstrap unauthorized::Unauthorized request from InvisiRisk bootstrap API. Verify app_token is valid for $IR_URL."
  rm -f "$response_file"
  exit 1
fi
if [ "$http_status" = "403" ]; then
  echo "::error title=PSE bootstrap forbidden::Forbidden request from InvisiRisk bootstrap API. Verify app_token is authorized for $IR_URL and has access to the target project."
  rm -f "$response_file"
  exit 1
fi
if [ "$http_status" -lt 200 ] || [ "$http_status" -ge 300 ]; then
  echo "::error title=PSE bootstrap failed::Bootstrap API request failed with HTTP $http_status from $IR_URL."
  cat "$response_file" >&2 || true
  rm -f "$response_file"
  exit 1
fi
bash "$response_file"
bootstrap_exit=$?
rm -f "$response_file"
exit "$bootstrap_exit"
`;

  execFile('bash', ['-lc', bootstrapCommand], {
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
