#!/bin/bash

set -e

# Function to log messages
log_info() {
    echo "[INFO] $1"
}

log_error() {
    echo "[ERROR] $1" >&2
}

# Setup Docker function
setup_docker() {
    log_info "Checking if Docker is installed..."
    if ! command -v docker &> /dev/null; then
        log_error "Docker not found. Installing Docker..."

        # Read OS release info
        if [ -f "/etc/os-release" ]; then
            . /etc/os-release
            if echo "$NAME" | grep -q "Alpine"; then
                log_info "Installing Docker on Alpine..."
                apk update
                apk add docker
                rc-update add docker boot
                service docker start
            elif echo "$NAME" | grep -q "Ubuntu"; then
                log_info "Installing Docker on Ubuntu..."
                apt-get update
                apt-get install -y docker.io
            elif echo "$NAME" | grep -q "Debian"; then
                log_info "Installing Docker on Debian..."
                apt-get update
                apt-get install -y docker.io
            else
                log_error "Unsupported OS. Unable to install Docker."
                exit 1
            fi
        else
            log_error "Could not determine OS type"
            exit 1
        fi
    else
        log_info "Docker is installed."
    fi

    # Check if Docker daemon is running
    if ! docker info &> /dev/null; then
        log_info "Docker daemon not running. Starting Docker service..."
        sudo service docker start
        sleep 5

        if ! docker info &> /dev/null; then
            log_error "Failed to start Docker service"
            exit 1
        fi
        log_info "Docker daemon started successfully."
    else
        log_info "Docker daemon is running."
    fi
}

# Function to fetch with retries
fetch_with_retries() {
    local url=$1
    local max_retries=${2:-5}
    local delay=${3:-3}
    local backoff_factor=${4:-1.5}

    for ((i=1; i<=max_retries; i++)); do
        log_info "Attempt #$i: Fetching $url..."
        if response=$(curl -sSL -w "%{http_code}" "$url"); then
            http_code=${response: -3}
            content=${response:0:${#response}-3}

            if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
                log_info "Successfully fetched $url. Status code: $http_code"
                echo "$content"
                return 0
            fi
        fi

        log_error "Attempt #$i failed"
        if [ $i -eq $max_retries ]; then
            return 1
        fi

        sleep $delay
        delay=$(echo "$delay * $backoff_factor" | bc)
    done
}

# Function to configure iptables
setup_iptables() {
    log_info "Setting up iptables..."

    if command -v apk &> /dev/null; then
        apk add iptables ca-certificates git
    else
        apt-get update
        apt-get install -y iptables ca-certificates git
    fi

    iptables -t nat -N pse 2>/dev/null || true
    iptables -t nat -A OUTPUT -j pse 2>/dev/null || true

    # Get container IP
    container_ip=$(docker inspect -f "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}" pse)
    if [ -z "$container_ip" ]; then
        log_error "Could not retrieve IP address of pse container"
        exit 1
    fi

    log_info "IP address of pse container: $container_ip"
    iptables -t nat -A pse -p tcp -m tcp --dport 443 -j DNAT --to-destination "${container_ip}:12345"
    log_info "iptables configuration completed."
}

# Function to set up CA certificates
setup_ca() {
    log_info "Setting up CA certificates..."
    local ca_url="https://pse.invisirisk.com/ca"
    local ca_file="/etc/ssl/certs/pse.pem"

    cert=$(fetch_with_retries "$ca_url")
    echo "$cert" > "$ca_file"

    update-ca-certificates
    git config --global http.sslCAInfo "$ca_file"
    export NODE_EXTRA_CA_CERTS="$ca_file"
    export REQUESTS_CA_BUNDLE="$ca_file"
    log_info "CA certificates configured."
}

# Function to initiate SBOM scan
initiate_sbom_scan() {
    local vb_api_url=$1
    local vb_api_key=$2

    log_info "Initiating SBOM scan..."
    response=$(curl -s -X POST \
        -H "Content-Type: application/json" \
        -d "{\"api_key\":\"$vb_api_key\"}" \
        "$vb_api_url/utilityapi/v1/scan")

    scan_id=$(echo "$response" | jq -r '.data.scan_id')
    if [ -z "$scan_id" ]; then
        log_error "Failed to initiate SBOM scan"
        exit 1
    fi

    echo "$scan_id"
}

# Function to fetch ECR credentials
fetch_ecr_credentials() {
    local vb_api_url=$1
    local vb_api_key=$2

    log_info "Fetching ECR credentials..."
    response=$(curl -s \
        "$vb_api_url/utilityapi/v1/registry?api_key=$vb_api_key")

    echo "$response" | jq -r '.data' | base64 -d
}

# Function to login to ECR
login_to_ecr() {
    local username=$1
    local password=$2
    local registry_id=$3
    local region=$4

    log_info "Logging in to Amazon ECR..."
    if ! docker login -u "$username" "${registry_id}.dkr.ecr.${region}.amazonaws.com" --password "$password"; then
        log_error "Failed to log in to Amazon ECR"
        exit 1
    fi
    log_info "Successfully logged in to Amazon ECR."
}

# Function to run VB image
run_vb_image() {
    local vb_api_url=$1
    local vb_api_key=$2
    local registry_id=$3
    local region=$4

    log_info "Finding network starting with github_network_..."
    network_name=$(docker network ls | grep "github_network_" | awk '{print $2}' | head -n1)
    if [ -z "$network_name" ]; then
        network_name="bridge"
        log_info "No github_network_ found, using bridge network"
    else
        log_info "Found network: $network_name"
    fi

    docker run --network "$network_name" -d --name pse -p 12345:12345 \
        -e "INVISIRISK_JWT_TOKEN=$vb_api_key" \
        -e "GITHUB_TOKEN=$GITHUB_TOKEN" \
        -e "PSE_DEBUG_FLAG=--alsologtostderr" \
        -e "POLICY_LOG=t" \
        -e "INVISIRISK_PORTAL=$vb_api_url" \
        "${registry_id}.dkr.ecr.${region}.amazonaws.com/invisirisk/pse-proxy"

    log_info "VB Docker image started successfully."
}

# Main function
main() {
    log_info "Starting Pipeline Security Engine action..."

    # Get input variables
    VB_API_URL=${VB_API_URL:-}
    VB_API_KEY=${VB_API_KEY:-}
    GITHUB_TOKEN=${GITHUB_TOKEN:-}

    if [ -z "$VB_API_URL" ] || [ -z "$VB_API_KEY" ] || [ -z "$GITHUB_TOKEN" ]; then
        log_error "Required environment variables not set"
        exit 1
    }

    # Execute steps
    setup_docker

    scan_id=$(initiate_sbom_scan "$VB_API_URL" "$VB_API_KEY")
    log_info "Scan ID: $scan_id"

    ecr_creds=$(fetch_ecr_credentials "$VB_API_URL" "$VB_API_KEY")
    username=$(echo "$ecr_creds" | jq -r '.username')
    password=$(echo "$ecr_creds" | jq -r '.password')
    region=$(echo "$ecr_creds" | jq -r '.region')
    registry_id=$(echo "$ecr_creds" | jq -r '.registry_id')

    login_to_ecr "$username" "$password" "$registry_id" "$region"
    run_vb_image "$VB_API_URL" "$VB_API_KEY" "$registry_id" "$region"

    container_id=$(docker ps -aqf name=^pse$)
    export CONTAINER_ID="$container_id"
    log_info "Container ID: $container_id"

    setup_iptables
    setup_ca

    # Notify PSE of workflow start
    base="${GITHUB_SERVER_URL}/"
    repo="$GITHUB_REPOSITORY"
    log_info "Notifying PSE of workflow start for repository: $repo"

    curl -X POST "https://pse.invisirisk.com/start" \
        --data-urlencode "builder=github" \
        --data-urlencode "id=$scan_id" \
        --data-urlencode "build_id=$GITHUB_RUN_ID" \
        --data-urlencode "build_url=${base}${repo}/actions/runs/${GITHUB_RUN_ID}/attempts/${GITHUB_RUN_ATTEMPT}" \
        --data-urlencode "project=$GITHUB_REPOSITORY" \
        --data-urlencode "workflow=${GITHUB_WORKFLOW} - ${GITHUB_JOB}" \
        --data-urlencode "builder_url=$base" \
        --data-urlencode "scm=git" \
        --data-urlencode "scm_commit=$GITHUB_SHA" \
        --data-urlencode "scm_branch=$GITHUB_REF_NAME" \
        --data-urlencode "scm_origin=${base}${repo}"

    log_info "Pipeline Security Engine action completed successfully."
}

# Run main function
main