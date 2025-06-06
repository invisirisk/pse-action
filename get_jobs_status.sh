#!/bin/bash

# Exit on error
set -e

# Optional: GitHub API version
GITHUB_API_VERSION="${GITHUB_API_VERSION:-2022-11-28}"

# Call GitHub API
# Call GitHub API and capture response
echo "Fetching GitHub job statuses..." >&2
github_response=$(curl -sSL \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  -H "X-GitHub-Api-Version: ${GITHUB_API_VERSION}" \
  "https://api.github.com/repos/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}/jobs")

# Basic check if fetching GitHub response failed or returned empty
# Note: curl -sSL without --fail won't exit non-zero on HTTP errors (e.g., 401, 404).
# The response body might contain JSON error details from GitHub.
if [ -z "$github_response" ]; then
  echo "Warning: GitHub API response was empty. This might indicate an issue." >&2
fi

# Output the GitHub response (maintaining a similar behavior to the original script's implicit output)
echo "GitHub API Response:"
echo "${github_response}"

# --- Send to Custom API ---
echo "Preparing to send GitHub response to custom API..." >&2

# Validate required environment variables
if [ -z "$PSE_API_URL" ]; then
  echo "Error: PSE_API_URL is not set. Please set this environment variable..." >&2
  exit 1
fi

if [ -z "$PSE_APP_TOKEN" ]; then
  echo "Error: PSE_APP_TOKEN is not set. Please set this environment variable." >&2
  exit 1
fi

if [ -z "$PSE_SCAN_ID" ]; then
  echo "Error: PSE_SCAN_ID is not set. Please set this environment variable." >&2
  exit 1
fi

# Construct custom API URL
custom_api_url="${PSE_API_URL}/ingestionapi/v1/update-job-status?api_key=${PSE_APP_TOKEN}&scan_id=${PSE_SCAN_ID}"

echo "Sending GitHub job status to custom API endpoint: ${custom_api_url}" >&2

# Prepare for temporary file usage and ensure cleanup
response_body_file=""                                         # Initialize variable
trap 'rm -f "$response_body_file"' EXIT SIGHUP SIGINT SIGTERM # Setup cleanup for temp file

response_body_file=$(mktemp)
# Check if mktemp failed (it usually exits non-zero, and set -e would catch it)
if [ -z "$response_body_file" ] || ! [ -f "$response_body_file" ]; then
  echo "Error: Failed to create temporary file for API response." >&2
  exit 1
fi

# Perform the POST request to the custom API
# Capture http_status and write response body to the temp file
http_status_custom_api=$(
  curl -sSL -w "%{http_code}" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "${github_response}" \
    -o "${response_body_file}" \
    "${custom_api_url}"
)

# Read the body from the temp file
response_body_custom_api=$(cat "${response_body_file}")
# Temp file will be cleaned up by the trap on EXIT

echo "Custom API Response Status: $http_status_custom_api"
echo "Custom API Response Body:"
echo "${response_body_custom_api}"

# Check if the custom API call was successful
if ! [[ "$http_status_custom_api" =~ ^2[0-9]{2}$ ]]; then
  echo "Error: Custom API call to ${custom_api_url} failed with status $http_status_custom_api." >&2
  exit 1
fi

echo "Successfully sent job status to custom API."
