const { execFileSync } = require('child_process');
const { getRequestErrorMessage, OIDC_MESSAGES } = require('./messages');
const { buildEnv, exportVariable, getInput, handleDeprecatedInputs, maskSecret, pick, saveState } = require('./utils');

const DEFAULT_OIDC_AUDIENCE = 'invisirisk-oidc-validator';

function info(message) {
  console.log(`[BAF] ${message}`);
}

function debug(enabled, message) {
  if (enabled) {
    console.log(`::debug::${message}`);
  }
}

class OidcError extends Error {
  constructor(title, message) {
    super(message);
    this.name = 'OidcError';
    this.title = title;
  }
}

function oidcError(title, message) {
  return new OidcError(title, message);
}

function oidcMessageError({ title, message }) {
  return oidcError(title, message);
}

function escapeWorkflowCommand(value) {
  return String(value)
    .replace(/%/g, '%25')
    .replace(/\r/g, '%0D')
    .replace(/\n/g, '%0A');
}

function reportFailure(error, log = console.error) {
  if (error instanceof OidcError) {
    log(`::error title=${escapeWorkflowCommand(error.title)}::${escapeWorkflowCommand(error.message)}`);
    return;
  }
  log(`PSE setup failed: ${error.message}`);
}

function buildOidcExchangeUrl(apiUrl, debugEnabled = false) {
  try {
    return new URL('/oidc/exchange', apiUrl).toString();
  } catch (error) {
    debug(debugEnabled, `Failed to build the OIDC exchange URL: ${error.message}`);
    throw oidcMessageError(OIDC_MESSAGES.configurationRequired);
  }
}

async function parseJsonResponse(response, errorMessage, debugEnabled = false) {
  try {
    return await response.json();
  } catch (error) {
    debug(debugEnabled, `Failed to parse JSON response: ${error.message}`);
    throw oidcMessageError(errorMessage);
  }
}

function withHttpStatus(message, status) {
  return `${message} (HTTP status ${status})`;
}

function handleRequestError(origin, status) {
  const { title, message } = getRequestErrorMessage(origin, status);
  return oidcError(title, withHttpStatus(message, status));
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
    throw oidcMessageError(OIDC_MESSAGES.github.accessRequired);
  }
  if (!fetchImpl) {
    throw oidcMessageError(OIDC_MESSAGES.github.runnerUnavailable);
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
    debug(debugEnabled, `GitHub OIDC token request failed: ${error.message}`);
    throw oidcMessageError(OIDC_MESSAGES.github.connectionUnavailable);
  }

  if (!response.ok) {
    throw oidcMessageError(OIDC_MESSAGES.github.accessDenied);
  }

  const payload = await parseJsonResponse(
    response,
    OIDC_MESSAGES.github.invalidResponse,
    debugEnabled,
  );
  if (!payload || typeof payload.value !== 'string' || !payload.value) {
    throw oidcMessageError(OIDC_MESSAGES.github.tokenMissing);
  }
  debug(debugEnabled, 'Received GitHub OIDC token.');
  return payload.value;
}

/**
 * Fetches the current GitHub Actions run from the GitHub API and extracts the
 * source branch and numeric workflow ID. These values identify the workflow to
 * BAF and are included in the subsequent OIDC token exchange request.
 *
 * @returns {Promise<{branch: string, workflowId: number}>} The validated
 * workflow context required by the OIDC exchange.
 */
async function requestGithubWorkflowContext({
  githubToken,
  envSource = process.env,
  fetchImpl = fetch,
  debugEnabled = false,
}) {
  if (!githubToken) {
    throw oidcMessageError(OIDC_MESSAGES.workflow.accessRequired);
  }
  if (!envSource.GITHUB_REPOSITORY || !envSource.GITHUB_RUN_ID) {
    throw oidcMessageError(OIDC_MESSAGES.workflow.contextMissing);
  }
  if (!fetchImpl) {
    throw oidcMessageError(OIDC_MESSAGES.workflow.runnerUnavailable);
  }

  const [owner, repository] = envSource.GITHUB_REPOSITORY.split('/');
  if (!owner || !repository) {
    throw oidcMessageError(OIDC_MESSAGES.workflow.contextMissing);
  }

  const apiUrl = pick(envSource.GITHUB_API_URL, 'https://api.github.com').replace(/\/$/, '');
  const workflowRunUrl = `${apiUrl}/repos/${encodeURIComponent(owner)}/${encodeURIComponent(repository)}/actions/runs/${encodeURIComponent(envSource.GITHUB_RUN_ID)}`;
  debug(debugEnabled, `Requesting GitHub workflow context for run ${envSource.GITHUB_RUN_ID}.`);

  let response;
  try {
    response = await fetchImpl(workflowRunUrl, {
      headers: {
        Authorization: `Bearer ${githubToken}`,
        Accept: 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
      },
    });
  } catch (error) {
    debug(debugEnabled, `GitHub workflow context request failed: ${error.message}`);
    throw oidcMessageError(OIDC_MESSAGES.workflow.connectionUnavailable);
  }
  debug(debugEnabled, `GitHub workflow context response status: ${response.status}.`);

  if (!response.ok) {
    throw handleRequestError('github', response.status);
  }

  const payload = await parseJsonResponse(
    response,
    OIDC_MESSAGES.workflow.invalidResponse,
    debugEnabled,
  );
  const workflowId = Number(payload && payload.workflow_id);
  if (!Number.isInteger(workflowId) || workflowId <= 0) {
    throw oidcMessageError(OIDC_MESSAGES.workflow.idMissing);
  }

  const branch = payload && typeof payload.head_branch === 'string'
    ? payload.head_branch.trim()
    : '';
  if (!branch) {
    throw oidcMessageError(OIDC_MESSAGES.workflow.branchRequired);
  }

  debug(debugEnabled, `Resolved GitHub branch "${branch}" and workflow_id ${workflowId}.`);
  return { branch, workflowId };
}

function extractTokenFromExchangeResponse(payload, debugEnabled = false) {
  const normalizedPayload = unwrapLambdaProxyPayload(payload, debugEnabled);
  return normalizedPayload && typeof normalizedPayload.api_key === 'string'
    ? normalizedPayload.api_key.trim()
    : '';
}

function unwrapLambdaProxyPayload(payload, debugEnabled = false) {
  if (!payload || typeof payload !== 'object' || typeof payload.body !== 'string') {
    return payload;
  }

  try {
    return JSON.parse(payload.body);
  } catch (error) {
    debug(debugEnabled, `Failed to parse OIDC Lambda proxy response: ${error.message}`);
    throw oidcMessageError(OIDC_MESSAGES.exchange.invalidResponse);
  }
}

function getExchangePayloadStatusCode(payload) {
  const statusCode = payload && Number(payload.statusCode);
  return Number.isInteger(statusCode) ? statusCode : null;
}

async function exchangeOidcForToken({
  exchangeUrl,
  audience,
  branch,
  workflowId,
  envSource,
  fetchImpl = fetch,
  debugEnabled = false,
}) {
  if (!exchangeUrl) {
    throw oidcMessageError(OIDC_MESSAGES.configurationRequired);
  }
  if (!branch) {
    throw oidcMessageError(OIDC_MESSAGES.workflow.branchRequired);
  }
  if (!Number.isInteger(Number(workflowId)) || Number(workflowId) <= 0) {
    throw oidcMessageError(OIDC_MESSAGES.workflow.idMissing);
  }

  const oidcToken = await requestGithubOidcToken(audience, envSource, fetchImpl, debugEnabled);
  debug(debugEnabled, `Exchanging GitHub OIDC token at ${exchangeUrl}.`);

  let response;
  try {
    response = await fetchImpl(exchangeUrl, {
      method: 'POST',
      headers: {
        Accept: 'application/json',
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        oidc_token: oidcToken,
        branch,
        workflow_id: Number(workflowId),
      }),
    });
  } catch (error) {
    debug(debugEnabled, `OIDC token exchange request failed: ${error.message}`);
    throw oidcMessageError(OIDC_MESSAGES.exchange.connectionUnavailable);
  }
  debug(debugEnabled, `OIDC exchange response status: ${response.status}.`);

  if (!response.ok) {
    throw handleRequestError('oidc', response.status);
  }

  const payload = await parseJsonResponse(
    response,
    OIDC_MESSAGES.exchange.invalidResponse,
    debugEnabled,
  );
  const payloadStatusCode = getExchangePayloadStatusCode(payload);
  if (payloadStatusCode !== null && (payloadStatusCode < 200 || payloadStatusCode >= 300)) {
    throw handleRequestError('oidc', payloadStatusCode);
  }
  const token = extractTokenFromExchangeResponse(payload, debugEnabled);
  if (!token) {
    throw oidcMessageError(OIDC_MESSAGES.exchange.tokenMissing);
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
    echo "::error title=PSE bootstrap unauthorized::Unauthorized request from InvisiRisk bootstrap API. Verify the authentication token is valid for $IR_URL."
  elif [ "$http_status" = "403" ]; then
    echo "::error title=PSE bootstrap forbidden::Forbidden request from InvisiRisk bootstrap API. Verify the authentication token is authorized for $IR_URL and has access to the target project."
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
    info('Signing in securely with GitHub...');
    const exchangeUrl = buildOidcExchangeUrl(env.IR_URL, debugEnabled);
    const workflowContext = await requestGithubWorkflowContext({
      githubToken: env.GITHUB_TOKEN,
      envSource,
      fetchImpl,
      debugEnabled,
    });
    env.IR_TOKEN = await exchangeOidcForToken({
      exchangeUrl,
      audience: DEFAULT_OIDC_AUDIENCE,
      branch: workflowContext.branch,
      workflowId: workflowContext.workflowId,
      envSource,
      fetchImpl,
      debugEnabled,
    });
    maskSecret(env.IR_TOKEN);
    exportVariable('IR_TOKEN', env.IR_TOKEN);
    info('Secure sign-in succeeded.');
  } else {
    info(debugEnabled, 'Using provided API token.');
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
      reportFailure(error);
      process.exit(1);
    });
}

module.exports = {
  buildRuntimeEnv,
  buildOidcExchangeUrl,
  exchangeOidcForToken,
  extractTokenFromExchangeResponse,
  requestGithubWorkflowContext,
  requestGithubOidcToken,
  reportFailure,
  runBootstrap,
  run,
};
