#!/bin/bash
set -euo pipefail

# Bootstrap script for pse-data-collector
# Downloads and installs the pse-data-collector binary

API_URL="${API_URL:-}"
API_KEY="${API_KEY:-}"
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
VERSION="${VERSION:-}"
DEBUG="${DEBUG:-false}"

log() { echo "[pse][$(date '+%H:%M:%S')] $*" >&2; }
debug_log() { [ "$DEBUG" = "true" ] && echo "[pse][DEBUG][$(date '+%H:%M:%S')] $*" >&2 || true; }

# Ensure prerequisites are installed:
#   iproute2 — needed for `ip route` to resolve the docker gateway IP
#   iptables  — needed for NAT rules that redirect traffic through PSE proxy
_missing_pkgs=""
command -v ip       >/dev/null 2>&1 || _missing_pkgs="$_missing_pkgs iproute2"
command -v iptables >/dev/null 2>&1 || _missing_pkgs="$_missing_pkgs iptables"
if [ -n "$_missing_pkgs" ]; then
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq && apt-get install -y -qq $_missing_pkgs >/dev/null 2>&1
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache $_missing_pkgs >/dev/null 2>&1
    fi
fi
unset _missing_pkgs

curl_get() {
    local url="$1"
    debug_log "GET $url"
    if [ "$DEBUG" = "true" ]; then
        # Show full response body even on HTTP error
        HTTP_CODE=$(curl -sS -w "\n%{http_code}" -o /tmp/pse_curl_body "$url" 2>&1 || true)
        BODY=$(cat /tmp/pse_curl_body 2>/dev/null || true)
        STATUS=$(echo "$HTTP_CODE" | tail -1)
        debug_log "HTTP status: $STATUS"
        debug_log "Response body: $BODY"
        if [ "$STATUS" != "200" ]; then
            echo "[pse][ERROR] Request failed with HTTP $STATUS: $BODY" >&2
            exit 1
        fi
        echo "$BODY"
    else
        curl -sSf "$url"
    fi
}

if [ -z "$API_URL" ] || [ -z "$API_KEY" ]; then
    echo "Usage: API_URL=<url> API_KEY=<key> bash bootstrap_collector.sh"
    echo "  API_URL: Base URL of the upload API"
    echo "  API_KEY: API key for authentication"
    exit 1
fi

# Detect OS
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$OS" in
    linux)  OS="linux" ;;
    darwin) OS="darwin" ;;
    *)
        echo "Unsupported OS: $OS"
        exit 1
        ;;
esac

# Detect architecture
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *)
        echo "Unsupported architecture: $ARCH"
        exit 1
        ;;
esac

log "Detected OS=$OS arch=$ARCH"
debug_log "API_URL=$API_URL"
debug_log "INSTALL_DIR=$INSTALL_DIR"
debug_log "VERSION=${VERSION:-latest}"

# Build download URL
DOWNLOAD_QUERY="arch=${ARCH}&os=${OS}&api_key=${API_KEY}"
if [ -n "$VERSION" ]; then
    DOWNLOAD_QUERY="${DOWNLOAD_QUERY}&version=${VERSION}"
fi

# Get presigned download URL — API_URL is the bare base URL, /ingestionapi/v1 is baked in here
log "Fetching download URL for pse-data-collector..."
RESPONSE=$(curl_get "${API_URL}/ingestionapi/v1/pse-data-collector/download?${DOWNLOAD_QUERY}")
debug_log "Download URL response: $RESPONSE"
DOWNLOAD_URL=$(echo "$RESPONSE" | grep -o '"download_url":"[^"]*"' | cut -d'"' -f4)

if [ -z "$DOWNLOAD_URL" ]; then
    echo "[pse][ERROR] Failed to get download URL. Full response: $RESPONSE" >&2
    exit 1
fi
debug_log "Resolved download URL: $DOWNLOAD_URL"

# Download binary directly
log "Downloading pse-data-collector..."
TEMP_BIN=$(mktemp)
curl -sSf -o "$TEMP_BIN" "$DOWNLOAD_URL"
chmod +x "$TEMP_BIN"

# Install
log "Installing to ${INSTALL_DIR}/pse-data-collector..."
if [ "$(id -u)" = "0" ]; then
    mv "$TEMP_BIN" "${INSTALL_DIR}/pse-data-collector"
else
    sudo mv "$TEMP_BIN" "${INSTALL_DIR}/pse-data-collector"
fi

log "pse-data-collector installed successfully"
