const { spawnSync } = require('child_process');
const { buildEnv, getInput, getState, handleDeprecatedInputs, pick } = require('./utils');

function run(spawn = spawnSync, stdout = process.stdout, stderr = process.stderr) {
  const env = buildEnv({
    IR_URL: pick(getInput('api_url'), process.env.PSE_API_URL),
    IR_TOKEN: pick(getInput('app_token'), process.env.PSE_APP_TOKEN),
    SEND_JOB_STATUS: getInput('collect_job_status') === 'false' ? 'false' : 'true',
  });

  const debug = pick(getInput('debug'), process.env.DEBUG);
  if (debug === 'true') {
    env.DEBUG = 'true';
  }

  const githubToken = pick(getInput('github_token'), process.env.GITHUB_TOKEN);
  if (githubToken) {
    env.GITHUB_TOKEN = githubToken;
  }

  console.log('Running PSE cleanup...');
  const result = spawn('pse-data-collector', ['cleanup'], {
    encoding: 'utf8',
    env,
  });

  if (result.stdout) {
    stdout.write(result.stdout);
  }
  if (result.stderr) {
    stderr.write(result.stderr);
  }

  if (result.error) {
    throw new Error(`PSE cleanup invocation failed: ${result.error.message}`);
  }

  if (typeof result.status === 'number') {
    return result.status;
  }

  return result.signal ? 1 : 0;
}

function main(spawn = spawnSync, exit = process.exit, stdout = process.stdout, stderr = process.stderr, stateReader = getState) {
  try {
    if (handleDeprecatedInputs(true)) {
      return;
    }
    if (stateReader('pse_setup_completed') !== 'true') {
      return;
    }
    const status = run(spawn, stdout, stderr);
    if (status !== 0) {
      exit(status || 1);
    }
  } catch (error) {
    stderr.write(`${error.message || 'PSE cleanup invocation failed'}\n`);
    exit(1);
  }
}

if (require.main === module) {
  main();
}

module.exports = {
  main,
  run,
};
