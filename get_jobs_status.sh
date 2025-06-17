#!/bin/bash

# Exit on error
set -e

# Optional: GitHub API version
GITHUB_API_VERSION="${GITHUB_API_VERSION:-2022-11-28}"

# Debug mode flag (default to false if not set)
DEBUG="${DEBUG:-false}"

# Function to print debug messages only when DEBUG is true
debug() {
  if [[ "$DEBUG" == "true" ]]; then
    echo "[DEBUG] $*" >&2
  fi
}

# Function to load metadata from analytics_metadata.json file
load_metadata_from_file() {
  if [ -f "analytics_metadata.json" ]; then
    debug "Loading scan ID and run ID from analytics_metadata.json"
    if command -v jq >/dev/null 2>&1; then
      SCAN_ID=$(jq -r '.scan_id // empty' analytics_metadata.json)
      GITHUB_RUN_ID=$(jq -r '.run_id // empty' analytics_metadata.json)
      debug "Loaded SCAN_ID=$SCAN_ID and GITHUB_RUN_ID=$GITHUB_RUN_ID"
    else
      # Fallback to grep if jq is not available
      SCAN_ID=$(grep -o '"scan_id"[[:space:]]*:[[:space:]]*"[^"]*"' analytics_metadata.json | sed 's/.*"scan_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
      GITHUB_RUN_ID=$(grep -o '"run_id"[[:space:]]*:[[:space:]]*"[^"]*"' analytics_metadata.json | sed 's/.*"run_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
      debug "Loaded SCAN_ID=$SCAN_ID and GITHUB_RUN_ID=$GITHUB_RUN_ID (using grep)"
    fi
  fi
}

# Call the function to load metadata from analytics_metadata.json
load_metadata_from_file

# Global variables for temporary files
TEMP_FILES=()

# Function to clean up temporary files
cleanup() {
  for file in "${TEMP_FILES[@]}"; do
    if [ -f "$file" ]; then
      rm -f "$file"
    fi
  done
}

# Set up trap to clean up temporary files on exit
trap cleanup EXIT SIGHUP SIGINT SIGTERM

# Function to create a temporary file and add it to the cleanup list
create_temp_file() {
  local suffix="$1"
  local temp_file

  if [ -n "$suffix" ]; then
    temp_file=$(mktemp --suffix="$suffix")
  else
    temp_file=$(mktemp)
  fi

  if [ -z "$temp_file" ] || ! [ -f "$temp_file" ]; then
    echo "Error: Failed to create temporary file." >&2
    exit 1
  fi

  TEMP_FILES+=("$temp_file")
  echo "$temp_file"
}

# Function to check HTTP status code
check_http_status() {
  local status_code="$1"
  local error_message="$2"
  local response_body="$3"

  # Check if status code is in 2xx range
  if [[ "$status_code" =~ ^2[0-9][0-9]$ ]]; then
    return 0
  else
    echo "Error: $error_message" >&2
    echo "Status code: $status_code" >&2
    debug "Response body: $response_body"
    return 1
  fi
}

# Function to implement exponential backoff retry logic
retry_with_backoff() {
  local max_attempts=3
  local timeout=1
  local attempt=1
  local exit_code=0
  local cmd="$@"

  while [[ $attempt -le $max_attempts ]]; do
    debug "Attempt $attempt of $max_attempts: $cmd"
    [[ $attempt -gt 1 && "$DEBUG" != "true" ]] && echo "Retrying..." >&2

    # Execute the command
    eval "$cmd"
    exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
      break
    fi

    # Calculate sleep time with exponential backoff (1s, 2s, 4s)
    timeout=$((timeout * 2))

    debug "Command failed with exit code $exit_code. Retrying in ${timeout}s..."
    sleep $timeout

    attempt=$((attempt + 1))
  done

  if [[ $exit_code -ne 0 ]]; then
    echo "All $max_attempts attempts failed" >&2
    debug "Failed command: $cmd"
  fi

  return $exit_code
}

# Function to validate required environment variables
validate_env_vars() {
  local missing_vars=0

  if [ -z "$API_URL" ]; then
    echo "API_URL is not set. Please set this environment variable." >&2
    missing_vars=1
  fi

  if [ -z "$APP_TOKEN" ]; then
    echo "APP_TOKEN is not set. Please set this environment variable." >&2
    missing_vars=1
  fi

  if [ -z "$SCAN_ID" ]; then
    echo "SCAN_ID is not set. Please set this environment variable." >&2
    missing_vars=1
  fi

  return $missing_vars
}

# Function to fetch GitHub Actions job status
fetch_github_jobs() {
  echo "Fetching GitHub job statuses..." >&2

  # Create a temporary file for the response body
  local response_file
  response_file=$(create_temp_file)

  # Variable to store the response body and http status
  local response_body
  local http_status
  debug "Sleeping for 5 seconds before fetching GitHub job statuses..."
  sleep 5
  # Command to execute with retry logic
  local curl_cmd="http_status=\$(curl -sSL -w \"%{http_code}\" \
    -H \"Accept: application/vnd.github+json\" \
    -H \"Authorization: Bearer $GITHUB_TOKEN\" \
    -H \"X-GitHub-Api-Version: ${GITHUB_API_VERSION}\" \
    -o \"${response_file}\" \
    \"https://api.github.com/repos/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}/jobs\")"

  # Execute the curl command with retry logic
  if ! retry_with_backoff "$curl_cmd"; then
    echo "Failed to fetch GitHub job statuses after multiple attempts" >&2
    exit 1
  fi

  # Read the response body from the temp file
  response_body=$(cat "${response_file}")

  # Check if the GitHub API call was successful
  if ! check_http_status "$http_status" "GitHub API call failed" "$response_body"; then
    exit 1
  fi

  # Additional check if response is empty despite successful status code
  if [ -z "$response_body" ]; then
    echo "Warning: GitHub API response was empty despite successful status code. This might indicate an issue." >&2
  fi

  # Output the GitHub response only if DEBUG is true
  debug "GitHub API Response:"
  debug "${response_body}"

  # Return the response body
  echo "$response_body"
}

# Function to send data to SaaS platform
send_to_saas_platform() {
  local data="$1"

  debug "Preparing to send GitHub response to custom API..."
  [[ "$DEBUG" != "true" ]] && echo "Sending data to API..." >&2

  # Validate required environment variables
  if ! validate_env_vars; then
    exit 1
  fi

  # Construct custom API URL
  local custom_api_url="${API_URL}/ingestionapi/v1/upload-generic-file?api_key=${APP_TOKEN}&scan_id=${SCAN_ID}&file_type=job_status"

  debug "Sending GitHub job status to custom API endpoint: ${custom_api_url}"

  # Create a temporary file for the response body
  local response_file
  response_file=$(create_temp_file)

  # Create a temporary JSON file for the GitHub response
  local json_file
  json_file=$(create_temp_file ".json")
  echo "${data}" >"${json_file}"

  # Debug: Print the content of the JSON file only if DEBUG is true
  debug "JSON content before validation:"
  if [[ "$DEBUG" == "true" ]]; then
    cat "${json_file}" >&2
    echo "" >&2
  fi

  # Validate JSON format before sending
  if ! jq empty "${json_file}" 2>/dev/null; then
    echo "Error: Invalid JSON format in the data to be sent." >&2
    exit 1
  fi

  # Perform the POST request to the custom API using multipart/form-data with retry logic
  # Capture http_status and write response body to the temp file
  local http_status
  local curl_cmd="http_status=\$(curl -sSL -w \"%{http_code}\" \
      -X POST \
      -H \"accept: application/json\" \
      -H \"Content-Type: multipart/form-data\" \
      -F \"file=@${json_file};filename=job_status.json;type=application/json\" \
      -o \"${response_file}\" \
      \"${custom_api_url}\")"

  # Execute the curl command with retry logic
  if ! retry_with_backoff "$curl_cmd"; then
    echo "Failed to send data to custom API after multiple attempts" >&2
    exit 1
  fi

  # Read the body from the temp file
  local response_body
  response_body=$(cat "${response_file}")

  debug "Custom API Response Status: $http_status"
  debug "Custom API Response Body:"
  debug "${response_body}"

  # Check if the custom API call was successful
  if ! check_http_status "$http_status" "Custom API call to ${custom_api_url} failed" "$response_body"; then
    exit 1
  fi

  echo "Successfully sent job status to custom API."
}

# Main function to orchestrate the workflow
main() {
  # Step 1: Fetch GitHub Actions job status
  local github_data
  github_data=$(fetch_github_jobs)

  # Step 2: Send data to SaaS platform
  send_to_saas_platform "$github_data"
}

# Execute the main function
main
