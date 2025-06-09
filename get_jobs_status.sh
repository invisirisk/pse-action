#!/bin/bash

# Exit on error
set -e

# Optional: GitHub API version
GITHUB_API_VERSION="${GITHUB_API_VERSION:-2022-11-28}"

# Call GitHub API and capture both status code and response
echo "Fetching GitHub job statuses..." >&2

# Create a temporary file for the response body
github_response_file=$(mktemp)
if [ -z "$github_response_file" ] || ! [ -f "$github_response_file" ]; then
  echo "Error: Failed to create temporary file for GitHub API response." >&2
  exit 1
fi

# Add the temp file to our cleanup trap
trap 'rm -f "$github_response_file"' EXIT SIGHUP SIGINT SIGTERM

# Call GitHub API with status code capture
http_status_github=$(curl -sSL -w "%{http_code}" \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  -H "X-GitHub-Api-Version: ${GITHUB_API_VERSION}" \
  -o "${github_response_file}" \
  "https://api.github.com/repos/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}/jobs")

# Read the response body from the temp file
github_response=$(cat "${github_response_file}")

# Check if the GitHub API call was successful
if ! [[ "$http_status_github" =~ ^2[0-9]{2}$ ]]; then
  echo "Error: GitHub API call failed with status $http_status_github." >&2
  echo "Response body: $github_response" >&2
  exit 1
fi

# Additional check if response is empty despite successful status code
if [ -z "$github_response" ]; then
  echo "Warning: GitHub API response was empty despite successful status code. This might indicate an issue." >&2
fi

# Output the GitHub response (maintaining a similar behavior to the original script's implicit output)
echo "GitHub API Response:"
echo "${github_response}"

# --- Send to Custom API ---
echo "Preparing to send GitHub response to custom API..." >&2

# Validate required environment variables
if [ -z "$PSE_API_URL" ]; then
  echo "PSE_API_URL is not set. Please set this environment variable..." >&2
  exit 1
fi

if [ -z "$PSE_APP_TOKEN" ]; then
  echo "PSE_APP_TOKEN is not set. Please set this environment variable." >&2
  exit 1
fi

if [ -z "$PSE_SCAN_ID" ]; then
  echo "PSE_SCAN_ID is not set. Please set this environment variable." >&2
  exit 1
fi

# Construct custom API URL
custom_api_url="${PSE_API_URL}/ingestionapi/v1/upload-generic-file?api_key=${PSE_APP_TOKEN}&scan_id=${PSE_SCAN_ID}&file_type=job_status"

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

# Create a temporary JSON file for the GitHub response
json_file=$(mktemp --suffix=.json)
echo "${github_response}" >"${json_file}"
trap 'rm -f "$response_body_file" "$json_file"' EXIT SIGHUP SIGINT SIGTERM

# Perform the POST request to the custom API using multipart/form-data
# Capture http_status and write response body to the temp file
http_status_custom_api=$(
  curl -sSL -w "%{http_code}" \
    -X POST \
    -H "accept: application/json" \
    -H "Content-Type: multipart/form-data" \
    -F "file=@${json_file};type=application/json" \
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
