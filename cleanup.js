const core = require('@actions/core');
const http = require("@actions/http-client");
const exec = require('@actions/exec');

async function run() {
  try {
    core.debug("cleanup - start");

    // Step 1: Print Docker container logs
    try {
      core.info("Fetching logs for Docker container 'pse'...");
      await exec.exec('docker logs pse', [], {
        listeners: {
          stdout: (data) => core.info(data.toString()), // Print logs to GitHub Actions log
          stderr: (data) => core.error(data.toString()), // Print errors to GitHub Actions log
        },
      });
    } catch (logError) {
      core.error(`Failed to fetch logs for Docker container: ${logError.message}`);
    }

    // Step 2: Stop and remove the Docker container
    try {
      await exec.exec('docker stop pse');
      await exec.exec('docker rm pse');
      core.info("Docker container stopped and removed successfully.");
    } catch (dockerError) {
      core.error(`Failed to stop or remove Docker container: ${dockerError.message}`);
    }

    // Step 3: Notify PSE of workflow completion
    const client = new http.HttpClient("pse-action", [], {
      ignoreSslError: true,
    });

    const base = process.env.GITHUB_SERVER_URL + "/";
    const repo = process.env.GITHUB_REPOSITORY;

    const q = new URLSearchParams({
      build_url: base + repo + "/actions/runs/" + process.env.GITHUB_RUN_ID + "/attempts/" + process.env.GITHUB_RUN_ATTEMPT,
      status: process.env.GITHUB_RUN_RESULT,
    });

    const res = await client.post('https://pse.invisirisk.com/end', q.toString(), {
      "Content-Type": "application/x-www-form-urlencoded",
    });

    if (res.message.statusCode !== 200) {
      core.error(`Error talking to PSE. Status: ${res.message.statusCode}`);
    }

    core.debug("cleanup - done");
  } catch (error) {
    core.info(`Cleanup failed with message: ${error.message}`);
  }
}

run();