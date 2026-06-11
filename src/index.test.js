const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {
  buildOidcExchangeUrl,
  exchangeOidcForToken,
  extractTokenFromExchangeResponse,
  run,
  runBootstrap,
} = require('./index');

test('buildOidcExchangeUrl defaults to /oidc/exchange', () => {
  assert.equal(
    buildOidcExchangeUrl('https://ir.example'),
    'https://ir.example/oidc/exchange',
  );
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

test('run exchanges GitHub OIDC for token when app_token is missing', async () => {
  const inputs = {
    api_url: 'https://ir.example',
    app_token: '',
    oidc_exchange_url: 'https://auth.example/oidc/exchange',
    oidc_audience: 'invisirisk-oidc-validator',
    debug: 'false',
    mode: 'native',
    github_token: '',
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
      },
      fetchImpl: async (url, options) => {
        calls.push({ url, options });
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

  assert.equal(calls.length, 2);
  assert.match(calls[0].url, /audience=invisirisk-oidc-validator/);
  assert.equal(calls[0].options.headers.Authorization, 'Bearer github-request-token');
  assert.equal(calls[1].url, 'https://auth.example/oidc/exchange');
  assert.deepEqual(JSON.parse(calls[1].options.body), {
    oidc_token: 'github-oidc-token',
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

test('run uses GITHUB_OIDC_AUDIENCE when oidc_audience input is missing', async () => {
  const inputs = {
    api_url: 'https://ir.example',
    app_token: '',
    debug: 'false',
    mode: 'native',
    github_token: '',
  };
  const calls = [];

  await run({
    execFile: () => {},
    inputReader: (name) => inputs[name] || '',
    envSource: {
      ACTIONS_ID_TOKEN_REQUEST_URL: 'https://token.actions.githubusercontent.com/id-token',
      ACTIONS_ID_TOKEN_REQUEST_TOKEN: 'github-request-token',
      GITHUB_OIDC_AUDIENCE: 'invisirisk-oidc-validator',
    },
    fetchImpl: async (url) => {
      calls.push(url);
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

  assert.match(calls[0], /audience=invisirisk-oidc-validator/);
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

test('run throws helpful error when GitHub OIDC environment is unavailable', async () => {
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
  }, /GitHub OIDC is unavailable/);
});

test('exchangeOidcForToken includes exchange failure detail', async () => {
  let callCount = 0;

  await assert.rejects(async () => {
    await exchangeOidcForToken({
      exchangeUrl: 'https://ir.example/oidc/exchange',
      audience: 'invisirisk-oidc-validator',
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
  }, /OIDC token exchange failed with status 403: repository is not mapped to project/);
});

test('exchangeOidcForToken rejects Lambda proxy error response', async () => {
  let callCount = 0;

  await assert.rejects(async () => {
    await exchangeOidcForToken({
      exchangeUrl: 'https://ir.example/oidc/exchange',
      audience: 'invisirisk-oidc-validator',
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
  }, /OIDC token exchange failed with status 403: No active repository mapping found for repository/);
});

test('exchangeOidcForToken rejects non-JSON exchange response', async () => {
  let callCount = 0;

  await assert.rejects(async () => {
    await exchangeOidcForToken({
      exchangeUrl: 'https://ir.example/oidc/exchange',
      audience: 'invisirisk-oidc-validator',
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
  }, /OIDC token exchange returned a non-JSON response/);
});
