const core = require('@actions/core');
const http = require("@actions/http-client");


const fs = require('fs');

// most @actions toolkit packages have async methods
async function run() {
  try {

    core.debug("cleanup - start");
    client = new http.HttpClient("pse-action", [], {
      ignoreSslError: true,
    });
    const base = process.env.GITHUB_SERVER_URL + "/";
    const repo = process.env.GITHUB_REPOSITORY;


    const q = new URLSearchParams({
      build_url: base + repo + "/actions/runs/" + process.env.GITHUB_RUN_ID + "/attempts/" + process.env.GITHUB_RUN_ATTEMPT,
      status: process.env.GITHUB_RUN_RESULT
    });
    const res = await client.post('https://pse.invisirisk.com/end', q.toString(),
      {
        "Content-Type": "application/x-www-form-urlencoded",
      }
    );
    core.notice(res.message.statusCode)
    if (res.message.statusCode != 200) {
      core.error("error talking to PSE. Status " + res.message.statusCode)
    }
    const body = await res.readBody()
    //core.notice(body)
    const obj = JSON.parse(body)
    core.notice(obj)
    core.debug("cleanup - done");
  } catch (error) {
    core.info("end post failed with message " + error.message);
  }
}

run();
