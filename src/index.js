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

function buildOidcExchangeUrl(apiUrl) {
  try {
    return new URL('/oidc/exchange', apiUrl).toString();
  } catch (_) {
    throw oidcError(
      'PSE configuration required',
      'Secure sign-in is not configured correctly. Contact your PSE administrator.',
    );
  }
}

async function parseJsonResponse(response, reference, message) {
  try {
    return await response.json();
  } catch (_) {
    throw oidcError(reference, message);
  }
}

function githubWorkflowRequestError(status) {
  if (status === 401 || status === 403) {
    return oidcError(
      'PSE requires workflow access',
      'PSE requires permission to read this workflow run. Add "actions: read" to the workflow permissions, then rerun the workflow.',
    );
  }
  if (status === 404) {
    return oidcError(
      'PSE could not verify this workflow',
      'GitHub could not locate the current workflow run. Rerun the workflow; if the issue persists, contact your PSE administrator.',
    );
  }
  if (status === 429 || status >= 500) {
    return oidcError(
      'GitHub is temporarily unavailable',
      'PSE could not verify this workflow with GitHub. Retry the workflow; if the issue persists, contact your PSE administrator.',
    );
  }
  return oidcError(
    'PSE could not verify this workflow',
    'PSE could not verify the current workflow run. Retry the workflow; if the issue persists, contact your PSE administrator.',
  );
}

function oidcExchangeRequestError(status) {
  if (status === 401) {
    return oidcError(
      'PSE requires secure sign-in access',
      'GitHub could not verify this workflow for PSE. Add "id-token: write" to the workflow permissions, then rerun the workflow.',
    );
  }
  if (status === 403) {
    return oidcError(
      'PSE project connection required',
      'This repository, branch, or workflow is not connected to an active PSE project. Verify the project mapping and GitHub App installation in PSE, then rerun the workflow.',
    );
  }
  if (status === 404) {
    return oidcError(
      'PSE project connection required',
      'No PSE project connection was found for this workflow. Connect the repository, branch, and workflow to a PSE project, then rerun the workflow.',
    );
  }
  if (status === 429) {
    return oidcError(
      'PSE sign-in temporarily unavailable',
      'PSE cannot accept another secure sign-in request at this time. Retry the workflow shortly.',
    );
  }
  if (status >= 500) {
    return oidcError(
      'PSE sign-in temporarily unavailable',
      'PSE secure sign-in is temporarily unavailable. Retry the workflow; if the issue persists, contact your PSE administrator.',
    );
  }
  return oidcError(
    'PSE secure sign-in failed',
    'PSE could not complete secure sign-in. Retry the workflow; if the issue persists, contact your PSE administrator.',
  );
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
    throw oidcError(
      'PSE requires secure sign-in access',
      'PSE requires permission to verify this workflow with GitHub. Add "id-token: write" to the workflow permissions, then rerun the workflow.',
    );
  }
  if (!fetchImpl) {
    throw oidcError(
      'PSE secure sign-in unavailable',
      'This runner does not support PSE secure sign-in. Use a supported GitHub Actions runner or contact your PSE administrator.',
    );
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
  } catch (_) {
    throw oidcError(
      'GitHub connection unavailable',
      'PSE could not reach GitHub for secure sign-in. Verify the runner can connect to GitHub, then rerun the workflow.',
    );
  }

  if (!response.ok) {
    throw oidcError(
      'PSE requires secure sign-in access',
      'GitHub did not allow PSE to verify this workflow. Add "id-token: write" to the workflow permissions, then rerun the workflow.',
    );
  }

  const payload = await parseJsonResponse(
    response,
    'PSE secure sign-in failed',
    'GitHub returned an unexpected secure sign-in response. Retry the workflow; if the issue persists, contact your PSE administrator.',
  );
  if (!payload || typeof payload.value !== 'string' || !payload.value) {
    throw oidcError(
      'PSE secure sign-in failed',
      'GitHub did not complete secure sign-in for this workflow. Retry the workflow; if the issue persists, contact your PSE administrator.',
    );
  }
  debug(debugEnabled, 'Received GitHub OIDC token.');
  return payload.value;
}

async function requestGithubWorkflowContext({
  githubToken,
  envSource = process.env,
  fetchImpl = fetch,
  debugEnabled = false,
}) {
  if (!githubToken) {
    throw oidcError(
      'PSE requires workflow access',
      'PSE requires permission to read this workflow run. Add "actions: read" to the workflow permissions, then rerun the workflow.',
    );
  }
  if (!envSource.GITHUB_REPOSITORY || !envSource.GITHUB_RUN_ID) {
    throw oidcError(
      'PSE could not verify this workflow',
      'PSE could not identify the current GitHub Actions run. Ensure PSE is running inside a GitHub Actions workflow.',
    );
  }
  if (!fetchImpl) {
    throw oidcError(
      'PSE workflow verification unavailable',
      'This runner cannot provide the current workflow details. Use a supported GitHub Actions runner or contact your PSE administrator.',
    );
  }

  const [owner, repository] = envSource.GITHUB_REPOSITORY.split('/');
  if (!owner || !repository) {
    throw oidcError(
      'PSE could not verify this workflow',
      'PSE could not identify the current GitHub Actions run. Ensure PSE is running inside a GitHub Actions workflow.',
    );
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
  } catch (_) {
    throw oidcError(
      'GitHub connection unavailable',
      'PSE could not reach GitHub to verify this workflow. Verify the runner can connect to GitHub, then rerun the workflow.',
    );
  }

  if (!response.ok) {
    throw githubWorkflowRequestError(response.status);
  }

  const payload = await parseJsonResponse(
    response,
    'PSE could not verify this workflow',
    'GitHub returned an unexpected response while PSE was verifying this workflow. Retry the workflow; if the issue persists, contact your PSE administrator.',
  );
  const workflowId = Number(payload && payload.workflow_id);
  if (!Number.isInteger(workflowId) || workflowId <= 0) {
    throw oidcError(
      'PSE could not verify this workflow',
      'PSE could not identify the current workflow. Retry the workflow; if the issue persists, contact your PSE administrator.',
    );
  }

  const branch = payload && typeof payload.head_branch === 'string'
    ? payload.head_branch.trim()
    : '';
  if (!branch) {
    throw oidcError(
      'PSE requires a branch-based run',
      'PSE could not identify a branch for this run. Workflows started from a tag or without a branch are not supported.',
    );
  }

  debug(debugEnabled, `Resolved GitHub branch "${branch}" and workflow_id ${workflowId}.`);
  return { branch, workflowId };
}

function extractTokenFromExchangeResponse(payload) {
  const normalizedPayload = unwrapLambdaProxyPayload(payload);
  return normalizedPayload && typeof normalizedPayload.api_key === 'string'
    ? normalizedPayload.api_key.trim()
    : '';
}

function unwrapLambdaProxyPayload(payload) {
  if (!payload || typeof payload !== 'object' || typeof payload.body !== 'string') {
    return payload;
  }

  try {
    return JSON.parse(payload.body);
  } catch (_) {
    throw oidcError(
      'PSE secure sign-in failed',
      'PSE received an unexpected secure sign-in response. Retry the workflow; if the issue persists, contact your PSE administrator.',
    );
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
    throw oidcError(
      'PSE configuration required',
      'Secure sign-in is not configured correctly. Contact your PSE administrator.',
    );
  }
  if (!branch) {
    throw oidcError(
      'PSE requires a branch-based run',
      'PSE could not identify a branch for this run. Workflows started from a tag or without a branch are not supported.',
    );
  }
  if (!Number.isInteger(Number(workflowId)) || Number(workflowId) <= 0) {
    throw oidcError(
      'PSE could not verify this workflow',
      'PSE could not identify the current workflow. Retry the workflow; if the issue persists, contact your PSE administrator.',
    );
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
  } catch (_) {
    throw oidcError(
      'PSE connection unavailable',
      'The runner could not reach PSE for secure sign-in. Verify the runner network connection, then rerun the workflow.',
    );
  }
  debug(debugEnabled, `OIDC exchange response status: ${response.status}.`);

  if (!response.ok) {
    throw oidcExchangeRequestError(response.status);
  }

  const payload = await parseJsonResponse(
    response,
    'PSE secure sign-in failed',
    'PSE received an unexpected secure sign-in response. Retry the workflow; if the issue persists, contact your PSE administrator.',
  );
  const payloadStatusCode = getExchangePayloadStatusCode(payload);
  if (payloadStatusCode !== null && (payloadStatusCode < 200 || payloadStatusCode >= 300)) {
    throw oidcExchangeRequestError(payloadStatusCode);
  }
  const token = extractTokenFromExchangeResponse(payload);
  if (!token) {
    throw oidcError(
      'PSE secure sign-in failed',
      'PSE secure sign-in did not complete. Retry the workflow; if the issue persists, contact your PSE administrator.',
    );
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
    const exchangeUrl = buildOidcExchangeUrl(env.IR_URL);
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
