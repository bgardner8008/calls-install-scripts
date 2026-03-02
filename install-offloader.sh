#!/bin/bash

# install-offloader.sh — Install calls-offloader as a Linux systemd service.
# Works for both internet-connected (downloads binary) and air-gapped (uses local binary) installs.
#
# Usage:
#   Internet:  sudo ./install-offloader.sh --version v0.9.4
#   Air-gap:   sudo ./install-offloader.sh --binary ./calls-offloader-linux-amd64
#
# See: https://github.com/mattermost/calls-offloader/blob/master/docs/getting_started.md

set -eo pipefail

INSTALL_PATH="/usr/local/bin/calls-offloader"
SERVICE_FILE="/lib/systemd/system/calls-offloader.service"
SERVICE_USER="mattermost"
DEFAULT_PORT="4545"
GITHUB_BASE="https://github.com/mattermost/calls-offloader/releases/download"

usage() {
    echo "Usage: sudo $0 [OPTIONS]"
    echo ""
    echo "One of --version or --binary is required."
    echo ""
    echo "Options:"
    echo "  --version VERSION        Download this version from GitHub releases (e.g. v0.9.4)"
    echo "  --binary PATH            Use a local binary file (for air-gapped installs)"
    echo "  --arch amd64|arm64       CPU architecture for download (default: auto-detected)"
    echo "  --port PORT              Listening port (default: $DEFAULT_PORT)"
    echo "  --image-registry VALUE   Docker image registry prefix (e.g. localhost:5000/mattermost)"
    echo "                           Required for air-gapped deployments"
    echo "  --no-self-registration   Disable automatic client self-registration"
    echo ""
    echo "Examples:"
    echo "  sudo $0 --version v0.9.4"
    echo "  sudo $0 --version v0.9.4 --image-registry localhost:5000/mattermost"
    echo "  sudo $0 --binary ./calls-offloader-linux-amd64 --image-registry localhost:5000/mattermost"
    exit 1
}

OFFLOADER_VERSION=""
BINARY_PATH=""
ARCH=""
PORT="$DEFAULT_PORT"
IMAGE_REGISTRY=""
SELF_REGISTRATION="true"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            if [ -z "${2:-}" ]; then echo "ERROR: --version requires a value"; usage; fi
            OFFLOADER_VERSION="$2"; shift 2 ;;
        --binary)
            if [ -z "${2:-}" ]; then echo "ERROR: --binary requires a path"; usage; fi
            BINARY_PATH="$2"; shift 2 ;;
        --arch)
            if [ -z "${2:-}" ]; then echo "ERROR: --arch requires a value"; usage; fi
            ARCH="$2"; shift 2 ;;
        --port)
            if [ -z "${2:-}" ]; then echo "ERROR: --port requires a value"; usage; fi
            PORT="$2"; shift 2 ;;
        --image-registry)
            if [ -z "${2:-}" ]; then echo "ERROR: --image-registry requires a value"; usage; fi
            IMAGE_REGISTRY="$2"; shift 2 ;;
        --no-self-registration)
            SELF_REGISTRATION="false"; shift ;;
        --help|-h) usage ;;
        *) echo "ERROR: Unknown argument: $1"; echo ""; usage ;;
    esac
done

# Require exactly one of --version or --binary
if [ -z "$OFFLOADER_VERSION" ] && [ -z "$BINARY_PATH" ]; then
    echo "ERROR: One of --version or --binary is required"
    echo ""
    usage
fi
if [ -n "$OFFLOADER_VERSION" ] && [ -n "$BINARY_PATH" ]; then
    echo "ERROR: --version and --binary are mutually exclusive"
    echo ""
    usage
fi

if [ -n "$OFFLOADER_VERSION" ] && [[ ! $OFFLOADER_VERSION =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: Invalid version format: $OFFLOADER_VERSION (expected vX.Y.Z)"
    exit 1
fi
if [ -n "$BINARY_PATH" ] && [ ! -f "$BINARY_PATH" ]; then
    echo "ERROR: Binary file not found: $BINARY_PATH"
    exit 1
fi
if [ -n "$ARCH" ] && [ "$ARCH" != "amd64" ] && [ "$ARCH" != "arm64" ]; then
    echo "ERROR: --arch must be amd64 or arm64"
    exit 1
fi
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    echo "ERROR: Invalid port: $PORT"
    exit 1
fi

# Auto-detect arch when downloading
if [ -z "$ARCH" ] && [ -n "$OFFLOADER_VERSION" ]; then
    case "$(uname -m)" in
        x86_64)        ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        *)
            echo "ERROR: Unsupported architecture: $(uname -m)"
            echo "Specify --arch amd64 or --arch arm64"
            exit 1 ;;
    esac
fi

LOG_FILE=/tmp/install-offloader.log

echo "Installing calls-offloader" | tee $LOG_FILE
if [ -n "$OFFLOADER_VERSION" ]; then
    echo "  Version:        $OFFLOADER_VERSION ($ARCH)" | tee -a $LOG_FILE
else
    echo "  Binary:         $BINARY_PATH" | tee -a $LOG_FILE
fi
echo "  Port:           $PORT" | tee -a $LOG_FILE
if [ -n "$IMAGE_REGISTRY" ]; then
    echo "  Image registry: $IMAGE_REGISTRY" | tee -a $LOG_FILE
fi
echo "" | tee -a $LOG_FILE

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo "ERROR: This script must be run as root (use sudo)"
        exit 1
    fi
}

# Sets DOWNLOADED_BINARY to the path of the downloaded file
DOWNLOADED_BINARY=""
download_binary() {
    local url="$GITHUB_BASE/$OFFLOADER_VERSION/calls-offloader-linux-$ARCH"
    DOWNLOADED_BINARY="/tmp/calls-offloader-$OFFLOADER_VERSION-linux-$ARCH"
    echo "Downloading binary..." | tee -a $LOG_FILE
    echo "  $url" | tee -a $LOG_FILE
    if command -v curl > /dev/null 2>&1; then
        curl -fL --progress-bar "$url" -o "$DOWNLOADED_BINARY"
    elif command -v wget > /dev/null 2>&1; then
        wget -q --show-progress "$url" -O "$DOWNLOADED_BINARY"
    else
        echo "ERROR: Neither curl nor wget is available" | tee -a $LOG_FILE
        exit 1
    fi
    echo "" | tee -a $LOG_FILE
}

setup_user() {
    echo "Setting up $SERVICE_USER system user..." | tee -a $LOG_FILE
    if ! id "$SERVICE_USER" > /dev/null 2>&1; then
        useradd --system --user-group "$SERVICE_USER"
        echo "  Created $SERVICE_USER system user" | tee -a $LOG_FILE
    else
        echo "  User $SERVICE_USER already exists" | tee -a $LOG_FILE
    fi
    if getent group docker > /dev/null 2>&1; then
        usermod -a -G docker "$SERVICE_USER"
        echo "  Added $SERVICE_USER to docker group" | tee -a $LOG_FILE
    else
        echo "  WARNING: docker group not found — ensure Docker is installed before starting the service" | tee -a $LOG_FILE
    fi
}

install_binary() {
    local src="$1"
    echo "Installing binary to $INSTALL_PATH..." | tee -a $LOG_FILE
    cp "$src" "$INSTALL_PATH"
    chown "$SERVICE_USER:$SERVICE_USER" "$INSTALL_PATH"
    chmod +x "$INSTALL_PATH"
}

write_service_file() {
    echo "Writing systemd service file to $SERVICE_FILE..." | tee -a $LOG_FILE

    # Build Environment= lines. Note: envconfig derives var names from struct field
    # names (not TOML keys), so e.g. Jobs.ImageRegistry -> JOBS_IMAGEREGISTRY.
    local env_lines
    env_lines="Environment=API_SECURITY_ALLOWSELFREGISTRATION=$SELF_REGISTRATION"
    if [ "$PORT" != "$DEFAULT_PORT" ]; then
        env_lines="$env_lines
Environment=API_HTTP_LISTENADDRESS=:$PORT"
    fi
    if [ -n "$IMAGE_REGISTRY" ]; then
        env_lines="$env_lines
Environment=JOBS_IMAGEREGISTRY=$IMAGE_REGISTRY"
    fi

    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=calls-offloader
After=network.target

[Service]
Type=simple
ExecStart=$INSTALL_PATH
Restart=always
RestartSec=10
User=$SERVICE_USER
Group=$SERVICE_USER
$env_lines

[Install]
WantedBy=multi-user.target
EOF
}

enable_or_restart_service() {
    systemctl daemon-reload
    if systemctl is-active --quiet calls-offloader 2>/dev/null; then
        echo "Restarting calls-offloader service..." | tee -a $LOG_FILE
        systemctl restart calls-offloader
    else
        echo "Enabling and starting calls-offloader service..." | tee -a $LOG_FILE
        systemctl enable --now calls-offloader
    fi
}

verify_service() {
    echo "Verifying service..." | tee -a $LOG_FILE
    local i=0
    while [ $i -lt 5 ]; do
        if curl -sf "http://localhost:$PORT/version" > /dev/null 2>&1; then
            local info
            info=$(curl -sf "http://localhost:$PORT/version")
            echo "  Service is running: $info" | tee -a $LOG_FILE
            return 0
        fi
        i=$((i+1))
        sleep 2
    done
    echo "  WARNING: Service did not respond at http://localhost:$PORT/version" | tee -a $LOG_FILE
    echo "  Check status: systemctl status calls-offloader" | tee -a $LOG_FILE
}

main() {
    check_root

    local binary_src
    if [ -n "$OFFLOADER_VERSION" ]; then
        download_binary
        binary_src="$DOWNLOADED_BINARY"
    else
        binary_src="$BINARY_PATH"
    fi

    setup_user
    install_binary "$binary_src"
    write_service_file
    enable_or_restart_service
    verify_service

    echo "" | tee -a $LOG_FILE
    echo "=== Installation Complete ===" | tee -a $LOG_FILE
    echo "" | tee -a $LOG_FILE
    echo "Service commands:" | tee -a $LOG_FILE
    echo "  Status:  systemctl status calls-offloader" | tee -a $LOG_FILE
    echo "  Logs:    journalctl -u calls-offloader -f" | tee -a $LOG_FILE
    echo "  Version: curl http://localhost:$PORT/version" | tee -a $LOG_FILE
    echo "" | tee -a $LOG_FILE
    echo "Configure the Mattermost Calls plugin:" | tee -a $LOG_FILE
    echo "  Set 'Job service URL' to: http://<this-host>:$PORT" | tee -a $LOG_FILE
    echo "" | tee -a $LOG_FILE
    echo "Full configuration reference:" | tee -a $LOG_FILE
    echo "  https://github.com/mattermost/calls-offloader/blob/master/config/config.sample.toml" | tee -a $LOG_FILE
    echo "Log file: $LOG_FILE" | tee -a $LOG_FILE
}

main "$@"
