const core = require('@actions/core');
const http = require("@actions/http-client");


const fs = require('fs');

// most @actions toolkit packages have async methods
async function run() {
  try {

    core.info("running cleanup ");
    client = new http.HttpClient("pse-action", [], {
      ignoreSslError: true,
    });
    const base = process.env.GITHUB_SERVER_URL + "/";
    const repo = process.env.GITHUB_REPOSITORY;


    const q = new URLSearchParams({
      build_url: base + repo + "/actions/runs/" + process.env.GITHUB_RUN_ID + "/attempts/" + process.env.GITHUB_RUN_ATTEMPT,
      status: process.env.GITHUB_RUN_RESULT
    });
    await client.post('https://pse.invisirisk.com/end', q.toString(),
      {
        "Content-Type": "application/x-www-form-urlencoded",
      }
    );
    core.warning("cleanup - done");
  } catch (error) {
    core.warning("end post failed with message" + error.message);
  }
}

run();
