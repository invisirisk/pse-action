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

MODE=${MODE:-all}
log "Starting PSE GitHub Action in $MODE mode"

# Bootstrap pse-data-collector binary
export API_KEY="${APP_TOKEN}"
SCRIPT_DIR="$(dirname "$0")"
bash "$SCRIPT_DIR/bootstrap_collector.sh"

# Delegate to pse-data-collector
# All env vars (API_URL, APP_TOKEN, SCAN_ID, MODE, DEBUG, etc.)
# are already set by main.js and read by pse-data-collector via EnvVars
pse-data-collector run --mode "$MODE"

log "PSE GitHub Action completed successfully in $MODE mode"
