const fs = require('fs');
const os = require('os');

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
  getInput,
  getState,
  handleDeprecatedCleanupInput,
  pick,
  saveState,
  warn,
};