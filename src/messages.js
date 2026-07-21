const CONFIGURATION_REQUIRED = {
  title: 'BAF configuration required',
  message: 'Secure sign-in is not configured correctly. Contact your BAF administrator.',
};

const WORKFLOW_ACCESS_REQUIRED = {
  title: 'BAF requires workflow access',
  message: 'BAF requires permission to read this workflow run. Add "actions: read" to the workflow permissions, then rerun the workflow.',
};

const WORKFLOW_CONTEXT_MISSING = {
  title: 'BAF could not verify this workflow',
  message: 'BAF could not identify the current GitHub Actions run. Ensure BAF is running inside a GitHub Actions workflow.',
};

const WORKFLOW_UNAVAILABLE = {
  title: 'BAF workflow verification unavailable',
  message: 'This runner cannot provide the current workflow details. Use a supported GitHub Actions runner or contact your BAF administrator.',
};

const WORKFLOW_CONNECTION_UNAVAILABLE = {
  title: 'GitHub connection unavailable',
  message: 'BAF could not reach GitHub to verify this workflow. Verify the runner can connect to GitHub, then rerun the workflow.',
};

const WORKFLOW_RESPONSE_INVALID = {
  title: 'BAF could not verify this workflow',
  message: 'GitHub returned an unexpected response while BAF was verifying this workflow. Retry the workflow; if the issue persists, contact your BAF administrator.',
};

const WORKFLOW_ID_MISSING = {
  title: 'BAF could not verify this workflow',
  message: 'BAF could not identify the current workflow. Retry the workflow; if the issue persists, contact your BAF administrator.',
};

const BRANCH_REQUIRED = {
  title: 'BAF requires a branch-based run',
  message: 'BAF could not identify a branch for this run. Workflows started from a tag or without a branch are not supported.',
};

const SECURE_SIGN_IN_ACCESS_REQUIRED = {
  title: 'BAF requires secure sign-in access',
  message: 'BAF requires permission to verify this workflow with GitHub. Add "id-token: write" to the workflow permissions, then rerun the workflow.',
};

const SECURE_SIGN_IN_UNAVAILABLE = {
  title: 'BAF secure sign-in unavailable',
  message: 'This runner does not support BAF secure sign-in. Use a supported GitHub Actions runner or contact your BAF administrator.',
};

const GITHUB_CONNECTION_UNAVAILABLE = {
  title: 'GitHub connection unavailable',
  message: 'BAF could not reach GitHub for secure sign-in. Verify the runner can connect to GitHub, then rerun the workflow.',
};

const GITHUB_ACCESS_DENIED = {
  title: 'BAF requires secure sign-in access',
  message: 'GitHub did not allow BAF to verify this workflow. Add "id-token: write" to the workflow permissions, then rerun the workflow.',
};

const GITHUB_RESPONSE_INVALID = {
  title: 'BAF secure sign-in failed',
  message: 'GitHub returned an unexpected secure sign-in response. Retry the workflow; if the issue persists, contact your BAF administrator.',
};

const GITHUB_TOKEN_MISSING = {
  title: 'BAF secure sign-in failed',
  message: 'GitHub did not complete secure sign-in for this workflow. Retry the workflow; if the issue persists, contact your BAF administrator.',
};

const EXCHANGE_CONNECTION_UNAVAILABLE = {
  title: 'BAF connection unavailable',
  message: 'The runner could not reach BAF for secure sign-in. Verify the runner network connection, then rerun the workflow.',
};

const EXCHANGE_RESPONSE_INVALID = {
  title: 'BAF secure sign-in failed',
  message: 'BAF received an unexpected secure sign-in response. Retry the workflow; if the issue persists, contact your BAF administrator.',
};

const EXCHANGE_TOKEN_MISSING = {
  title: 'BAF secure sign-in failed',
  message: 'BAF secure sign-in did not complete. Retry the workflow; if the issue persists, contact your BAF administrator.',
};

const OIDC_MESSAGES = {
  configurationRequired: CONFIGURATION_REQUIRED,
  github: {
    accessRequired: SECURE_SIGN_IN_ACCESS_REQUIRED,
    runnerUnavailable: SECURE_SIGN_IN_UNAVAILABLE,
    connectionUnavailable: GITHUB_CONNECTION_UNAVAILABLE,
    accessDenied: GITHUB_ACCESS_DENIED,
    invalidResponse: GITHUB_RESPONSE_INVALID,
    tokenMissing: GITHUB_TOKEN_MISSING,
  },
  workflow: {
    accessRequired: WORKFLOW_ACCESS_REQUIRED,
    contextMissing: WORKFLOW_CONTEXT_MISSING,
    runnerUnavailable: WORKFLOW_UNAVAILABLE,
    connectionUnavailable: WORKFLOW_CONNECTION_UNAVAILABLE,
    invalidResponse: WORKFLOW_RESPONSE_INVALID,
    idMissing: WORKFLOW_ID_MISSING,
    branchRequired: BRANCH_REQUIRED,
  },
  exchange: {
    connectionUnavailable: EXCHANGE_CONNECTION_UNAVAILABLE,
    invalidResponse: EXCHANGE_RESPONSE_INVALID,
    tokenMissing: EXCHANGE_TOKEN_MISSING,
  },
};

const REQUEST_ERROR_MESSAGES = {
  github: {
    access: WORKFLOW_ACCESS_REQUIRED,
    notFound: {
      title: 'BAF could not verify this workflow',
      message: 'GitHub could not locate the current workflow run. Rerun the workflow; if the issue persists, contact your BAF administrator.',
    },
    unavailable: {
      title: 'GitHub is temporarily unavailable',
      message: 'BAF could not verify this workflow with GitHub. Retry the workflow; if the issue persists, contact your BAF administrator.',
    },
    default: {
      title: 'BAF could not verify this workflow',
      message: 'BAF could not verify the current workflow run. Retry the workflow; if the issue persists, contact your BAF administrator.',
    },
  },
  oidc: {
    unauthorized: {
      title: 'BAF requires secure sign-in access',
      message: 'GitHub could not verify this workflow for BAF. Add "id-token: write" to the workflow permissions, then rerun the workflow.',
    },
    forbidden: {
      title: 'BAF project connection required',
      message: 'This repository, branch, or workflow is not connected to an active BAF project. Verify the project mapping and GitHub App installation in BAF, then rerun the workflow.',
    },
    notFound: {
      title: 'BAF project connection required',
      message: 'No BAF project connection was found for this workflow. Connect the repository, branch, and workflow to a BAF project, then rerun the workflow.',
    },
    rateLimited: {
      title: 'BAF sign-in temporarily unavailable',
      message: 'BAF cannot accept another secure sign-in request at this time. Retry the workflow shortly.',
    },
    unavailable: {
      title: 'BAF sign-in temporarily unavailable',
      message: 'BAF secure sign-in is temporarily unavailable. Retry the workflow; if the issue persists, contact your BAF administrator.',
    },
    default: {
      title: 'BAF secure sign-in failed',
      message: 'BAF could not complete secure sign-in. Retry the workflow; if the issue persists, contact your BAF administrator.',
    },
  },
};

const REQUEST_ERROR_TYPES = {
  github: {
    401: 'access',
    403: 'access',
    404: 'notFound',
    429: 'unavailable',
    serverError: 'unavailable',
  },
  oidc: {
    401: 'unauthorized',
    403: 'forbidden',
    404: 'notFound',
    429: 'rateLimited',
    serverError: 'unavailable',
  },
};

function getRequestErrorMessage(origin, status) {
  const messages = REQUEST_ERROR_MESSAGES[origin];
  const types = REQUEST_ERROR_TYPES[origin];
  if (!messages || !types) {
    throw new Error(`Unsupported request error origin: ${origin}`);
  }

  const errorType = types[status] || (status >= 500 ? types.serverError : 'default');
  return messages[errorType];
}

module.exports = {
  getRequestErrorMessage,
  OIDC_MESSAGES,
};
