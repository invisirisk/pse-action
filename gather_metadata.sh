# Function to upload scan metadata
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}
main() {
  log "Uploading scan metadata"

  # Create a JSON file with scan details
  log "Creating scan details JSON file"
  JSON_FILE="analytics_metadata.json"

  stdbuf -o0 printf '{"scan_id":"%s","run_id":"%s"}' "$PSE_SCAN_ID" "$GITHUB_RUN_ID" >"$JSON_FILE"
}
main
