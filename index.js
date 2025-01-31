const core = require('@actions/core');
const http = require('@actions/http-client');
const exec = require('@actions/exec');
const fs = require('fs');
const dns = require('dns');
const util = require('util');
const which = require('which');

// Utility function to fetch with retries
async function fetchWithRetries(url, maxRetries = 5, delay = 3000, exponentialBackoffFactor = 1.5) {
  const client = new http.HttpClient("pse-action", [], {
    ignoreSslError: true,
  });

  for (let i = 0; i < maxRetries; i++) {
    try {
      const res = await client.get(url);
      const statusCode = res.message.statusCode;

      if (statusCode >= 200 && statusCode < 300) {
        return res;
      }
      throw new Error(`Error retrieving resource from ${url}, status code: ${statusCode}`);
    } catch (error) {
      core.error(`Attempt #${i + 1}: Request failed: ${error.message}`);
      if (i === maxRetries - 1) {
        throw error;
      }
      core.info(`Retrying in ${delay / 1000} seconds...`);
      await new Promise(resolve => setTimeout(resolve, delay));
      delay *= exponentialBackoffFactor;
    }
  }
}

// Function to set up CA certificates
async function caSetup() {
  const caURL = 'https://pse.invisirisk.com/ca';
  const resp = await fetchWithRetries(caURL);
  const cert = await resp.readBody();
  const caFile = "/etc/ssl/certs/pse.pem";

  fs.writeFileSync(caFile, cert);
  await exec.exec('update-ca-certificates');

  await exec.exec('git', ["config", "--global", "http.sslCAInfo", caFile]);
  core.exportVariable('NODE_EXTRA_CA_CERTS', caFile);
  core.exportVariable('REQUESTS_CA_BUNDLE', caFile);
}

// Function to configure iptables
async function iptables() {
  var apk = false;

  if (await which('apt-get', { nothrow: true }) == null) {
    apk = true;
  }

  if (apk) {
    await exec.exec("apk", ["add", "iptables", "ca-certificates", "git"], {
      silent: true,
      listeners: {
        stdout: (data) => {},
        stderr: (data) => {},
      },
    });
  } else {
    await exec.exec("apt-get", ["update"], {
      silent: true,
      listeners: {
        stdout: (data) => {},
        stderr: (data) => {},
      },
    });
    await exec.exec("apt-get", ["install", "-y", "iptables", "ca-certificates", "git"], {
      silent: true,
      listeners: {
        stdout: (data) => {},
        stderr: (data) => {},
      },
    });
  }

  await exec.exec("iptables", ["-t", "nat", "-N", "pse"], { silent: true });
  await exec.exec("iptables", ["-t", "nat", "-A", "OUTPUT", "-j", "pse"], { silent: true });

  const lookup = util.promisify(dns.lookup);
  const dresp = await lookup('pse');
  await exec.exec("iptables", [
    "-t", "nat", "-A", "pse", "-p", "tcp", "-m", "tcp", "--dport", "443", "-j", "DNAT", "--to-destination", dresp.address + ":12345"
  ], {
    silent: true,
    listeners: {
      stdout: (data) => {},
      stderr: (data) => {},
    },
  });
}

// Function to initiate SBOM scan
async function initiateSBOMScan(vbApiUrl, vbApiKey) {
  const client = new http.HttpClient("pse-action", [], {
    ignoreSslError: true,
  });

  const url = `${vbApiUrl}/utilityapi/v1/scan`;
  const data = JSON.stringify({ api_key: vbApiKey });

  const res = await client.post(url, data, {
    "Content-Type": "application/json",
  });

  if (res.message.statusCode !== 200) {
    throw new Error(`Failed to initiate SBOM scan: ${res.message.statusCode}`);
  }

  const responseBody = await res.readBody();
  const responseData = JSON.parse(responseBody);
  return responseData.data.scan_id;
}

// Function to fetch ECR credentials
async function fetchECRCredentials(vbApiUrl, vbApiKey) {
  const client = new http.HttpClient("pse-action", [], {
    ignoreSslError: true,
  });

  const url = `${vbApiUrl}/utilityapi/v1/registry?api_key=${vbApiKey}`;
  const res = await client.get(url);

  if (res.message.statusCode !== 200) {
    throw new Error(`Failed to fetch ECR credentials: ${res.message.statusCode}`);
  }

  const responseBody = await res.readBody();
  const responseData = JSON.parse(responseBody);
  const decodedToken = Buffer.from(responseData.data, 'base64').toString('utf-8');
  return JSON.parse(decodedToken);
}

// Function to log in to Amazon ECR
async function loginToECR(username, password, registryId, region) {
  await exec.exec(`echo ${password} | docker login -u ${username} ${registryId}.dkr.ecr.${region}.amazonaws.com --password-stdin`);
}

// Function to run the VB image
async function runVBImage(vbApiUrl, vbApiKey, registryId, region) {
  await exec.exec(`docker run --name pse -e INVISIRISK_JWT_TOKEN=${vbApiKey} -e GITHUB_TOKEN=${process.env.GITHUB_TOKEN} -e PSE_DEBUG_FLAG="--alsologtostderr" -e POLICY_LOG="t" -e INVISIRISK_PORTAL=${vbApiUrl} ${registryId}.dkr.ecr.${region}.amazonaws.com/pse-proxy`);
}

// Main function
async function run() {
  try {
    const vbApiUrl = core.getInput('VB_API_URL');
    const vbApiKey = core.getInput('VB_API_KEY');

    // Step 4: Initiate SBOM Scan
    const scanId = await initiateSBOMScan(vbApiUrl, vbApiKey);
    core.setOutput('scan_id', scanId);

    // Step 5: Fetch ECR Credentials
    const ecrCredentials = await fetchECRCredentials(vbApiUrl, vbApiKey);
    const { username, password, region, registry_id } = ecrCredentials;

    // Step 6: Log in to Amazon ECR
    await loginToECR(username, password, registry_id, region);

    // Step 7: Run VB Image
    await runVBImage(vbApiUrl, vbApiKey, registry_id, region);

    // Step 8: Set Container ID as Output
    const containerId = (await exec.getExecOutput('docker ps -aqf name=^pse$')).stdout.trim();
    core.exportVariable('CONTAINER_ID', containerId);


    // Step 1: Configure iptables
    await iptables();

    // Step 2: Set up CA certificates
    await caSetup();

    // Step 3: Notify PSE of workflow start
    const base = process.env.GITHUB_SERVER_URL + "/";
    const repo = process.env.GITHUB_REPOSITORY;

    const client = new http.HttpClient("pse-action", [], {
      ignoreSslError: true,
    });

    const scan_id = core.getInput('SCAN_ID');
    const q = new URLSearchParams({
      builder: 'github',
      id: scan_id,
      build_id: process.env.GITHUB_RUN_ID,
      build_url: base + repo + "/actions/runs/" + process.env.GITHUB_RUN_ID + "/attempts/" + process.env.GITHUB_RUN_ATTEMPT,
      project: process.env.GITHUB_REPOSITORY,
      workflow: process.env.GITHUB_WORKFLOW + " - " + process.env.GITHUB_JOB,
      builder_url: base,
      scm: 'git',
      scm_commit: process.env.GITHUB_SHA,
      scm_branch: process.env.GITHUB_REF_NAME,
      scm_origin: base + repo,
    });

    await client.post('https://pse.invisirisk.com/start', q.toString(), {
      "Content-Type": "application/x-www-form-urlencoded",
    });

    // // Step 4: Initiate SBOM Scan
    // const scanId = await initiateSBOMScan(vbApiUrl, vbApiKey);
    // core.setOutput('scan_id', scanId);

    // // Step 5: Fetch ECR Credentials
    // const ecrCredentials = await fetchECRCredentials(vbApiUrl, vbApiKey);
    // const { username, password, region, registry_id } = ecrCredentials;

    // // Step 6: Log in to Amazon ECR
    // await loginToECR(username, password, registry_id, region);

    // // Step 7: Run VB Image
    // await runVBImage(vbApiUrl, vbApiKey, registry_id, region);

    // // Step 8: Set Container ID as Output
    // const containerId = (await exec.getExecOutput('docker ps -aqf name=^pse$')).stdout.trim();
    // core.exportVariable('CONTAINER_ID', containerId);

  } catch (error) {
    core.setFailed(error.message);
  }
}

run();