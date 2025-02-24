#!/bin/bash

set -e

# Function to log messages
log_info() {
    echo "[INFO] $1"
}

log_error() {
    echo "[ERROR] $1" >&2
}

log_debug() {
    echo "[DEBUG] $1"
}

# Function to notify PSE of workflow completion
notify_pse() {
    log_debug "cleanup - start"

    log_info "Notifying PSE of workflow completion..."

    base="${GITHUB_SERVER_URL}/"
    repo="${GITHUB_REPOSITORY}"
    build_url="${base}${repo}/actions/runs/${GITHUB_RUN_ID}/attempts/${GITHUB_RUN_ATTEMPT}"

    response=$(curl -s -X POST \
        -H "Content-Type: application/x-www-form-urlencoded" \
        --data-urlencode "build_url=$build_url" \
        --data-urlencode "status=$GITHUB_RUN_RESULT" \
        "https://pse.invisirisk.com/end")

    if [ $? -eq 0 ]; then
        log_info "PSE notification sent successfully."
    else
        log_error "Error talking to PSE. Status: $?"
    fi
}

# Function to fetch and print Docker container logs
fetch_container_logs() {
    log_info "Fetching logs for Docker container 'pse'..."

    if ! docker logs pse 2>&1; then
        log_error "Failed to fetch logs for Docker container"
        return 1
    fi
}

# Function to stop and remove Docker container
cleanup_container() {
    log_info "Waiting 60 seconds before container cleanup..."
    sleep 60

    log_info "Stopping Docker container..."
    if ! docker stop pse 2>/dev/null; then
        log_error "Failed to stop Docker container"
    fi

    log_info "Removing Docker container..."
    if ! docker rm pse 2>/dev/null; then
        log_error "Failed to remove Docker container"
    fi

    log_info "Docker container stopped and removed successfully."
}

# Main cleanup function
main() {
    log_debug "cleanup - start"

    # Step 1: Notify PSE of workflow completion
    notify_pse || log_error "PSE notification failed"

    # Step 2: Print Docker container logs
    fetch_container_logs || log_error "Log fetching failed"

    # Step 3: Stop and remove the Docker container
    cleanup_container || log_error "Container cleanup failed"

    log_debug "cleanup - done"
}

# Run main function and capture any errors
if ! main; then
    log_info "Cleanup failed"
    exit 1
fi