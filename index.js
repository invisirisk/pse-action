/******/ (() => { // webpackBootstrap
/******/ 	var __webpack_modules__ = ({

/***/ 351:
/***/ ((module, __unused_webpack_exports, __nccwpck_require__) => {

const { execFileSync } = __nccwpck_require__(81);
const { buildEnv, getInput, handleDeprecatedCleanupInput, pick } = __nccwpck_require__(608);

function runBootstrap(env, execFile = execFileSync) {
  const bootstrapUrl = new URL('/ingestionapi/v1/pse/bootstrap', env.IR_URL);
  bootstrapUrl.search = new URLSearchParams({
    api_key: env.IR_TOKEN,
    ir_token: env.IR_TOKEN,
    mode: env.MODE || 'native',
    runner: env.RUNNER || 'github',
  }).toString();

  env.BOOTSTRAP_URL = bootstrapUrl.toString();

  execFile('bash', ['-lc', 'curl -sSf "$BOOTSTRAP_URL" | bash'], {
    stdio: 'inherit',
    env,
  });
}

function buildRuntimeEnv(inputReader = getInput, envSource = process.env) {
  const env = buildEnv({
    IR_URL: inputReader('api_url'),
    IR_TOKEN: pick(inputReader('app_token'), envSource.IR_TOKEN, envSource.APP_TOKEN),
  });

  const mode = pick(inputReader('mode'));
  if (mode) {
    env.MODE = mode;
  }

  if ((mode || 'native') === 'sidecar') {
    env.PSE_IMAGE_TAG = pick(inputReader('pse_image_tag'), 'latest');
  }

  const debug = pick(inputReader('debug'));
  if (debug === 'true') {
    env.DEBUG = 'true';
  }

  const collectDependencies = pick(inputReader('collect_dependencies'));
  if (collectDependencies) {
    env.COLLECT_DEPENDENCIES = collectDependencies;
  }

  const workdir = pick(inputReader('workdir'));
  if (workdir) {
    env.WORKDIR = workdir;
  }

  const githubToken = pick(inputReader('github_token'), envSource.GITHUB_TOKEN);
  if (githubToken) {
    env.GITHUB_TOKEN = githubToken;
  }

  return env;
}

function run({ execFile = execFileSync, inputReader = getInput, envSource = process.env } = {}) {
  const env = buildRuntimeEnv(inputReader, envSource);

  if (!env.IR_URL) {
    throw new Error('Missing required input: api_url');
  }
  if (!env.IR_TOKEN) {
    throw new Error('Missing required input: app_token (or IR_TOKEN/APP_TOKEN environment variable)');
  }

  console.log(`Running PSE setup in ${env.MODE || 'native'} mode...`);
  runBootstrap(env, execFile);
}

if (require.main === require.cache[eval('__filename')]) {
  try {
    if (!handleDeprecatedCleanupInput()) {
      run();
    }
  } catch (error) {
    console.error(`PSE setup failed: ${error.message}`);
    process.exit(1);
  }
}

module.exports = {
  buildRuntimeEnv,
  runBootstrap,
  run,
};

/***/ }),

/***/ 608:
/***/ ((module, __unused_webpack_exports, __nccwpck_require__) => {

const fs = __nccwpck_require__(147);
const os = __nccwpck_require__(37);

const DEPRECATED_CLEANUP_MESSAGE = 'The "cleanup" input is deprecated. Cleanup runs automatically through the action post step. Remove the cleanup step from your workflow.';

function readNamedValue(prefix, name) {
  const key = `${prefix}_${name.replace(/ /g, '_').replace(/-/g, '_').toUpperCase()}`;
  return (process.env[key] || '').trim();
}

function getInput(name) {
  return readNamedValue('INPUT', name);
}

function getState(name) {
  return (process.env[`STATE_${name}`] || '').trim();
}

function pick(...values) {
  for (const value of values) {
    const normalized = typeof value === 'string' ? value.trim() : '';
    if (normalized) {
      return normalized;
    }
  }
  return '';
}

function saveState(name, value) {
  const stateFile = process.env.GITHUB_STATE;
  if (stateFile) {
    fs.appendFileSync(stateFile, `${name}=${value}${os.EOL}`, 'utf8');
  }
}

function buildEnv(overrides = {}) {
  return {
    ...process.env,
    RUNNER: 'github',
    ...overrides,
  };
}

function warn(message, title = 'PSE Action') {
  console.warn(`::warning title=${title}::${message}`);
}

function error(message, title = 'PSE Action') {
  console.error(`::error title=${title}::${message}`);
}

function handleDeprecatedCleanupInput(isPost = false) {
  const shouldWarn = isPost ? getState('skip_post') === 'true' : getInput('cleanup') === 'true';
  if (!shouldWarn) {
    return false;
  }

  warn(DEPRECATED_CLEANUP_MESSAGE, 'Deprecated cleanup input');
  if (!isPost) {
    saveState('skip_post', 'true');
  }
  return true;
}

module.exports = {
  buildEnv,
  error,
  getInput,
  getState,
  handleDeprecatedCleanupInput,
  pick,
  saveState,
  warn,
};

/***/ }),

/***/ 81:
/***/ ((module) => {

"use strict";
module.exports = require("child_process");

/***/ }),

/***/ 147:
/***/ ((module) => {

"use strict";
module.exports = require("fs");

/***/ }),

/***/ 37:
/***/ ((module) => {

"use strict";
module.exports = require("os");

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
/******/ 	
/******/ 	// startup
/******/ 	// Load entry module and return exports
/******/ 	// This entry module is referenced by other modules so it can't be inlined
/******/ 	var __webpack_exports__ = __nccwpck_require__(351);
/******/ 	module.exports = __webpack_exports__;
/******/ 	
/******/ })()
;