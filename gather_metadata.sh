# Function to upload scan metadata
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}
main() {
    log "Uploading scan metadata"

    # Create a JSON file with scan details
    log "Creating scan details JSON file"
    JSON_FILE="analytics_metadata.json"

    cat >"$JSON_FILE" <<EOF
{
  "scan_id": "$PSE_SCAN_ID",
  "run_id": "$GITHUB_RUN_ID"
}
EOF
}
main
