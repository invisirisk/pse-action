const core = require('@actions/core');
const http = require("@actions/http-client");


const fs = require('fs');

// most @actions toolkit packages have async methods
async function run() {
  try {
    core.info("cleanup");
    core.info(JSON.stringify(process.env));
    client = new http.HttpClient("pse-action", [], { ignoreSslError: true });
    let base = process.env.GITHUB_SERVER_URL + "/";
    let repo = process.env.GITHUB_REPOSITORY;

    let q = new URLSearchParams({
      'builder': 'github',
      'build_id': process.env.GITHUB_RUN_ID,
      build_url: base + repo + "/actions/runs/" + process.env.GITHUB_RUN_ID + "/attempts/" + process.env.GITHUB_RUN_ATTEMPT,
      status: process.env.GITHUB_RUN_RESULT
    });
    console.log(q.toString())

  } catch (error) {
    core.setFailed(error.message);
  }
}

run();