#!/bin/bash
# PSE GitHub Action - Intercept Script
# This script configures iptables and certificates for HTTPS interception

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
validate_environment() {
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

# Function to set up iptables rules
setup_iptables() {
  log "Setting up iptables rules"
  
  # Check if in test mode
  if [ "$TEST_MODE" = "true" ]; then
    log "Running in TEST_MODE, skipping iptables setup"
    return 0
  fi
  
  # Configure iptables rules
  local proxy_port=12345
  
  # By this point, PROXY_IP should be set either directly or via discover_pse_proxy_ip
  # in the validate_environment function
  if [ -z "$PROXY_IP" ]; then
    log "ERROR: PROXY_IP is not set. This should not happen as validation should have caught this."
    log "Here are the available environment variables that might help debug:"
    env | grep -E 'PROXY|PSE|GITHUB_' || true
    exit 1
  fi
  
  log "Using proxy IP for iptables: $PROXY_IP"
  
  # Check if iptables is available
  if ! command -v iptables >/dev/null 2>&1; then
    log "iptables not found, installing..."
    
    # Install iptables based on the available package manager
    if command -v apt-get >/dev/null 2>&1; then
      run_with_privilege apt-get update
      run_with_privilege apt-get install -y iptables
    elif command -v yum >/dev/null 2>&1; then
      run_with_privilege yum install -y iptables
    else
      log "ERROR: Unsupported package manager. Please install iptables manually."
      exit 1
    fi
  fi
  
  # Add iptables rules
  run_with_privilege iptables -t nat -N pse
  run_with_privilege iptables -t nat -A OUTPUT -j pse
  run_with_privilege iptables -t nat -A pse -p tcp --dport 443 -j REDIRECT --to-ports "$proxy_port"
  #run_with_privilege iptables -t nat -A POSTROUTING -j MASQUERADE
  
  log "iptables rules set up successfully"
}



# Function to set up HTTP proxy environment variables
setup_http_proxy() {
  log "Setting up HTTP proxy environment variables"
  
  export http_proxy=http://127.0.0.1:3128
  export HTTP_PROXY=http://127.0.0.1:3128
  export https_proxy=http://127.0.0.1:3128
  export HTTPS_PROXY=http://127.0.0.1:3128
  export no_proxy="app.invisirisk.com,localhost,127.0.0.1"
  export NO_PROXY="app.invisirisk.com,localhost,127.0.0.1"
  
  # Add to GitHub environment variables for subsequent steps
  echo "http_proxy=http://127.0.0.1:3128" >> $GITHUB_ENV
  echo "HTTP_PROXY=http://127.0.0.1:3128" >> $GITHUB_ENV
  echo "https_proxy=http://127.0.0.1:3128" >> $GITHUB_ENV
  echo "HTTPS_PROXY=http://127.0.0.1:3128" >> $GITHUB_ENV
  echo "no_proxy=app.invisirisk.com,localhost,127.0.0.1" >> $GITHUB_ENV
  echo "NO_PROXY=app.invisirisk.com,localhost,127.0.0.1" >> $GITHUB_ENV
  
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
    if curl -L -k -s -o /tmp/pse.crt https://pse.invisirisk.com/ca; then
      # Copy to the proper location for Ubuntu/Debian
      run_with_privilege cp /tmp/pse.crt /usr/local/share/ca-certificates/extra/pse.crt
      log "CA certificate successfully retrieved and copied to /usr/local/share/ca-certificates/extra/"
      break
    else
      log "Failed to retrieve CA certificate, retrying in $RETRY_DELAY seconds..."
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
  echo "NODE_EXTRA_CA_CERTS=$CA_CERT_PATH" >> $GITHUB_ENV
  echo "REQUESTS_CA_BUNDLE=$CA_CERT_PATH" >> $GITHUB_ENV
  

  # Add handling for docker
  if command -v docker >/dev/null 2>&1; then
    echo "Docker is installed, configuring..."
    run_with_privilege mkdir -p /etc/docker/certs.d
    run_with_privilege cp "$CA_CERT_PATH" /etc/docker/certs.d/pse.crt

    export DOCKER_CERT_PATH=/etc/docker/certs.d/pse.crt
    
    # Add to GITHUB_ENV to persist this variable
    echo "DOCKER_CERT_PATH=/etc/docker/certs.d/pse.crt" >> $GITHUB_ENV

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
}

# Main function
main() {
  log "Starting PSE GitHub Action intercept mode"
  
  validate_environment
  #setup_iptables
  setup_http_proxy
  setup_certificates
  start_capture
  
  log "Intercept mode completed successfully"
  log "HTTPS traffic is now being intercepted by the PSE proxy"
}

# Execute main function
main
