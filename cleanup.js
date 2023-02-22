const core = require('@actions/core');
const http = require("@actions/http-client");
const github = require("@actions/github");

const fs = require('fs');

// most @actions toolkit packages have async methods
async function run() {
  try {
    core.info("cleanup");
    core.info(JSON.stringify(process.env));

  } catch (error) {
    core.setFailed(error.message);
  }
}

run();
