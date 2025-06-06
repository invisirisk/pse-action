#!/bin/bash
# PSE GitHub Action - Setup Script
# This script pulls and runs the PSE proxy container

# Enable strict error handling
set -e

# Enable debug mode if requested or forced
if [ "$DEBUG" = "true" ] || [ "$DEBUG_FORCE" = "true" ]; then
  DEBUG="true"
  export DEBUG
  set -x
fi

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

# Validate required environment variables
validate_env_vars() {
  local required_vars=("ECR_USERNAME" "ECR_TOKEN" "ECR_REGION" "ECR_REGISTRY_ID" "SCAN_ID" "GITHUB_TOKEN")

  for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
      log "ERROR: Required environment variable $var is not set"
      exit 1
    fi
  done

  log "Environment validation successful"
}

# Function to set up dependencies
setup_dependencies() {
  log "Setting up dependencies"

  # Check if in test mode
  if [ "$TEST_MODE" = "true" ]; then
    log "Running in TEST_MODE, skipping dependency setup"
    return 0
  fi

  # Install Docker if not available
  if ! command -v docker >/dev/null 2>&1; then
    log "Docker not found, installing..."

    # Install Docker based on the available package manager
    if command -v apt-get >/dev/null 2>&1; then
      run_with_privilege apt-get update
      run_with_privilege apt-get install -y docker.io
    elif command -v yum >/dev/null 2>&1; then
      run_with_privilege yum install -y docker
    else
      log "ERROR: Unsupported package manager. Please install Docker manually."
      exit 1
    fi

    # Start Docker service
    run_with_privilege systemctl start docker || true
  fi

  log "Dependencies setup completed"
}

# Function to pull and start PSE container
pull_and_start_pse_container() {
  log "Pulling and starting PSE container"

  # Check if in test mode
  if [ "$TEST_MODE" = "true" ]; then
    log "Running in TEST_MODE, skipping container setup"
    return 0
  fi

  # Login to ECR
  log "Logging in to ECR"
  echo "$ECR_TOKEN" | run_with_privilege docker login --username "$ECR_USERNAME" --password-stdin "$ECR_REGISTRY_ID.dkr.ecr.$ECR_REGION.amazonaws.com"

  # Define possible repository paths to try
  local REPO_PATHS=(
    "$ECR_REGISTRY_ID.dkr.ecr.$ECR_REGION.amazonaws.com/invisirisk/pse-proxy:bh-test"
    "invisirisk/pse-proxy:bh-test"
  )

  # Try to pull the PSE container from each repository path
  local PSE_IMAGE=""
  local PULL_OUTPUT=""
  local MAX_RETRIES=3
  local ATTEMPT=1
  local RETRY_DELAY=5

  for REPO_PATH in "${REPO_PATHS[@]}"; do
    log "Attempting to pull PSE container from $REPO_PATH"

    while [ $ATTEMPT -le $MAX_RETRIES ]; do
      PULL_OUTPUT=$(run_with_privilege docker pull "$REPO_PATH" 2>&1) && {
        log "Successfully pulled PSE container from $REPO_PATH"
        PSE_IMAGE="$REPO_PATH"
        break 2
      } || {
        log "Failed to pull PSE container from $REPO_PATH (attempt $ATTEMPT/$MAX_RETRIES)"
        log "Error: $PULL_OUTPUT"

        if [ $ATTEMPT -lt $MAX_RETRIES ]; then
          log "Retrying in $RETRY_DELAY seconds..."
          sleep $RETRY_DELAY
          RETRY_DELAY=$((RETRY_DELAY * 2))
          ATTEMPT=$((ATTEMPT + 1))
        fi
      }
    done

    # Reset attempt counter for next repository path
    ATTEMPT=1
    RETRY_DELAY=5
  done

  if [ -z "$PSE_IMAGE" ]; then
    log "ERROR: Failed to pull PSE container from any repository path"
    log "Last error: $PULL_OUTPUT"
    exit 1
  fi

  log "Starting PSE container, in a different daemon"
  run_with_privilege docker run -d --name pse \
    -e PSE_DEBUG_FLAG="--alsologtostderr" \
    -e POLICY_LOG="t" \
    -e INVISIRISK_JWT_TOKEN="$APP_TOKEN" \
    -e INVISIRISK_PORTAL="$PORTAL_URL" \
    -e GITHUB_TOKEN="$GITHUB_TOKEN" \
    "$PSE_IMAGE"

  # Get container IP for iptables configuration using container name from docker ps
  CONTAINER_NAME=$(run_with_privilege docker ps --filter "ancestor=$PSE_IMAGE" --format "{{.Names}}")
  log "Found PSE container with name: $CONTAINER_NAME"

  # Get the IP address from the container
  PSE_IP=$(run_with_privilege docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$CONTAINER_NAME")
  log "Obtained PSE container IP: $PSE_IP"

  # If we couldn't get the IP using the container name, fall back to the old method
  if [ -z "$PSE_IP" ]; then
    log "Warning: Could not get IP using container name, falling back to container ID 'pse'"
    PSE_IP=$(run_with_privilege docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' pse)
  fi

  export PSE_IP
  export PROXY_IP="$PSE_IP"

  # Save the API values to environment for later use
  echo "PSE_API_URL=$API_URL" >>$GITHUB_ENV
  echo "PSE_APP_TOKEN=$APP_TOKEN" >>$GITHUB_ENV
  echo "PSE_PORTAL_URL=$PORTAL_URL" >>$GITHUB_ENV
  echo "PSE_PROXY_IP=$PSE_IP" >>$GITHUB_ENV
  echo "PSE_SCAN_ID=$SCAN_ID" >>$GITHUB_ENV

  # Also save the PSE proxy IP as an output parameter
  echo "proxy_ip=$PSE_IP" >>$GITHUB_OUTPUT
  echo "::set-output name=proxy_ip::$PSE_IP"

  # Double check that the proxy IP has been properly set as output
  log "Set proxy_ip output parameter to: $PSE_IP"

  log "PSE container started with IP: $PSE_IP"
  log "Proxy IP has been saved to GitHub environment as PSE_PROXY_IP"
}

# Function to signal build start
signal_build_start() {
  log "Signaling build start to InvisiRisk Portal"

  # Check if in test mode
  if [ "$TEST_MODE" = "true" ]; then
    log "Running in TEST_MODE, skipping build start signal"
    return 0
  fi

  # Construct API URL for build start signal
  local API_ENDPOINT="$API_URL/utilityapi/v1/scan/$SCAN_ID/start"
  log "Sending build start signal to $API_ENDPOINT"

  # Make API request to signal build start
  local RESPONSE
  RESPONSE=$(curl -s -X POST "$API_ENDPOINT" \
    -H "Authorization: Bearer $APP_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"status":"started"}')

  log "API response received"

  # Check if response contains an error
  if echo "$RESPONSE" | grep -q "error"; then
    local ERROR_MSG
    ERROR_MSG=$(parse_json "$RESPONSE" "error")
    log "ERROR: Failed to signal build start: $ERROR_MSG"
    # Don't exit on this error, it's not critical
    return 1
  fi

  log "Build start signal sent successfully"
  return 0
}

# Function to register cleanup script
register_cleanup() {
  log "Registering cleanup script"

  # Create cleanup script in the workspace
  local CLEANUP_SCRIPT="$GITHUB_WORKSPACE/.pse-cleanup.sh"

  cat >"$CLEANUP_SCRIPT" <<'EOF'
#!/bin/bash
# PSE Cleanup Script
# This script is automatically generated and will be executed at the end of the job

echo "Running PSE cleanup..."
if [ -n "$GITHUB_ACTION_PATH" ]; then
  "$GITHUB_ACTION_PATH/cleanup.sh"
else
  echo "ERROR: GITHUB_ACTION_PATH is not set, cannot find cleanup script"
  exit 1
fi
EOF

  # Make the cleanup script executable
  chmod +x "$CLEANUP_SCRIPT"
  chmod +x "$GITHUB_ACTION_PATH/get_jobs_status.sh"
  # Register the cleanup script with GitHub
  #echo "::add-path::$GITHUB_WORKSPACE"
  #echo "::set-env name=GITHUB_PATH::$GITHUB_PATH:$GITHUB_WORKSPACE"

  log "Cleanup script registered"
}

unset_env_variables() {
  local required_vars=("ECR_USERNAME" "ECR_TOKEN" "ECR_REGION" "ECR_REGISTRY_ID")

  for var in "${required_vars[@]}"; do
    echo "$var=" >>"$GITHUB_ENV"
  done

  log "Environment unset successful"
}

# Main function
main() {
  log "Starting PSE GitHub Action setup mode"

  validate_env_vars
  setup_dependencies
  pull_and_start_pse_container
  #signal_build_start
  register_cleanup
  unset_env_variables

  log "Setup mode completed successfully"
  log "PSE container is running at IP: $PROXY_IP"
  log "This IP address has been saved to GitHub environment as PSE_PROXY_IP"
  log "Use this value in the intercept mode by setting mode: 'intercept' and proxy_ip: \${{ steps.<step-id>.outputs.proxy_ip }}"
}

# Execute main function
main
