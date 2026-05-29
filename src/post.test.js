const test = require('node:test');
const assert = require('node:assert/strict');

const {
  END_SIGNAL_FAILURE_EXIT_CODE,
  POLICY_FAILURE_EXIT_CODE,
  getAnnotationMessage,
  handleCleanupError,
  hasExistingErrorAnnotation,
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

test('getAnnotationMessage extracts the actionable policy message from cleanup logs', () => {
  const message = getAnnotationMessage({
    stdout: [
      '[2026-05-12 04:20:27] Starting PSE cleanup',
      '[2026-05-12 04:20:28] Policy gate failed: InvisiRisk blocked this build because accessing vbirmock.free.beeceptor.com violated security policy. Review the InvisiRisk report for details.',
      '[2026-05-12 04:20:29] Displaying logs for PSE binary',
    ].join('\n'),
  });

  assert.equal(message, 'InvisiRisk blocked this build because accessing vbirmock.free.beeceptor.com violated security policy. Review the InvisiRisk report for details.');
});

test('hasExistingErrorAnnotation detects workflow error commands from cleanup output', () => {
  assert.equal(hasExistingErrorAnnotation({ stderr: '::error title=Policy gate failed::blocked by policy\n' }), true);
  assert.equal(hasExistingErrorAnnotation({ stdout: 'plain log output\n' }), false);
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

test('handleCleanupError does not duplicate a policy annotation already emitted by cleanup.sh', () => {
  let exitCode = null;
  const annotations = [];

  withoutConsoleError(() => {
    handleCleanupError(
      {
        message: 'blocked',
        status: POLICY_FAILURE_EXIT_CODE,
        stderr: '::error title=Policy gate failed::InvisiRisk blocked this build because a policy violation was detected.\n',
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
  assert.deepEqual(annotations, []);
});

test('handleCleanupError fails the workflow on end-signal failures', () => {
  let exitCode = null;
  const annotations = [];

  withoutConsoleError(() => {
    handleCleanupError(
      {
        message: 'end failed',
        status: END_SIGNAL_FAILURE_EXIT_CODE,
        stderr: '[2026-05-12 04:20:27] InvisiRisk could not complete build finalization because the /end request failed after 3 attempts. Final HTTP status: 500. Response: upstream timeout.\n',
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
    message: 'InvisiRisk could not complete build finalization because the /end request failed after 3 attempts. Final HTTP status: 500. Response: upstream timeout.',
    title: 'InvisiRisk /end failed',
  }]);
});

test('handleCleanupError annotates non-policy cleanup failures with the last actionable error', () => {
  let exitCode = null;
  const annotations = [];

  withoutConsoleError(() => {
    handleCleanupError(
      {
        message: 'cleanup failed',
        status: 1,
        stderr: [
          '[2026-05-12 04:20:27] Cleaning up certificates',
          '[2026-05-12 04:20:27] ERROR: PSE cleanup failed on line 312 while running: update-ca-certificates --fresh',
        ].join('\n'),
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
    message: 'PSE cleanup failed on line 312 while running: update-ca-certificates --fresh',
    title: 'PSE cleanup failed',
  }]);
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
    assert.equal(error.message, 'policy output\ncleanup stderr');
    assert.equal(error.stdout, 'policy output\n');
    assert.equal(error.stderr, 'cleanup stderr\n');
    return true;
  });

  assert.equal(stdout, 'policy output\n');
  assert.equal(stderr, 'cleanup stderr\n');
});
