const { execFileSync } = require('child_process');
const { buildEnv, exportVariable, getInput, handleDeprecatedInputs, maskSecret, pick, saveState } = require('./utils');

const DEFAULT_OIDC_AUDIENCE = 'invisirisk-oidc-validator';

function info(message) {
  console.log(`[PSE] ${message}`);
}

function debug(enabled, message) {
  if (enabled) {
    console.log(`::debug::${message}`);
  }
}

function buildOidcExchangeUrl(apiUrl, configuredUrl) {
  try {
    return new URL(configuredUrl || '/oidc/exchange', apiUrl).toString();
  } catch (error) {
    throw new Error(`Invalid OIDC exchange URL configuration: ${error.message}`);
  }
}

async function parseJsonResponse(response, context) {
  try {
    return await response.json();
  } catch (error) {
    throw new Error(`${context} returned a non-JSON response.`);
  }
}

async function readErrorDetail(response) {
  try {
    const errorPayload = await response.json();
    return errorPayload.detail || errorPayload.message || errorPayload.error || '';
  } catch (_) {
    try {
      return await response.text();
    } catch (__) {
      return '';
    }
  }
}

async function requestGithubOidcToken(
  audience,
  envSource = process.env,
  fetchImpl = fetch,
  debugEnabled = false,
) {
  const requestUrl = envSource.ACTIONS_ID_TOKEN_REQUEST_URL;
  const requestToken = envSource.ACTIONS_ID_TOKEN_REQUEST_TOKEN;
  if (!requestUrl || !requestToken) {
    throw new Error('GitHub OIDC is unavailable. Set workflow permissions: id-token: write.');
  }
  if (!fetchImpl) {
    throw new Error('Fetch API is unavailable. This action requires Node 20 or newer.');
  }

  const separator = requestUrl.includes('?') ? '&' : '?';
  const url = `${requestUrl}${separator}audience=${encodeURIComponent(audience)}`;
  debug(debugEnabled, `Requesting GitHub OIDC token with audience "${audience}".`);

  let response;
  try {
    response = await fetchImpl(url, {
      headers: {
        Authorization: `Bearer ${requestToken}`,
        Accept: 'application/json',
      },
    });
  } catch (error) {
    throw new Error(`GitHub OIDC token request failed: ${error.message}`);
  }

  if (!response.ok) {
    const detail = await readErrorDetail(response);
    throw new Error(`GitHub OIDC token request failed with status ${response.status}${detail ? `: ${detail}` : ''}.`);
  }

  const payload = await parseJsonResponse(response, 'GitHub OIDC token request');
  if (!payload || typeof payload.value !== 'string' || !payload.value) {
    throw new Error('GitHub OIDC token response did not include a token value.');
  }
  debug(debugEnabled, 'Received GitHub OIDC token.');
  return payload.value;
}

function extractTokenFromExchangeResponse(payload) {
  return pick(
    payload && payload.api_key,
    payload && payload.app_token,
    payload && payload.access_token,
    payload && payload.token,
    payload && payload.data && payload.data.api_key,
    payload && payload.data && payload.data.app_token,
    payload && payload.data && payload.data.access_token,
    payload && payload.data && payload.data.token,
  );
}

async function exchangeOidcForToken({
  apiUrl,
  exchangeUrl,
  audience,
  projectId,
  workflowPath,
  envSource,
  fetchImpl = fetch,
  debugEnabled = false,
}) {
  if (!projectId) {
    throw new Error('Missing required input: project_id when app_token is not provided');
  }
  if (!exchangeUrl) {
    throw new Error('Missing OIDC exchange URL.');
  }

  const oidcToken = await requestGithubOidcToken(audience, envSource, fetchImpl, debugEnabled);
  debug(
    debugEnabled,
    `Exchanging GitHub OIDC token at ${exchangeUrl} for project_id=${projectId}${workflowPath ? ` workflow_path=${workflowPath}` : ''}.`,
  );

  let response;
  try {
    response = await fetchImpl(exchangeUrl, {
      method: 'POST',
      headers: {
        Accept: 'application/json',
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        api_url: apiUrl,
        project_id: projectId,
        workflow_path: workflowPath || '',
        oidc_token: oidcToken,
        audience,
      }),
    });
  } catch (error) {
    throw new Error(`OIDC token exchange request failed: ${error.message}`);
  }
  debug(debugEnabled, `OIDC exchange response status: ${response.status}.`);

  if (!response.ok) {
    const detail = await readErrorDetail(response);
    throw new Error(`OIDC token exchange failed with status ${response.status}${detail ? `: ${detail}` : ''}.`);
  }

  const payload = await parseJsonResponse(response, 'OIDC token exchange');
  const token = extractTokenFromExchangeResponse(payload);
  if (!token) {
    throw new Error('OIDC exchange response did not include an API token or access token.');
  }
  debug(debugEnabled, 'OIDC exchange returned a runtime token.');
  return token;
}

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
if ! curl -sSf -H "x-api-key: $IR_TOKEN" "$BOOTSTRAP_URL" | bash; then
  http_status=$(curl -sS -o /dev/null -w "%{http_code}" -H "x-api-key: $IR_TOKEN" "$BOOTSTRAP_URL" || true)
  if [ "$http_status" = "401" ]; then
    echo "::error title=PSE bootstrap unauthorized::Unauthorized request from InvisiRisk bootstrap API. Verify app_token is valid for $IR_URL."
  elif [ "$http_status" = "403" ]; then
    echo "::error title=PSE bootstrap forbidden::Forbidden request from InvisiRisk bootstrap API. Verify app_token is authorized for $IR_URL and has access to the target project."
  fi
  exit 1
fi
`;

  try {
    execFile('bash', ['-lc', bootstrapCommand], {
      stdio: 'inherit',
      env,
    });
  } catch (error) {
    throw new Error('PSE bootstrap failed. See the annotated error above for details.');
  }
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

async function run({
  execFile = execFileSync,
  inputReader = getInput,
  envSource = process.env,
  fetchImpl = fetch,
} = {}) {
  const env = buildRuntimeEnv(inputReader, envSource);

  if (!env.IR_URL) {
    throw new Error('Missing required input: api_url');
  }
  const debugEnabled = pick(inputReader('debug'), env.DEBUG, envSource.DEBUG) === 'true';
  if (!env.IR_TOKEN) {
    info('No API token provided; using GitHub OIDC token exchange.');
    const audience = pick(inputReader('oidc_audience'), envSource.GITHUB_OIDC_AUDIENCE, DEFAULT_OIDC_AUDIENCE);
    const exchangeUrl = buildOidcExchangeUrl(env.IR_URL, pick(inputReader('oidc_exchange_url')));
    env.IR_TOKEN = await exchangeOidcForToken({
      apiUrl: env.IR_URL,
      exchangeUrl,
      audience,
      projectId: pick(inputReader('project_id'), envSource.PSE_PROJECT_ID, envSource.PROJECT_ID),
      workflowPath: pick(inputReader('workflow_path'), envSource.PSE_WORKFLOW_PATH),
      envSource,
      fetchImpl,
      debugEnabled,
    });
    maskSecret(env.IR_TOKEN);
    exportVariable('IR_TOKEN', env.IR_TOKEN);
    info('OIDC exchange succeeded; runtime token exported as IR_TOKEN.');
  } else {
    debug(debugEnabled, 'Using provided API token.');
  }

  console.log(`Running PSE setup in ${env.MODE || 'native'} mode...`);
  runBootstrap(env, execFile);
  saveState('pse_setup_completed', 'true');
}

if (require.main === module) {
  Promise.resolve()
    .then(async () => {
      if (!handleDeprecatedInputs()) {
        await run();
      }
    })
    .catch((error) => {
      console.error(`PSE setup failed: ${error.message}`);
      process.exit(1);
    });
}

module.exports = {
  buildRuntimeEnv,
  buildOidcExchangeUrl,
  exchangeOidcForToken,
  extractTokenFromExchangeResponse,
  requestGithubOidcToken,
  runBootstrap,
  run,
};
