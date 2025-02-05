const core = require('@actions/core');
const http = require('@actions/http-client');
const exec = require('@actions/exec');
const fs = require('fs');
const dns = require('dns');
const util = require('util');
const which = require('which');

/**
 * Utility function to check and setup Docker.
 * Output: Ensures Docker is installed and running.
 * Throws an error if Docker setup fails.
 */
async function setupDocker() {
  try {
    core.info('Checking if Docker is installed...');
    await which('docker');
    core.info('Docker is installed.');
    
    // Check if Docker daemon is running
    try {
      core.info('Checking if Docker daemon is running...');
      await exec.exec('docker info', [], { silent: true });
      core.info('Docker daemon is running.');
    } catch (error) {
      core.info('Docker daemon not running. Starting Docker service...');
      
      // Try to start Docker service
      try {
        await exec.exec('sudo service docker start');
        core.info('Waiting for Docker to start...');
        await new Promise(resolve => setTimeout(resolve, 5000));
        
        // Verify Docker is now running
        await exec.exec('docker info', [], { silent: true });
        core.info('Docker daemon started successfully.');
      } catch (startError) {
        throw new Error(`Failed to start Docker service: ${startError.message}`);
      }
    }

  } catch (err) {
    core.error('Docker not found. Installing Docker...');

    // Read /etc/os-release to determine the OS
    try {
      const osReleaseData = fs.readFileSync('/etc/os-release', 'utf8');
      if (osReleaseData.includes('Alpine')) {
        // Docker installation for Alpine Linux
        core.info('Installing Docker on Alpine...');
        try {
          await exec.exec('apk update');
          await exec.exec('apk add docker');
          core.info('Docker installed and started on Alpine.');
        } catch (installError) {
          throw new Error(`Failed to install Docker on Alpine: ${installError.message}`);
        }
      } else if (osReleaseData.includes('Ubuntu')) {
        // Docker installation for Ubuntu
        core.info('Installing Docker on Ubuntu...');
        try {
          await exec.exec('sudo apt-get update');
          await exec.exec('sudo apt-get install -y docker.io');
          await exec.exec('sudo systemctl enable --now docker');
          core.info('Docker installed and started on Ubuntu.');
        } catch (installError) {
          throw new Error(`Failed to install Docker on Ubuntu: ${installError.message}`);
        }
      } else {
        throw new Error('Unsupported OS. Unable to install Docker.');
      }
    } catch (err) {
      throw new Error('Failed to detect OS or install Docker: ' + err.message);
    }
  }
}

/**
 * Utility function to fetch with retries.
 * Output: Returns the HTTP response if successful.
 * Throws an error if all retries fail.
 */
async function fetchWithRetries(url, maxRetries = 5, delay = 3000, exponentialBackoffFactor = 1.5) {
  const client = new http.HttpClient("pse-action", [], {
    ignoreSslError: true,
  });

  for (let i = 0; i < maxRetries; i++) {
    try {
      core.info(`Attempt #${i + 1}: Fetching ${url}...`);
      const res = await client.get(url);
      const statusCode = res.message.statusCode;

      if (statusCode >= 200 && statusCode < 300) {
        core.info(`Successfully fetched ${url}. Status code: ${statusCode}`);
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

/**
 * Function to configure iptables.
 * Output: Installs iptables and configures NAT rules.
 */
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

  // Get the IP address of the `pse` container
  let containerIp = '';
  try {
    const inspectOutput = await exec.getExecOutput('docker inspect -f "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}" pse');
    containerIp = inspectOutput.stdout.trim();
    core.info(`IP address of pse container: ${containerIp}`);
  } catch (error) {
    core.error(`Failed to get IP address of pse container: ${error.message}`);
    throw error;
  }

  if (!containerIp) {
    throw new Error('Could not retrieve IP address of pse container.');
  }

  // Use the container's IP address in the iptables command
  await exec.exec("iptables", [
    "-t", "nat", "-A", "pse", "-p", "tcp", "-m", "tcp", "--dport", "443", "-j", "DNAT", "--to-destination", `${containerIp}:12345`
  ],
   {
    silent: true,
    listeners: {
      stdout: (data) => {},
      stderr: (data) => {},
    },
  });
  await exec.exec("iptables", ["-t", "nat", "-L", "-v", "-n"]);
  core.info('iptables configuration completed.');
}


/**
 * Function to set up CA certificates.
 * Output: Downloads and configures CA certificates.
 * Exports environment variables for CA certificates.
 */
async function caSetup() {
  core.info('Setting up CA certificates...');
  const caURL = 'https://pse.invisirisk.com/ca';
  const resp = await fetchWithRetries(caURL, 5, 3000, 1.5);;
  const cert = await resp.readBody();
  const caFile = "/etc/ssl/certs/pse.pem";

  fs.writeFileSync(caFile, cert);
  core.info('CA certificate downloaded and saved.');

  await exec.exec('update-ca-certificates');
  core.info('CA certificates updated.');

  await exec.exec('git', ["config", "--global", "http.sslCAInfo", caFile]);
  core.exportVariable('NODE_EXTRA_CA_CERTS', caFile);
  core.exportVariable('REQUESTS_CA_BUNDLE', caFile);
  core.info('CA certificates configured for Git and environment variables.');
}
let scan_Id;


/**
 * Function to initiate SBOM scan.
 * Output: Returns the scan ID if successful.
 * Throws an error if the scan initiation fails.
 */
async function initiateSBOMScan(vbApiUrl, vbApiKey) {
  core.info('Initiating SBOM scan...');
  const client = new http.HttpClient("pse-action", [], {
    ignoreSslError: true,
    allowRedirectDowngrade: true,
  });

  const url = `${vbApiUrl}/utilityapi/v1/scan`;
  const data = JSON.stringify({ api_key: vbApiKey });

  const res = await client.post(url, data, {
    "Content-Type": "application/json",
  });

  if (res.message.statusCode !== 201) {
    throw new Error(`Failed to initiate SBOM scan: ${res.message.statusCode}`);
  }

  const responseBody = await res.readBody();
  const responseData = JSON.parse(responseBody);
  core.info(`SBOM scan initiated successfully. Scan ID: ${responseData.data.scan_id}`);
  scan_Id= responseData.data.scan_id;
  return responseData.data.scan_id;
}

/**
 * Function to fetch ECR credentials.
 * Output: Returns decoded ECR credentials.
 * Throws an error if fetching credentials fails.
 */
async function fetchECRCredentials(vbApiUrl, vbApiKey) {
  core.info('Fetching ECR credentials...');
  const client = new http.HttpClient("pse-action", [], {
    ignoreSslError: true,
    allowRedirectDowngrade: true,
  });

  const url = `${vbApiUrl}/utilityapi/v1/registry?api_key=${vbApiKey}`;
  const res = await client.get(url);

  if (res.message.statusCode !== 200) {
    throw new Error(`Failed to fetch ECR credentials: ${res.message.statusCode}`);
  }

  const responseBody = await res.readBody();
  const responseData = JSON.parse(responseBody);
  const decodedToken = Buffer.from(responseData.data, 'base64').toString('utf-8');
  core.info('ECR credentials fetched successfully.');
  return JSON.parse(decodedToken);
}

/**
 * Function to log in to Amazon ECR.
 * Output: Logs in to Amazon ECR using provided credentials.
 */
async function loginToECR(username, password, registryId, region) {
  core.info('Logging in to Amazon ECR...');

  let stdout = '';
  let stderr = '';

  try {
    await exec.exec(`docker login -u ${username} ${registryId}.dkr.ecr.${region}.amazonaws.com --password ${password}`, [], {
      listeners: {
        stdout: (data) => {
          stdout += data.toString(); // Capture stdout
        },
        stderr: (data) => {
          stderr += data.toString(); // Capture stderr
        },
      },
    });

    // Print the output
    core.info('Docker login output:');
    core.info(stdout);

    if (stderr) {
      core.error('Docker login errors:');
      core.error(stderr);
    }

    core.info('Successfully logged in to Amazon ECR.');
  } catch (error) {
    core.error('Failed to log in to Amazon ECR:');
    core.error(stdout); // Print captured stdout
    core.error(stderr); // Print captured stderr
    throw error; // Re-throw the error to fail the action
  }
}

/**
 * Function to run the VB image.
 * Output: Runs the VB Docker image with the specified configuration.
 */
const { execSync } = require('child_process');

async function runVBImage(vbApiUrl, vbApiKey, registryId, region) {
  core.info('Finding network starting with github_network_...');

  let networkName = 'bridge'; // Default fallback
  try {
    // Execute the command to get the network list
    const networks = execSync('docker network ls', { encoding: 'utf8' });

    // Find the network name that starts with "github_network_"
    const foundNetwork = networks
      .split('\n')
      .map(line => line.trim().split(/\s+/)[1]) // Extract the second column (network name)
      .find(name => name && name.startsWith('github_network_'));

    if (foundNetwork) {
      networkName = foundNetwork;
      core.info(`Found network: ${networkName}`);
    } else {
      core.warning('No network starting with github_network_ found, using bridge network');
    }
  } catch (error) {
    core.warning(`Failed to get network list: ${error.message}`);
  }

  // Run the container with the detected network
  core.info(`Running VB Docker image on network ${networkName}...`);
  const githubToken = core.getInput('github-token');
  await exec.exec(
    `docker run --network ${networkName} -d --name pse -p 12345:12345 ` +
    `-e INVISIRISK_JWT_TOKEN=${vbApiKey} ` +
    `-e GITHUB_TOKEN=${githubToken} ` +
    `-e PSE_DEBUG_FLAG="--alsologtostderr" ` +
    `-e POLICY_LOG="t" ` +
    `-e INVISIRISK_PORTAL=${vbApiUrl} ` +
    `${registryId}.dkr.ecr.${region}.amazonaws.com/invisirisk/pse-proxy`
  );
  core.info('Waiting .......................');
  // await exec.exec(`docker logs pse`);
  // await exec.exec(`docker ps`);
  // await exec.exec(`docker network ls`);
  // await exec.exec(`docker network inspect bridge`);
  // await exec.exec(`docker network inspect host`);
  // await exec.exec(`docker inspect pse`);
  core.info('VB Docker image started successfully.');
}

/**WW
 * Main function.
 * Output: Executes the entire workflow, including Docker setup, SBOM scan, ECR login, and running the VB image.
 * Throws an error if any step fails.
 */
async function run() {
  try {
    core.info('Starting Pipeline Security Engine action...');

    // Step 0: Setup Docker
    await setupDocker();
    
    const vbApiUrl = core.getInput('VB_API_URL');
    const vbApiKey = core.getInput('VB_API_KEY');
    core.info(`Using VB_API_URL: ${vbApiUrl}`);

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
    core.info(`Container ID: ${containerId}`);

    // Step 1: Configure iptables
    await iptables();
    // Step 2: Set up CA certificates
    await caSetup();

    // Step 3: Notify PSE of workflow start
    const base = process.env.GITHUB_SERVER_URL + "/";
    const repo = process.env.GITHUB_REPOSITORY;
    core.info(`Notifying PSE of workflow start for repository: ${repo}`);

    const client = new http.HttpClient("pse-action", [], {
      ignoreSslError: true,
    });

    const scan_id = core.getInput('SCAN_ID');
    const q = new URLSearchParams({
      builder: 'github',
      id: scan_Id,
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
    core.info('PSE notified of workflow start.');

    

    core.info('Pipeline Security Engine action completed successfully.');
  } catch (error) {
    core.setFailed(`Action failed: ${error.message}`);
  }
}

run();