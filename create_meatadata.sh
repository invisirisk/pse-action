# Function to create analytics metadata
create_analytics_metadata() {
    log "Creating analytics metadata"
    log "DEBUG: SCAN_ID for metadata is '$SCAN_ID'"
    log "DEBUG: GITHUB_RUN_ID is '$GITHUB_RUN_ID'"
    log "DEBUG: GITHUB_ACTION_PATH is '$GITHUB_ACTION_PATH'"

    # Create a JSON file with scan details
    log "Creating scan details JSON file"
    JSON_FILE="analytics_metadata.json"
    local TARGET_FILE_PATH="$GITHUB_ACTION_PATH/$JSON_FILE"

    cat >"$TARGET_FILE_PATH" <<EOF
{
  "scan_id": "$SCAN_ID",
  "run_id": "$GITHUB_RUN_ID"
}
EOF
    log "DEBUG: Contents of $TARGET_FILE_PATH:"
    cat "$TARGET_FILE_PATH" || log "DEBUG: Failed to cat $TARGET_FILE_PATH"
    log "DEBUG: analytics_metadata.json file path for upload: $TARGET_FILE_PATH"
}

# Main function
create_analytics_metadata
