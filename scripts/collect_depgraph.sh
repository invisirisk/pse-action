#!/bin/bash
# PSE Dependency Graph Collection Script
# Simplified version with clear logging for debugging

# Note: set -e is NOT used here to allow proper error handling and reporting
# Each critical operation checks its own exit code

PSE_BASE_URL="https://pse.invisirisk.com"
PROJECT_PATH="${GITHUB_WORKSPACE:-.}"

echo "========================================="
echo "PSE DEPENDENCY GRAPH COLLECTION"
echo "========================================="
echo "Project Path: $PROJECT_PATH"
echo "PSE Base URL: $PSE_BASE_URL"
echo ""

# ============================================
# STEP 1: List Project Directories (1 levels)
# ============================================
echo "[STEP 1] Listing project directories (1 levels deep)..."
file_list=$(find "$PROJECT_PATH" -maxdepth 1 \( -type f -o -type d \) 2>/dev/null | \
  grep -v '/\.git/' | \
  sed "s|^$PROJECT_PATH/||" | \
  sed "s|^$PROJECT_PATH$||" | \
  grep -v '^$' | \
  jq -R . | jq -s .)

file_count=$(echo "$file_list" | jq 'length')
echo "✓ Found $file_count files/directories"
echo ""

# ============================================
# STEP 2: Call Scan API (Discover + Generate Scripts)
# ============================================
echo "[STEP 2] Calling Scan API (discovers technologies and generates scripts)..."
scan_request=$(jq -n --argjson files "$file_list" '{project_files: $files, include_dev_deps: true}')

echo "→ Request Payload:"
echo "$scan_request" | jq -C '.' 2>/dev/null || echo "$scan_request"
echo ""

echo "→ Calling: POST $PSE_BASE_URL/depgraph/scan"
scan_response=$(curl -X POST "$PSE_BASE_URL/depgraph/scan" \
  -H "Content-Type: application/json" \
  -d "$scan_request" \
  -k --tlsv1.2 \
  --connect-timeout 10 \
  --max-time 30 \
  -s -w "\nHTTP_CODE:%{http_code}")

http_code=$(echo "$scan_response" | grep "HTTP_CODE:" | cut -d: -f2)
scan_body=$(echo "$scan_response" | sed '/HTTP_CODE:/d')

echo "← Response (HTTP $http_code):"
echo "$scan_body" | jq -C '.' 2>/dev/null || echo "$scan_body"
echo ""

# Check for errors
if [ "$http_code" != "200" ]; then
  echo "✗ Scan API failed with HTTP $http_code"
  exit 1
fi

# Parse scan results - API now returns direct array of scripts
scripts_count=$(echo "$scan_body" | jq -r 'length' 2>/dev/null)

if [ -z "$scripts_count" ] || [ "$scripts_count" = "null" ]; then
  scripts_count=0
fi

echo "✓ Detected $scripts_count technology(ies)"
echo ""

# Exit if no scripts
if [ "$scripts_count" -eq 0 ] 2>/dev/null; then
  echo "No technologies found. Exiting."
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
  
  echo "========================================="
  echo "Processing: $technology"
  echo "Path: $project_path"
  echo "Confidence: $confidence"
  echo "========================================="
  echo ""
  
  # ============================================
  # STEP 3A: Execute Script
  # ============================================
  echo "[STEP 3A] Executing dependency script for $technology..."
  script_file="/tmp/depgraph_${technology}_$$.sh"
  echo "$script_content" > "$script_file"
  chmod +x "$script_file"
  
  echo "→ Running script in: $project_path"
  cd "$project_path"
  
  # Use temp file to handle potentially large outputs
  dependency_output_file="/tmp/depgraph_output_${technology}_$$.txt"
  bash "$script_file" > "$dependency_output_file" 2>&1
  script_exit_code=$?
  
  cd - > /dev/null
  rm -f "$script_file"
  
  if [ $script_exit_code -ne 0 ]; then
    echo "✗ Script execution failed (exit code: $script_exit_code)"
    echo "← Script Error Output:"
    head -c 5000 "$dependency_output_file"
    echo ""
    rm -f "$dependency_output_file"
    continue
  fi
  
  output_size=$(stat -f%z "$dependency_output_file" 2>/dev/null || stat -c%s "$dependency_output_file" 2>/dev/null)
  echo "← Script Output:"
  echo "Output length: $output_size bytes"
  echo "Output preview (first 500 chars):"
  head -c 500 "$dependency_output_file"
  echo ""
  
  echo "✓ Script executed successfully"
  echo ""
  
  # ============================================
  # STEP 3B: Call Parse API
  # ============================================
  echo "[STEP 3B] Calling Parse API for $technology..."
  
  # Build JSON request using file to avoid "Argument list too long" error with large outputs
  parse_request_file="/tmp/depgraph_request_${technology}_$$.json"
  jq -Rs --arg tech "$technology" '{technology: $tech, raw_output: .}' < "$dependency_output_file" > "$parse_request_file"
  
  request_size=$(stat -f%z "$parse_request_file" 2>/dev/null || stat -c%s "$parse_request_file" 2>/dev/null)
  echo "→ Request Payload:"
  echo "Payload length: $request_size bytes"
  echo "Payload preview (first 300 chars):"
  head -c 300 "$parse_request_file" | jq -C '.' 2>/dev/null || head -c 300 "$parse_request_file"
  echo ""
  
  echo "→ Calling: POST $PSE_BASE_URL/depgraph/parse"
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
  
  echo "← Response (HTTP $parse_http_code):"
  echo "$parse_body" | jq -C '.' 2>/dev/null || echo "$parse_body"
  echo ""
  
  if [ "$parse_http_code" != "200" ]; then
    echo "✗ Parse API failed for $technology"
    continue
  fi
  
  dep_count=$(echo "$parse_body" | jq '.dependencies | length' 2>/dev/null || echo "0")
  echo "✓ Parse successful - $dep_count dependencies found"
  echo ""
done

echo "========================================="
echo "DEPENDENCY GRAPH COLLECTION COMPLETE"
echo "========================================="
