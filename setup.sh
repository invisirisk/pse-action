#!/bin/bash
# PSE GitHub Action - Setup Script
# This script serves as a dispatcher for the different modes of the PSE GitHub Action

# Enable strict error handling
set -e

# Enable debug mode if requested or forced
if [ "$DEBUG" = "true" ] || [ "$DEBUG_FORCE" = "true" ]; then
  DEBUG="true"
  export DEBUG
  set -x
fi

# Set default mode if not provided
MODE=${MODE:-all}

# Log with timestamp
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Error handler
error_handler() {
  log "ERROR: An error occurred on line $1"
  exit 1
}

# Set up error trap
trap 'error_handler $LINENO' ERR

# Validate mode-specific requirements
validate_mode_requirements() {
  log "Validating requirements for mode: $MODE"
  
  case "$MODE" in
    prepare)
      # For prepare mode, api_url and app_token are required
      if [ -z "$API_URL" ] || [ -z "$APP_TOKEN" ]; then
        log "ERROR: api_url and app_token are required for prepare mode"
        exit 1
      fi
      ;;
      
    setup)
      # For setup mode, api_url, app_token, and scan_id are required unless in test mode
      if [ -z "$API_URL" ] || [ -z "$APP_TOKEN" ]; then
        log "ERROR: api_url and app_token are required for setup mode"
        exit 1
      fi
      
      if [ -z "$SCAN_ID" ] && [ "$TEST_MODE" != "true" ]; then
        log "ERROR: scan_id is required for setup mode when not in test mode"
        exit 1
      fi
      ;;
      
    intercept)
      # For intercept mode, scan_id is required unless in test mode
      # Note: proxy_ip and proxy_hostname are now optional as they can be auto-discovered
      if [ -z "$SCAN_ID" ] && [ "$TEST_MODE" != "true" ]; then
        log "ERROR: scan_id is required for intercept mode when not in test mode"
        exit 1
      fi
      ;;
      
    all)
      # For all mode, api_url and app_token are required
      if [ -z "$API_URL" ] || [ -z "$APP_TOKEN" ]; then
        log "ERROR: api_url and app_token are required for all mode"
        exit 1
      fi
      ;;

    docker-intercept)
      # For all mode, api_url and app_token are required
      if [ -z "$API_URL" ] || [ -z "$APP_TOKEN" ]; then
        log "ERROR: api_url and app_token are required for all mode"
        exit 1
      fi
      ;;
      
    binary-setup)
      # For binary-setup mode, api_url, app_token, and scan_id are required unless in test mode
      if [ -z "$API_URL" ] || [ -z "$APP_TOKEN" ]; then
        log "ERROR: api_url and app_token are required for binary-setup mode"
        exit 1
      fi
      
      if [ -z "$SCAN_ID" ] && [ "$TEST_MODE" != "true" ]; then
        log "ERROR: scan_id is required for binary-setup mode when not in test mode"
        exit 1
      fi
      ;;
      
    *)
      # For legacy modes, validate based on their equivalent modes
      case "$MODE" in
        full)
          if [ -z "$API_URL" ] || [ -z "$APP_TOKEN" ]; then
            log "ERROR: api_url and app_token are required for full mode"
            exit 1
          fi
          ;;
          
        pse_only)
          if [ -z "$API_URL" ] || [ -z "$APP_TOKEN" ]; then
            log "ERROR: api_url and app_token are required for pse_only mode"
            exit 1
          fi
          
          if [ -z "$SCAN_ID" ] && [ "$TEST_MODE" != "true" ]; then
            log "ERROR: scan_id is required for pse_only mode when not in test mode"
            exit 1
          fi
          ;;
          
        build_only)
          if [ -z "$PROXY_IP" ] && [ -z "$PROXY_HOSTNAME" ]; then
            log "ERROR: proxy_ip or proxy_hostname is required for build_only mode"
            exit 1
          fi
          
          if [ -z "$SCAN_ID" ] && [ "$TEST_MODE" != "true" ]; then
            log "ERROR: scan_id is required for build_only mode when not in test mode"
            exit 1
          fi
          ;;
          
        prepare_only)
          if [ -z "$API_URL" ] || [ -z "$APP_TOKEN" ]; then
            log "ERROR: api_url and app_token are required for prepare_only mode"
            exit 1
          fi
          ;;
      esac
      ;;
  esac
  
  log "Mode-specific requirements validation successful"
}

# Main function
main() {
  log "Starting PSE GitHub Action in $MODE mode"
  
  # Validate mode-specific requirements
  validate_mode_requirements
  
  # Create scripts directory if it doesn't exist
  SCRIPTS_DIR="$(dirname "$0")/scripts"
  if [ ! -d "$SCRIPTS_DIR" ]; then
    mkdir -p "$SCRIPTS_DIR"
    
  # Copy and make executable the mode scripts
  for script in prepare setup intercept binary_setup; do
    cp "$(dirname "$0")/scripts/mode_${script}.sh" "$SCRIPTS_DIR/" 2>/dev/null || true
    chmod +x "$SCRIPTS_DIR/mode_${script}.sh" 2>/dev/null || true
  done

  fi
  
   # Execute the appropriate script based on the mode
  case "$MODE" in
    prepare|setup|binary_setup|intercept)
      if [[ -f "$SCRIPTS_DIR/mode_${MODE}.sh" ]]; then
        . "$SCRIPTS_DIR/mode_${MODE}.sh"
      else
        log "ERROR: mode_${MODE}.sh script not found in $SCRIPTS_DIR"
        exit 1
      fi
      ;;
    all)
      for script in prepare setup intercept; do
        if [[ -f "$SCRIPTS_DIR/mode_${script}.sh" ]]; then
          . "$SCRIPTS_DIR/mode_${script}.sh"
        else
          log "ERROR: mode_${script}.sh script not found in $SCRIPTS_DIR"
          exit 1
        fi
      done
      ;;
    docker-intercept)
      for script in prepare binary_setup intercept; do
        if [[ -f "$SCRIPTS_DIR/mode_${script}.sh" ]]; then
          . "$SCRIPTS_DIR/mode_${script}.sh"
        else
          log "ERROR: mode_${script}.sh script not found in $SCRIPTS_DIR"
          exit 1
        fi
      done
      ;;
    *)
      log "ERROR: Invalid mode specified: $MODE"
      exit 1
      ;;

    # Legacy mode support for backward compatibility
    full)
      log "Running in full mode (legacy) - performing all operations"
      MODE="all"
      export MODE
      main
      ;;
      
    pse_only)
      log "Running in pse_only mode (legacy) - equivalent to setup mode"
      MODE="setup"
      export MODE
      main
      ;;
      
    build_only)
      log "Running in build_only mode (legacy) - equivalent to intercept mode"
      MODE="intercept"
      export MODE
      main
      ;;
      
    prepare_only)
      log "Running in prepare_only mode (legacy) - equivalent to prepare mode"
      MODE="prepare"
      export MODE
      main
      ;;
      
    *)
      log "ERROR: Invalid mode $MODE. Valid modes are 'prepare', 'setup', 'intercept', 'binary-setup', and 'all'"
      log "Legacy modes 'full', 'pse_only', 'build_only', and 'prepare_only' are also supported for backward compatibility"
      exit 1
      ;;
  esac
  
  log "PSE GitHub Action completed successfully in $MODE mode"
}

# Execute main function
main
