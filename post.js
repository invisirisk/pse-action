const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');

function getInput(name) {
  const key = `INPUT_${name.replace(/ /g, '_').replace(/-/g, '_').toUpperCase()}`;
  return (process.env[key] || '').trim();
}

function getState(name) {
  return (process.env[`STATE_${name}`] || '').trim();
}

function sh(cmd, env) {
  execSync(cmd, { stdio: 'inherit', env, shell: '/bin/bash' });
}

function run() {
  const actionPath = __dirname;

  // Resolve env vars: prefer state saved from main step, fall back to PSE_* from GITHUB_ENV
  const apiUrl = getState('api_url') || process.env.PSE_API_URL || '';
  const appToken = getState('app_token') || process.env.PSE_APP_TOKEN || '';
  const portalUrl = getState('portal_url') || process.env.PSE_PORTAL_URL || apiUrl;
  const debug = getState('debug') || process.env.DEBUG || 'false';
  const githubToken = getState('github_token') || process.env.GITHUB_TOKEN || '';
  const scanId = getState('scan_id') || process.env.SCAN_ID || process.env.PSE_SCAN_ID || '';
  const collectDeps = process.env.PSE_COLLECT_DEPENDENCIES !== 'false';
  const workdir = process.env.IR_WORKDIR || '';

  const env = {
    ...process.env,
    GITHUB_ACTION_PATH: process.env.GITHUB_ACTION_PATH || actionPath,
    API_URL: apiUrl,
    APP_TOKEN: appToken,
    PORTAL_URL: portalUrl,
    DEBUG: debug,
    GITHUB_TOKEN: githubToken,
  };

  // Step 1: Send job status if enabled (GitHub-specific, kept in action)
  const sendJobStatus = getState('send_job_status') || getInput('send_job_status');
  if (sendJobStatus === 'true') {
    console.log('Fetching and sending job status...');
    try {
      execSync(`bash ${path.join(actionPath, 'get_jobs_status.sh')}`, {
        stdio: 'inherit',
        env,
      });
    } catch (error) {
      console.error(`Warning: Failed to send job status: ${error.message}`);
    }
  }

  // Step 2: Read computed job status
  let jobStatus = 'unknown';
  try {
    jobStatus = fs.readFileSync('/tmp/pse_computed_job_status', 'utf8').trim();
  } catch (_) {
    // File won't exist if job status step was skipped or failed
  }

  // Step 3: Run cleanup via pse-data-collector
  console.log('Running PSE cleanup...');
  const debugFlag = debug === 'true' ? '--debug' : '';
  const depgraphFlag = collectDeps ? '--depgraph' : '--depgraph=false';
  const workdirFlag = workdir ? `--workdir "${workdir}"` : '';
  const buildUrl = `https://github.com/${process.env.GITHUB_REPOSITORY || ''}/actions/runs/${process.env.GITHUB_RUN_ID || ''}`;

  try {
    sh(`pse-data-collector cleanup \
      --scan-id "${scanId}" \
      --api-url "${apiUrl}" \
      --api-key "${appToken}" \
      --job-status "${jobStatus}" \
      ${depgraphFlag} \
      --build-url "${buildUrl}" \
      ${workdirFlag} \
      ${debugFlag} | bash`, env);
  } catch (error) {
    console.error(`Warning: Cleanup had errors: ${error.message}`);
  }
}

try {
  run();
} catch (error) {
  console.error(`PSE cleanup failed: ${error.message}`);
  // Don't exit with error in post step — cleanup failures shouldn't fail the job
  process.exit(0);
}
