const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {
  buildOidcExchangeUrl,
  exchangeOidcForToken,
  extractTokenFromExchangeResponse,
  matrixIdentifier,
  requestGithubWorkflowContext,
  requestGithubOidcToken,
  reportFailure,
  run,
  runBootstrap,
} = require('./index');

test('buildOidcExchangeUrl defaults to /oidc/exchange', () => {
  assert.equal(
    buildOidcExchangeUrl('https://ir.example'),
    'https://ir.example/oidc/exchange',
  );
});

test('requestGithubWorkflowContext resolves numeric workflow ID and branch', async () => {
  const context = await requestGithubWorkflowContext({
    githubToken: 'github-api-token',
    envSource: {
      GITHUB_API_URL: 'https://github.example/api/v3',
      GITHUB_REPOSITORY: 'invisirisk/pse-action',
      GITHUB_RUN_ID: '987654',
      GITHUB_REF_NAME: 'fallback-branch',
    },
    fetchImpl: async (url, options) => {
      assert.equal(url, 'https://github.example/api/v3/repos/invisirisk/pse-action/actions/runs/987654');
      assert.equal(options.headers.Authorization, 'Bearer github-api-token');
      return {
        ok: true,
        status: 200,
        json: async () => ({ workflow_id: 12345, head_branch: 'feature/oidc-context' }),
      };
    },
  });

  assert.deepEqual(context, {
    branch: 'feature/oidc-context',
    workflowId: 12345,
  });
});

test('requestGithubWorkflowContext rejects runs without head_branch', async () => {
  await assert.rejects(async () => {
    await requestGithubWorkflowContext({
      githubToken: 'github-api-token',
      envSource: {
        GITHUB_REPOSITORY: 'invisirisk/pse-action',
        GITHUB_RUN_ID: '987654',
        GITHUB_REF_NAME: 'tag-that-must-not-be-used-as-a-branch',
      },
      fetchImpl: async () => ({
        ok: true,
        status: 200,
        json: async () => ({ workflow_id: 12345, head_branch: null }),
      }),
    });
  }, /could not identify a branch.*tag or without a branch are not supported/);
});

test('requestGithubWorkflowContext includes the GitHub HTTP status in request errors', async () => {
  await assert.rejects(async () => {
    await requestGithubWorkflowContext({
      githubToken: 'github-api-token',
      envSource: {
        GITHUB_REPOSITORY: 'invisirisk/pse-action',
        GITHUB_RUN_ID: '987654',
      },
      fetchImpl: async () => ({ ok: false, status: 403 }),
    });
  }, /HTTP status 403/);
});

test('requestGithubWorkflowContext logs request exceptions only at debug level', async () => {
  const messages = [];
  const originalLog = console.log;
  console.log = (message) => messages.push(message);

  try {
    for (const debugEnabled of [false, true]) {
      await assert.rejects(async () => {
        await requestGithubWorkflowContext({
          githubToken: 'github-api-token',
          envSource: {
            GITHUB_REPOSITORY: 'invisirisk/pse-action',
            GITHUB_RUN_ID: '987654',
          },
          fetchImpl: async () => {
            throw new Error('socket closed unexpectedly');
          },
          debugEnabled,
        });
      }, /could not reach GitHub/);
    }
  } finally {
    console.log = originalLog;
  }

  assert.equal(
    messages.filter((message) => message === '::debug::GitHub workflow context request failed: socket closed unexpectedly').length,
    1,
  );
});

test('requestGithubOidcToken explains how to enable secure sign-in', async () => {
  await assert.rejects(async () => {
    await requestGithubOidcToken('invisirisk-oidc-validator', {});
  }, /requires permission to verify this workflow.*id-token: write/);
});

test('reportFailure creates a clear GitHub error annotation without a public error code', async () => {
  let oidcFailure;
  try {
    await requestGithubOidcToken('invisirisk-oidc-validator', {});
  } catch (error) {
    oidcFailure = error;
  }

  const messages = [];
  reportFailure(oidcFailure, (message) => messages.push(message));

  assert.equal(messages.length, 1);
  assert.match(messages[0], /^::error title=BAF requires secure sign-in access::/);
  assert.match(messages[0], /Add "id-token: write" to the workflow permissions/);
  assert.doesNotMatch(messages[0], /BAF-OIDC|Reference:/);
});

test('runBootstrap sets mode to native for docker-intercept or missing MODE', () => {
  // MODE is docker-intercept
  let env = {
    IR_URL: 'https://ir.example',
    IR_TOKEN: 'token',
    MODE: 'docker-intercept',
    RUNNER: 'github',
  };
  let called = false;
  runBootstrap(env, (cmd, args, opts) => {
    called = true;
    // BOOTSTRAP_URL should have mode=native
    assert.match(opts.env.BOOTSTRAP_URL, /mode=native/);
  });
  assert.ok(called);

  // MODE is missing
  env = {
    IR_URL: 'https://ir.example',
    IR_TOKEN: 'token',
    RUNNER: 'github',
  };
  called = false;
  runBootstrap(env, (cmd, args, opts) => {
    called = true;
    assert.match(opts.env.BOOTSTRAP_URL, /mode=native/);
  });
  assert.ok(called);

  // MODE is something else
  env = {
    IR_URL: 'https://ir.example',
    IR_TOKEN: 'token',
    MODE: 'sidecar',
    RUNNER: 'github',
  };
  called = false;
  runBootstrap(env, (cmd, args, opts) => {
    called = true;
    assert.match(opts.env.BOOTSTRAP_URL, /mode=sidecar/);
  });
  assert.ok(called);
});

test('run passes pse_image_tag through to bootstrap environment', async () => {
  const inputs = {
    api_url: 'https://ir.example',
    app_token: 'token',
    debug: 'true',
    mode: 'sidecar',
    pse_image_tag: 'release-2026-05',
    collect_dependencies: 'true',
    workdir: '/workspace',
    github_token: '',
  };
  let execCall;

  await run({
    execFile: (...args) => {
      execCall = args;
    },
    inputReader: (name) => inputs[name] || '',
    envSource: { GITHUB_TOKEN: 'default-gh-token' },
  });

  assert.equal(execCall[0], 'bash');
  assert.equal(execCall[1][0], '-lc');
  assert.match(execCall[1][1], /if ! curl -sSf -H "x-api-key: \$IR_TOKEN" "\$BOOTSTRAP_URL" \| bash; then/);
  assert.match(execCall[1][1], /http_status=\$\(curl -sS -o \/dev\/null -w "%\{http_code\}" -H "x-api-key: \$IR_TOKEN" "\$BOOTSTRAP_URL" \|\| true\)/);
  assert.match(execCall[1][1], /::error title=PSE bootstrap forbidden::Forbidden request from InvisiRisk bootstrap API\./);
  assert.equal(execCall[2].env.PSE_IMAGE_TAG, 'release-2026-05');
  assert.equal(execCall[2].env.GITHUB_TOKEN, 'default-gh-token');
  assert.match(execCall[2].env.BOOTSTRAP_URL, /mode=sidecar/);
  assert.doesNotMatch(execCall[2].env.BOOTSTRAP_URL, /api_key=/);
  assert.doesNotMatch(execCall[2].env.BOOTSTRAP_URL, /ir_token=/);
});

test('run resolves token from env fallback', async () => {
  const inputs = {
    api_url: 'https://ir.example',
    app_token: '',
    debug: 'true',
    mode: 'sidecar',
    pse_image_tag: '',
    collect_dependencies: 'true',
    workdir: '/workspace',
    github_token: '',
  };
  let execCall;

  await run({
    execFile: (...args) => {
      execCall = args;
    },
    inputReader: (name) => inputs[name] || '',
    envSource: { GITHUB_TOKEN: 'default-gh-token', IR_TOKEN: 'fallback-token' },
  });

  assert.equal(execCall[2].env.IR_TOKEN, 'fallback-token');
  assert.equal(execCall[2].env.PSE_IMAGE_TAG, 'latest');
  assert.equal(execCall[2].env.GITHUB_TOKEN, 'default-gh-token');
});

test('run logs use of a provided API token only at debug level', async () => {
  const messages = [];
  const originalLog = console.log;
  console.log = (message) => messages.push(message);

  try {
    for (const debugEnabled of ['false', 'true']) {
      await run({
        execFile: () => {},
        inputReader: (name) => ({
          api_url: 'https://ir.example',
          app_token: 'provided-token',
          debug: debugEnabled,
          mode: 'native',
        })[name] || '',
        envSource: {},
      });
    }
  } finally {
    console.log = originalLog;
  }

  assert.equal(
    messages.filter((message) => message === '::debug::Using provided API token.').length,
    1,
  );
});

test('run exchanges GitHub OIDC for token when app_token is missing', async () => {
  const inputs = {
    api_url: 'https://ir.example',
    app_token: '',
    debug: 'false',
    mode: 'native',
    github_token: 'github-api-token',
  };
  const githubEnvFile = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'pse-action-')), 'env');
  const originalGithubEnv = process.env.GITHUB_ENV;
  process.env.GITHUB_ENV = githubEnvFile;
  const calls = [];
  let execCall;

  try {
    await run({
      execFile: (...args) => {
        execCall = args;
      },
      inputReader: (name) => inputs[name] || '',
      envSource: {
        ACTIONS_ID_TOKEN_REQUEST_URL: 'https://token.actions.githubusercontent.com/id-token',
        ACTIONS_ID_TOKEN_REQUEST_TOKEN: 'github-request-token',
        GITHUB_REPOSITORY: 'invisirisk/pse-action',
        GITHUB_RUN_ID: '987654',
        GITHUB_REF_NAME: 'fallback-branch',
      },
      fetchImpl: async (url, options) => {
        calls.push({ url, options });
        if (url === 'https://api.github.com/repos/invisirisk/pse-action/actions/runs/987654') {
          return {
            ok: true,
            status: 200,
            json: async () => ({ workflow_id: 12345, head_branch: 'feature/oidc-context' }),
          };
        }
        if (url.startsWith('https://token.actions.githubusercontent.com/id-token')) {
          return {
            ok: true,
            status: 200,
            json: async () => ({ value: 'github-oidc-token' }),
          };
        }
        return {
          ok: true,
          status: 200,
          json: async () => ({ api_key: 'exchanged-runtime-token' }),
        };
      },
    });
  } finally {
    if (originalGithubEnv === undefined) {
      delete process.env.GITHUB_ENV;
    } else {
      process.env.GITHUB_ENV = originalGithubEnv;
    }
  }

  assert.equal(calls.length, 3);
  assert.equal(calls[0].options.headers.Authorization, 'Bearer github-api-token');
  assert.match(calls[1].url, /audience=invisirisk-oidc-validator/);
  assert.equal(calls[1].options.headers.Authorization, 'Bearer github-request-token');
  assert.equal(calls[2].url, 'https://ir.example/oidc/exchange');
  assert.deepEqual(JSON.parse(calls[2].options.body), {
    oidc_token: 'github-oidc-token',
    branch: 'feature/oidc-context',
    workflow_id: 12345,
  });
  assert.equal(execCall[2].env.IR_TOKEN, 'exchanged-runtime-token');
  assert.match(fs.readFileSync(githubEnvFile, 'utf8'), /IR_TOKEN=exchanged-runtime-token/);
});

test('extractTokenFromExchangeResponse handles Lambda proxy response body', () => {
  const token = extractTokenFromExchangeResponse({
    statusCode: 200,
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      success: true,
      project_id: '0ed5e5c5-823c-4d5c-bafa-d5962ee4738c',
      api_key: 'lambda-proxy-api-key',
    }),
  });

  assert.equal(token, 'lambda-proxy-api-key');
});

test('extractTokenFromExchangeResponse only accepts api_key', () => {
  assert.equal(extractTokenFromExchangeResponse({ access_token: 'ignored-token' }), '');
  assert.equal(extractTokenFromExchangeResponse({ data: { api_key: 'ignored-token' } }), '');
});

test('run throws helpful error when api_url is missing', async () => {
  await assert.rejects(async () => {
    await run({
      inputReader: (name) => {
        const inputs = {
          api_url: '',
          app_token: 'token',
          debug: 'true',
          mode: 'native',
          pse_image_tag: 'latest',
          collect_dependencies: 'true',
          workdir: '/workspace',
          github_token: '',
        };
        return inputs[name] || '';
      },
    });
  }, /Missing required input: api_url/);
});

test('run throws helpful error when GitHub workflow context is unavailable', async () => {
  await assert.rejects(async () => {
    await run({
      inputReader: (name) => {
        const inputs = {
          api_url: 'https://ir.example',
          app_token: '',
          debug: 'false',
          mode: 'native',
        };
        return inputs[name] || '';
      },
      envSource: {},
    });
  }, /requires permission to read this workflow run.*actions: read/);
});

test('exchangeOidcForToken explains an inactive project connection without exposing backend detail', async () => {
  let callCount = 0;

  await assert.rejects(async () => {
    await exchangeOidcForToken({
      exchangeUrl: 'https://ir.example/oidc/exchange',
      audience: 'invisirisk-oidc-validator',
      branch: 'develop',
      workflowId: 12345,
      envSource: {
        ACTIONS_ID_TOKEN_REQUEST_URL: 'https://token.actions.githubusercontent.com/id-token',
        ACTIONS_ID_TOKEN_REQUEST_TOKEN: 'github-request-token',
      },
      fetchImpl: async () => {
        callCount += 1;
        if (callCount === 1) {
          return {
            ok: true,
            status: 200,
            json: async () => ({ value: 'github-oidc-token' }),
          };
        }
        return {
          ok: false,
          status: 403,
          json: async () => ({ detail: 'repository is not mapped to project' }),
        };
      },
    });
  }, (error) => {
    assert.match(error.message, /not connected to an active BAF project/);
    assert.doesNotMatch(error.message, /repository is not mapped to project/);
    assert.match(error.message, /HTTP status 403/);
    return true;
  });
});

test('exchangeOidcForToken normalizes a Lambda proxy error for the user', async () => {
  let callCount = 0;

  await assert.rejects(async () => {
    await exchangeOidcForToken({
      exchangeUrl: 'https://ir.example/oidc/exchange',
      audience: 'invisirisk-oidc-validator',
      branch: 'develop',
      workflowId: 12345,
      envSource: {
        ACTIONS_ID_TOKEN_REQUEST_URL: 'https://token.actions.githubusercontent.com/id-token',
        ACTIONS_ID_TOKEN_REQUEST_TOKEN: 'github-request-token',
      },
      fetchImpl: async () => {
        callCount += 1;
        if (callCount === 1) {
          return {
            ok: true,
            status: 200,
            json: async () => ({ value: 'github-oidc-token' }),
          };
        }
        return {
          ok: true,
          status: 200,
          json: async () => ({
            statusCode: 403,
            body: JSON.stringify({
              success: false,
              message: 'No active repository mapping found for repository',
            }),
          }),
        };
      },
    });
  }, (error) => {
    assert.match(error.message, /not connected to an active BAF project/);
    assert.doesNotMatch(error.message, /No active repository mapping/);
    assert.match(error.message, /HTTP status 403/);
    return true;
  });
});

test('exchangeOidcForToken hides malformed response details from the user', async () => {
  let callCount = 0;

  await assert.rejects(async () => {
    await exchangeOidcForToken({
      exchangeUrl: 'https://ir.example/oidc/exchange',
      audience: 'invisirisk-oidc-validator',
      branch: 'develop',
      workflowId: 12345,
      envSource: {
        ACTIONS_ID_TOKEN_REQUEST_URL: 'https://token.actions.githubusercontent.com/id-token',
        ACTIONS_ID_TOKEN_REQUEST_TOKEN: 'github-request-token',
      },
      fetchImpl: async () => {
        callCount += 1;
        if (callCount === 1) {
          return {
            ok: true,
            status: 200,
            json: async () => ({ value: 'github-oidc-token' }),
          };
        }
        return {
          ok: true,
          status: 200,
          json: async () => {
            throw new Error('invalid json');
          },
        };
      },
    });
  }, /unexpected secure sign-in response/);
});

test('run passes job_name through to bootstrap environment', () => {
  const inputs = {
    api_url: 'https://ir.example',
    app_token: 'token',
    github_token: '',
    job_name: 'build',
    matrix_obj: JSON.stringify({ name: 'ubuntu-2204', base_image: 'ubuntu:22.04' }, null, 2),
  };
  let execCall;

  run({
    execFile: (...args) => {
      execCall = args;
    },
    inputReader: (name) => inputs[name] || '',
    envSource: { GITHUB_TOKEN: 'default-gh-token', GITHUB_JOB: 'build' },
  });

  assert.equal(execCall[2].env.JOB_NAME, 'build ubuntu-2204');
});

test('matrixIdentifier prefers label, then name, with a stable hash fallback', () => {
  assert.equal(matrixIdentifier(JSON.stringify({ label: 'Linux AMD64', name: 'ubuntu-2204' })), 'Linux AMD64');
  assert.equal(matrixIdentifier(JSON.stringify({ name: 'rockylinux-8' }, null, 2)), 'rockylinux-8');

  const fallback = matrixIdentifier(JSON.stringify({ os: 'ubuntu-latest', node: 20 }));
  assert.match(fallback, /^matrix-[0-9a-f]{8}$/);
  assert.equal(fallback, matrixIdentifier(JSON.stringify({ os: 'ubuntu-latest', node: 20 })));
});

test('run falls back to GITHUB_JOB when job_name expression is not evaluated', () => {
  const inputs = {
    api_url: 'https://ir.example',
    app_token: 'token',
    github_token: '',
    job_name: '${{ github.job }}${{ toJson(matrix) }}',
  };
  let execCall;

  run({
    execFile: (...args) => {
      execCall = args;
    },
    inputReader: (name) => inputs[name] || '',
    envSource: { GITHUB_TOKEN: 'default-gh-token', GITHUB_JOB: 'build' },
  });

  assert.equal(execCall[2].env.JOB_NAME, 'build');
});
