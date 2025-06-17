#!/bin/bash
set -euo pipefail

# Optional: GitHub API version
GITHUB_API_VERSION="${GITHUB_API_VERSION:-2022-11-28}"

# Debug mode flag (default to false if not set)
DEBUG="${DEBUG:-false}"

# Global variables for temporary files
TEMP_FILES=()

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
            debug "Loaded SCAN_ID=$SCAN_ID"
        else
            # Fallback to grep if jq is not available
            SCAN_ID=$(grep -o '"scan_id"[[:space:]]*:[[:space:]]*"[^"]*"' analytics_metadata.json | sed 's/.*"scan_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
            debug "Loaded SCAN_ID=$SCAN_ID"
        fi
    fi
}

# Function to clean up temporary files
cleanup() {
    for file in "${TEMP_FILES[@]}"; do
        if [ -f "$file" ]; then
            rm -f "$file"
            debug "Cleaned up temporary file: $file"
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
        # Using 'eval' with care: ensure $cmd is controlled and not user-supplied arbitrary input.
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

# Function to validate required environment variables for SaaS platform
validate_saas_env_vars() {
    local missing_vars=0

    if [ -z "${API_URL:-}" ]; then
        echo "API_URL is not set. Please set this environment variable for SaaS integration." >&2
        missing_vars=1
    fi

    if [ -z "${APP_TOKEN:-}" ]; then
        echo "APP_TOKEN is not set. Please set this environment variable for SaaS integration." >&2
        missing_vars=1
    fi

    if [ -z "${SCAN_ID:-}" ]; then
        echo "SCAN_ID is not set. Please set this environment variable for SaaS integration or ensure analytics_metadata.json is present." >&2
        missing_vars=1
    fi

    return $missing_vars
}

# Function to fetch all jobs for the current GitHub workflow run
fetch_github_workflow_jobs() {
    debug "Fetching GitHub workflow job statuses..."

    # Create a temporary file for the response body
    local response_file
    response_file=$(create_temp_file "api_response_jobs.json")

    local response_body
    local http_status
    debug "Sleeping for 2 seconds before fetching GitHub job statuses..."
    sleep 2

    local curl_cmd="http_status=\$(curl -sSL -w \"%{http_code}\" \
    -H \"Accept: application/vnd.github+json\" \
    -H \"Authorization: Bearer ${GITHUB_TOKEN}\" \
    -H \"X-GitHub-Api-Version: ${GITHUB_API_VERSION:-2022-11-28}\" \
    -o \"${response_file}\" \
    \"https://api.github.com/repos/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}/jobs\")"

    if ! retry_with_backoff "$curl_cmd"; then
        echo "Error: Failed to fetch GitHub job statuses after multiple attempts" >&2
        echo ""
        return 1
    fi

    response_body=$(cat "${response_file}")

    if ! check_http_status "$http_status" "GitHub API call for jobs failed" "$response_body"; then
        echo ""
        return 1
    fi

    if [ -z "$response_body" ]; then
        debug "Warning: GitHub API response for jobs was empty despite successful status code."
    fi

    debug "GitHub API Response (Jobs):"
    debug "${response_body}"

    echo "$response_body"
    return 0
}

# Function to download job logs
download_job_logs() {
    local job_id="$1"
    local output_file="${log_dir}/${job_id}.log"

    echo "Downloading logs for job: $job_id"

    # Use the GitHub CLI to download logs
    if command -v gh >/dev/null 2>&1; then
        if gh run view --repo "$GITHUB_REPOSITORY" --job "$job_id" --log >"$output_file"; then
            echo "✅ Saved logs for job $job_id"
            return 0
        else
            echo "⚠️ GitHub CLI failed, trying API method"
            # Fallback to API method if CLI fails
            local api_url="${GITHUB_API_URL}/repos/${GITHUB_REPOSITORY}/actions/jobs/${job_id}/logs"

            local redirect_url_file
            redirect_url_file=$(create_temp_file)

            # Get the redirect URL with retry logic
            local curl_redirect_cmd="curl -sI \
                -H \"Authorization: Bearer $GITHUB_TOKEN\" \
                -H \"Accept: application/vnd.github.v3+json\" \
                \"$api_url\" > \"$redirect_url_file\""

            if ! retry_with_backoff "$curl_redirect_cmd"; then
                echo "❌ Failed to get redirect URL for job $job_id after multiple attempts"
                echo "Logs unavailable for job $job_id (redirect URL failed)" >"$output_file"
                return 1
            fi

            redirect_url=$(grep -i '^location:' "$redirect_url_file" | awk '{print $2}' | tr -d '\r')

            if [ -z "$redirect_url" ]; then
                echo "❌ Failed to get redirect URL for job $job_id"
                echo "Logs unavailable for job $job_id" >"$output_file"
                return 1
            fi

            # Download the actual logs with retry logic
            local http_status
            local curl_download_cmd="http_status=\$(curl -s -w \"%{http_code}\" -L -o \"$output_file\" \
                -H \"Authorization: Bearer $GITHUB_TOKEN\" \
                \"$redirect_url\")"

            if ! retry_with_backoff "$curl_download_cmd"; then
                echo "❌ Failed to download logs for job $job_id after multiple attempts"
                echo "Logs download failed (API - retry failed)" >"$output_file"
                return 1
            fi

            if [[ "$http_status" -ge 200 && "$http_status" -lt 300 ]]; then
                echo "✅ Saved logs for job $job_id (via API)"
                return 0
            else
                echo "❌ Failed to download logs for job $job_id (HTTP $http_status)"
                echo "Logs download failed (HTTP $http_status)" >"$output_file"
                return 1
            fi
        fi
    else
        echo "Warning: GitHub CLI (gh) not found. Falling back to API method for job logs."
        local api_url="${GITHUB_API_URL}/repos/${GITHUB_REPOSITORY}/actions/jobs/${job_id}/logs"

        local redirect_url_file
        redirect_url_file=$(create_temp_file)

        # Get the redirect URL with retry logic
        local curl_redirect_cmd="curl -sI \
            -H \"Authorization: Bearer $GITHUB_TOKEN\" \
            -H \"Accept: application/vnd.github.v3+json\" \
            \"$api_url\" > \"$redirect_url_file\""

        if ! retry_with_backoff "$curl_redirect_cmd"; then
            echo "❌ Failed to get redirect URL for job $job_id after multiple attempts"
            echo "Logs unavailable for job $job_id (redirect URL failed)" >"$output_file"
            return 1
        fi

        redirect_url=$(grep -i '^location:' "$redirect_url_file" | awk '{print $2}' | tr -d '\r')

        if [ -z "$redirect_url" ]; then
            echo "❌ Failed to get redirect URL for job $job_id"
            echo "Logs unavailable for job $job_id" >"$output_file"
            return 1
        fi

        # Download the actual logs with retry logic
        local http_status
        local curl_download_cmd="http_status=\$(curl -s -w \"%{http_code}\" -L -o \"$output_file\" \
            -H \"Authorization: Bearer $GITHUB_TOKEN\" \
            \"$redirect_url\")"

        if ! retry_with_backoff "$curl_download_cmd"; then
            echo "❌ Failed to download logs for job $job_id after multiple attempts"
            echo "Logs download failed (API - retry failed)" >"$output_file"
            return 1
        fi

        if [[ "$http_status" -ge 200 && "$http_status" -lt 300 ]]; then
            echo "✅ Saved logs for job $job_id (via API)"
            return 0
        else
            echo "❌ Failed to download logs for job $job_id (HTTP $http_status)"
            echo "Logs download failed (HTTP $http_status)" >"$output_file"
            return 1
        fi
    fi
}

# Function to send the zip file to SaaS platform
send_zip_to_saas_platform() {
    local zip_file_path="$1"

    debug "Preparing to send log archive to custom API..."
    [[ "$DEBUG" != "true" ]] && echo "Sending log archive to API..." >&2

    # Validate required environment variables
    if ! validate_saas_env_vars; then
        return 1 # Do not exit, just skip sending if vars are missing
    fi

    if [ ! -f "$zip_file_path" ]; then
        echo "Error: Zip file not found at $zip_file_path. Cannot send to SaaS platform." >&2
        return 1
    fi

    # Construct custom API URL
    local custom_api_url="${API_URL}/ingestionapi/v1/upload-generic-file?api_key=${APP_TOKEN}&scan_id=${SCAN_ID}&file_type=logs"

    debug "Sending log archive to custom API endpoint: ${custom_api_url}"

    # Create a temporary file for the response body
    local response_file
    response_file=$(create_temp_file)

    # Perform the POST request to the custom API using multipart/form-data with retry logic
    local http_status
    local curl_cmd="http_status=\$(curl -sSL -w \"%{http_code}\" \
      -X POST \
      -H \"accept: application/json\" \
      -H \"Content-Type: multipart/form-data\" \
      -F \"file=@${zip_file_path};filename=$(basename "$zip_file_path");type=application/zip\" \
      -o \"${response_file}\" \
      \"${custom_api_url}\")"

    # Execute the curl command with retry logic
    if ! retry_with_backoff "$curl_cmd"; then
        echo "Failed to send log archive to custom API after multiple attempts" >&2
        return 1
    fi

    # Read the body from the temp file
    local response_body
    response_body=$(cat "${response_file}")

    debug "Custom API Response Status: $http_status"
    debug "Custom API Response Body:"
    debug "${response_body}"

    # Check if the custom API call was successful
    if ! check_http_status "$http_status" "Custom API call to ${custom_api_url} failed" "$response_body"; then
        return 1
    fi

    echo "Successfully sent log archive to custom API."
    return 0
}

run_analysis() {
    echo "Starting log fetching"

    # Call the function to load metadata from analytics_metadata.json
    load_metadata_from_file

    # Create output directory
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local log_dir="job_logs_${timestamp}"
    local zip_file="all_logs_${timestamp}.zip"

    mkdir -p "$log_dir"
    echo "Created log directory: $log_dir"

    # Fetch all jobs for the current workflow run
    local all_jobs_data
    all_jobs_data=$(fetch_github_workflow_jobs)

    if [ -z "$all_jobs_data" ]; then
        echo "⚠️ Failed to fetch job data from GitHub API or response was empty."
        echo "No jobs to process" >"${log_dir}/no_jobs.txt"
    else
        # Extract unique IDs of completed jobs
        local completed_job_ids
        if ! command -v jq >/dev/null 2>&1; then
            echo "Error: jq is not installed. Cannot parse job data." >&2
            echo "jq not installed" >"${log_dir}/error.txt"
            completed_job_ids=""
        else
            completed_job_ids=$(echo "$all_jobs_data" | jq -r '.jobs[]? | select(.status == "completed") | .id' | sort -u)
        fi

        if [ -z "$completed_job_ids" ]; then
            echo "ℹ️ No completed jobs found for this workflow run or failed to parse."
            echo "No completed jobs found" >"${log_dir}/no_completed_jobs.txt"
        else
            debug "Processing completed job IDs: $completed_job_ids"
            local processed_job_count=0
            local job_id_array
            read -ra job_id_array <<<"$completed_job_ids"

            for job_id in "${job_id_array[@]}"; do
                job_id_trimmed=$(echo "$job_id" | xargs)
                if [[ -n "$job_id_trimmed" ]]; then
                    download_job_logs "$job_id_trimmed" || true
                    processed_job_count=$((processed_job_count + 1))
                fi
            done

            if [[ $processed_job_count -eq 0 ]]; then
                echo "⚠️ No valid job IDs were processed from the fetched completed jobs list."
                echo "No valid jobs processed" >"${log_dir}/no_valid_jobs.txt"
            fi
        fi
    fi

    # Create zip archive
    if ! zip -r "$zip_file" "$log_dir"; then
        echo "❌ Failed to create log archive: $zip_file" >&2
        exit 1
    fi
    echo "📦 Created log archive: $zip_file"

    # Send the zip file to SaaS platform
    send_zip_to_saas_platform "$zip_file" || echo "Warning: Failed to send log archive to SaaS platform."

    # Cleanup temporary log directory (the zip file is kept for output)
    rm -rf "$log_dir"
    debug "Cleaned up temporary log directory: $log_dir"

    # Set output for the zip file path
    echo "log_archive=$zip_file" >>$GITHUB_OUTPUT
    echo "::notice title=Log Analysis Complete::Log archive created at $zip_file"
    echo "📂 Absolute path: $(pwd)/$zip_file"
}

# Execute the main analysis function
run_analysis
