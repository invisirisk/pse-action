#!/bin/bash

# Exit on error
set -e

# Optional: GitHub API version
GITHUB_API_VERSION="${GITHUB_API_VERSION:-2022-11-28}"

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

  if ! [[ "$status_code" =~ ^2[0-9]{2}$ ]]; then
    echo "Error: $error_message with status $status_code." >&2
    if [ -n "$response_body" ]; then
      echo "Response body: $response_body" >&2
    fi
    return 1
  fi

  return 0
}

# Function to validate required environment variables
validate_env_vars() {
  local missing_vars=0

  if [ -z "$PSE_API_URL" ]; then
    echo "PSE_API_URL is not set. Please set this environment variable." >&2
    missing_vars=1
  fi

  if [ -z "$PSE_APP_TOKEN" ]; then
    echo "PSE_APP_TOKEN is not set. Please set this environment variable." >&2
    missing_vars=1
  fi

  if [ -z "$PSE_SCAN_ID" ]; then
    echo "PSE_SCAN_ID is not set. Please set this environment variable." >&2
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

  # Call GitHub API with status code capture
  local http_status
  http_status=$(curl -sSL -w "%{http_code}" \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "X-GitHub-Api-Version: ${GITHUB_API_VERSION}" \
    -o "${response_file}" \
    "https://api.github.com/repos/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}/jobs")

  # Read the response body from the temp file
  local response_body
  response_body=$(cat "${response_file}")

  # Check if the GitHub API call was successful
  if ! check_http_status "$http_status" "GitHub API call failed" "$response_body"; then
    exit 1
  fi

  # Additional check if response is empty despite successful status code
  if [ -z "$response_body" ]; then
    echo "Warning: GitHub API response was empty despite successful status code. This might indicate an issue." >&2
  fi

  # Output the GitHub response
  echo "GitHub API Response:"
  echo "${response_body}"

  # Return the response body
  echo "$response_body"
}

# Function to send data to SaaS platform
send_to_saas_platform() {
  local data="$1"

  echo "Preparing to send GitHub response to custom API..." >&2

  # Validate required environment variables
  if ! validate_env_vars; then
    exit 1
  fi

  # Construct custom API URL
  local custom_api_url="${PSE_API_URL}/ingestionapi/v1/upload-generic-file?api_key=${PSE_APP_TOKEN}&scan_id=${PSE_SCAN_ID}&file_type=job_status"

  echo "Sending GitHub job status to custom API endpoint: ${custom_api_url}" >&2

  # Create a temporary file for the response body
  local response_file
  response_file=$(create_temp_file)

  # Create a temporary JSON file for the GitHub response
  local json_file
  json_file=$(create_temp_file ".json")
  echo "${data}" >"${json_file}"

  # Perform the POST request to the custom API using multipart/form-data
  # Capture http_status and write response body to the temp file
  local http_status
  http_status=$(
    curl -sSL -w "%{http_code}" \
      -X POST \
      -H "accept: application/json" \
      -H "Content-Type: multipart/form-data" \
      -F "file=@${json_file};type=application/json" \
      -o "${response_file}" \
      "${custom_api_url}"
  )

  # Read the body from the temp file
  local response_body
  response_body=$(cat "${response_file}")

  echo "Custom API Response Status: $http_status"
  echo "Custom API Response Body:"
  echo "${response_body}"

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
