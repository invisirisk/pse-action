const test = require('node:test');
const assert = require('node:assert/strict');

const { main, run } = require('./post');

test('main skips cleanup when setup did not complete', () => {
  let called = false;
  let exitCode = null;

  main(
    () => {
      called = true;
      return { status: 0, stdout: '', stderr: '' };
    },
    (code) => {
      exitCode = code;
    },
    { write: () => {} },
    { write: () => {} },
    () => '',
  );

  assert.equal(called, false);
  assert.equal(exitCode, null);
});

test('run streams collector stdout and stderr once', () => {
  let stdout = '';
  let stderr = '';

  const status = run(
    () => ({
      status: 0,
      stdout: 'cleanup stdout\n',
      stderr: 'cleanup stderr\n',
    }),
    { write: (chunk) => { stdout += chunk; } },
    { write: (chunk) => { stderr += chunk; } },
  );

  assert.equal(status, 0);
  assert.equal(stdout, 'cleanup stdout\n');
  assert.equal(stderr, 'cleanup stderr\n');
});

test('main fails the post step with the collector exit code', () => {
  let stdout = '';
  let stderr = '';
  let exitCode = null;

  main(
    () => ({
      status: 43,
      stdout: 'collector stdout\n',
      stderr: 'collector stderr\n',
    }),
    (code) => {
      exitCode = code;
    },
    { write: (chunk) => { stdout += chunk; } },
    { write: (chunk) => { stderr += chunk; } },
    () => 'true',
  );

  assert.equal(exitCode, 43);
  assert.equal(stdout, 'collector stdout\n');
  assert.equal(stderr, 'collector stderr\n');
});

test('main reports wrapper-local invocation failures', () => {
  let stderr = '';
  let exitCode = null;

  main(
    () => ({
      status: null,
      error: new Error('spawn ENOENT'),
    }),
    (code) => {
      exitCode = code;
    },
    { write: () => {} },
    { write: (chunk) => { stderr += chunk; } },
    () => 'true',
  );

  assert.equal(exitCode, 1);
  assert.equal(stderr, 'PSE cleanup invocation failed: spawn ENOENT\n');
});

test('main does not replay the cleanup transcript after a collector failure', () => {
  let stdout = '';
  let stderr = '';
  let exitCode = null;

  main(
    () => ({
      status: 1,
      stdout: '::error title=Policy Violation::blocked by policy\n',
      stderr: 'collector failure details\n',
    }),
    (code) => {
      exitCode = code;
    },
    { write: (chunk) => { stdout += chunk; } },
    { write: (chunk) => { stderr += chunk; } },
    () => 'true',
  );

  assert.equal(exitCode, 1);
  assert.equal(stdout, '::error title=Policy Violation::blocked by policy\n');
  assert.equal(stderr, 'collector failure details\n');
});
