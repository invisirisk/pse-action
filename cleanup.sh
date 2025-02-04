#!/bin/bash

set -e

# Function to print Docker container logs
print_docker_logs() {
  echo "Fetching logs for Docker container 'pse'..."
  if docker logs pse 2>&1; then
    echo "Docker logs fetched successfully."
  else
    echo "Failed to fetch logs for Docker container."
  fi
}

# Function to stop and remove the Docker container
stop_and_remove_container() {
  echo "Stopping and removing Docker container 'pse'..."
  if docker stop pse && docker rm pse; then
    echo "Docker container stopped and removed successfully."
  else
    echo "Failed to stop or remove Docker container."
  fi
}

# Function to notify PSE of workflow completion
notify_pse() {
  local base="$GITHUB_SERVER_URL/"
  local repo="$GITHUB_REPOSITORY"
  local build_url="${base}${repo}/actions/runs/${GITHUB_RUN_ID}/attempts/${GITHUB_RUN_ATTEMPT}"
  local status="$GITHUB_RUN_RESULT"

  local q="build_url=${build_url}&status=${status}"

  echo "Notifying PSE of workflow completion..."
  response=$(curl -s -f -X POST "https://pse.invisirisk.com/end" -H "Content-Type: application/x-www-form-urlencoded" -d "$q")

  if [ $? -ne 0 ]; then
    echo "Error talking to PSE. Status: $?"
  else
    echo "Notification sent to PSE successfully."
  fi
}

# Main function
main() {
  echo "Cleanup - start"

  # Step 1: Print Docker container logs
  print_docker_logs

  # Step 2: Stop and remove the Docker container
  stop_and_remove_container

  # Step 3: Notify PSE of workflow completion
  notify_pse

  echo "Cleanup - done"
}

# Run the main function
main