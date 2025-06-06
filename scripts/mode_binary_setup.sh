#!/bin/bash
# PSE GitHub Action - Binary Setup Script
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

  # Extract the PSE binary from the container image without running it
  log "Extracting PSE binary from container image"

  # Create a temporary directory to store the binary
  local PSE_BIN_DIR="$GITHUB_WORKSPACE/pse-bin"
  mkdir -p "$PSE_BIN_DIR"

  # Create a container without starting it
  local TEMP_CONTAINER_ID
  TEMP_CONTAINER_ID=$(run_with_privilege docker create "$PSE_IMAGE")

  if [ -z "$TEMP_CONTAINER_ID" ]; then
    log "ERROR: Failed to create temporary container from image $PSE_IMAGE"
    exit 1
  fi

  # Copy the PSE binary from the container to the host
  log "Copying PSE binary from container to host"
  if ! run_with_privilege docker cp "$TEMP_CONTAINER_ID:/pse" "$PSE_BIN_DIR/pse"; then
    log "ERROR: Failed to copy PSE binary from container"
    exit 1
  fi
  # Make the binary executable
  run_with_privilege chmod +x "$PSE_BIN_DIR/pse"

  # Copy the PSE policy from the container to the host
  log "Copying PSE policy from container to host"
  if ! run_with_privilege docker cp "$TEMP_CONTAINER_ID:/policy.json" "$PSE_BIN_DIR/policy.json"; then
    log "ERROR: Failed to copy PSE policy from container"
    exit 1
  fi

  # Make the policy file readable
  run_with_privilege chmod +r "$PSE_BIN_DIR/policy.json"

  # Copy the PSE config from the container to the host
  log "Copying PSE config from container to host"
  if ! run_with_privilege docker cp "$TEMP_CONTAINER_ID:/cfg.yaml" "$PSE_BIN_DIR/cfg.yaml"; then
    log "ERROR: Failed to copy PSE config from container"
    exit 1
  fi

  # Make the config file readable
  run_with_privilege chmod +r "$PSE_BIN_DIR/cfg.yaml"

  # Copy leaks.toml from the container to the host
  log "Copying PSE leaks.toml from container to host"
  if ! run_with_privilege docker cp "$TEMP_CONTAINER_ID:/leaks.toml" "$PSE_BIN_DIR/leaks.toml"; then
    log "ERROR: Failed to copy PSE leaks.toml from container"
    exit 1
  fi

  # Make the leaks.toml file readable
  run_with_privilege chmod +r "$PSE_BIN_DIR/leaks.toml"
  run_with_privilege cp "$PSE_BIN_DIR/leaks.toml" /tmp/leaks.toml

  echo "Showing directory contents of $PSE_BIN_DIR"
  run_with_privilege ls -lrth "$PSE_BIN_DIR"

  # Remove the temporary container
  log "Removing temporary container"
  run_with_privilege docker rm "$TEMP_CONTAINER_ID" >/dev/null 2>&1 || true

  log "Successfully extracted PSE binary and other files to $PSE_BIN_DIR/pse"

  # Save the binary path to environment for later use
  echo "PSE_BINARY_PATH=$PSE_BIN_DIR/pse" >>$GITHUB_ENV

  # set proxy_ip to the ip of this machine
  PSE_IP=$(run_with_privilege hostname -I | awk '{print $1}')

  export PSE_IP
  export PROXY_IP="$PSE_IP"

  # Run pse binary with full command including policy and config
  # when running pse; let's make INVISIRISK_JWT_TOKEN and INVISIRISK_PORTAL available as environment variables at the OS level
  export INVISIRISK_JWT_TOKEN="$APP_TOKEN"
  export INVISIRISK_PORTAL="$PORTAL_URL"
  export PSE_DEBUG_FLAG=--alsologtostderr
  export POLICY_LOG=t

  log "Starting PSE binary in serve mode with policy and config"

  # Define log file path
  PSE_LOG_FILE="/tmp/pse_binary.log"
  echo "PSE_LOG_FILE=$PSE_LOG_FILE" >>$GITHUB_ENV
  log "PSE_LOG_FILE set to $PSE_LOG_FILE"

  # Add this to your mode_binary_setup.sh script before starting the PSE binary
  log "Temporarily disabling IPv6"
  run_with_privilege sysctl -w net.ipv6.conf.all.disable_ipv6=1
  run_with_privilege sysctl -w net.ipv6.conf.default.disable_ipv6=1
  run_with_privilege sysctl -w net.ipv6.conf.lo.disable_ipv6=1

  # We need to run pse in background
  if [ "$(id -u)" = "0" ]; then
    # Running as root, execute directly
    log "Running pse as root"
    (cd "$PSE_BIN_DIR" && ./pse serve --policy ./policy.json --config ./cfg.yaml --leaks /tmp/leaks.toml --global-session true >"$PSE_LOG_FILE" 2>&1 &)
  else
    # Not running as root, use sudo
    log "Running pse with sudo"
    (cd "$PSE_BIN_DIR" && sudo -E ./pse serve --policy ./policy.json --config ./cfg.yaml --leaks /tmp/leaks.toml --global-session true >"$PSE_LOG_FILE" 2>&1 &)
  fi

  # Give the PSE binary a moment to start up
  sleep 5

  # check if the log file is being written to
  if [ ! -f "$PSE_LOG_FILE" ]; then
    log "ERROR: PSE log file not found"
    #exit 1
  else
    log "PSE log file found"
  fi

  # Do a pwd to check the directory
  log "Current directory:"
  run_with_privilege pwd

  # List the directory contents for the directory containing $PSE_LOG_FILE
  log "Directory contents for $(dirname "$PSE_LOG_FILE"):"
  run_with_privilege ls -alh "$(dirname "$PSE_LOG_FILE")"

  # Find the PSE process ID reliably
  log "Finding PSE process ID..."
  if [ "$(id -u)" = "0" ]; then
    PSE_PID=$(pgrep -f "pse serve" | head -1)
  else
    PSE_PID=$(sudo pgrep -f "pse serve" | head -1)
  fi

  if [ -z "$PSE_PID" ]; then
    log "ERROR: Could not find PSE process ID"
    log "Processes containing 'pse':"
    ps aux | grep pse
    exit 1
  fi

  log "PSE binary started with PID: $PSE_PID"
  echo "PSE_PID=$PSE_PID" >>$GITHUB_ENV

  # Verify the process is running
  if ! run_with_privilege ps -p "$PSE_PID" >/dev/null 2>&1; then
    log "ERROR: PSE binary process with PID $PSE_PID not found"
    run_with_privilege ps -eaf
    exit 1
  else
    log "PSE binary process with PID $PSE_PID is running"
  fi

  # Let's run netstat to check if port 12345 is open
  echo "Checking if port 12345 is open ===>"
  run_with_privilege netstat -tuln
  echo "<==="

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
  log "Starting PSE GitHub Action binary setup mode"

  validate_env_vars
  setup_dependencies
  pull_and_start_pse_container
  #signal_build_start
  register_cleanup
  unset_env_variables

  log "Binary setup mode completed successfully"
  log "PSE container is running at IP: $PROXY_IP"
  log "This IP address has been saved to GitHub environment as PSE_PROXY_IP"
  log "Use this value in the intercept mode by setting mode: 'intercept' and proxy_ip: \${{ steps.<step-id>.outputs.proxy_ip }}"
}

# Execute main function
main
