const test = require('node:test');
const assert = require('node:assert/strict');

const { buildRuntimeEnv, run } = require('./main');

test('buildRuntimeEnv defaults pse_image_tag to latest', () => {
  const inputs = {
    api_url: 'https://ir.example',
    app_token: 'token',
    debug: 'false',
    test_mode: 'false',
    mode: 'sidecar',
    pse_image_tag: '',
    collect_dependencies: 'true',
    workdir: '/workspace',
    github_token: '',
  };

  const env = buildRuntimeEnv((name) => inputs[name] || '', { GITHUB_TOKEN: 'default-gh-token' });

  assert.equal(env.PSE_IMAGE_TAG, 'latest');
  assert.equal(env.GITHUB_TOKEN, 'default-gh-token');
});

test('run passes pse_image_tag through to bootstrap environment', () => {
  const inputs = {
    send_job_status: 'true',
    api_url: 'https://ir.example',
    app_token: 'token',
    debug: 'true',
    test_mode: 'false',
    mode: 'sidecar',
    pse_image_tag: 'release-2026-05',
    collect_dependencies: 'true',
    workdir: '/workspace',
    github_token: '',
  };
  const stateWrites = [];
  let execCall;

  run({
    execFile: (...args) => {
      execCall = args;
    },
    inputReader: (name) => inputs[name] || '',
    stateWriter: (name, value) => {
      stateWrites.push([name, value]);
    },
    envSource: { GITHUB_TOKEN: 'default-gh-token' },
  });

  assert.equal(execCall[0], 'bash');
  assert.deepEqual(execCall[1], ['-lc', 'curl -sSf "$BOOTSTRAP_URL" | bash']);
  assert.equal(execCall[2].env.PSE_IMAGE_TAG, 'release-2026-05');
  assert.equal(execCall[2].env.GITHUB_TOKEN, 'default-gh-token');
  assert.match(execCall[2].env.BOOTSTRAP_URL, /mode=sidecar/);
  assert.deepEqual(stateWrites, [
    ['api_url', 'https://ir.example'],
    ['ir_token', 'token'],
    ['debug', 'true'],
    ['send_job_status', 'true'],
    ['runner', 'github'],
    ['github_token', 'default-gh-token'],
  ]);
});