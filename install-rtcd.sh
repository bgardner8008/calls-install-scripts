#!/bin/bash
set -euo pipefail

# RTCD Installation Script for Linux
# This script installs rtcd as a systemd service
#
# Usage:
#   Online mode (downloads binary from GitHub):
#     sudo ./install-rtcd.sh
#
#   Air-gapped mode (uses a pre-downloaded binary):
#     sudo ./install-rtcd.sh /path/to/rtcd-linux-amd64 [--checksum /path/to/rtcd-checksums.txt]
#
#   In air-gapped mode, download the binary (and optionally the checksums file) from
#   https://github.com/mattermost/rtcd/releases on an internet-connected machine,
#   copy them to this machine, then run this script with the binary path as an argument.

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default values
DEFAULT_VERSION="v1.2.4"
INSTALL_DIR="/opt/rtcd"
RTCD_USER="rtcd"
RTCD_GROUP="rtcd"

# Parse arguments
AIRGAP_BINARY=""
AIRGAP_CHECKSUM_FILE=""

usage() {
    echo "Usage:"
    echo "  Online mode:    sudo $0"
    echo "  Air-gapped mode: sudo $0 <binary-path> [--checksum <checksums-file>]"
    echo ""
    echo "Arguments:"
    echo "  <binary-path>          Path to pre-downloaded rtcd binary (e.g. rtcd-linux-amd64)"
    echo "  --checksum <file>      Path to pre-downloaded checksums file (e.g. rtcd-checksums.txt)"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --checksum)
            if [[ -z "${2:-}" ]]; then
                echo "Error: --checksum requires a file argument"
                usage
            fi
            AIRGAP_CHECKSUM_FILE="$2"
            shift 2
            ;;
        --help|-h)
            usage
            ;;
        -*)
            echo "Unknown option: $1"
            usage
            ;;
        *)
            if [[ -n "$AIRGAP_BINARY" ]]; then
                echo "Error: unexpected argument '$1'"
                usage
            fi
            AIRGAP_BINARY="$1"
            shift
            ;;
    esac
done

AIRGAP_MODE=false
if [[ -n "$AIRGAP_BINARY" ]]; then
    AIRGAP_MODE=true
fi

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Cleanup function for error handling
cleanup_on_error() {
    log_error "Installation failed. Cleaning up..."
    if [[ "$AIRGAP_MODE" == false ]]; then
        rm -f /tmp/rtcd-linux-amd64
        rm -f /tmp/rtcd-checksums.txt
    fi
    exit 1
}

trap cleanup_on_error ERR

# Check if running as root or with sudo
if [[ $EUID -ne 0 ]]; then
   log_error "This script must be run as root or with sudo"
   exit 1
fi

# Validate air-gapped inputs before doing anything else
if [[ "$AIRGAP_MODE" == true ]]; then
    if [[ ! -f "$AIRGAP_BINARY" ]]; then
        log_error "Binary file not found: $AIRGAP_BINARY"
        exit 1
    fi
    if [[ ! -r "$AIRGAP_BINARY" ]]; then
        log_error "Binary file is not readable: $AIRGAP_BINARY"
        exit 1
    fi
    if [[ -n "$AIRGAP_CHECKSUM_FILE" ]]; then
        if [[ ! -f "$AIRGAP_CHECKSUM_FILE" ]]; then
            log_error "Checksum file not found: $AIRGAP_CHECKSUM_FILE"
            exit 1
        fi
        if [[ ! -r "$AIRGAP_CHECKSUM_FILE" ]]; then
            log_error "Checksum file is not readable: $AIRGAP_CHECKSUM_FILE"
            exit 1
        fi
    fi
    log_info "Air-gapped mode: using binary $AIRGAP_BINARY"
fi

# Check prerequisites
log_info "Checking prerequisites..."
MISSING_DEPS=()

REQUIRED_CMDS=(systemctl useradd)
if [[ "$AIRGAP_MODE" == false ]]; then
    REQUIRED_CMDS+=(wget)
fi

for cmd in "${REQUIRED_CMDS[@]}"; do
    if ! command -v "$cmd" &> /dev/null; then
        MISSING_DEPS+=("$cmd")
    fi
done

if [ ${#MISSING_DEPS[@]} -ne 0 ]; then
    log_error "Missing required dependencies: ${MISSING_DEPS[*]}"
    log_error "Please install them and try again"
    exit 1
fi

# Check if rtcd is already installed
if systemctl is-active --quiet rtcd 2>/dev/null; then
    log_warn "rtcd service is currently running"
    read -p "Do you want to stop and reinstall? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log_info "Stopping rtcd service..."
        systemctl stop rtcd
    else
        log_info "Installation cancelled"
        exit 0
    fi
fi

if [[ "$AIRGAP_MODE" == true ]]; then
    # Air-gapped: use the provided binary
    BINARY_SRC="$AIRGAP_BINARY"
    log_info "Installing rtcd from $(basename "$AIRGAP_BINARY")..."

    # Verify checksum against local checksums file if provided
    if [[ -n "$AIRGAP_CHECKSUM_FILE" ]]; then
        log_info "Verifying binary checksum..."
        if command -v sha256sum &> /dev/null; then
            BINARY_NAME=$(basename "$AIRGAP_BINARY")
            EXPECTED_CHECKSUM=$(grep "${BINARY_NAME}" "$AIRGAP_CHECKSUM_FILE" | awk '{print $1}' | head -1)
            if [[ -n "$EXPECTED_CHECKSUM" ]]; then
                ACTUAL_CHECKSUM=$(sha256sum "$AIRGAP_BINARY" | awk '{print $1}')
                if [[ "$EXPECTED_CHECKSUM" == "$ACTUAL_CHECKSUM" ]]; then
                    log_info "✓ Checksum verified successfully"
                else
                    log_error "Checksum verification failed!"
                    log_error "Expected: $EXPECTED_CHECKSUM"
                    log_error "Got:      $ACTUAL_CHECKSUM"
                    log_error "The binary may be corrupted or tampered with. Aborting."
                    exit 1
                fi
            else
                log_warn "Binary name '${BINARY_NAME}' not found in checksums file (skipping verification)"
            fi
        else
            log_warn "sha256sum not available, skipping checksum verification"
        fi
    else
        log_warn "No checksum file provided (skipping verification)"
        log_warn "To verify integrity, re-run with: --checksum /path/to/rtcd-checksums.txt"
    fi
else
    # Online mode: prompt for version and download
    echo ""
    log_info "Please enter the rtcd version to install"
    read -p "Version (default: ${DEFAULT_VERSION}): " RTCD_VERSION
    RTCD_VERSION=${RTCD_VERSION:-$DEFAULT_VERSION}

    # Ensure version starts with 'v'
    if [[ ! $RTCD_VERSION =~ ^v ]]; then
        RTCD_VERSION="v${RTCD_VERSION}"
    fi

    log_info "Installing rtcd ${RTCD_VERSION}..."

    # Download rtcd binary
    log_info "Downloading rtcd binary..."
    cd /tmp
    DOWNLOAD_URL="https://github.com/mattermost/rtcd/releases/download/${RTCD_VERSION}/rtcd-linux-amd64"

    if ! wget -q --show-progress "${DOWNLOAD_URL}"; then
        log_error "Failed to download rtcd from ${DOWNLOAD_URL}"
        log_error "Please verify the version exists at https://github.com/mattermost/rtcd/releases"
        exit 1
    fi

    BINARY_SRC="/tmp/rtcd-linux-amd64"

    # Verify checksum using GitHub API
    log_info "Verifying binary checksum..."
    if command -v sha256sum &> /dev/null && command -v curl &> /dev/null; then
        # Fetch expected checksum from GitHub API
        EXPECTED_CHECKSUM=$(curl -s "https://api.github.com/repos/mattermost/rtcd/releases/tags/${RTCD_VERSION}" \
            | grep '"digest"' | head -1 \
            | sed 's/.*sha256:\([^"]*\).*/\1/' 2>/dev/null)

        if [ -n "$EXPECTED_CHECKSUM" ] && [ "$EXPECTED_CHECKSUM" != "" ]; then
            # Compute actual checksum
            ACTUAL_CHECKSUM=$(sha256sum /tmp/rtcd-linux-amd64 | awk '{print $1}')

            if [ "$EXPECTED_CHECKSUM" = "$ACTUAL_CHECKSUM" ]; then
                log_info "✓ Checksum verified successfully"
            else
                log_warn "Checksum verification failed!"
                log_warn "Expected: $EXPECTED_CHECKSUM"
                log_warn "Got: $ACTUAL_CHECKSUM"
                log_warn "Continuing anyway, but binary may be corrupted"
            fi
        else
            log_info "Could not fetch checksum from GitHub API (skipping verification)"
        fi
    else
        if ! command -v sha256sum &> /dev/null; then
            log_info "sha256sum not available, skipping checksum verification"
        fi
        if ! command -v curl &> /dev/null; then
            log_info "curl not available, skipping checksum verification"
        fi
    fi
fi

# Create rtcd user if it doesn't exist
if ! id "$RTCD_USER" &>/dev/null; then
    log_info "Creating rtcd user..."
    useradd -r -s /bin/false "$RTCD_USER"
else
    log_info "User $RTCD_USER already exists"
fi

# Create directory structure
log_info "Creating directory structure..."
mkdir -p "${INSTALL_DIR}"/{config,logs,data}

# Install binary
log_info "Installing binary..."
cp "$BINARY_SRC" "${INSTALL_DIR}/rtcd"
chmod +x "${INSTALL_DIR}/rtcd"
# Remove downloaded temp file in online mode (air-gapped binary is the user's file; leave it)
if [[ "$AIRGAP_MODE" == false ]]; then
    rm -f "$BINARY_SRC"
fi

# Create config file
log_info "Creating configuration file..."
cat > "${INSTALL_DIR}/config/config.toml" <<'EOF'
[RTC]
ICEPortUDP = 8443

[API]
HTTP.ListenAddress = "0.0.0.0:8045"

[API.Security]
AllowSelfRegistration = true

[Store]
DataSource = "data/rtcd_db"

[Logger]
EnableConsole = true
ConsoleLevel = "INFO"
EnableFile = true
FileLocation = "logs/rtcd.log"
FileLevel = "INFO"
EOF

# Set ownership
log_info "Setting ownership..."
chown -R "${RTCD_USER}:${RTCD_GROUP}" "${INSTALL_DIR}"

# Verify binary installation
log_info "Verifying binary installation..."
if [ ! -x "${INSTALL_DIR}/rtcd" ]; then
    log_error "Binary is not executable"
    exit 1
fi
log_info "Binary installed successfully"

# Create systemd service
log_info "Creating systemd service..."
cat > /etc/systemd/system/rtcd.service <<'EOF'
[Unit]
Description=Mattermost rtcd Service
After=network.target

[Service]
Type=simple
User=rtcd
Group=rtcd
WorkingDirectory=/opt/rtcd
ExecStart=/opt/rtcd/rtcd --config config/config.toml
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

# Security settings
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

# Check if required ports are available
log_info "Checking port availability..."
PORT_CONFLICTS=()

# Check TCP port 8045 (API)
if ss -ltn 2>/dev/null | grep -q ":8045 " || netstat -ltn 2>/dev/null | grep -q ":8045 "; then
    PORT_CONFLICTS+=("8045/tcp (API)")
fi

# Check UDP port 8443 (RTC)
if ss -lun 2>/dev/null | grep -q ":8443 " || netstat -lun 2>/dev/null | grep -q ":8443 "; then
    PORT_CONFLICTS+=("8443/udp (RTC)")
fi

# Check TCP port 8443 (RTC fallback)
if ss -ltn 2>/dev/null | grep -q ":8443 " || netstat -ltn 2>/dev/null | grep -q ":8443 "; then
    PORT_CONFLICTS+=("8443/tcp (RTC)")
fi

if [ ${#PORT_CONFLICTS[@]} -ne 0 ]; then
    log_warn "The following required ports are already in use:"
    for port in "${PORT_CONFLICTS[@]}"; do
        echo "  - $port"
    done
    echo ""
    log_warn "This may be caused by:"
    echo "  - Mattermost server running in Docker (uses same ports)"
    echo "  - Another rtcd instance already running"
    echo "  - Other services using these ports"
    echo ""
    log_info "You can check what's using the ports with:"
    echo "  sudo ss -lptn | grep ':8045\\|:8443'"
    echo "  sudo ss -lpun | grep ':8443'"
    echo ""
    read -p "Do you want to continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Installation cancelled. Please free the ports and try again."
        exit 0
    fi
    log_warn "Continuing despite port conflicts..."
fi

# Reload systemd and enable service
log_info "Configuring systemd service..."
systemctl daemon-reload
systemctl enable rtcd

# Start the service
log_info "Starting rtcd service..."
if systemctl start rtcd; then
    log_info "Service started successfully"
else
    log_error "Failed to start service"
    echo ""
    systemctl status rtcd --no-pager
    echo ""
    log_error "Common causes:"
    echo "  - Ports 8443 or 8045 already in use (check with: sudo ss -lptn | grep ':8045\\|:8443')"
    echo "  - Config file errors"
    echo "  - View detailed logs: journalctl -u rtcd -n 50 --no-pager"
    exit 1
fi

# Wait a moment for service to initialize
sleep 2

# Check service status
if systemctl is-active --quiet rtcd; then
    log_info "✓ rtcd installation completed successfully!"
    echo ""
    log_info "Service status:"
    systemctl status rtcd --no-pager -l
    echo ""
    log_info "Useful commands:"
    echo "  - Check version: curl http://localhost:8045/version"
    echo "  - View logs: journalctl -u rtcd -f"
    echo "  - Stop service: systemctl stop rtcd"
    echo "  - Start service: systemctl start rtcd"
    echo "  - Restart service: systemctl restart rtcd"
    echo "  - Edit config: ${INSTALL_DIR}/config/config.toml"
    echo ""
    log_warn "IMPORTANT: Configure your firewall to allow:"
    log_warn "  - UDP port 8443 (RTC/ICE traffic)"
    log_warn "  - TCP port 8045 (API access)"
    echo ""
    log_warn "Example firewall commands:"
    echo "  # Using ufw:"
    echo "  sudo ufw allow 8443/udp"
    echo "  sudo ufw allow 8045/tcp"
    echo ""
    echo "  # Using firewalld:"
    echo "  sudo firewall-cmd --permanent --add-port=8443/udp"
    echo "  sudo firewall-cmd --permanent --add-port=8045/tcp"
    echo "  sudo firewall-cmd --reload"
    echo ""
    log_info "Configuration file location: ${INSTALL_DIR}/config/config.toml"
    log_info "You may need to update ICEHostOverride if behind NAT"
else
    log_error "Service is not running"
    echo ""
    systemctl status rtcd --no-pager
    echo ""
    log_error "Check logs for details: journalctl -u rtcd -n 50 --no-pager"
    exit 1
fi

