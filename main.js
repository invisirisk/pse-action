const { execSync } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

function getInput(name) {
  const key = `INPUT_${name.replace(/ /g, '_').replace(/-/g, '_').toUpperCase()}`;
  return (process.env[key] || '').trim();
}

function saveState(name, value) {
  const stateFile = process.env.GITHUB_STATE;
  if (stateFile) {
    fs.appendFileSync(stateFile, `${name}=${value}${os.EOL}`, 'utf8');
  }
}

function appendGithubEnv(key, value) {
  const envFile = process.env.GITHUB_ENV;
  if (envFile) {
    fs.appendFileSync(envFile, `${key}=${value}${os.EOL}`, 'utf8');
  }
}

function appendGithubOutput(key, value) {
  const outputFile = process.env.GITHUB_OUTPUT;
  if (outputFile) {
    fs.appendFileSync(outputFile, `${key}=${value}${os.EOL}`, 'utf8');
  }
}

function mapOutputFile(filePath) {
  if (!fs.existsSync(filePath)) return;
  const content = fs.readFileSync(filePath, 'utf8');
  for (const line of content.trim().split('\n')) {
    const idx = line.indexOf('=');
    if (idx === -1) continue;
    const key = line.slice(0, idx);
    const value = line.slice(idx + 1);
    appendGithubOutput(key, value);
    appendGithubEnv(key, value);
  }
}

function sh(cmd, env) {
  execSync(cmd, { stdio: 'inherit', env, shell: '/bin/bash' });
}

function run() {
  const apiUrl = getInput('api_url');
  const appToken = getInput('app_token');
  const portalUrl = getInput('portal_url') || apiUrl;
  const debug = getInput('debug');
  const testMode = getInput('test_mode');
  const scanId = getInput('scan_id');
  const arch = getInput('arch');
  const sendJobStatus = getInput('send_job_status');
  const mode = getInput('mode') || 'all';

  const env = { ...process.env };

  // Save state for post step
  saveState('api_url', apiUrl);
  saveState('app_token', appToken);
  saveState('portal_url', portalUrl);
  saveState('debug', debug);
  saveState('send_job_status', sendJobStatus);
  saveState('github_token', env.GITHUB_TOKEN || '');

  console.log(`Running PSE setup in ${mode} mode...`);

  if (testMode === 'true') {
    console.log('Test mode enabled, skipping API calls.');
    return;
  }

  // Step 1: Install pse-data-collector via bootstrap
  console.log('Installing pse-data-collector...');
  const gatewayUrl = `${apiUrl}/ingestionapi/v1`;
  const bootstrapEnv = { ...env, API_KEY: appToken, DEBUG: debug };
  const bootstrapScript = path.join(__dirname, 'bootstrap_collector.sh');
  sh(`bash "${bootstrapScript}"`, bootstrapEnv);

  // Step 2: Prepare (create scan)
  if (!scanId) {
    const runId = `${process.env.GITHUB_RUN_ID || ''}_${process.env.GITHUB_RUN_ATTEMPT || '1'}`;
    const debugFlag = debug === 'true' ? '--debug' : '';
    console.log('Creating scan...');
    sh(`pse-data-collector prepare --api-url "${gatewayUrl}" --api-key "${appToken}" --run-id "${runId}" ${debugFlag} | bash`, env);

    // Read prepare output and bridge to GITHUB_OUTPUT/GITHUB_ENV
    mapOutputFile('/tmp/pse_prepare_output');

    // Also save scan_id to state
    if (fs.existsSync('/tmp/pse_prepare_output')) {
      const prepareContent = fs.readFileSync('/tmp/pse_prepare_output', 'utf8');
      const scanIdMatch = prepareContent.match(/SCAN_ID=(.+)/);
      if (scanIdMatch) {
        saveState('scan_id', scanIdMatch[1].trim());
      }
    }
  } else {
    appendGithubOutput('SCAN_ID', scanId);
    appendGithubEnv('SCAN_ID', scanId);
    saveState('scan_id', scanId);
  }

  // Read SCAN_ID from env (set by mapOutputFile or directly)
  const resolvedScanId = scanId || (() => {
    try {
      const content = fs.readFileSync('/tmp/pse_prepare_output', 'utf8');
      const match = content.match(/SCAN_ID=(.+)/);
      return match ? match[1].trim() : '';
    } catch (_) { return ''; }
  })();

  // Step 3: Download PSE binary
  console.log('Downloading PSE binary...');
  const archFlag = arch ? `--arch "${arch}"` : '';
  const debugFlag = debug === 'true' ? '--debug' : '';
  sh(`pse-data-collector download-pse --api-url "${gatewayUrl}" --api-key "${appToken}" ${archFlag} ${debugFlag} | bash`, env);

  // Step 4: Setup PSE (iptables, certs, /start)
  console.log('Setting up PSE...');
  const proxyIp = (() => {
    // Auto-detect: use hostname -I to get the host IP
    try {
      return execSync("hostname -I | awk '{print $1}'", { encoding: 'utf8' }).trim();
    } catch (_) { return '127.0.0.1'; }
  })();

  const buildUrl = `https://github.com/${process.env.GITHUB_REPOSITORY || ''}/actions/runs/${process.env.GITHUB_RUN_ID || ''}`;
  const scmOrigin = `https://github.com/${process.env.GITHUB_REPOSITORY || ''}`;
  const scmBranch = (process.env.GITHUB_REF_NAME || '').replace('refs/heads/', '');
  const scmCommit = process.env.GITHUB_SHA || '';
  const project = process.env.GITHUB_REPOSITORY || '';

  sh(`pse-data-collector setup-pse \
    --proxy-ip "${proxyIp}" \
    --scan-id "${resolvedScanId}" \
    --api-url "${gatewayUrl}" \
    --api-key "${appToken}" \
    --portal-url "${portalUrl}" \
    --build-url "${buildUrl}" \
    --scm-origin "${scmOrigin}" \
    --scm-branch "${scmBranch}" \
    --scm-commit "${scmCommit}" \
    --project "${project}" \
    ${debugFlag} | bash`, env);

  // Bridge /tmp/pse_env to GITHUB_ENV/GITHUB_OUTPUT
  mapOutputFile('/tmp/pse_env');

  appendGithubOutput('proxy_ip', proxyIp);
  appendGithubOutput('scan_id', resolvedScanId);
}

try {
  run();
} catch (error) {
  console.error(`PSE setup failed: ${error.message}`);
  process.exit(1);
}
