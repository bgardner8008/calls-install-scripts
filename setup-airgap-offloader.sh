#!/bin/bash

# Air-Gap Docker Registry Setup for Mattermost Calls
# Run this script on an internet-connected machine (Linux or macOS with Docker Desktop/OrbStack)
# to download required artifacts and prepare a transfer bundle for air-gapped deployment.
# To deploy on the air-gapped machine, use the generated deploy-airgap-offloader.sh (Linux only).
#
# Usage: ./setup-airgap-offloader.sh [OPTIONS]
# At least one of --recorder, --transcriber, or --offloader is required.
# Example: ./setup-airgap-offloader.sh --recorder v0.8.8 --transcriber v0.7.1 --offloader v0.9.4

set -eo pipefail

GITHUB_BASE="https://github.com/mattermost/calls-offloader/releases/download"

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Before running script, determine the latest versions to install, see below."
    echo "The versions used in following examples are out of date."
    echo ""
    echo "This script runs in two steps:"
    echo "  1. Run on an internet-connected machine to download artifacts (images, binary)."
    echo "  2. Transfer the generated files to the air-gapped machine and run deploy-airgap-offloader.sh."
    echo ""
    echo "Options (at least one required):"
    echo "  --recorder VERSION     Version of mattermost/calls-recorder image (e.g., v0.8.8)"
    echo "  --transcriber VERSION  Version of mattermost/calls-transcriber image (e.g., v0.7.1)"
    echo "  --offloader VERSION    Version of calls-offloader binary to download (e.g., v0.9.4)"
    echo "  --arch amd64|arm64     Target CPU architecture: controls offloader binary and Docker image"
    echo "                         platform (default: amd64)"
    echo ""
    echo "Examples:"
    echo "  $0 --recorder v0.8.8 --transcriber v0.7.1 --offloader v0.9.4"
    echo "  $0 --recorder v0.8.8 --transcriber v0.7.1"
    echo "  $0 --offloader v0.9.4"
    echo ""
    echo "To find the correct versions for your Calls plugin:"
    echo "1. Check your Calls plugin version in System Console > Plugins > Plugin Management"
    echo "2. Visit: https://github.com/mattermost/mattermost-plugin-calls/blob/v<YOUR_VERSION>/plugin.json"
    echo "3. Look for 'calls_recorder_version' and 'calls_transcriber_version' entries"
    echo "4. Use the latest version of calls-offloader found on github release page"
    echo ""
    echo "Environment variables (optional):"
    echo "  REGISTRY_HOST  Docker registry host on the air-gapped machine (default: localhost)"
    echo "  REGISTRY_PORT  Docker registry port on the air-gapped machine (default: 5000)"
    exit 1
}

validate_version() {
    local version=$1
    local name=$2
    if [[ ! $version =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "ERROR: Invalid version format for $name: $version"
        echo "Expected format: vX.Y.Z (e.g., v0.8.5)"
        exit 1
    fi
}

CALLS_RECORDER_VERSION=""
CALLS_TRANSCRIBER_VERSION=""
CALLS_OFFLOADER_VERSION=""
OFFLOADER_ARCH="amd64"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --recorder)
            if [ -z "${2:-}" ]; then echo "ERROR: --recorder requires a version argument"; echo ""; usage; fi
            CALLS_RECORDER_VERSION="$2"; shift 2 ;;
        --transcriber)
            if [ -z "${2:-}" ]; then echo "ERROR: --transcriber requires a version argument"; echo ""; usage; fi
            CALLS_TRANSCRIBER_VERSION="$2"; shift 2 ;;
        --offloader)
            if [ -z "${2:-}" ]; then echo "ERROR: --offloader requires a version argument"; echo ""; usage; fi
            CALLS_OFFLOADER_VERSION="$2"; shift 2 ;;
        --arch)
            if [ -z "${2:-}" ]; then echo "ERROR: --arch requires a value"; echo ""; usage; fi
            OFFLOADER_ARCH="$2"; shift 2 ;;
        --help|-h) usage ;;
        *) echo "ERROR: Unknown argument: $1"; echo ""; usage ;;
    esac
done

if [ -z "$CALLS_RECORDER_VERSION" ] && [ -z "$CALLS_TRANSCRIBER_VERSION" ] && [ -z "$CALLS_OFFLOADER_VERSION" ]; then
    echo "ERROR: At least one of --recorder, --transcriber, or --offloader must be specified"
    echo ""
    usage
fi

if [ -n "$OFFLOADER_ARCH" ] && [ "$OFFLOADER_ARCH" != "amd64" ] && [ "$OFFLOADER_ARCH" != "arm64" ]; then
    echo "ERROR: --arch must be amd64 or arm64"
    exit 1
fi

if [ -n "$CALLS_RECORDER_VERSION" ]; then
    validate_version "$CALLS_RECORDER_VERSION" "calls-recorder"
fi
if [ -n "$CALLS_TRANSCRIBER_VERSION" ]; then
    validate_version "$CALLS_TRANSCRIBER_VERSION" "calls-transcriber"
fi
if [ -n "$CALLS_OFFLOADER_VERSION" ]; then
    validate_version "$CALLS_OFFLOADER_VERSION" "calls-offloader"
fi

REGISTRY_HOST="${REGISTRY_HOST:-localhost}"
REGISTRY_PORT="${REGISTRY_PORT:-5000}"

LOG_FILE=/tmp/air-gap-registry-setup.log

echo "Air-Gap Bundle Preparation for Mattermost Calls Offloader" | tee $LOG_FILE
if [ -n "$CALLS_RECORDER_VERSION" ]; then
    echo "  Recorder version:    $CALLS_RECORDER_VERSION (linux/$OFFLOADER_ARCH)" | tee -a $LOG_FILE
fi
if [ -n "$CALLS_TRANSCRIBER_VERSION" ]; then
    echo "  Transcriber version: $CALLS_TRANSCRIBER_VERSION (linux/$OFFLOADER_ARCH)" | tee -a $LOG_FILE
fi
if [ -n "$CALLS_OFFLOADER_VERSION" ]; then
    echo "  Offloader version:   $CALLS_OFFLOADER_VERSION (linux/$OFFLOADER_ARCH)" | tee -a $LOG_FILE
fi
echo "" | tee -a $LOG_FILE

check_docker() {
    if ! docker info > /dev/null 2>&1; then
        echo "ERROR: Docker is not running or not accessible." | tee -a $LOG_FILE
        echo "Please start Docker and try again." | tee -a $LOG_FILE
        exit 1
    fi
}

check_internet() {
    if ! curl -s --connect-timeout 5 https://hub.docker.com > /dev/null 2>&1; then
        echo "ERROR: Internet access is required to run this script." | tee -a $LOG_FILE
        echo "To deploy on an air-gapped machine, use deploy-airgap-offloader.sh instead." | tee -a $LOG_FILE
        exit 1
    fi
}

pull_and_save_images() {
    echo "Pulling images from Docker Hub (platform: linux/$OFFLOADER_ARCH)..." | tee -a $LOG_FILE
    if [ -n "$CALLS_RECORDER_VERSION" ]; then
        docker pull --platform linux/$OFFLOADER_ARCH mattermost/calls-recorder:$CALLS_RECORDER_VERSION 2>&1 | tee -a $LOG_FILE
    fi
    if [ -n "$CALLS_TRANSCRIBER_VERSION" ]; then
        docker pull --platform linux/$OFFLOADER_ARCH mattermost/calls-transcriber:$CALLS_TRANSCRIBER_VERSION 2>&1 | tee -a $LOG_FILE
    fi
    docker pull --platform linux/$OFFLOADER_ARCH registry:2 2>&1 | tee -a $LOG_FILE

    echo "" | tee -a $LOG_FILE
    echo "Saving images to archives..." | tee -a $LOG_FILE

    if [ -n "$CALLS_RECORDER_VERSION" ]; then
        docker save mattermost/calls-recorder:$CALLS_RECORDER_VERSION | gzip > calls-recorder-$CALLS_RECORDER_VERSION.tar.gz
        echo "  Saved $(pwd)/calls-recorder-$CALLS_RECORDER_VERSION.tar.gz" | tee -a $LOG_FILE
    fi
    if [ -n "$CALLS_TRANSCRIBER_VERSION" ]; then
        docker save mattermost/calls-transcriber:$CALLS_TRANSCRIBER_VERSION | gzip > calls-transcriber-$CALLS_TRANSCRIBER_VERSION.tar.gz
        echo "  Saved $(pwd)/calls-transcriber-$CALLS_TRANSCRIBER_VERSION.tar.gz" | tee -a $LOG_FILE
    fi
    docker save registry:2 | gzip > registry-2.tar.gz
    echo "  Saved $(pwd)/registry-2.tar.gz" | tee -a $LOG_FILE
}

download_offloader_binary() {
    local url="$GITHUB_BASE/$CALLS_OFFLOADER_VERSION/calls-offloader-linux-$OFFLOADER_ARCH"
    local dest="./calls-offloader-linux-$OFFLOADER_ARCH"
    echo "Downloading calls-offloader binary..." | tee -a $LOG_FILE
    echo "  $url" | tee -a $LOG_FILE
    if command -v curl > /dev/null 2>&1; then
        curl -fL --progress-bar "$url" -o "$dest"
    elif command -v wget > /dev/null 2>&1; then
        wget -q --show-progress "$url" -O "$dest"
    else
        echo "ERROR: Neither curl nor wget is available" | tee -a $LOG_FILE
        exit 1
    fi
    echo "  Saved $(pwd)/calls-offloader-linux-$OFFLOADER_ARCH" | tee -a $LOG_FILE
    echo "" | tee -a $LOG_FILE
}

create_airgap_deployment_script() {
    echo "" | tee -a $LOG_FILE
    echo "Generating deploy-airgap-offloader.sh..." | tee -a $LOG_FILE

    local script="./deploy-airgap-offloader.sh"

    # Header — unquoted heredoc so we can embed generation-time values now.
    # Deploy-time shell variables are escaped as \$ to appear literally in output.
    cat > "$script" << EOF
#!/bin/bash

# Air-Gap Offloader Deployment Script
# Generated by setup-airgap-offloader.sh
# Recorder version:    ${CALLS_RECORDER_VERSION:-not included}
# Transcriber version: ${CALLS_TRANSCRIBER_VERSION:-not included}
# Offloader version:   ${CALLS_OFFLOADER_VERSION:-not included} ${CALLS_OFFLOADER_VERSION:+($OFFLOADER_ARCH)}
#
# Run this script on the air-gapped machine from the directory containing the transferred files.
# Usage: ./deploy-airgap-offloader.sh

set -e

REGISTRY_HOST="\${REGISTRY_HOST:-$REGISTRY_HOST}"
REGISTRY_PORT="\${REGISTRY_PORT:-$REGISTRY_PORT}"

echo "Deploying Mattermost Calls Offloader in air-gapped environment..."
echo "Registry: \$REGISTRY_HOST:\$REGISTRY_PORT"
echo ""
EOF

    # Image sections — only included when Docker images are in the bundle
    if [ -n "$CALLS_RECORDER_VERSION" ] || [ -n "$CALLS_TRANSCRIBER_VERSION" ]; then

        # Load images — single-quoted heredoc, no variable expansion, all $ are deploy-time
        cat >> "$script" << 'LOAD_SECTION'
# Load Docker images
echo "Loading Docker images..."
docker load < registry-2.tar.gz
LOAD_SECTION
        # Append per-image load lines with versions embedded at generation time
        [ -n "$CALLS_RECORDER_VERSION" ]    && echo "docker load < calls-recorder-$CALLS_RECORDER_VERSION.tar.gz"    >> "$script"
        [ -n "$CALLS_TRANSCRIBER_VERSION" ] && echo "docker load < calls-transcriber-$CALLS_TRANSCRIBER_VERSION.tar.gz" >> "$script"
        echo 'echo ""' >> "$script"
        echo "" >> "$script"

        # Docker daemon config and local registry startup — single-quoted heredoc
        cat >> "$script" << 'REGISTRY_SECTION'
# Configure Docker daemon for insecure local registry
echo "Configuring Docker daemon..."
sudo mkdir -p /etc/docker
DAEMON_JSON="/etc/docker/daemon.json"
REGISTRY_ENTRY="$REGISTRY_HOST:$REGISTRY_PORT"
if [ -f "$DAEMON_JSON" ]; then
    BACKUP="$DAEMON_JSON.backup.$(date +%Y%m%d_%H%M%S)"
    sudo cp "$DAEMON_JSON" "$BACKUP"
    echo "  Backed up existing daemon.json to $BACKUP"
    if ! command -v jq > /dev/null 2>&1; then
        echo "ERROR: jq is required. Install with: apt-get install jq / yum install jq"
        exit 1
    fi
    sudo jq --arg reg "$REGISTRY_ENTRY" \
        'if (.["insecure-registries"] | index($reg)) == null then .["insecure-registries"] += [$reg] else . end' \
        "$DAEMON_JSON" | sudo tee "$DAEMON_JSON.tmp" > /dev/null && sudo mv "$DAEMON_JSON.tmp" "$DAEMON_JSON"
else
    echo "{\"insecure-registries\": [\"$REGISTRY_ENTRY\"]}" | sudo tee "$DAEMON_JSON" > /dev/null
fi
sudo systemctl restart docker
sleep 10
echo ""

# Start local registry
echo "Starting local Docker registry..."
docker stop local-registry 2>/dev/null || true
docker rm local-registry 2>/dev/null || true
docker run -d \
    --name local-registry \
    --restart=always \
    -p $REGISTRY_PORT:5000 \
    registry:2
sleep 5
echo ""

# Tag and push images to local registry
echo "Pushing images to local registry..."
REGISTRY_SECTION

        # Push commands — unquoted heredoc: versions embedded now, \$ for deploy-time vars
        if [ -n "$CALLS_RECORDER_VERSION" ]; then
            cat >> "$script" << EOF
docker tag mattermost/calls-recorder:$CALLS_RECORDER_VERSION \$REGISTRY_HOST:\$REGISTRY_PORT/mattermost/calls-recorder:$CALLS_RECORDER_VERSION
docker push \$REGISTRY_HOST:\$REGISTRY_PORT/mattermost/calls-recorder:$CALLS_RECORDER_VERSION
EOF
        fi
        if [ -n "$CALLS_TRANSCRIBER_VERSION" ]; then
            cat >> "$script" << EOF
docker tag mattermost/calls-transcriber:$CALLS_TRANSCRIBER_VERSION \$REGISTRY_HOST:\$REGISTRY_PORT/mattermost/calls-transcriber:$CALLS_TRANSCRIBER_VERSION
docker push \$REGISTRY_HOST:\$REGISTRY_PORT/mattermost/calls-transcriber:$CALLS_TRANSCRIBER_VERSION
EOF
        fi
        echo 'echo ""' >> "$script"
        echo "" >> "$script"
    fi

    # Offloader section — mutually exclusive with the manual-note fallback
    if [ -n "$CALLS_OFFLOADER_VERSION" ]; then
        # Invoke install-offloader.sh with arch and registry embedded at generation time
        cat >> "$script" << EOF
# Install calls-offloader service
echo "Installing calls-offloader..."
sudo ./install-offloader.sh \\
    --binary ./calls-offloader-linux-$OFFLOADER_ARCH \\
    --image-registry \$REGISTRY_HOST:\$REGISTRY_PORT/mattermost
echo ""
EOF
    elif [ -n "$CALLS_RECORDER_VERSION" ] || [ -n "$CALLS_TRANSCRIBER_VERSION" ]; then
        # Images only — tell the operator to update their existing offloader config
        cat >> "$script" << 'NOTE_SECTION'
echo "NOTE: Update your calls-offloader image registry setting to:"
echo "  $REGISTRY_HOST:$REGISTRY_PORT/mattermost"
echo "Then restart: sudo systemctl restart calls-offloader"
echo ""
NOTE_SECTION
    fi

    # Footer — single-quoted heredoc
    cat >> "$script" << 'FOOTER'
echo "=== Deployment Complete ==="
echo ""
echo "IMPORTANT: On the Mattermost server, ensure the Calls plugin Job service URL"
echo "points to this offloader, then restart the Calls plugin to pick up the new registry."
FOOTER

    chmod +x "$script"
    echo "  Generated $(pwd)/deploy-airgap-offloader.sh" | tee -a $LOG_FILE
}

copy_install_script() {
    local script_dir
    script_dir=$(cd "$(dirname "$0")" && pwd)
    local src="$script_dir/install-offloader.sh"
    local dest="$(pwd)/install-offloader.sh"

    if [ ! -f "$src" ]; then
        echo "WARNING: install-offloader.sh not found in $script_dir" | tee -a $LOG_FILE
        echo "  Please copy install-offloader.sh into the transfer bundle manually." | tee -a $LOG_FILE
        return
    fi

    if [ "$src" = "$dest" ]; then
        echo "  install-offloader.sh is already in the bundle directory" | tee -a $LOG_FILE
        return
    fi

    cp "$src" "$dest"
    chmod +x "$dest"
    echo "  Copied $(pwd)/install-offloader.sh" | tee -a $LOG_FILE
}

main() {
    check_internet

    # Docker is only needed when downloading images
    if [ -n "$CALLS_RECORDER_VERSION" ] || [ -n "$CALLS_TRANSCRIBER_VERSION" ]; then
        check_docker
        pull_and_save_images
    fi

    if [ -n "$CALLS_OFFLOADER_VERSION" ]; then
        download_offloader_binary
    fi

    create_airgap_deployment_script

    if [ -n "$CALLS_OFFLOADER_VERSION" ]; then
        copy_install_script
    fi

    echo "" | tee -a $LOG_FILE
    echo "=== Preparation Complete ===" | tee -a $LOG_FILE
    echo "" | tee -a $LOG_FILE
    echo "Transfer these files to your air-gapped machine:" | tee -a $LOG_FILE
    if [ -n "$CALLS_RECORDER_VERSION" ]; then
        echo "  $(pwd)/calls-recorder-$CALLS_RECORDER_VERSION.tar.gz" | tee -a $LOG_FILE
    fi
    if [ -n "$CALLS_TRANSCRIBER_VERSION" ]; then
        echo "  $(pwd)/calls-transcriber-$CALLS_TRANSCRIBER_VERSION.tar.gz" | tee -a $LOG_FILE
    fi
    if [ -n "$CALLS_RECORDER_VERSION" ] || [ -n "$CALLS_TRANSCRIBER_VERSION" ]; then
        echo "  $(pwd)/registry-2.tar.gz" | tee -a $LOG_FILE
    fi
    if [ -n "$CALLS_OFFLOADER_VERSION" ]; then
        echo "  $(pwd)/calls-offloader-linux-$OFFLOADER_ARCH" | tee -a $LOG_FILE
        echo "  $(pwd)/install-offloader.sh" | tee -a $LOG_FILE
    fi
    echo "  $(pwd)/deploy-airgap-offloader.sh" | tee -a $LOG_FILE
    echo "" | tee -a $LOG_FILE
    echo "Then on the air-gapped machine, run:" | tee -a $LOG_FILE
    echo "  ./deploy-airgap-offloader.sh" | tee -a $LOG_FILE
    echo "" | tee -a $LOG_FILE
    echo "Log file: $LOG_FILE" | tee -a $LOG_FILE
}

main "$@"
