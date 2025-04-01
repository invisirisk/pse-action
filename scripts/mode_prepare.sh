#!/bin/bash
# PSE GitHub Action - Prepare Script
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
validate_env_vars() {
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

# Function to parse nested JSON
parse_nested_json() {
  local json="$1"
  local path="$2"
  
  # Split the path into components
  IFS='.' read -ra PARTS <<< "$path"
  
  # Check if jq is available
  if command -v jq >/dev/null 2>&1; then
    # Use jq for more reliable JSON parsing
    value=$(echo "$json" | jq -r "$path" 2>/dev/null)
    if [ "$value" != "null" ] && [ -n "$value" ]; then
      echo "$value"
      return 0
    fi
  fi
  
  # Fallback to recursive grep-based parsing
  local current_json="$json"
  for part in "${PARTS[@]}"; do
    current_json=$(echo "$current_json" | grep -o "\"$part\":{[^}]*}" | sed -E 's/"'"$part"'"://')
  done
  
  echo "$current_json"
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

  log "API response: $RESPONSE"
  
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
  RESPONSE=$(curl -L -v -X POST "$API_ENDPOINT" \
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
  log "Setting outputs for GitHub Actions"
  
  # Use newer GitHub Actions output syntax (via GITHUB_OUTPUT environment file)
  echo "ecr_username=$ECR_USERNAME" >> "$GITHUB_OUTPUT"
  echo "ecr_token=$ECR_TOKEN" >> "$GITHUB_OUTPUT"
  echo "ecr_region=$ECR_REGION" >> "$GITHUB_OUTPUT"
  echo "ecr_registry_id=$ECR_REGISTRY_ID" >> "$GITHUB_OUTPUT"
  echo "scan_id=$SCAN_ID" >> "$GITHUB_OUTPUT"
  
  # Also set outputs using the older syntax for backward compatibility
  echo "::set-output name=ecr_username::$ECR_USERNAME"
  echo "::set-output name=ecr_token::$ECR_TOKEN"
  echo "::set-output name=ecr_region::$ECR_REGION"
  echo "::set-output name=ecr_registry_id::$ECR_REGISTRY_ID"
  echo "::set-output name=scan_id::$SCAN_ID"
  
  # Save to GitHub environment variables for use in subsequent jobs
  echo "ECR_USERNAME=$ECR_USERNAME" >> $GITHUB_ENV
  echo "ECR_TOKEN=$ECR_TOKEN" >> $GITHUB_ENV
  echo "ECR_REGION=$ECR_REGION" >> $GITHUB_ENV
  echo "ECR_REGISTRY_ID=$ECR_REGISTRY_ID" >> $GITHUB_ENV
  echo "SCAN_ID=$SCAN_ID" >> $GITHUB_ENV
  
  # Save API values to environment for later use
  echo "PSE_API_URL=$API_URL" >> $GITHUB_ENV
  echo "PSE_APP_TOKEN=$APP_TOKEN" >> $GITHUB_ENV
  echo "PSE_PORTAL_URL=$PORTAL_URL" >> $GITHUB_ENV
  
  # Log the outputs for debugging (with some redaction for sensitive values)
  log "Output values set:"
  log "ecr_username: ${ECR_USERNAME:0:3}***"
  log "ecr_token: ***"
  log "ecr_region: $ECR_REGION"
  log "ecr_registry_id: $ECR_REGISTRY_ID"
  log "scan_id: $SCAN_ID"
  
  # Debug: Print the contents of GITHUB_OUTPUT file
  log "Contents of GITHUB_OUTPUT file:"
  if [ -f "$GITHUB_OUTPUT" ]; then
    log "$(cat $GITHUB_OUTPUT)"
  else
    log "GITHUB_OUTPUT file does not exist or is not accessible"
  fi
}

# Main function
main() {
  log "Starting PSE GitHub Action prepare mode"
  
  validate_env_vars
  get_ecr_credentials
  prepare_scan_id
  set_outputs
  
  log "Prepare mode completed successfully"
}

# Execute main function
main
