#!/bin/bash
# PSE GitHub Action - Setup Script
# Bootstraps pse-data-collector and delegates to it

set -e

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

error_handler() {
  log "ERROR: An error occurred on line $1"
  exit 1
}

trap 'error_handler $LINENO' ERR

MODE=${MODE:-native}
RUNNER=${RUNNER:-github}
log "Starting PSE Action in $MODE mode (runner: $RUNNER)"

# Bootstrap pse-data-collector binary and run it
export API_KEY="${APP_TOKEN}"
export API_URL="${IR_URL}"
log "Fetching bootstrap script from ${IR_URL}/ingestionapi/v1/pse/bootstrap"
curl -sSf "${IR_URL}/ingestionapi/v1/pse/bootstrap?api_key=${API_KEY}&mode=${MODE}&runner=${RUNNER}" | bash

log "PSE GitHub Action completed successfully in $MODE mode"
