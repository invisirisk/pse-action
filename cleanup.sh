#!/bin/bash
# PSE GitHub Action - Cleanup Script
# This script cleans up the PSE proxy configuration and signals the end of the build

# Enable strict error handling
set -e


# Get DEBUG flag (defaults to false)
DEBUG="${DEBUG:-false}"

# PSE Base URL
PSE_BASE_URL="https://pse.invisirisk.com"


# PSE debug logging (controlled by DEBUG flag)
debug() {
  if [ "$DEBUG" = "true" ]; then
    echo "$@"
  fi
}

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

# Validate required environment variables
validate_env_vars() {
  # Check for API_URL
  if [ -z "$API_URL" ]; then
    debug "API_URL is not set, trying to use PSE_API_URL from previous step..."
    if [ -n "$PSE_API_URL" ]; then
      export API_URL="$PSE_API_URL"
      debug "Using API_URL from previous step: $API_URL"
    else
      log "ERROR: Could not determine API_URL. Please provide it as an input parameter or run setup first."
      exit 1
    fi
  fi

  # Check for APP_TOKEN
  if [ -z "$APP_TOKEN" ]; then
    debug "APP_TOKEN is not set, trying to use PSE_APP_TOKEN from previous step..."
    if [ -n "$PSE_APP_TOKEN" ]; then
      export APP_TOKEN="$PSE_APP_TOKEN"
      debug "Using APP_TOKEN from previous step (value hidden)"
    else
      log "ERROR: Could not determine APP_TOKEN. Please provide it as an input parameter or run setup first."
      exit 1
    fi
  fi

  # Check for PORTAL_URL
  if [ -z "$PORTAL_URL" ]; then
    debug "PORTAL_URL is not set, trying to use PSE_PORTAL_URL from previous step..."
    if [ -n "$PSE_PORTAL_URL" ]; then
      export PORTAL_URL="$PSE_PORTAL_URL"
      debug "Using PORTAL_URL from previous step: $PORTAL_URL"
    else
      # Try to use API_URL as fallback
      export PORTAL_URL="$API_URL"
      debug "Using API_URL as fallback for PORTAL_URL: $PORTAL_URL"
    fi
  fi

  # Check SCAN_ID separately with warning instead of error
  if [ -z "$SCAN_ID" ]; then
    debug "SCAN_ID is not set, using a default value for cleanup..."
    # Generate a unique ID for this cleanup session
    export SCAN_ID="cleanup_$(date +%s)_${GITHUB_RUN_ID:-unknown}"
    debug "Using generated SCAN_ID: $SCAN_ID"
  fi

  debug "Environment validation successful"
}

# Helper function to run commands with or without sudo based on environment
run_with_privilege() {
  if [ "$(id -u)" = "0" ]; then
    # Running as root (common in containers), execute directly
    "$@"
  else
    # Not running as root, use sudo
    sudo "$@"
  fi
}

# Function to display PSE binary logs
display_pse_binary_logs() {
  # Only show logs if DEBUG is enabled
  if [ "$DEBUG" != "true" ]; then
    return 0
  fi

  log "Displaying logs for PSE binary"

  # Check if in test mode
  if [ "$TEST_MODE" = "true" ]; then
    log "Running in TEST_MODE, skipping PSE binary logs display"
    return 0
  fi

  LOG_FILE_TO_DISPLAY="/tmp/pse_binary.log"

  # Check if the log file exists
  if [ ! -f "$LOG_FILE_TO_DISPLAY" ]; then
    log "Log file $LOG_FILE_TO_DISPLAY does not exist"
    return 0
  fi

  # Display a separator for better readability
  echo "================================================================="
  echo "                   PSE BINARY LOGS                               "
  echo "================================================================="

  # Display the log file contents
  cat "$LOG_FILE_TO_DISPLAY" || log "Failed to display PSE binary logs"

  # Display another separator
  echo "================================================================="
  echo "                END OF PSE BINARY LOGS                           "
  echo "================================================================="
}

# Function to URL encode a string
url_encode() {
  local string="$1"
  local encoded=""
  local i
  for ((i = 0; i < ${#string}; i++)); do
    local c="${string:$i:1}"
    case "$c" in
    [a-zA-Z0-9.~_-]) encoded="$encoded$c" ;;
    *) encoded="$encoded$(printf '%%%02X' "'$c")" ;;
    esac
  done
  echo "$encoded"
}

# Function to validate scan ID
validate_scan_id() {
  if [ -z "$SCAN_ID" ]; then
    log "ERROR: No SCAN_ID available"
    return 1
  fi

  if [ "$SCAN_ID" = "null" ] || [ "$SCAN_ID" = "undefined" ]; then
    log "ERROR: Invalid SCAN_ID: $SCAN_ID"
    return 1
  fi

  # Check if SCAN_ID is a valid UUID (basic check)
  if ! echo "$SCAN_ID" | grep -E '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' >/dev/null; then
    debug "WARNING: SCAN_ID does not appear to be a valid UUID: $SCAN_ID"
    # Continue anyway as it might be a different format
  fi

  debug "SCAN_ID validation passed: $SCAN_ID"
  return 0
}

# Function to collect dependency graphs
collect_dependency_graphs() {
  debug "Starting dependency graph collection..."

  # Inline dependency graph collection
  local PROJECT_PATH="${GITHUB_WORKSPACE:-.}"
  local DEBUG_FLAG="${DEBUG:-false}"
  local INCLUDE_DEV_DEPS="${INCLUDE_DEV_DEPS:-true}"
  
  log "[INFO] Starting dependency graph collection"
  log "[INFO] Executing dependency graph collection script"
  
  local depgraph_exit_code=0
  bash <(curl -sS -X GET "$PSE_BASE_URL/collector/depgraph" \
    -G \
    --data-urlencode "project_path=$PROJECT_PATH" \
    --data-urlencode "pse_base_url=$PSE_BASE_URL" \
    --data-urlencode "include_dev_deps=$INCLUDE_DEV_DEPS" \
    --data-urlencode "debug=$DEBUG_FLAG" \
    -k --tlsv1.2 \
    --connect-timeout 10 \
    --max-time 30) || depgraph_exit_code=$?
  
  if [ "$depgraph_exit_code" -ne 0 ]; then
    log "WARNING: Dependency graph collection failed with exit code $depgraph_exit_code, but continuing"
    return 0
  fi
  
  log "[INFO] Dependency graph collection completed successfully"
}

# Function to signal build end
signal_build_end() {
  log "Signaling build end to InvisiRisk API"

  # Check if in test mode
  if [ "$TEST_MODE" = "true" ]; then
    log "Running in TEST_MODE, skipping API call"
    return 0
  fi

  # Default to PSE endpoint directly
  debug "Using default PSE endpoint: $PSE_BASE_URL"

  # Build URL for the GitHub run
  build_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"

  # Build parameters
  params="id=$(url_encode "$SCAN_ID")"
  params="${params}&build_url=$(url_encode "$build_url")"
  params="${params}&status=$(url_encode "${INPUT_JOB_STATUS:-unknown}")"

  debug "Sending end signal to PSE with parameters: $params"

  # Send request with retries
  MAX_RETRIES=3
  RETRY_DELAY=2
  ATTEMPT=1

  while [ $ATTEMPT -le $MAX_RETRIES ]; do
    debug "Sending end signal, attempt $ATTEMPT of $MAX_RETRIES"

    RESPONSE=$(curl -X POST "${PSE_BASE_URL}/end" \
      -H 'Content-Type: application/x-www-form-urlencoded' \
      -H 'User-Agent: pse-action' \
      -d "$params" \
      -k --tlsv1.2 --insecure \
      --connect-timeout 5 \
      --retry 3 --retry-delay 2 --max-time 10 \
      -s -w "\n%{http_code}" 2>&1)

    debug "Response: $RESPONSE"

    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    RESPONSE_BODY=$(echo "$RESPONSE" | sed '$d')

    if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
      log "End signal sent successfully (HTTP $HTTP_CODE)"
      debug "Response: $RESPONSE_BODY"
      return 0
    else
      log "Failed to send end signal (HTTP $HTTP_CODE)"
      debug "Response: $RESPONSE_BODY"
      log "Retrying in $RETRY_DELAY seconds..."
      sleep $RETRY_DELAY
      RETRY_DELAY=$((RETRY_DELAY * 2))
      ATTEMPT=$((ATTEMPT + 1))
    fi
  done

  log "WARNING: Failed to send end signal after $MAX_RETRIES attempts"
  log "Continuing anyway..."
  return 0
}

# Function to display container logs
display_container_logs() {
  # Only show logs if DEBUG is enabled
  if [ "$DEBUG" != "true" ]; then
    return 0
  fi

  log "Displaying logs for PSE container"

  # Check if in test mode
  if [ "$TEST_MODE" = "true" ]; then
    log "Running in TEST_MODE, skipping container logs display"
    return 0
  fi

  # Find the PSE proxy container by name
  local container_name="pse"
  
  # Check if container exists
  if ! run_with_privilege docker ps -a --format "{{.Names}}" | grep -q "^${container_name}$"; then
    log "PSE proxy container '${container_name}' not found - skipping log display"
    return 0
  fi

  # Display a separator for better readability
  echo "================================================================="
  echo "                PSE PROXY CONTAINER LOGS                         "
  echo "================================================================="

  # Display the container logs
  run_with_privilege docker logs "$container_name" || log "Failed to display logs for container $container_name"

  # Display another separator
  echo "================================================================="
  echo "             END OF PSE PROXY CONTAINER LOGS                     "
  echo "================================================================="
}

# Function to clean up PSE container
cleanup_pse_container() {
  log "Cleaning up PSE container"

  # Check if in test mode
  if [ "$TEST_MODE" = "true" ]; then
    log "Running in TEST_MODE, skipping PSE container cleanup"
    return 0
  fi

  # Stop and remove PSE container if it exists
  if sudo docker ps -a | grep -q pse; then
    sudo docker stop pse 2>/dev/null || true
    sudo docker rm pse 2>/dev/null || true
    log "PSE container stopped and removed"
  else
    log "No PSE container to clean up"
  fi
}

# Function to clean up iptables rules
cleanup_iptables() {
  log "Cleaning up iptables rules"

  # Check if in test mode
  if [ "$TEST_MODE" = "true" ]; then
    log "Running in TEST_MODE, skipping iptables cleanup"
    return 0
  fi

  # Remove iptables rules
  if sudo iptables -t nat -L pse >/dev/null 2>&1; then
    sudo iptables -t nat -D OUTPUT -j pse 2>/dev/null || true
    sudo iptables -t nat -F pse 2>/dev/null || true
    sudo iptables -t nat -X pse 2>/dev/null || true
    log "iptables rules removed successfully"
  else
    log "No iptables rules to clean up"
  fi
}

# Function to clean up certificates
cleanup_certificates() {
  log "Cleaning up certificates"

  # Check if in test mode
  if [ "$TEST_MODE" = "true" ]; then
    log "Running in TEST_MODE, skipping certificate cleanup"
    return 0
  fi

  # Remove PSE certificate from the Ubuntu CA store
  if [ -f /usr/local/share/ca-certificates/extra/pse.crt ]; then
    log "Removing PSE certificate from CA store"
    run_with_privilege rm -f /usr/local/share/ca-certificates/extra/pse.crt
    log "Running update-ca-certificates"
    run_with_privilege update-ca-certificates --fresh
    log "PSE certificate removed"
  elif [ -f /etc/ssl/certs/pse.pem ]; then
    # Backward compatibility for old installations
    log "Removing legacy PSE certificate"
    run_with_privilege rm -f /etc/ssl/certs/pse.pem
    run_with_privilege update-ca-certificates --fresh
    log "Legacy PSE certificate removed"
  else
    log "No PSE certificate found to clean up"
  fi

  # Reset Git SSL configuration
  git config --global --unset http.sslCAInfo || true

  # Clean up environment variables
  unset NODE_EXTRA_CA_CERTS
  unset REQUESTS_CA_BUNDLE

  # Re-enable IPv6 if it was disabled
  log "Re-enabling IPv6"
  run_with_privilege sysctl -w net.ipv6.conf.all.disable_ipv6=0
  run_with_privilege sysctl -w net.ipv6.conf.default.disable_ipv6=0
  run_with_privilege sysctl -w net.ipv6.conf.lo.disable_ipv6=0

  log "Certificate cleanup completed"
}
unset_http_proxy() {
  log "Unsetting HTTP proxy environment variables"

  local proxy_vars=(
    "http_proxy"
    "HTTP_PROXY"
    "https_proxy"
    "HTTPS_PROXY"
    "no_proxy"
    "NO_PROXY"
  )

  for var in "${proxy_vars[@]}"; do
    echo "$var=" >>$GITHUB_ENV
    unset "$var"
  done

  log "HTTP proxy environment variables unset successfully"
}

# Main execution
main() {
  log "Starting PSE GitHub Action cleanup"

  # Validate environment variables
  validate_env_vars

  # Determine if we're in a containerized environment
  IS_CONTAINERIZED=false
  if [ -n "$PSE_PROXY_HOSTNAME" ]; then
    log "Detected containerized build environment using hostname: $PSE_PROXY_HOSTNAME"
    IS_CONTAINERIZED=true
  fi

  # Display PSE binary logs if we're using the binary setup mode
  if [ -n "$PSE_LOG_FILE" ]; then
    display_pse_binary_logs
  fi

  # Collect dependency graphs before signaling build end (if enabled)
  if [ "${PSE_COLLECT_DEPENDENCIES:-true}" = "false" ]; then
    log "Dependency graph collection disabled via collect_dependencies flag"
  else
    collect_dependency_graphs
  fi

  # Signal build end to InvisiRisk API
  signal_build_end

  # Only display container logs and clean up container if not in a containerized environment
  # In a containerized environment, the PSE container is managed by GitHub Actions as a service container
  if [ "$IS_CONTAINERIZED" = "false" ]; then
    # Display container logs before cleanup
    display_container_logs "pse"

    # Clean up container
    cleanup_pse_container
  else
    log "Skipping container cleanup in containerized environment"
    log "The service container will be automatically cleaned up by GitHub Actions"
  fi

  # Always clean up iptables and certificates
  cleanup_iptables
  cleanup_certificates
  unset_http_proxy

  log "PSE GitHub Action cleanup completed successfully"
}

# Execute main function
main
