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

# Function to cat file content if DEBUG is true
debug_cat_file() {
    local file_to_cat="$1"
    if [ "$DEBUG" = "true" ]; then
        if [ -f "$file_to_cat" ] && [ -s "$file_to_cat" ]; then # Check if file exists and is not empty
            echo "--- Debug content of $file_to_cat start ---" >&2
            cat "$file_to_cat" >&2
            echo "--- Debug content of $file_to_cat end ---" >&2
        elif [ "$DEBUG" = "true" ]; then
            echo "Debug: File $file_to_cat not found or empty for catting." >&2
        fi
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
    local suffix="${1:-}" # Optional suffix
    local temp_file
    # Try to create in /tmp first for runners, then fallback to mktemp default
    if [[ -n "$suffix" ]]; then
        temp_file=$(mktemp "/tmp/tmp.${suffix}.XXXXXX" 2>/dev/null) || temp_file=$(mktemp "tmp.${suffix}.XXXXXX")
    else
        temp_file=$(mktemp "/tmp/tmp.XXXXXX" 2>/dev/null) || temp_file=$(mktemp "tmp.XXXXXX")
    fi

    if [ -z "$temp_file" ] || [ ! -f "$temp_file" ]; then
        echo "Error: mktemp failed to create a temporary file (suffix: '$suffix')." >&2
        return 1 # Indicate failure
    fi
    TEMP_FILES+=("$temp_file")
    debug "Created temporary file: $temp_file"
    echo "$temp_file"
}

# Function to create a temporary directory and add it to the cleanup list
create_temp_dir() {
    local temp_dir
    # Try to create in /tmp first for runners, then fallback to mktemp default
    temp_dir=$(mktemp -d "/tmp/tmpdir.XXXXXX" 2>/dev/null) || temp_dir=$(mktemp -d "tmpdir.XXXXXX")
    if [ -z "$temp_dir" ] || [ ! -d "$temp_dir" ]; then
        echo "Error: mktemp -d failed to create a temporary directory." >&2
        return 1 # Indicate failure
    fi
    TEMP_FILES+=("$temp_dir")
    debug "Created temporary directory: $temp_dir"
    echo "$temp_dir"
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
    local target_output_dir="$2"

    if [ -z "$target_output_dir" ]; then
        echo "Error: Output directory not provided to download_job_logs for job $job_id." >&2
        return 1
    fi

    # Ensure the target output directory exists
    if ! mkdir -p "$target_output_dir"; then
        echo "Error: Could not create output directory '$target_output_dir' for job $job_id." >&2
        return 1
    fi

    local output_file="${target_output_dir}/job_${job_id}_logs.txt"

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
            local curl_response_content_file
            curl_response_content_file=$(create_temp_file "curl_api_log_response.txt")
            if [ -z "$curl_response_content_file" ]; then
                echo "Error: create_temp_file failed for API log download response." >&2
                echo "Logs download failed (temp file creation error for API response)" >"$output_file"
                return 1
            fi

            local curl_download_cmd="http_status=\$(curl -s -w \"%{http_code}\" -L -o \"$curl_response_content_file\" \
                \"$redirect_url\")"

            if ! retry_with_backoff "$curl_download_cmd"; then
                echo "❌ Failed to download logs for job $job_id after multiple attempts (curl execution error or repeated non-HTTP failures)."
                debug "Last curl command executed by retry_with_backoff: $curl_download_cmd"
                debug_cat_file "$curl_response_content_file"
                echo "Logs download failed (API - retry mechanism failed)" >"$output_file"
                return 1
            fi

            # At this point, retry_with_backoff succeeded, meaning curl executed and http_status should be set.
            if [[ "$http_status" -ge 200 && "$http_status" -lt 300 ]]; then
                echo "✅ Saved logs for job $job_id (via API, HTTP $http_status)"
                if ! mv "$curl_response_content_file" "$output_file"; then
                    echo "Error: Failed to move downloaded log content from $curl_response_content_file to $output_file" >&2
                    # Attempt to copy as a fallback
                    if cp "$curl_response_content_file" "$output_file"; then
                        echo "Warning: mv failed, but cp succeeded for $output_file. Log content might be duplicated in temp." >&2
                        return 0 # Still success as logs are in place
                    else
                        echo "Logs download successful (HTTP $http_status) but failed to save to $output_file" >"$output_file"
                        return 1 # Treat as failure if we can't save the log
                    fi
                fi
                return 0
            else
                echo "❌ Failed to download logs for job $job_id (API returned HTTP $http_status)"
                debug_cat_file "$curl_response_content_file"
                echo "Logs download failed (API - HTTP $http_status)" >"$output_file"
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

# Function to send content (string or file) to SaaS platform
send_content_to_saas() {
    local content_to_send="$1" # Can be a string or a path to a file
    local remote_filename="$2"
    local saas_file_type="$3" # e.g., "text", "logs_zip" (used in API URL and to determine MIME type)

    debug "Preparing to send content '$remote_filename' (type: $saas_file_type) to custom API..."
    [[ "$DEBUG" != "true" ]] && echo "Sending content '$remote_filename' to API..." >&2

    # Validate required environment variables
    if ! validate_saas_env_vars; then
        return 1 # Do not exit, just skip sending if vars are missing
    fi

    local content_temp_file
    local is_content_path=false
    # Check if content_to_send is an existing file path
    if [ -f "$content_to_send" ]; then
        debug "Content to send is an existing file: $content_to_send"
        content_temp_file="$content_to_send"
        is_content_path=true
    else
        debug "Content to send is a string. Writing to temporary file."
        content_temp_file=$(create_temp_file "saas_upload_content")
        if [ -z "$content_temp_file" ]; then
            echo "Error: create_temp_file failed for SaaS content upload." >&2
            return 1
        fi
        echo -n "$content_to_send" >"$content_temp_file"
    fi

    if [ ! -f "$content_temp_file" ]; then
        echo "Error: Content file not found at $content_temp_file. Cannot send to SaaS platform." >&2
        # Clean up temp file if it was created for string content and something went wrong before this check
        if [ "$is_content_path" = false ] && [ -n "$content_temp_file" ] && [[ "$TEMP_FILES" == *"$content_temp_file"* ]]; then
            # This check is a bit complex; relies on TEMP_FILES for safety.
            # Simpler: just attempt rm -f if is_content_path is false.
            if [ "$is_content_path" = false ]; then rm -f "$content_temp_file"; fi
        fi
        return 1
    fi

    # Determine MIME type based on saas_file_type
    local mime_type="application/octet-stream" # Default
    if [[ "$saas_file_type" == *"zip"* ]]; then
        mime_type="application/zip"
    elif [[ "$saas_file_type" == "text"* ]]; then # handles 'text' or 'text_plain'
        mime_type="text/plain"
    fi
    debug "Using MIME type: $mime_type for saas_file_type: $saas_file_type"

    # Construct custom API URL, using saas_file_type from argument
    local custom_api_url="${API_URL}/ingestionapi/v1/upload-generic-file?api_key=${APP_TOKEN}&scan_id=${SCAN_ID}&file_type=logs"

    debug "Sending content '$remote_filename' to custom API endpoint: ${custom_api_url}"
    debug "Size of content file '$content_temp_file' to be uploaded:"
    wc -c <"$content_temp_file" >&2
    ls -l "$content_temp_file" >&2

    local response_file
    response_file=$(create_temp_file "saas_api_response")
    if [ -z "$response_file" ]; then
        echo "Error: create_temp_file failed for API response." >&2
        if [ "$is_content_path" = false ]; then rm -f "$content_temp_file"; fi # Cleanup content temp file
        return 1
    fi

    local http_status
    local curl_cmd="http_status=\$(curl -sSL -v -w \"%{http_code}\" \
      -X POST \
      -H \"accept: application/json\" \
      -H \"Content-Type: multipart/form-data\" \
      -F \"file=@${content_temp_file};filename=${remote_filename}\" \
      -o \"${response_file}\" \
      \"${custom_api_url}\")"

    if ! retry_with_backoff "$curl_cmd"; then
        echo "Failed to send content '$remote_filename' to custom API after multiple attempts" >&2
        if [ "$is_content_path" = false ]; then rm -f "$content_temp_file"; fi # Cleanup content temp file
        return 1
    fi

    # Cleanup the temporary content file if it was created for string content
    if [ "$is_content_path" = false ]; then
        rm -f "$content_temp_file"
        # Note: create_temp_file adds to TEMP_FILES, so it will be cleaned on script exit anyway,
        # but explicit removal here is good practice if the file is no longer needed immediately.
    fi

    local response_body
    response_body=$(cat "${response_file}") # response_file is already in TEMP_FILES for auto-cleanup

    debug "Custom API Response Status for '$remote_filename': $http_status"
    debug "Custom API Response Body for '$remote_filename':"
    debug "${response_body}"

    if ! check_http_status "$http_status" "Custom API call for '$remote_filename' to ${custom_api_url} failed" "$response_body"; then
        return 1
    fi

    echo "Successfully sent content '$remote_filename' (type: $saas_file_type) to custom API."
    return 0
}

run_analysis() {
    echo "Starting log fetching"

    # Call the function to load metadata from analytics_metadata.json
    load_metadata_from_file

    # Create output directory
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local log_dir="job_logs_${timestamp}"

    mkdir -p "$log_dir"
    echo "Created log directory: $log_dir"

    # Fetch all jobs for the current workflow run
    local all_jobs_data
    all_jobs_data=$(fetch_github_workflow_jobs)

    if [ -z "$all_jobs_data" ]; then
        echo "⚠️ Failed to fetch job data from GitHub API or response was empty."
        echo "No jobs to process" >"${log_dir}/no_jobs.txt"
    else
        if ! command -v jq >/dev/null 2>&1; then
            echo "Error: jq is not installed. Cannot parse job data." >&2
            echo "jq not installed" >"${log_dir}/error.txt"
            # Cannot proceed to get job ID without jq
        else
            # jq is available, try to get the first completed job ID
            local first_completed_job_id
            first_completed_job_id=$(echo "$all_jobs_data" | jq -r '(.jobs[]? | select(.status == "completed") | .id) | select(length > 0)' | head -n 1)

            if [ -z "$first_completed_job_id" ]; then
                echo "ℹ️ No completed job ID found for this workflow run (jq query returned empty or only whitespace)."
                # Optionally, create a marker file in $log_dir if needed
                # echo "No completed job ID found" >"${log_dir}/no_completed_job_id.txt"
            else
                debug "First completed job ID: $first_completed_job_id"
                echo "Attempting to download logs for job ID: $first_completed_job_id"

                # download_job_logs saves the file to "${log_dir}/job_${job_id}_logs.log"
                if download_job_logs "$first_completed_job_id" "$log_dir"; then
                    local downloaded_log_file="${log_dir}/job_${first_completed_job_id}_logs.txt"
                    if [ -f "$downloaded_log_file" ]; then
                        echo "✅ Successfully downloaded logs for job $first_completed_job_id to $downloaded_log_file"

                        local remote_log_filename="job_${first_completed_job_id}_logs.txt" # Or .log, as preferred by SaaS

                        # Send the downloaded log file. Your changes in send_content_to_saas hardcoded
                        # file_type=logs in the API URL and removed mime_type from curl call.
                        # The third argument "logs" here aligns with that expectation for saas_file_type.
                        if send_content_to_saas "$downloaded_log_file" "$remote_log_filename" "logs"; then
                            echo "✅ Successfully sent logs for job $first_completed_job_id to SaaS platform."
                        else
                            echo "⚠️ Warning: Failed to send logs for job $first_completed_job_id to SaaS platform."
                            # Consider 'return 1' for critical failures
                        fi
                    else
                        echo "❌ Error: Log file $downloaded_log_file not found after download_job_logs claimed success for job $first_completed_job_id."
                        # Consider 'return 1'
                    fi
                else
                    echo "❌ Failed to download logs for job $first_completed_job_id."
                    # Consider 'return 1'
                fi
            fi
        fi
    fi
    # All zipping logic, log downloads, and related debug/test code has been removed.

    # Cleanup temporary log directory (the zip file is kept for output)
    rm -rf "$log_dir"
    debug "Cleaned up temporary log directory: $log_dir"

}

# Execute the main analysis function
run_analysis
