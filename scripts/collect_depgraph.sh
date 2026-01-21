#!/bin/bash
# PSE Dependency Graph Collection Script
# Supports DEBUG_PSE flag for verbose logging

# Note: set -e is NOT used here to allow proper error handling and reporting
# Each critical operation checks its own exit code

PSE_BASE_URL="https://pse.invisirisk.com"
PROJECT_PATH="${GITHUB_WORKSPACE:-.}"
DEBUG_PSE="${DEBUG_PSE:-false}"

# Logging helpers
log_debug() {
  if [ "$DEBUG_PSE" = "true" ]; then
    echo "$@"
  fi
}

log_info() {
  echo "$@"
}

log_debug "========================================="
log_debug "PSE DEPENDENCY GRAPH COLLECTION"
log_debug "========================================="
log_debug "Project Path: $PROJECT_PATH"
log_debug "PSE Base URL: $PSE_BASE_URL"
log_debug "Debug Mode: $DEBUG_PSE"
log_debug ""

# ============================================
# STEP 1: List Project Directories (1 levels)
# ============================================
log_debug "[STEP 1] Listing project directories (1 levels deep)..."
file_list=$(find "$PROJECT_PATH" -maxdepth 1 \( -type f -o -type d \) 2>/dev/null | \
  grep -v '/\.git/' | \
  sed "s|^$PROJECT_PATH/||" | \
  sed "s|^$PROJECT_PATH$||" | \
  grep -v '^$' | \
  jq -R . | jq -s .)

file_count=$(echo "$file_list" | jq 'length')
log_debug "✓ Found $file_count files/directories"
log_debug ""

# ============================================
# STEP 2: Call Scan API (Discover + Generate Scripts)
# ============================================
log_debug "[STEP 2] Calling Scan API (discovers technologies and generates scripts)..."
scan_request=$(jq -n --argjson files "$file_list" '{project_files: $files, include_dev_deps: true}')

log_debug "→ Request Payload:"
log_debug "$scan_request" | jq -C '.' 2>/dev/null || log_debug "$scan_request"
log_debug ""

log_debug "→ Calling: POST $PSE_BASE_URL/depgraph/scan"
scan_response=$(curl -X POST "$PSE_BASE_URL/depgraph/scan" \
  -H "Content-Type: application/json" \
  -d "$scan_request" \
  -k --tlsv1.2 \
  --connect-timeout 10 \
  --max-time 30 \
  -s -w "\nHTTP_CODE:%{http_code}")

http_code=$(echo "$scan_response" | grep "HTTP_CODE:" | cut -d: -f2)
scan_body=$(echo "$scan_response" | sed '/HTTP_CODE:/d')

log_debug "← Response (HTTP $http_code):"
log_debug "$scan_body" | jq -C '.' 2>/dev/null || log_debug "$scan_body"
log_debug ""

# Check for errors
if [ "$http_code" != "200" ]; then
  log_info "✗ Scan API failed with HTTP $http_code"
  log_info "$scan_body"
  exit 1
fi

# Parse scan results - API now returns direct array of scripts
scripts_count=$(echo "$scan_body" | jq -r 'length' 2>/dev/null)

if [ -z "$scripts_count" ] || [ "$scripts_count" = "null" ]; then
  scripts_count=0
fi

log_info "✓ Detected $scripts_count technology(ies)"

# Exit if no scripts
if [ "$scripts_count" -eq 0 ] 2>/dev/null; then
  log_info "No technologies found. Exiting."
  exit 0
fi

# ============================================
# STEP 3: Process Each Script
# ============================================
echo "$scan_body" | jq -c '.[]' 2>/dev/null | while IFS= read -r script_obj; do
  technology=$(echo "$script_obj" | jq -r '.technology')
  project_path=$(echo "$script_obj" | jq -r '.project_path // "."')
  script_content=$(echo "$script_obj" | jq -r '.script')
  confidence=$(echo "$script_obj" | jq -r '.confidence')
  
  # Convert to absolute path
  if [[ ! "$project_path" = /* ]]; then
    project_path="$PROJECT_PATH/$project_path"
  fi
  
  log_debug "========================================="
  log_debug "Processing: $technology"
  log_debug "Path: $project_path"
  log_debug "Confidence: $confidence"
  log_debug "========================================="
  log_debug ""
  
  # ============================================
  # STEP 3A: Execute Script
  # ============================================
  log_debug "[STEP 3A] Executing dependency script for $technology..."
  script_file="/tmp/depgraph_${technology}_$$.sh"
  echo "$script_content" > "$script_file"
  chmod +x "$script_file"
  
  log_debug "→ Running script in: $project_path"
  cd "$project_path"
  
  # Use temp file to handle potentially large outputs
  dependency_output_file="/tmp/depgraph_output_${technology}_$$.txt"
  bash "$script_file" > "$dependency_output_file" 2>&1
  script_exit_code=$?
  
  cd - > /dev/null
  rm -f "$script_file"
  
  if [ $script_exit_code -ne 0 ]; then
    log_info "✗ Script execution failed for $technology (exit code: $script_exit_code)"
    log_info "← Script Error Output:"
    head -c 5000 "$dependency_output_file"
    log_info ""
    rm -f "$dependency_output_file"
    continue
  fi
  
  output_size=$(stat -f%z "$dependency_output_file" 2>/dev/null || stat -c%s "$dependency_output_file" 2>/dev/null)
  log_debug "← Script Output:"
  log_debug "Output length: $output_size bytes"
  log_debug "Output preview (first 500 chars):"
  if [ "$DEBUG_PSE" = "true" ]; then
    head -c 500 "$dependency_output_file"
  fi
  log_debug ""
  
  log_debug "✓ Script executed successfully"
  log_debug ""
  
  # ============================================
  # STEP 3B: Call Parse API
  # ============================================
  log_debug "[STEP 3B] Calling Parse API for $technology..."
  
  # Build JSON request using file to avoid "Argument list too long" error with large outputs
  parse_request_file="/tmp/depgraph_request_${technology}_$$.json"
  jq -Rs --arg tech "$technology" '{technology: $tech, raw_output: .}' < "$dependency_output_file" > "$parse_request_file"
  
  request_size=$(stat -f%z "$parse_request_file" 2>/dev/null || stat -c%s "$parse_request_file" 2>/dev/null)
  log_debug "→ Request Payload:"
  log_debug "Payload length: $request_size bytes"
  log_debug "Payload preview (first 300 chars):"
  if [ "$DEBUG_PSE" = "true" ]; then
    head -c 300 "$parse_request_file" | jq -C '.' 2>/dev/null || head -c 300 "$parse_request_file"
  fi
  log_debug ""
  
  log_debug "→ Calling: POST $PSE_BASE_URL/depgraph/parse"
  parse_response=$(curl -X POST "$PSE_BASE_URL/depgraph/parse" \
    -H "Content-Type: application/json" \
    -d @"$parse_request_file" \
    -k --tlsv1.2 \
    --connect-timeout 10 \
    --max-time 30 \
    -s -w "\nHTTP_CODE:%{http_code}")
  
  # Clean up temp files
  rm -f "$dependency_output_file" "$parse_request_file"
  
  parse_http_code=$(echo "$parse_response" | grep "HTTP_CODE:" | cut -d: -f2)
  parse_body=$(echo "$parse_response" | sed '/HTTP_CODE:/d')
  
  log_debug "← Response (HTTP $parse_http_code):"
  log_debug "$parse_body" | jq -C '.' 2>/dev/null || log_debug "$parse_body"
  log_debug ""
  
  if [ "$parse_http_code" != "200" ]; then
    log_info "✗ Parse API failed for $technology"
    log_info "$parse_body"
    continue
  fi
  
  dep_count=$(echo "$parse_body" | jq '.dependencies | length' 2>/dev/null || echo "0")
  log_info "✓ Collected $dep_count dependencies for $technology"
done

log_info "✓ Dependency graph collection complete"
