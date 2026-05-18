const test = require('node:test');
const assert = require('node:assert/strict');

const { buildRuntimeEnv, run } = require('./main');

test('buildRuntimeEnv defaults pse_image_tag to latest', () => {
  const inputs = {
    api_url: 'https://ir.example',
    app_token: '',
    debug: 'false',
    mode: 'sidecar',
    pse_image_tag: '',
    collect_dependencies: 'true',
    workdir: '/workspace',
    github_token: '',
  };

  const env = buildRuntimeEnv((name) => inputs[name] || '', {
    GITHUB_TOKEN: 'default-gh-token',
    IR_TOKEN: 'token-from-env',
  });

  assert.equal(env.PSE_IMAGE_TAG, 'latest');
  assert.equal(env.GITHUB_TOKEN, 'default-gh-token');
  assert.equal(env.IR_TOKEN, 'token-from-env');
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
  assert.deepEqual(execCall[1], ['-lc', 'curl -sSf "$BOOTSTRAP_URL" | bash']);
  assert.equal(execCall[2].env.PSE_IMAGE_TAG, 'release-2026-05');
  assert.equal(execCall[2].env.GITHUB_TOKEN, 'default-gh-token');
  assert.match(execCall[2].env.BOOTSTRAP_URL, /mode=sidecar/);
  assert.match(execCall[2].env.BOOTSTRAP_URL, /api_key=token/);
  assert.match(execCall[2].env.BOOTSTRAP_URL, /ir_token=token/);
});

test('run resolves token from env fallback', () => {
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
  let execCall;

  run({
    execFile: (...args) => {
      execCall = args;
    },
    inputReader: (name) => inputs[name] || '',
    envSource: { GITHUB_TOKEN: 'default-gh-token', IR_TOKEN: 'fallback-token' },
  });

  assert.equal(execCall[2].env.IR_TOKEN, 'fallback-token');
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