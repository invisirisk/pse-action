const test = require('node:test');
const assert = require('node:assert/strict');
const { run, runBootstrap } = require('./index');

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

test('run passes pse_image_tag through to bootstrap environment', () => {
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

  run({
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

test('run resolves token from env fallback', () => {
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

  run({
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

test('run throws helpful error when api_url is missing', () => {
  assert.throws(() => {
    run({
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

test('run throws helpful error when token is missing', () => {
  assert.throws(() => {
    run({
      inputReader: (name) => {
        const inputs = {
          api_url: 'https://ir.example',
          app_token: '',
          debug: 'true',
          mode: 'native',
          pse_image_tag: 'latest',
          collect_dependencies: 'true',
          workdir: '/workspace',
          github_token: '',
        };
        return inputs[name] || '';
      },
      envSource: {},
    });
  }, /Missing required input: app_token/);
});
