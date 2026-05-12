const test = require('node:test');
const assert = require('node:assert/strict');

const {
  END_SIGNAL_FAILURE_EXIT_CODE,
  POLICY_FAILURE_EXIT_CODE,
  extractEndSignalFailureMessage,
  extractPolicyFailureMessage,
  handleCleanupError,
  isEndSignalFailure,
  isPolicyFailure,
  run,
} = require('./post');

function withoutConsoleError(fn) {
  const originalError = console.error;
  console.error = () => {};
  try {
    fn();
  } finally {
    console.error = originalError;
  }
}

test('isPolicyFailure detects dedicated policy exit code', () => {
  assert.equal(isPolicyFailure({ status: POLICY_FAILURE_EXIT_CODE }), true);
  assert.equal(isPolicyFailure({ status: 1 }), false);
  assert.equal(isPolicyFailure({}), false);
});

test('isPolicyFailure detects policy block output from older collector binaries', () => {
  assert.equal(isPolicyFailure({ status: 1, stdout: 'InvisiRisk blocked this build because access violated security policy.' }), true);
  assert.equal(isPolicyFailure({ status: 1, stderr: 'random teardown failure' }), false);
});

test('isEndSignalFailure detects dedicated end-signal exit code', () => {
  assert.equal(isEndSignalFailure({ status: END_SIGNAL_FAILURE_EXIT_CODE }), true);
  assert.equal(isEndSignalFailure({ status: 1 }), false);
});

test('extractEndSignalFailureMessage returns the end-signal failure message from cleanup logs', () => {
  const message = extractEndSignalFailureMessage({
    stderr: '[2026-05-12 04:20:27] InvisiRisk could not complete build finalization because the /end request failed.\n',
  });

  assert.equal(message, 'InvisiRisk could not complete build finalization because the /end request failed.');
});

test('extractPolicyFailureMessage returns the layman-friendly message from cleanup logs', () => {
  const message = extractPolicyFailureMessage({
    stdout: '[2026-05-12 04:20:27] Policy gate failed: InvisiRisk blocked this build because accessing vbirmock.free.beeceptor.com violated security policy. Review the InvisiRisk report for details.\n',
  });

  assert.equal(message, 'InvisiRisk blocked this build because accessing vbirmock.free.beeceptor.com violated security policy. Review the InvisiRisk report for details.');
});

test('handleCleanupError fails the workflow on policy failures', () => {
  let exitCode = null;
  const annotations = [];

  withoutConsoleError(() => {
    handleCleanupError(
      {
        message: 'blocked',
        status: POLICY_FAILURE_EXIT_CODE,
        stdout: '[2026-05-12 04:20:27] Policy gate failed: InvisiRisk blocked this build because accessing vbirmock.free.beeceptor.com violated security policy. Review the InvisiRisk report for details.\n',
      },
      (code) => {
        exitCode = code;
      },
      (message, title) => {
        annotations.push({ message, title });
      },
    );
  });

  assert.equal(exitCode, 1);
  assert.deepEqual(annotations, [{
    message: 'InvisiRisk blocked this build because accessing vbirmock.free.beeceptor.com violated security policy. Review the InvisiRisk report for details.',
    title: 'Policy gate failed',
  }]);
});

test('handleCleanupError fails the workflow on end-signal failures', () => {
  let exitCode = null;
  const annotations = [];

  withoutConsoleError(() => {
    handleCleanupError(
      {
        message: 'end failed',
        status: END_SIGNAL_FAILURE_EXIT_CODE,
        stderr: '[2026-05-12 04:20:27] InvisiRisk could not complete build finalization because the /end request failed.\n',
      },
      (code) => {
        exitCode = code;
      },
      (message, title) => {
        annotations.push({ message, title });
      },
    );
  });

  assert.equal(exitCode, 1);
  assert.deepEqual(annotations, [{
    message: 'InvisiRisk could not complete build finalization because the /end request failed.',
    title: 'InvisiRisk /end failed',
  }]);
});

test('handleCleanupError keeps non-policy cleanup failures non-blocking', () => {
  let exitCode = null;

  withoutConsoleError(() => {
    handleCleanupError({ message: 'cleanup failed', status: 1 }, (code) => {
      exitCode = code;
    });
  });

  assert.equal(exitCode, 0);
});

test('run replays cleanup output and throws enriched error on failure', () => {
  let stdout = '';
  let stderr = '';

  assert.throws(() => {
    run(
      () => ({
        status: 1,
        stdout: 'policy output\n',
        stderr: 'cleanup stderr\n',
      }),
      { write: (chunk) => { stdout += chunk; } },
      { write: (chunk) => { stderr += chunk; } },
    );
  }, (error) => {
    assert.equal(error.status, 1);
    assert.equal(error.stdout, 'policy output\n');
    assert.equal(error.stderr, 'cleanup stderr\n');
    return true;
  });

  assert.equal(stdout, 'policy output\n');
  assert.equal(stderr, 'cleanup stderr\n');
});