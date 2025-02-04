#!/bin/bash

set -e

# Utility function to fetch with retries
fetch_with_retries() {
  local url=$1
  local max_retries=${2:-5}
  local delay=${3:-3000}
  local exponential_backoff_factor=${4:-1.5}

  for ((i=0; i<max_retries; i++)); do
    if response=$(curl -s -f "$url"); then
      echo "$response"
      return 0
    else
      echo "Attempt #$((i+1)): Request failed: $?"
      if [ $i -eq $((max_retries-1)) ]; then
        return 1
      fi
      echo "Retrying in $((delay/1000)) seconds..."
      sleep $((delay/1000))
      delay=$(echo "$delay * $exponential_backoff_factor" | bc)
    fi
  done
}

# Function to fetch ECR credentials
fetch_ecr_credentials() {
  local vb_api_url=$1
  local vb_api_key=$2

  local url="$vb_api_url/utilityapi/v1/registry?api_key=$vb_api_key"
  response=$(curl -s -f "$url")
  if [ $? -ne 0 ]; then
    echo "Failed to fetch ECR credentials: $?"
    return 1
  fi

  decoded_token=$(echo "$response" | jq -r '.data' | base64 --decode)
  echo "$decoded_token"
}

# Function to log in to Amazon ECR
login_to_ecr() {
  local username=$1
  local password=$2
  local registry_id=$3
  local region=$4

  echo "$password" | docker login -u "$username" "$registry_id.dkr.ecr.$region.amazonaws.com" --password-stdin
}

# Function to run the VB image
run_vb_image() {
  local vb_api_url=$1
  local vb_api_key=$2
  local registry_id=$3
  local region=$4

  docker run --name pse \
    -e INVISIRISK_JWT_TOKEN="$vb_api_key" \
    -e GITHUB_TOKEN="$GITHUB_TOKEN" \
    -e PSE_DEBUG_FLAG="--alsologtostderr" \
    -e POLICY_LOG="t" \
    -e INVISIRISK_PORTAL="$vb_api_url" \
    "$registry_id.dkr.ecr.$region.amazonaws.com/pse-proxy"
}

# Function to set up CA certificates
ca_setup() {
  local ca_url="https://pse.invisirisk.com/ca"
  local ca_file="/etc/ssl/certs/pse.pem"

  cert=$(fetch_with_retries "$ca_url")
  echo "$cert" > "$ca_file"
  update-ca-certificates

  git config --global http.sslCAInfo "$ca_file"
  export NODE_EXTRA_CA_CERTS="$ca_file"
  export REQUESTS_CA_BUNDLE="$ca_file"
}

# Function to configure iptables
iptables_setup() {
  if ! command -v apt-get &> /dev/null; then
    apk add iptables ca-certificates git --quiet
  else
    apt-get update --quiet
    apt-get install -y iptables ca-certificates git --quiet
  fi

  iptables -t nat -N pse
  iptables -t nat -A OUTPUT -j pse

  dns_resp=$(getent hosts pse | awk '{ print $1 }')
  iptables -t nat -A pse -p tcp -m tcp --dport 443 -j DNAT --to-destination "$dns_resp:12345"
}

# Function to initiate SBOM scan
initiate_sbom_scan() {
  local vb_api_url=$1
  local vb_api_key=$2

  local url="$vb_api_url/utilityapi/v1/scan"
  local data="{\"api_key\":\"$vb_api_key\"}"

  response=$(curl -s -f -X POST "$url" -H "Content-Type: application/json" -d "$data")
  if [ $? -ne 0 ]; then
    echo "Failed to initiate SBOM scan: $?"
    return 1
  fi

  scan_id=$(echo "$response" | jq -r '.data.scan_id')
  echo "$scan_id"
}

# Main function
main() {
  vb_api_url=$1
  vb_api_key=$2

  # Step 7: Initiate SBOM Scan
  scan_id=$(initiate_sbom_scan "$vb_api_url" "$vb_api_key")
  echo "scan_id=$scan_id" >> $GITHUB_OUTPUT

  # Step 1: Fetch ECR Credentials
  ecr_credentials=$(fetch_ecr_credentials "$vb_api_url" "$vb_api_key")
  username=$(echo "$ecr_credentials" | jq -r '.username')
  password=$(echo "$ecr_credentials" | jq -r '.password')
  region=$(echo "$ecr_credentials" | jq -r '.region')
  registry_id=$(echo "$ecr_credentials" | jq -r '.registry_id')

  # Step 2: Log in to Amazon ECR
  login_to_ecr "$username" "$password" "$registry_id" "$region"

  # Step 3: Run VB Image
  run_vb_image "$vb_api_url" "$vb_api_key" "$registry_id" "$region"

  # Step 8: Set Container ID as Output
  container_id=$(docker ps -aqf "name=^pse$")
  echo "CONTAINER_ID=$container_id" >> $GITHUB_ENV

  # Step 4: Configure iptables
  iptables_setup

  # Step 5: Set up CA certificates
  ca_setup

  # Step 6: Notify PSE of workflow start
  base=$GITHUB_SERVER_URL/
  repo=$GITHUB_REPOSITORY

  scan_id=$3
  q="builder=github&id=$scan_id&build_id=$GITHUB_RUN_ID&build_url=$base$repo/actions/runs/$GITHUB_RUN_ID/attempts/$GITHUB_RUN_ATTEMPT&project=$GITHUB_REPOSITORY&workflow=$GITHUB_WORKFLOW - $GITHUB_JOB&builder_url=$base&scm=git&scm_commit=$GITHUB_SHA&scm_branch=$GITHUB_REF_NAME&scm_origin=$base$repo"

  curl -s -f -X POST "https://pse.invisirisk.com/start" -H "Content-Type: application/x-www-form-urlencoded" -d "$q"

}

main "$@"