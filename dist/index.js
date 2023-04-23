require('./sourcemap-register.js');/******/ (() => { // webpackBootstrap
/******/ 	var __webpack_modules__ = ({

/***/ 927:
/***/ ((module) => {

module.exports = eval("require")("@actions/core");


/***/ }),

/***/ 394:
/***/ ((module) => {

module.exports = eval("require")("@actions/exec");


/***/ }),

/***/ 273:
/***/ ((module) => {

module.exports = eval("require")("@actions/github");


/***/ }),

/***/ 837:
/***/ ((module) => {

module.exports = eval("require")("@actions/glob");


/***/ }),

/***/ 757:
/***/ ((module) => {

module.exports = eval("require")("@actions/http-client");


/***/ }),

/***/ 523:
/***/ ((module) => {

"use strict";
module.exports = require("dns");

/***/ }),

/***/ 147:
/***/ ((module) => {

"use strict";
module.exports = require("fs");

/***/ }),

/***/ 849:
/***/ ((module) => {

"use strict";
module.exports = require("util");

/***/ })

/******/ 	});
/************************************************************************/
/******/ 	// The module cache
/******/ 	var __webpack_module_cache__ = {};
/******/ 	
/******/ 	// The require function
/******/ 	function __nccwpck_require__(moduleId) {
/******/ 		// Check if module is in cache
/******/ 		var cachedModule = __webpack_module_cache__[moduleId];
/******/ 		if (cachedModule !== undefined) {
/******/ 			return cachedModule.exports;
/******/ 		}
/******/ 		// Create a new module (and put it into the cache)
/******/ 		var module = __webpack_module_cache__[moduleId] = {
/******/ 			// no module.id needed
/******/ 			// no module.loaded needed
/******/ 			exports: {}
/******/ 		};
/******/ 	
/******/ 		// Execute the module function
/******/ 		var threw = true;
/******/ 		try {
/******/ 			__webpack_modules__[moduleId](module, module.exports, __nccwpck_require__);
/******/ 			threw = false;
/******/ 		} finally {
/******/ 			if(threw) delete __webpack_module_cache__[moduleId];
/******/ 		}
/******/ 	
/******/ 		// Return the exports of the module
/******/ 		return module.exports;
/******/ 	}
/******/ 	
/************************************************************************/
/******/ 	/* webpack/runtime/compat */
/******/ 	
/******/ 	if (typeof __nccwpck_require__ !== 'undefined') __nccwpck_require__.ab = __dirname + "/";
/******/ 	
/************************************************************************/
var __webpack_exports__ = {};
// This entry need to be wrapped in an IIFE because it need to be isolated against other modules in the chunk.
(() => {
const core = __nccwpck_require__(927);
const github = __nccwpck_require__(273);

const http = __nccwpck_require__(757);

const fs = __nccwpck_require__(147);
const exec = __nccwpck_require__(394)
const glob = __nccwpck_require__(837);

const dns = __nccwpck_require__(523)
const util = __nccwpck_require__(849)


async function iptables() {

  await exec.exec("apk", ["add", "iptables", "bind-tools", "ca-certificates"], silent = true,
    stdout = (data) => {
    },
    stderr = (data) => {
    },
  )
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

  const res = await client.get('https://pse.invisirisk.com/ca');
  if (res.message.statusCode != 200) {
    core.error("error getting ca certificate, status " + res.message.statusCode)
    throw "error getting ca  certificate"
  }
  const cert = await res.readBody()

  const caFile = "/etc/ssl/certs/pse.pem";
  fs.writeFileSync(caFile, cert);
  await exec.exec('update-ca-certificates');

  await exec.exec('git', ["config", "--global", "http.sslCAInfo", caFile]);
  core.exportVariable('NODE_EXTRA_CA_CERTS', caFile);

}

async function checkCreate() {
  /*
    const token = core.getInput('github-token');
    const octokit = new github.getOctokit(token);
    await octokit.rest.checks.create({
      owner: github.context.repo.owner,
      repo: github.context.repo.repo,
      name: 'Readme Validator',
      head_sha: github.context.sha,
      status: 'completed',
      conclusion: 'failure',
      output: {
        title: 'README.md must start with a title',
        summary: 'Please use markdown syntax to create a title',
      }
    });
    */
}

// most @actions toolkit packages have async methods
async function run() {
  try {
    let base = process.env.GITHUB_SERVER_URL + "/";
    let repo = process.env.GITHUB_REPOSITORY;

    await iptables();

    client = new http.HttpClient("pse-action", [], {
      ignoreSslError: true,
    });

    await caSetup();

    await checkCreate();

    let q = new URLSearchParams({
      'builder': 'github',
      'build_id': process.env.GITHUB_RUN_ID,
      build_url: base + repo + "/actions/runs/" + process.env.GITHUB_RUN_ID + "/attempts/" + process.env.GITHUB_RUN_ATTEMPT,
      project: process.env.GITHUB_REPOSITORY,
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

})();

module.exports = __webpack_exports__;
/******/ })()
;
//# sourceMappingURL=index.js.map