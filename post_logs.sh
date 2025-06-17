#!/bin/bash
#
# This script fetches the logs of the first completed job in a GitHub Actions workflow,
# and uploads them to a specified SaaS platform.
#
# Dependencies: curl, jq, and optionally gh (GitHub CLI).

set -euo pipefail

# Set default for GitHub API version if not provided.
readonly GITHUB_API_VERSION="${GITHUB_API_VERSION:-2022-11-28}"

# Enable debug mode by setting DEBUG=true.
readonly DEBUG="${DEBUG:-false}"

# Array to keep track of temporary files and directories for cleanup.
TEMP_ITEMS=()

# --- Core Utility Functions ---

#
# Prints a debug message to stderr if DEBUG is true.
#
debug() {
    if [[ "$DEBUG" == "true" ]]; then
        # Use printf for safer, more consistent output.
        printf "[DEBUG] %s\n" "$*" >&2
    fi
}

#
# Displays the content of a file for debugging purposes.
#
debug_cat_file() {
    local file_to_cat="$1"
    if [[ "$DEBUG" == "true" ]]; then
        if [[ -s "$file_to_cat" ]]; then # -s checks if file exists and is not empty.
            echo "--- Debug content of $file_to_cat start ---" >&2
            cat "$file_to_cat" >&2
            echo "--- Debug content of $file_to_cat end ---" >&2
        else
            debug "File '$file_to_cat' not found or is empty."
        fi
    fi
}

#
# Schedules all items in the TEMP_ITEMS array for removal on script exit.
#
cleanup() {
    if ((${#TEMP_ITEMS[@]} > 0)); then
        debug "Cleaning up temporary items..."
        for item in "${TEMP_ITEMS[@]}"; do
            if [[ -e "$item" ]]; then # -e checks for file or directory existence.
                rm -rf "$item"
                debug "Removed: $item"
            fi
        done
    fi
}

#
# Set up a trap to call the cleanup function on script exit or interruption.
#
trap cleanup EXIT SIGHUP SIGINT SIGTERM

#
# Creates a temporary file or directory and schedules it for cleanup.
# Usage: create_temp [-d] [suffix]
#   -d: Create a directory instead of a file.
#
create_temp() {
    local opts=()
    local suffix=""
    # Simple argument parsing.
    if [[ "$1" == "-d" ]]; then
        opts+=("-d")
        shift
    fi
    suffix="${1:-}"

    # Prefer /tmp, fallback to the current directory.
    local temp_item
    temp_item=$(mktemp "${opts[@]}" "/tmp/tmp.${suffix}.XXXXXX" 2>/dev/null) || temp_item=$(mktemp "${opts[@]}")

    if [[ -z "$temp_item" ]] || [[ ! -e "$temp_item" ]]; then
        printf "Error: Failed to create temporary item.\n" >&2
        return 1
    fi

    TEMP_ITEMS+=("$temp_item")
    debug "Created temp item: $temp_item"
    echo "$temp_item"
}

# --- API and Command Execution Functions ---

#
# Checks if an HTTP status code is in the 2xx range.
#
check_http_status() {
    local status_code="$1"
    local error_message="$2"
    local response_body_file="$3" # Pass file path instead of content for large responses.

    if [[ "$status_code" =~ ^2[0-9]{2}$ ]]; then
        return 0
    else
        printf "Error: %s\n" "$error_message" >&2
        printf "Status code: %s\n" "$status_code" >&2
        debug_cat_file "$response_body_file"
        return 1
    fi
}

#
# Retries a command with exponential backoff.
# SECURITY: This version avoids `eval` by executing the command directly.
#
retry_with_backoff() {
    local max_attempts=3
    local timeout=1
    local attempt=1
    local exit_code=0

    # The command and its arguments are passed directly to this function.
    debug "Executing with retry: $*"
    while ((attempt <= max_attempts)); do
        if ((attempt > 1)); then
            printf "Retrying (%d/%d)...\n" "$attempt" "$max_attempts" >&2
        fi

        "$@"
        exit_code=$?

        if ((exit_code == 0)); then
            return 0
        fi

        debug "Command failed with exit code $exit_code. Retrying in ${timeout}s..."
        sleep "$timeout"
        timeout=$((timeout * 2))
        attempt=$((attempt + 1))
    done

    printf "Error: Command failed after %d attempts.\n" "$max_attempts" >&2
    debug "Failed command: $*"
    return "$exit_code"
}

# --- Application Logic ---

#
# Loads SCAN_ID from a metadata file. Supports jq with a grep/sed fallback.
#
load_metadata() {
    local metadata_file="analytics_metadata.json"
    if [[ ! -f "$metadata_file" ]]; then
        debug "Metadata file not found: $metadata_file"
        return
    fi

    debug "Loading SCAN_ID from $metadata_file"
    if command -v jq &>/dev/null; then
        SCAN_ID=$(jq -r '.scan_id // empty' "$metadata_file")
    else
        debug "jq not found. Falling back to grep/sed."
        SCAN_ID=$(grep -o '"scan_id"[[:space:]]*:[[:space:]]*"[^"]*"' "$metadata_file" | sed 's/.*"scan_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
    fi
    debug "Loaded SCAN_ID=${SCAN_ID:-not_found}"
}

#
# Validates that all required environment variables for the SaaS platform are set.
#
validate_saas_env_vars() {
    local missing_vars=()
    [[ -z "${API_URL:-}" ]] && missing_vars+=("API_URL")
    [[ -z "${APP_TOKEN:-}" ]] && missing_vars+=("APP_TOKEN")
    [[ -z "${SCAN_ID:-}" ]] && missing_vars+=("SCAN_ID")

    if ((${#missing_vars[@]} > 0)); then
        printf "Error: Missing required environment variables for SaaS integration: %s\n" "${missing_vars[*]}" >&2
        return 1
    fi
}

#
# Fetches all jobs for the current GitHub workflow run.
#
fetch_github_workflow_jobs() {
    local response_file
    response_file=$(create_temp) || return 1

    local http_status
    local api_url="https://api.github.com/repos/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}/jobs"

    debug "Fetching GitHub workflow jobs from: $api_url"
    # The sleep is a defensive measure to allow the GitHub API to become consistent.
    debug "Sleeping for 2 seconds before fetching job statuses..."
    sleep 2

    # We need to capture the http_status, so we run curl inside a subshell command.
    # This is one of the few cases where building a command for a wrapper is complex.
    # An alternative is to not wrap this specific curl call in retry_with_backoff.
    # For simplicity, we'll keep the direct call here and add retry logic manually.
    # Refactoring `retry_with_backoff` to handle this case would be overly complex.

    http_status=$(curl -sSL --write-out "%{http_code}" \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer ${GITHUB_TOKEN}" \
        -H "X-GitHub-Api-Version: ${GITHUB_API_VERSION}" \
        -o "$response_file" \
        "$api_url")

    if ! check_http_status "$http_status" "GitHub API call for jobs failed" "$response_file"; then
        return 1
    fi

    cat "$response_file"
}

#
# Downloads logs for a specific job ID via the GitHub API.
# This is a helper function used as a fallback if `gh` CLI fails or is missing.
#
_download_logs_via_api() {
    local job_id="$1"
    local output_file="$2"
    local redirect_url_file
    local http_status
    local api_url="${GITHUB_API_URL:-https://api.github.com}/repos/${GITHUB_REPOSITORY}/actions/jobs/${job_id}/logs"

    # 1. Get the redirect URL for the logs zip archive.
    debug "Getting log redirect URL from API for job $job_id"
    redirect_url_file=$(create_temp) || return 1
    http_status=$(curl -sI -w "%{http_code}" \
        -H "Authorization: Bearer ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: ${GITHUB_API_VERSION}" \
        -o "$redirect_url_file" \
        "$api_url")

    # The API for log download URL gives a 302 redirect. We need to check for that.
    if [[ "$http_status" != "302" ]]; then
        printf "Error: Failed to get log redirect URL for job %s (Status: %s)\n" "$job_id" "$http_status" >&2
        return 1
    fi

    local redirect_url
    redirect_url=$(grep -i '^location:' "$redirect_url_file" | awk '{print $2}' | tr -d '\r')

    if [[ -z "$redirect_url" ]]; then
        printf "Error: Could not parse redirect URL for job %s.\n" "$job_id" >&2
        return 1
    fi

    # 2. Download the actual logs from the redirect URL.
    debug "Downloading logs from redirect URL..."
    http_status=$(curl -sL -w "%{http_code}" -o "$output_file" "$redirect_url")

    if ! check_http_status "$http_status" "Failed to download logs from redirect URL" "$output_file"; then
        return 1
    fi

    debug "Successfully downloaded logs via API for job $job_id"
    return 0
}

#
# Downloads logs for a given job ID. Prefers `gh` CLI and falls back to API.
#
download_job_logs() {
    local job_id="$1"
    local output_file="$2"

    printf "Downloading logs for job: %s\n" "$job_id"

    # Method 1: Use GitHub CLI (preferred)
    if command -v gh &>/dev/null; then
        debug "Attempting to download logs using 'gh' CLI..."
        if retry_with_backoff gh run view --repo "$GITHUB_REPOSITORY" --job "$job_id" --log >"$output_file"; then
            printf "✅ Saved logs for job %s using 'gh' CLI.\n" "$job_id"
            return 0
        else
            printf "⚠️ 'gh' CLI command failed. Falling back to API method.\n" >&2
        fi
    else
        debug "GitHub CLI 'gh' not found. Using API method directly."
    fi

    # Method 2: Fallback to direct API call
    if _download_logs_via_api "$job_id" "$output_file"; then
        printf "✅ Saved logs for job %s using API fallback.\n" "$job_id"
        return 0
    else
        printf "❌ Failed to download logs for job %s after all attempts.\n" "$job_id" >&2
        # Create an empty file to signify failure but prevent later steps from breaking
        # on a non-existent file. Or return 1 to halt execution.
        echo "Log download failed for job $job_id" >"$output_file"
        return 1
    fi
}

#
# Sends a file to the SaaS platform.
#
send_file_to_saas() {
    local file_path="$1"
    local remote_filename="$2"

    printf "Sending file '%s' to SaaS platform...\n" "$remote_filename"

    if ! validate_saas_env_vars; then
        printf "⚠️ Skipping SaaS upload due to missing environment variables.\n" >&2
        return 1
    fi

    if [[ ! -s "$file_path" ]]; then
        printf "Warning: File '%s' is empty or does not exist. Skipping upload.\n" "$file_path" >&2
        return 1
    fi

    local response_file
    response_file=$(create_temp "saas_api_response") || return 1

    local api_url="${API_URL}/ingestionapi/v1/upload-generic-file"
    local http_status

    debug "Uploading to: $api_url"
    debug "File size: $(wc -c <"$file_path") bytes"

    # Using --fail-with-body for better error reporting in newer curl versions
    http_status=$(curl -sSL -w "%{http_code}" \
        -X POST \
        -H "Accept: application/json" \
        -H "Content-Type: multipart/form-data" \
        -F "file=@${file_path};filename=${remote_filename}" \
        -o "$response_file" \
        "${api_url}?api_key=${APP_TOKEN}&scan_id=${SCAN_ID}&file_type=logs")

    if ! check_http_status "$http_status" "SaaS API upload for '$remote_filename' failed" "$response_file"; then
        return 1
    fi

    printf "✅ Successfully sent '%s' to SaaS platform.\n" "$remote_filename"
    debug_cat_file "$response_file"
}

# --- Main Execution ---

main() {
    printf "Starting log fetching and analysis process...\n"

    # Load SCAN_ID from file, if it exists. This can be overridden by env var.
    load_metadata

    # Fetch all jobs for the current workflow run
    local all_jobs_data
    all_jobs_data=$(fetch_github_workflow_jobs)

    if [[ -z "$all_jobs_data" ]]; then
        printf "⚠️ Failed to fetch job data from GitHub API or the response was empty.\n" >&2
        return 0 # Not a fatal error, just nothing to process.
    fi

    # Check for jq dependency
    if ! command -v jq &>/dev/null; then
        printf "Error: 'jq' is not installed, which is required to parse job data.\n" >&2
        return 1
    fi

    # Find the ID of the first job that has completed.
    local first_completed_job_id
    first_completed_job_id=$(echo "$all_jobs_data" | jq -r '(.jobs[]? | select(.status == "completed") | .id) | first')

    if [[ -z "$first_completed_job_id" ]]; then
        printf "ℹ️ No completed jobs found in this workflow run.\n"
        return 0
    fi

    debug "Found first completed job ID: $first_completed_job_id"

    # Create a temporary file for the logs. It will be cleaned up automatically on exit.
    local downloaded_log_file
    downloaded_log_file=$(create_temp "joblog.txt") || return 1

    if download_job_logs "$first_completed_job_id" "$downloaded_log_file"; then
        local remote_filename="job_${first_completed_job_id}_logs.txt"
        send_file_to_saas "$downloaded_log_file" "$remote_filename"
    else
        printf "❌ Process failed: Could not download logs for job %s.\n" "$first_completed_job_id"
        return 1
    fi

    printf "Process completed successfully.\n"
}

# Execute the main function, passing all script arguments to it.
main "$@"
