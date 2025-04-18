#!/bin/bash
# PSE  - Prepare Script
# This script obtains scan ID and ECR credentials

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
validate_env_vars_for_prepare() {
  local required_vars=("API_URL" "APP_TOKEN")

  for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
      log "ERROR: Required environment variable $var is not set"
      exit 1
    fi
  done

  # Set PORTAL_URL to API_URL if not provided
  if [ -z "$PORTAL_URL" ]; then
    log "PORTAL_URL not set, using API_URL: $API_URL"
    PORTAL_URL="$API_URL"
    export PORTAL_URL
  fi

  log "Environment validation successful"
}

# Function to parse JSON
parse_json() {
  local json="$1"
  local field="$2"

  # Check if jq is available
  if command -v jq >/dev/null 2>&1; then
    # Use jq for more reliable JSON parsing
    value=$(echo "$json" | jq -r ".$field" 2>/dev/null)
    if [ "$value" != "null" ] && [ -n "$value" ]; then
      echo "$value"
      return 0
    fi
  fi

  # Fallback to grep-based parsing
  echo "$json" | grep -o "\"$field\":[^,}]*" | sed -E 's/"'"$field"'":"|,|}//'
}

# Function to get ECR credentials
get_ecr_credentials() {
  log "Getting ECR credentials from InvisiRisk API"

  # Check if in test mode
  if [ "$TEST_MODE" = "true" ]; then
    log "Running in TEST_MODE, using dummy ECR credentials"
    ECR_USERNAME="test-username"
    ECR_TOKEN="test-token"
    ECR_REGION="us-west-2"
    ECR_REGISTRY_ID="123456789012"
    export ECR_USERNAME ECR_TOKEN ECR_REGION ECR_REGISTRY_ID
    return 0
  fi

  # Construct API URL for ECR credentials
  local API_ENDPOINT="$API_URL/utilityapi/v1/registry?api_key=$APP_TOKEN"
  log "Obtaining ECR credentials from $API_ENDPOINT"

  # Make API request to get ECR credentials
  local RESPONSE
  RESPONSE=$(curl -L -s -X GET "$API_ENDPOINT" )

  log "API response received"

  # Check if response contains an error
  if echo "$RESPONSE" | grep -q "error"; then
    local ERROR_MSG
    ERROR_MSG=$(parse_json "$RESPONSE" "error")
    log "ERROR: Failed to get ECR credentials: $ERROR_MSG"
    exit 1
  fi

  # Parse the response to get the token
  local DECODED_TOKEN
  local DATA_FIELD
  DATA_FIELD=$(parse_json "$RESPONSE" "data")
  DECODED_TOKEN=$(echo "$DATA_FIELD" | base64 --decode)

  # Extract ECR credentials
  ECR_USERNAME=$(parse_json "$DECODED_TOKEN" "username")
  ECR_TOKEN=$(parse_json "$DECODED_TOKEN" "password")
  ECR_REGION=$(parse_json "$DECODED_TOKEN" "region")
  ECR_REGISTRY_ID=$(parse_json "$DECODED_TOKEN" "registry_id")

  # Validate extracted credentials
  if [ -z "$ECR_USERNAME" ] || [ -z "$ECR_TOKEN" ] || [ -z "$ECR_REGION" ] || [ -z "$ECR_REGISTRY_ID" ]; then
    log "ERROR: Failed to extract ECR credentials from API response"
    log "API Response: $RESPONSE"
    exit 1
  fi

  # Export the credentials for use in other functions
  export ECR_USERNAME ECR_TOKEN ECR_REGION ECR_REGISTRY_ID

  log "ECR credentials obtained successfully"
}

# Function to create or validate scan ID
prepare_scan_id() {
  log "Preparing scan ID"

  # Check if scan ID is already provided
  if [ -n "$SCAN_ID" ]; then
    log "Using provided scan ID: $SCAN_ID"
    return 0
  fi

  # Check if in test mode
  if [ "$TEST_MODE" = "true" ]; then
    log "Running in TEST_MODE, generating dummy scan ID"
    SCAN_ID="test-scan-$(date +%Y%m%d%H%M%S)"
    export SCAN_ID
    return 0
  fi

  # Create a new scan in the InvisiRisk Portal
  local API_ENDPOINT="$API_URL/utilityapi/v1/scan"
  log "Creating scan in InvisiRisk Portal at $API_ENDPOINT"

  # Make API request to create scan
  local RESPONSE
  RESPONSE=$(curl -L -X POST "$API_ENDPOINT" \
    -H "Content-Type: application/json" \
    -d "{\"api_key\":\"$APP_TOKEN\"}")

  log "API response received: $RESPONSE"

  # Check if response contains an error
  if echo "$RESPONSE" | grep -q "error"; then
    local ERROR_MSG
    ERROR_MSG=$(parse_json "$RESPONSE" "error")
    log "ERROR: Failed to create scan: $ERROR_MSG"
    exit 1
  fi

  # Parse the response to get the scan ID
  SCAN_ID=$(parse_json "$RESPONSE" "id")

  # If parsing failed, try alternative methods
  if [ -z "$SCAN_ID" ]; then
    log "Standard JSON parsing failed, trying alternative methods"
    SCAN_ID=$(echo "$RESPONSE" | grep -o '[0-9a-f]\{8\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{12\}' | head -1)
  fi

  # Validate scan ID
  if [ -z "$SCAN_ID" ]; then
    log "ERROR: Failed to extract scan ID from API response"
    log "API Response: $RESPONSE"
    exit 1
  fi

  # Export the scan ID for use in other functions
  export SCAN_ID

  log "Scan ID obtained successfully: $SCAN_ID"
}

# Function to set outputs for GitHub Actions
set_outputs() {
  log "Setting environment variables"

  # Export variables to current session
  export ECR_USERNAME
  export ECR_TOKEN
  export ECR_REGION
  export ECR_REGISTRY_ID
  export SCAN_ID

  # Export API values for later use
  export PSE_API_URL="$API_URL"
  export PSE_APP_TOKEN="$APP_TOKEN"
  export PSE_PORTAL_URL="$PORTAL_URL"

  # If running in GitHub Actions, also set GitHub-specific outputs
  if [ -n "$GITHUB_ENV" ] && [ -n "$GITHUB_OUTPUT" ]; then
    log "GitHub Actions environment detected, setting GitHub outputs"

    # Set GitHub outputs
    echo "ecr_username=$ECR_USERNAME" >> "$GITHUB_OUTPUT"
    echo "ecr_token=$ECR_TOKEN" >> "$GITHUB_OUTPUT"
    echo "ecr_region=$ECR_REGION" >> "$GITHUB_OUTPUT"
    echo "ecr_registry_id=$ECR_REGISTRY_ID" >> "$GITHUB_OUTPUT"
    echo "scan_id=$SCAN_ID" >> "$GITHUB_OUTPUT"

    # Set GitHub environment variables
    echo "ECR_USERNAME=$ECR_USERNAME" >> "$GITHUB_ENV"
    echo "ECR_TOKEN=$ECR_TOKEN" >> "$GITHUB_ENV"
    echo "ECR_REGION=$ECR_REGION" >> "$GITHUB_ENV"
    echo "ECR_REGISTRY_ID=$ECR_REGISTRY_ID" >> "$GITHUB_ENV"
    echo "SCAN_ID=$SCAN_ID" >> "$GITHUB_ENV"
    echo "PSE_API_URL=$API_URL" >> "$GITHUB_ENV"
    echo "PSE_APP_TOKEN=$APP_TOKEN" >> "$GITHUB_ENV"
    echo "PSE_PORTAL_URL=$PORTAL_URL" >> "$GITHUB_ENV"
  fi

  log "Environment variables set successfully"
}

install_dependencies() {
  log "Installing dependencies"

  # Detect the package manager
  if command -v apt-get >/dev/null 2>&1; then
    # Debian/Ubuntu (apt-get)
    log "Detected apt-get package manager"
    run_with_privilege apt-get update
    run_with_privilege apt-get install -y curl git procps jq
    if ! command -v docker >/dev/null 2>&1; then
      log "Docker not found, installing..."
      run_with_privilege apt-get install -y docker.io
      run_with_privilege systemctl start docker || true
    fi
  elif command -v apk >/dev/null 2>&1; then
    # Alpine (apk)
    log "Detected apk package manager"
    run_with_privilege apk update
    run_with_privilege apk add --no-cache curl git procps jq
    if ! command -v docker >/dev/null 2>&1; then
      log "Docker not found, installing..."
      run_with_privilege apk add --no-cache docker.io
      run_with_privilege systemctl start docker || true
    fi
  else
    log "Error: No supported package manager (apt-get or apk) found"
    exit 1
  fi

  log "Dependencies installed successfully"
}

# Validate required environment variables
validate_env_vars_for_setup() {
  local required_vars=("ECR_USERNAME" "ECR_TOKEN" "ECR_REGION" "ECR_REGISTRY_ID" "SCAN_ID")

  for var in "${required_vars[@]}"; do
    if [ -z "${!var}" ]; then
      log "ERROR: Required environment variable $var is not set"
      exit 1
    fi
  done

  log "Environment validation successful"
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
    "$ECR_REGISTRY_ID.dkr.ecr.$ECR_REGION.amazonaws.com/invisirisk/pse-proxy:dev-test"
    "invisirisk/pse-proxy:dev-test"
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

  # Export binary path
  export PSE_BINARY_PATH="$PSE_BIN_DIR/pse"

  # Set GitHub environment if running in GitHub Actions
  if [ -n "$GITHUB_ENV" ]; then
    echo "PSE_BINARY_PATH=$PSE_BIN_DIR/pse" >> $GITHUB_ENV
  fi

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
  export PSE_LOG_FILE

  if [ -n "$GITHUB_ENV" ]; then
    echo "PSE_LOG_FILE=$PSE_LOG_FILE" >> $GITHUB_ENV
  fi
  log "PSE_LOG_FILE set to $PSE_LOG_FILE"



  # Add this to your mode_binary_setup.sh script before starting the PSE binary
  # log "Temporarily disabling IPv6"
  # run_with_privilege sysctl -w net.ipv6.conf.all.disable_ipv6=1
  # run_with_privilege sysctl -w net.ipv6.conf.default.disable_ipv6=1
  # run_with_privilege sysctl -w net.ipv6.conf.lo.disable_ipv6=1

  # We need to run pse in background
  if [ "$(id -u)" = "0" ]; then
    # Running as root, execute directly
    log "Running pse as root"
    (cd "$PSE_BIN_DIR" && ./pse serve --policy ./policy.json --config ./cfg.yaml --leaks /tmp/leaks.toml --global-session true > "$PSE_LOG_FILE" 2>&1 &)
  else
    # Not running as root, use sudo
    log "Running pse with sudo"
    (cd "$PSE_BIN_DIR" && sudo -E ./pse serve --policy ./policy.json --config ./cfg.yaml --leaks /tmp/leaks.toml --global-session true > "$PSE_LOG_FILE" 2>&1 &)
  fi

  echo "Give the PSE binary a moment to start up"
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
  export PSE_PID

  if [ -n "$GITHUB_ENV" ]; then
    echo "PSE_PID=$PSE_PID" >> $GITHUB_ENV
  fi

  # Verify the process is running
  if ! run_with_privilege ps -p "$PSE_PID" > /dev/null 2>&1; then
    log "ERROR: PSE binary process with PID $PSE_PID not found"
    run_with_privilege ps -eaf
    exit 1
  else
    log "PSE binary process with PID $PSE_PID is running"
  fi


  # Check if port 12345 is open
  echo "Checking if port 12345 is open ===>"

  # Check if netstat is available, if not install it
  if ! command -v netstat >/dev/null 2>&1; then
    log "netstat not found, installing net-tools package..."
    if command -v apt-get >/dev/null 2>&1; then
      run_with_privilege apt-get update
      run_with_privilege apt-get install -y net-tools
    elif command -v yum >/dev/null 2>&1; then
      run_with_privilege yum install -y net-tools
    elif command -v apk >/dev/null 2>&1; then
      run_with_privilege apk add --no-cache net-tools
    else
      log "WARNING: Could not install netstat. Skipping port check."
      echo "<==="
      return 0
    fi
  fi

  run_with_privilege netstat -tuln
  echo "<==="

  # Save the API values to environment for later use
  # Create a profile script for persistent environment variables
  PSE_PROFILE="/etc/profile.d/pse-proxy.sh"

  log "Creating persistent environment variables in $PSE_PROFILE"

  # Create the profile script with sudo
  run_with_privilege tee -a "$PSE_PROFILE" > /dev/null << EOF
#!/bin/bash
export PSE_API_URL="$API_URL"
export PSE_APP_TOKEN="$APP_TOKEN"
export PSE_PORTAL_URL="$PORTAL_URL"
export PSE_PROXY_IP="$PSE_IP"
export PROXY_IP="$PSE_IP"
export PSE_BINARY_PATH="$PSE_BIN_DIR/pse"
export PSE_LOG_FILE="$PSE_LOG_FILE"
export PSE_PID="$PSE_PID"
export INVISIRISK_JWT_TOKEN="$APP_TOKEN"
export INVISIRISK_PORTAL="$PORTAL_URL"
export PSE_DEBUG_FLAG="--alsologtostderr"
export POLICY_LOG="t"
EOF

  # Make the profile script executable
  run_with_privilege chmod +x "$PSE_PROFILE"

  # Source the profile script immediately
  # shellcheck source=/dev/null
  source "$PSE_PROFILE"

  # Keep the existing exports for immediate use
  export PSE_API_URL="$API_URL"
  export PSE_APP_TOKEN="$APP_TOKEN"
  export PSE_PORTAL_URL="$PORTAL_URL"
  export PSE_PROXY_IP="$PSE_IP"

  # Set GitHub environment if running in GitHub Actions
  if [ -n "$GITHUB_ENV" ] && [ -n "$GITHUB_OUTPUT" ]; then
    echo "PSE_API_URL=$API_URL" >> $GITHUB_ENV
    echo "PSE_APP_TOKEN=$APP_TOKEN" >> $GITHUB_ENV
    echo "PSE_PORTAL_URL=$PORTAL_URL" >> $GITHUB_ENV
    echo "PSE_PROXY_IP=$PSE_IP" >> $GITHUB_ENV
    echo "proxy_ip=$PSE_IP" >> $GITHUB_OUTPUT
    echo "::set-output name=proxy_ip::$PSE_IP"
  fi

  # Also save the PSE proxy IP as an output parameter
  # echo "proxy_ip=$PSE_IP" >> $GITHUB_OUTPUT

  export proxy_ip="$PSE_IP"
  echo "::set-output name=proxy_ip::$PSE_IP"

  # Double check that the proxy IP has been properly set as output
  log "Set proxy_ip output parameter to: $PSE_IP"

  log "PSE container started with IP: $PSE_IP"
  log "Proxy IP has been exported as: $proxy_ip"
}

unset_env_variables() {
  local required_vars=("ECR_USERNAME" "ECR_TOKEN" "ECR_REGION" "ECR_REGISTRY_ID")

  # Unset both local and GitHub environment variables
  for var in "${required_vars[@]}"; do
    unset "$var"
    if [ -n "$GITHUB_ENV" ]; then
      echo "$var=" >> "$GITHUB_ENV"
    fi
  done

  log "Environment unset successful"
}

# Validate required environment variables
validate_environment_for_intercept() {
  log "Validating environment variables for intercept mode"

  # If PROXY_IP is not set, try to discover it (regardless of whether PROXY_HOSTNAME is set)
  if [ -z "$PROXY_IP" ]; then
    if [ -z "$PROXY_HOSTNAME" ]; then
      log "PROXY_IP or PROXY_HOSTNAME not provided, attempting to discover PSE proxy IP"
    else
      log "PROXY_HOSTNAME provided but PROXY_IP not set, resolving hostname to IP"
    fi

    discovered_ip=$(discover_pse_proxy_ip)

    if [ -n "$discovered_ip" ]; then
      log "Successfully discovered PSE proxy IP: $discovered_ip"
      export PROXY_IP="$discovered_ip"
      echo "PSE_PROXY_IP=$discovered_ip" >> $GITHUB_ENV
    else
      log "ERROR: Could not discover PSE proxy IP automatically"
      log "This may happen if the PSE proxy container is not running or not accessible"
      log "You can provide proxy_ip or proxy_hostname input parameter to resolve this issue"
      exit 1
    fi
  fi

  # If SCAN_ID is not set and we're not in test mode, fail
  if [ -z "$SCAN_ID" ] && [ "$TEST_MODE" != "true" ]; then
    log "ERROR: SCAN_ID must be provided for intercept mode when not in test mode"
    log "Please provide scan_id input parameter or run in test mode"
    exit 1
  fi

  log "Environment validation successful"
}

# Function to discover the PSE proxy container IP
discover_pse_proxy_ip() {
  # Redirect all log messages to stderr so they don't get captured in the function output
  log "Attempting to discover PSE proxy container IP" >&2
  local discovered_ip=""

  # First, check if Docker is available
  if command -v docker >/dev/null 2>&1; then
    log "Docker is available, attempting to find PSE proxy container" >&2

    # Try to find the container by image name
    log "Looking for PSE proxy container by image..." >&2
    local pse_containers=$(run_with_privilege docker ps --filter "ancestor=invisirisk/pse-proxy" --format "{{.Names}}" 2>/dev/null || echo "")

    # If not found, try with ECR path
    if [ -z "$pse_containers" ]; then
      log "Trying with ECR path..." >&2
      pse_containers=$(run_with_privilege docker ps --filter "ancestor=282904853176.dkr.ecr.us-west-2.amazonaws.com/invisirisk/pse-proxy" --format "{{.Names}}" 2>/dev/null || echo "")
    fi

    # If still not found, try with any available registry ID and region
    if [ -z "$pse_containers" ] && [ -n "$ECR_REGISTRY_ID" ] && [ -n "$ECR_REGION" ]; then
      log "Trying with provided ECR registry ID and region..." >&2
      pse_containers=$(run_with_privilege docker ps --filter "ancestor=$ECR_REGISTRY_ID.dkr.ecr.$ECR_REGION.amazonaws.com/invisirisk/pse-proxy" --format "{{.Names}}" 2>/dev/null || echo "")
    fi

    # If containers found, get the IP of the first one
    if [ -n "$pse_containers" ]; then
      local container_name=$(echo "$pse_containers" | head -n 1)
      log "Found PSE proxy container: $container_name" >&2
      discovered_ip=$(run_with_privilege docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$container_name" 2>/dev/null || echo "")
      log "Discovered PSE proxy IP: $discovered_ip" >&2
    else
      log "No PSE proxy containers found by image name" >&2
    fi
  else
    log "Docker is not available, cannot discover container directly" >&2
  fi

  # If we couldn't find the IP using Docker or Docker is not available,
  # try to resolve using hostname as a fallback
  if [ -z "$discovered_ip" ]; then
    log "Attempting to resolve PSE proxy using hostname..." >&2

    # Determine which hostname to use - use PROXY_HOSTNAME if provided, otherwise default to 'pse-proxy'
    local hostname_to_try="pse-proxy"
    local alt_hostname="${hostname_to_try}.local"

    if [ -n "$PROXY_HOSTNAME" ]; then
      log "Using provided PROXY_HOSTNAME: $PROXY_HOSTNAME" >&2
      hostname_to_try="$PROXY_HOSTNAME"
      alt_hostname=""  # Don't try .local suffix with user-provided hostname
    else
      log "Using default hostname: $hostname_to_try" >&2
    fi

    # Try all available hostname resolution methods in sequence until one succeeds

    # Method 1: getent
    if command -v getent >/dev/null 2>&1 && [ -z "$discovered_ip" ]; then
      log "Using getent to resolve hostname $hostname_to_try" >&2
      discovered_ip=$(getent hosts "$hostname_to_try" 2>/dev/null | awk '{ print $1 }' | head -n 1)

      if [ -n "$discovered_ip" ]; then
        log "Successfully resolved using getent: $discovered_ip" >&2
      elif [ -n "$alt_hostname" ]; then
        # Try with alternative hostname if it exists
        log "Trying alternative hostname with getent: $alt_hostname" >&2
        discovered_ip=$(getent hosts "$alt_hostname" 2>/dev/null | awk '{ print $1 }' | head -n 1)
        if [ -n "$discovered_ip" ]; then
          log "Successfully resolved alternative hostname using getent: $discovered_ip" >&2
        fi
      fi
    fi

    # Method 2: host command
    if command -v host >/dev/null 2>&1 && [ -z "$discovered_ip" ]; then
      log "Using host command to resolve hostname $hostname_to_try" >&2
      discovered_ip=$(host -t A "$hostname_to_try" 2>/dev/null | grep "has address" | head -n 1 | awk '{ print $NF }')

      if [ -n "$discovered_ip" ]; then
        log "Successfully resolved using host command: $discovered_ip" >&2
      elif [ -n "$alt_hostname" ]; then
        # Try with alternative hostname if it exists
        log "Trying alternative hostname with host command: $alt_hostname" >&2
        discovered_ip=$(host -t A "$alt_hostname" 2>/dev/null | grep "has address" | head -n 1 | awk '{ print $NF }')
        if [ -n "$discovered_ip" ]; then
          log "Successfully resolved alternative hostname using host command: $discovered_ip" >&2
        fi
      fi
    fi

    # Method 3: nslookup
    if command -v nslookup >/dev/null 2>&1 && [ -z "$discovered_ip" ]; then
      log "Using nslookup to resolve hostname $hostname_to_try" >&2
      discovered_ip=$(nslookup "$hostname_to_try" 2>/dev/null | grep "Address:" | tail -n 1 | awk '{ print $2 }')

      if [ -n "$discovered_ip" ]; then
        log "Successfully resolved using nslookup: $discovered_ip" >&2
      elif [ -n "$alt_hostname" ]; then
        # Try with alternative hostname if it exists
        log "Trying alternative hostname with nslookup: $alt_hostname" >&2
        discovered_ip=$(nslookup "$alt_hostname" 2>/dev/null | grep "Address:" | tail -n 1 | awk '{ print $2 }')
        if [ -n "$discovered_ip" ]; then
          log "Successfully resolved alternative hostname using nslookup: $discovered_ip" >&2
        fi
      fi
    fi

    # Method 4: ping (last resort)
    if command -v ping >/dev/null 2>&1 && [ -z "$discovered_ip" ]; then
      log "Using ping to resolve hostname $hostname_to_try" >&2
      discovered_ip=$(ping -c 1 "$hostname_to_try" 2>/dev/null | grep "PING" | head -n 1 | awk -F'[()]' '{ print $2 }')

      if [ -n "$discovered_ip" ]; then
        log "Successfully resolved using ping: $discovered_ip" >&2
      elif [ -n "$alt_hostname" ]; then
        # Try with alternative hostname if it exists
        log "Trying alternative hostname with ping: $alt_hostname" >&2
        discovered_ip=$(ping -c 1 "$alt_hostname" 2>/dev/null | grep "PING" | head -n 1 | awk -F'[()]' '{ print $2 }')
        if [ -n "$discovered_ip" ]; then
          log "Successfully resolved alternative hostname using ping: $discovered_ip" >&2
        fi
      fi
    fi

    if [ -n "$discovered_ip" ]; then
      log "Successfully resolved PSE proxy IP from hostname: $discovered_ip" >&2
    else
      log "Could not resolve PSE proxy hostname using any available method" >&2
    fi
  fi

  # Only output the IP address, nothing else
  echo "$discovered_ip"
}

# URL encode function
url_encode() {
  local string="$1"
  local strlen=${#string}
  local encoded=""
  local pos c o

  for (( pos=0 ; pos<strlen ; pos++ )); do
    c=${string:$pos:1}
    case "$c" in
      [-_.~a-zA-Z0-9] ) o="${c}" ;;
      * )               printf -v o '%%%02x' "'$c"
    esac
    encoded+="${o}"
  done
  echo "${encoded}"
}

# Function to start the capture by calling the /start endpoint
start_capture() {
  log "Starting capture by calling the /start endpoint"

  # Skip in test mode
  if [ "$TEST_MODE" = "true" ]; then
    log "Running in TEST_MODE, skipping capture start"
    return 0
  fi

  # Ensure we have PROXY_IP
  if [ -z "$PROXY_IP" ]; then
    log "ERROR: PROXY_IP is not set. Cannot start capture."
    exit 1
  fi

  # Initialize retry variables
  local RETRY_DELAY=5
  local ATTEMPT=1
  local MAX_ATTEMPTS=3

  # Get Git information with fallbacks for CI environment
  git_url=$(git config --get remote.origin.url 2>/dev/null || echo "https://github.com/$GITHUB_REPOSITORY.git")
  git_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "${GITHUB_REF#refs/heads/}")
  git_commit=$(git rev-parse HEAD 2>/dev/null || echo "$GITHUB_SHA")
  repo_name=$(basename -s .git "$git_url" 2>/dev/null || echo "$GITHUB_REPOSITORY")

  # Build URL for the GitHub run
  build_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"

  # Build parameters
  params="builder=$(url_encode "samplegithub")"
  params="${params}&id=$(url_encode "$SCAN_ID")"
  params="${params}&build_id=$(url_encode "$GITHUB_RUN_ID")"
  params="${params}&build_url=$(url_encode "$build_url")"
  params="${params}&project=$(url_encode "${repo_name:-$GITHUB_REPOSITORY}")"
  params="${params}&workflow=$(url_encode "$GITHUB_WORKFLOW")"
  params="${params}&builder_url=$(url_encode "$GITHUB_SERVER_URL")"
  params="${params}&scm=$(url_encode "git")"
  params="${params}&scm_commit=$(url_encode "$git_commit")"
  params="${params}&scm_branch=$(url_encode "$git_branch")"
  params="${params}&scm_origin=$(url_encode "$git_url")"

  log "Sending start signal to PSE service"

  # Try to send the start signal with retries
  while [ $ATTEMPT -le $MAX_ATTEMPTS ]; do
    log "Attempt $ATTEMPT of $MAX_ATTEMPTS..."

    RESPONSE=$(curl -X POST "https://pse.invisirisk.com/start" \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        -H 'User-Agent: pse-action' \
        -d "$params" \
        -k  \
        --connect-timeout 5 \
        --retry 3 --retry-delay 2 --max-time 10 \
        -s -w "\n%{http_code}" 2>&1)

    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    RESPONSE_BODY=$(echo "$RESPONSE" | sed '$d')

    if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
      log "Start signal sent successfully (HTTP $HTTP_CODE)"
      log "Response: $RESPONSE_BODY"
      return 0
    else
      log "Failed to send start signal (HTTP $HTTP_CODE)"
      log "Response: $RESPONSE_BODY"

      if [ $ATTEMPT -lt $MAX_ATTEMPTS ]; then
        log "Retrying in $RETRY_DELAY seconds..."
        sleep $RETRY_DELAY
        RETRY_DELAY=$((RETRY_DELAY * 2))
      fi
      ATTEMPT=$((ATTEMPT + 1))
    fi
  done

  log "ERROR: Failed to send start signal after $MAX_ATTEMPTS attempts"
  return 1
}

# Function to set up HTTP proxy environment variables
setup_http_proxy() {
  log "Setting up HTTP proxy environment variables"

  # Create a profile script for persistent proxy environment variables
  PSE_PROXY_PROFILE="/etc/profile.d/pse-proxy.sh"

  log "Creating persistent proxy environment variables in $PSE_PROXY_PROFILE"

  # Create the profile script with sudo
  run_with_privilege tee -a "$PSE_PROXY_PROFILE" > /dev/null << 'EOF'
export http_proxy="http://127.0.0.1:3128"
export HTTP_PROXY="http://127.0.0.1:3128"
export https_proxy="http://127.0.0.1:3128"
export HTTPS_PROXY="http://127.0.0.1:3128"
export no_proxy="app.invisirisk.com,localhost,127.0.0.1"
export NO_PROXY="app.invisirisk.com,localhost,127.0.0.1"
export PSE_CERT_PROFILE="/etc/profile.d/pse-cert.sh"
EOF

  # Make the profile script executable
  run_with_privilege chmod +x "$PSE_PROXY_PROFILE"

  # Source the profile script immediately
  # shellcheck source=/dev/null


  # Keep the existing exports for immediate use
  export http_proxy="http://127.0.0.1:3128"
  export HTTP_PROXY="http://127.0.0.1:3128"
  export https_proxy="http://127.0.0.1:3128"
  export HTTPS_PROXY="http://127.0.0.1:3128"
  export no_proxy="app.invisirisk.com,localhost,127.0.0.1"
  export NO_PROXY="app.invisirisk.com,localhost,127.0.0.1"

  # Keep GitHub Actions compatibility
  if [ -n "$GITHUB_ENV" ]; then
    echo "http_proxy=http://127.0.0.1:3128" >> $GITHUB_ENV
    echo "HTTP_PROXY=http://127.0.0.1:3128" >> $GITHUB_ENV
    echo "https_proxy=http://127.0.0.1:3128" >> $GITHUB_ENV
    echo "HTTPS_PROXY=http://127.0.0.1:3128" >> $GITHUB_ENV
    echo "no_proxy=app.invisirisk.com,localhost,127.0.0.1" >> $GITHUB_ENV
    echo "NO_PROXY=app.invisirisk.com,localhost,127.0.0.1" >> $GITHUB_ENV
  fi

  log "HTTP proxy environment variables set successfully"
}

# Function to set up certificates
setup_certificates() {
  log "Setting up certificates for HTTPS interception"

  MAX_RETRIES=5
  RETRY_DELAY=3
  ATTEMPT=1

  # Create directory for extra CA certificates if it doesn't exist
  run_with_privilege mkdir -p /usr/local/share/ca-certificates/extra
  log "Created directory for extra CA certificates"

  while [ $ATTEMPT -le $MAX_RETRIES ]; do
    log "Fetching CA certificate, attempt $ATTEMPT of $MAX_RETRIES"
    CURL_OUTPUT=$(curl -L -k -s -o /tmp/pse.crt https://pse.invisirisk.com/ca 2>&1)
    CURL_EXIT_CODE=$?

    if [ $CURL_EXIT_CODE -eq 0 ] && [ -f "/tmp/pse.crt" ]; then
      log "Certificate download successful"
      # Verify the certificate file is not empty
      if [ -s "/tmp/pse.crt" ]; then
        # Copy to the proper location for Ubuntu/Debian
        run_with_privilege cp /tmp/pse.crt /usr/local/share/ca-certificates/extra/pse.crt
        log "CA certificate successfully retrieved and copied to /usr/local/share/ca-certificates/extra/"
        break
      else
        log "WARNING: Downloaded certificate file is empty"
      fi
    else
      log "Failed to retrieve CA certificate (Exit code: $CURL_EXIT_CODE)"
      log "Curl output: $CURL_OUTPUT"
      log "Retrying in $RETRY_DELAY seconds..."
      sleep $RETRY_DELAY
      RETRY_DELAY=$((RETRY_DELAY * 2))
      ATTEMPT=$((ATTEMPT + 1))
    fi
  done

  if [ $ATTEMPT -gt $MAX_RETRIES ]; then
    log "ERROR: Failed to retrieve CA certificate after $MAX_RETRIES attempts"
    exit 1
  fi

  # Update CA certificates non-interactively

  log "Updating CA certificates..."
  run_with_privilege update-ca-certificates

  # Set the correct path for the installed certificate
  CA_CERT_PATH="/etc/ssl/certs/pse.crt"

  # Verify the certificate was properly installed
  if [ -f "$CA_CERT_PATH" ]; then
    log "CA certificate successfully installed at $CA_CERT_PATH"
  else
    # Try to find the actual location
    CA_CERT_PATH=$(find /etc/ssl/certs -name "*pse*" | head -n 1)
    if [ -z "$CA_CERT_PATH" ]; then
      log "WARNING: Could not locate installed CA certificate, using default path"
      CA_CERT_PATH="/etc/ssl/certs/pse.crt"
    else
      log "Found CA certificate at $CA_CERT_PATH"
    fi
  fi

  # Configure Git to use our CA
  git config --global http.sslCAInfo "$CA_CERT_PATH"
  #log "Configuring temporarily git to bypass SSL verification"
  #git config --global http.sslVerify false


  # Set environment variables for other tools
  export NODE_EXTRA_CA_CERTS="$CA_CERT_PATH"
  export REQUESTS_CA_BUNDLE="$CA_CERT_PATH"


  # Add to GITHUB_ENV to persist these variables
  if [ -n "$GITHUB_ENV" ]; then
  echo "NODE_EXTRA_CA_CERTS=$CA_CERT_PATH" >> $GITHUB_ENV
  echo "REQUESTS_CA_BUNDLE=$CA_CERT_PATH" >> $GITHUB_ENV
  fi

  # Add handling for docker
  if command -v docker >/dev/null 2>&1; then
    echo "Docker is installed, configuring..."
    run_with_privilege mkdir -p /etc/docker/certs.d
    run_with_privilege cp "$CA_CERT_PATH" /etc/docker/certs.d/pse.crt

    export DOCKER_CERT_PATH=/etc/docker/certs.d/pse.crt

    # Add to GITHUB_ENV to persist this variable
    if [ -n "$GITHUB_ENV" ]; then
    echo "DOCKER_CERT_PATH=/etc/docker/certs.d/pse.crt" >> $GITHUB_ENV
    fi

    if command -v systemctl >/dev/null 2>&1; then
      echo "Restarting docker with systemctl"
      #run_with_privilege systemctl restart docker
      #RESTART_EXIT_CODE=$?
      echo "DEBUG: systemctl docker restart exit code: $RESTART_EXIT_CODE"
    else
      echo "Restarting docker with service"
      #run_with_privilege service docker restart
      #RESTART_EXIT_CODE=$?
      echo "DEBUG: service docker restart exit code: $RESTART_EXIT_CODE"

    fi

  fi

  # Add a delay to allow Docker to fully restart
  log "DEBUG: Waiting for Docker to stabilize after restart"
  #sleep 5

  # Verify Docker is running after restart
  if run_with_privilege docker ps >/dev/null 2>&1; then
    log "DEBUG: Docker is running after restart"
  else
    log "WARNING: Docker may not be running properly after restart"
  fi

  log "Certificates configured successfully"

  run_with_privilege tee -a "$PSE_PROXY_PROFILE" > /dev/null << EOF
export CA_CERT_PATH="$CA_CERT_PATH"
git config --global http.sslCAInfo "$CA_CERT_PATH"
export NODE_EXTRA_CA_CERTS="$CA_CERT_PATH"
export REQUESTS_CA_BUNDLE="$CA_CERT_PATH"
export DOCKER_CERT_PATH=/etc/docker/certs.d/pse.crt
EOF
}


# Main function
intercept() {
  log "Starting PSE intercept mode"
  validate_environment_for_intercept
  setup_http_proxy
  setup_certificates
  start_capture
  log "Intercept mode completed successfully"
  log "HTTPS traffic is now being intercepted by the PSE proxy"
}


binary_setup() {
  log "Starting PSE binary setup mode"

  validate_env_vars_for_setup
  pull_and_start_pse_container
  unset_env_variables

  log "Binary setup mode completed successfully"
  log "PSE container is running at IP: $PROXY_IP"
  log "This IP address has been saved to GitHub environment as PSE_PROXY_IP"
  log "Use this value in the intercept mode by setting mode: 'intercept' and proxy_ip: \${{ steps.<step-id>.outputs.proxy_ip }}"
}


prepare() {
  log "Starting PSE prepare mode"

  install_dependencies
  validate_env_vars_for_prepare
  get_ecr_credentials
  prepare_scan_id
  set_outputs

  log "Prepare mode completed successfully"
}

create_cleanup() {
  log "Creating cleanup script"
  mkdir /tmp/pse_cleanup/
  cat > /tmp/pse_cleanup/cleanup.sh << 'EOF'
#!/bin/bash
# PSE  - Cleanup Script
# This script cleans up the PSE proxy configuration and signals the end of the build

# Enable strict error handling
set -e

# Enable debug mode if requested
if [ "$DEBUG" = "true" ]; then
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

# Validate required environment variables
validate_env_vars() {
  # Check for API_URL
  if [ -z "$API_URL" ]; then
    log "INFO: API_URL is not set, trying to use PSE_API_URL from previous step..."
    if [ -n "$PSE_API_URL" ]; then
      export API_URL="$PSE_API_URL"
      log "Using API_URL from previous step: $API_URL"
    else
      log "ERROR: Could not determine API_URL. Please provide it as an input parameter or run setup first."
      exit 1
    fi
  fi

  # Check for APP_TOKEN
  if [ -z "$APP_TOKEN" ]; then
    log "INFO: APP_TOKEN is not set, trying to use PSE_APP_TOKEN from previous step..."
    if [ -n "$PSE_APP_TOKEN" ]; then
      export APP_TOKEN="$PSE_APP_TOKEN"
      log "Using APP_TOKEN from previous step (value hidden)"
    else
      log "ERROR: Could not determine APP_TOKEN. Please provide it as an input parameter or run setup first."
      exit 1
    fi
  fi

  # Check for PORTAL_URL
  if [ -z "$PORTAL_URL" ]; then
    log "INFO: PORTAL_URL is not set, trying to use PSE_PORTAL_URL from previous step..."
    if [ -n "$PSE_PORTAL_URL" ]; then
      export PORTAL_URL="$PSE_PORTAL_URL"
      log "Using PORTAL_URL from previous step: $PORTAL_URL"
    else
      # Try to use API_URL as fallback
      export PORTAL_URL="$API_URL"
      log "Using API_URL as fallback for PORTAL_URL: $PORTAL_URL"
    fi
  fi

  # Check SCAN_ID separately with warning instead of error
  if [ -z "$SCAN_ID" ]; then
    log "INFO: SCAN_ID is not set, using a default value for cleanup..."
    # Generate a unique ID for this cleanup session
    export SCAN_ID="cleanup_$(date +%s)_${GITHUB_RUN_ID:-unknown}"
    log "Using generated SCAN_ID: $SCAN_ID"
  fi

  log "Environment validation successful"
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
  for (( i=0; i<${#string}; i++ )); do
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
    log "WARNING: SCAN_ID does not appear to be a valid UUID: $SCAN_ID"
    # Continue anyway as it might be a different format
  fi

  log "SCAN_ID validation passed: $SCAN_ID"
  return 0
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
  BASE_URL="https://pse.invisirisk.com"
  log "Using default PSE endpoint: $BASE_URL"


  # Build URL for the GitHub run
  build_url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"

  # Build parameters
  params="id=$(url_encode "$SCAN_ID")"
  params="${params}&build_url=$(url_encode "$build_url")"
  params="${params}&status=$(url_encode "${INPUT_JOB_STATUS:-unknown}")"

  log "Sending end signal to PSE with parameters: $params"

  # Send request with retries
  MAX_RETRIES=3
  RETRY_DELAY=2
  ATTEMPT=1

  while [ $ATTEMPT -le $MAX_RETRIES ]; do
    log "Sending end signal, attempt $ATTEMPT of $MAX_RETRIES"

    set +e
    # RESPONSE=$(curl -X POST "${BASE_URL}/end" \
    #   -H 'Content-Type: application/x-www-form-urlencoded' \
    #   -H 'User-Agent: pse-action' \
    #   -d "$params" \
    #   -k \
    #   --connect-timeout 5 \
    #   --retry 3 --retry-delay 2 --max-time 10 \
    #   -s -w "\n%{http_code}" 2>&1)
    RESPONSE=$(curl -X POST "https://pse.invisirisk.com/end" \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        -H 'User-Agent: pse-action' \
        -d "$params" \
        -k  \
        --connect-timeout 5 \
        --retry 3 --retry-delay 2 --max-time 10 \
        -s -w "\n%{http_code}" 2>&1)

    log "Response: $RESPONSE"

    HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
    RESPONSE_BODY=$(echo "$RESPONSE" | sed '$d')

    if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
      log "End signal sent successfully (HTTP $HTTP_CODE)"
      log "Response: $RESPONSE_BODY"
      return 0
    else
      log "Failed to send end signal (HTTP $HTTP_CODE)"
      log "Response: $RESPONSE_BODY"
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
  local container_name="$1"

  log "Displaying logs for container: $container_name"

  # Check if in test mode
  if [ "$TEST_MODE" = "true" ]; then
    log "Running in TEST_MODE, skipping container logs display"
    return 0
  fi

  # Check if container exists or existed, but this is a non critical error
  if ! sudo docker ps -a -q -f name="$container_name" > /dev/null 2>&1; then
    log "Container $container_name not found, cannot display logs"
    return 0
  fi

  # Display a separator for better readability
  echo "================================================================="
  echo "                   PSE CONTAINER LOGS                            "
  echo "================================================================="

  # Get all logs from the container
  sudo docker logs "$container_name" 2>&1 || log "Failed to retrieve container logs"

  # Display another separator
  echo "================================================================="
  echo "                END OF PSE CONTAINER LOGS                        "
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

  # Display container logs before stopping it
  display_container_logs "pse"

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

# Main execution
main() {
  log "Starting PSE GitHub Action cleanup"

  # Validate environment variables
  #validate_env_vars

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

  log "PSE GitHub Action cleanup completed successfully"
}

# Execute main function
main

EOF
}

main() {
  prepare
  binary_setup
  intercept
  cp /usr/local/share/ca-certificates/extra/pse.crt pse.crt
  create_cleanup
}

main