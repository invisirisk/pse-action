const core = require('@actions/core');
const wait = require('./wait');
const os = require('@nexssp/os/legacy')


// most @actions toolkit packages have async methods
async function run() {
  try {

    console.log('get("name"): ', os.get('NAME'))


    core.info(JSON.stringify(process.env));

  } catch (error) {
    core.setFailed(error.message);
  }
}

run();
