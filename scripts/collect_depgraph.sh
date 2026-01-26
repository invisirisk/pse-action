#!/bin/bash
# PSE Dependency Graph Collection Script - Simplified
# Fetches and executes a complete collection script from /collector/depgraph endpoint

PSE_BASE_URL="https://pse.invisirisk.com"
PROJECT_PATH="${GITHUB_WORKSPACE:-.}"
DEBUG="${DEBUG:-false}"

echo "[INFO] Starting dependency graph collection"

# Fetch complete collection script from /collector/depgraph endpoint
collection_script=$(curl -X POST "$PSE_BASE_URL/collector/depgraph" \
  -H "Content-Type: application/json" \
  -d "{\"project_path\":\"$PROJECT_PATH\",\"pse_base_url\":\"$PSE_BASE_URL\",\"include_dev_deps\":false,\"debug\":$DEBUG}" \
  -k --tlsv1.2 \
  --connect-timeout 10 \
  --max-time 30 \
  -s -w "\nHTTP_STATUS:%{http_code}" -o /tmp/depgraph_script_$$.sh)

http_status=$(echo "$collection_script" | grep "HTTP_STATUS:" | cut -d: -f2)

if [ "$http_status" != "200" ]; then
  echo "[ERROR] Failed to fetch collection script (HTTP $http_status)"
  cat /tmp/depgraph_script_$$.sh
  rm -f /tmp/depgraph_script_$$.sh
  exit 1
fi

echo "[INFO] Executing dependency graph collection script"
bash /tmp/depgraph_script_$$.sh
exit_code=$?

rm -f /tmp/depgraph_script_$$.sh

if [ $exit_code -ne 0 ]; then
  echo "[ERROR] Collection script failed with exit code: $exit_code"
  exit $exit_code
fi

echo "[INFO] Dependency graph collection completed successfully"
