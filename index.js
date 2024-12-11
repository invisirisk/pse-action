const core = require('@actions/core');
const github = require('@actions/github');

const http = require("@actions/http-client");

const fs = require('fs');
const exec = require('@actions/exec')
const glob = require('@actions/glob');

const dns = require('dns')
const util = require('util')
const which = require('which')


async function distribution() {
  var result = osInfo({ mode: 'sync' })

}

async function iptables() {

  var apk = false

  if (await which('apt-get', { nothrow: true }) == null) {
    apk = true

  }


  if (apk) {
    await exec.exec("apk", ["add", "iptables", "ca-certificates", "git"], silent = true,

      stdout = (data) => {
      },
      stderr = (data) => {
      },
    )
  } else {

    await exec.exec("apt-get", ["update"], silent = true,
      stdout = (data) => {
      },
      stderr = (data) => {
      },
    )
    await exec.exec("apt-get", ["install", "-y", "iptables", "ca-certificates", "git"], silent = true,
      stdout = (data) => {
      },
      stderr = (data) => {
      },
    )
  }

  await exec.exec("iptables", ["-t", "nat", "-N", "pse"], silent = true)
  await exec.exec("iptables", ["-t", "nat", "-A", "OUTPUT", "-j", "pse"], silent = true)

  const lookup = util.promisify(dns.lookup);
  const dresp = await lookup('pse');
  await exec.exec("iptables",
    ["-t", "nat", "-A", "pse", "-p", "tcp", "-m", "tcp", "--dport", "443", "-j", "DNAT", "--to-destination", dresp.address + ":12345"],
    silent = true,
    stdout = (data) => {
    },
    stderr = (data) => {
    },
  )

}

async function caSetup() {
  client = new http.HttpClient("pse-action", [], {
    ignoreSslError: true,
  });

  const retries = 5;
  let delay = 3000; // start with 3 seconds
  const delayIncrementFactor = 1.5;

  for (let i = 0; i < retries; i++) {
    const res = await client.get('https://pse.invisirisk.com/ca');
    if (res.message.statusCode === 200) {
      const cert = await res.readBody();
      const caFile = "/etc/ssl/certs/pse.pem";
      fs.writeFileSync(caFile, cert);
      await exec.exec('update-ca-certificates');

      await exec.exec('git', ["config", "--global", "http.sslCAInfo", caFile]);
      core.exportVariable('NODE_EXTRA_CA_CERTS', caFile);
      core.exportVariable('REQUESTS_CA_BUNDLE', caFile);
      return; // exit the function successfully
    } else {
      if (i < retries - 1) {
        core.warning(`Retry ${i + 1} failed with status ${res.message.statusCode}. Retrying in ${delay / 1000} seconds...`);
        await new Promise(resolve => setTimeout(resolve, delay));
        delay *= delayIncrementFactor; // increase delay exponentially
      } else {
        core.error("Max retries reached. Error getting CA certificate.");
        throw new Error("Error getting CA certificate after max retries");
      }
    }
  }
}


// most @actions toolkit packages have async methods
async function run() {
  try {
    let base = process.env.GITHUB_SERVER_URL + "/";
    let repo = process.env.GITHUB_REPOSITORY;
    //core.warning(process.env);
    await iptables();

    client = new http.HttpClient("pse-action", [], {
      ignoreSslError: true,
    });

    await caSetup();

 
    const scan_id = core.getInput('SCAN_ID');
    let q = new URLSearchParams({
      'builder': 'github',
      'id': scan_id,
      'build_id': process.env.GITHUB_RUN_ID,
      build_url: base + repo + "/actions/runs/" + process.env.GITHUB_RUN_ID + "/attempts/" + process.env.GITHUB_RUN_ATTEMPT,
      project: process.env.GITHUB_REPOSITORY,
      workflow: process.env.GITHUB_WORKFLOW + " - " + process.env.GITHUB_JOB,
      builder_url: base,
      scm: 'git',
      scm_commit: process.env.GITHUB_SHA,
      //      scm_prev_commit = process,
      scm_branch: process.env.GITHUB_REF_NAME,
      scm_origin: base + repo,
    });
    await client.post('https://pse.invisirisk.com/start', q.toString(),
      {
        "Content-Type": "application/x-www-form-urlencoded",
      }
    );
  } catch (error) {
    core.setFailed(error.message);
  }
}

run();
