const core = require('@actions/core');
const http = require("@actions/http-client");


const fs = require('fs');

// most @actions toolkit packages have async methods
async function run() {
  try {
    const token = core.getInput('github-token');
    if (!token || token == '') {
      throw new Error("'github-token' input missing, please include it in your workflow settings 'with' section as 'github-token: ${{ secrets.github_token }}'");
    }

    core.info("running cleanup " + token);
    core.info(JSON.stringify(process.env));
    client = new http.HttpClient("pse-action", [], {
      ignoreSslError: true,
    });
    const base = process.env.GITHUB_SERVER_URL + "/";
    const repo = process.env.GITHUB_REPOSITORY;
    const api = process.env.GITHUB_API_URL + "/repos";
    const run_id = process.env.GITHUB_RUN_ID;

    const qUrl = api + '/' + repo + '/actions/runs/' + run_id + '/jobs'
    core.info("url " + qUrl)
    const response = await client.get(
      qUrl,
      {
        "Authorization": "token " + token,
      }
    )
    core.info("response: " + response.message.statusCode);
    const body = await response.readBody()
    core.info("body: " + body);

    const q = new URLSearchParams({
      build_url: base + repo + "/actions/runs/" + process.env.GITHUB_RUN_ID + "/attempts/" + process.env.GITHUB_RUN_ATTEMPT,
      status: process.env.GITHUB_RUN_RESULT
    });
    client.post('https://pse.invisirisk.com/end', q.toString(),
      {
        "Content-Type": "application/x-www-form-urlencoded",
      }
    );

  } catch (error) {
    core.setFailed(error.message);
  }
} ''

run();
