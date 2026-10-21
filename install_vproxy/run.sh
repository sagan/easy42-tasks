#!/bin/sh
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/common.sh" ]; then
    . "$SCRIPT_DIR/common.sh"
fi
if [ -f "$SCRIPT_DIR/node_ip.env" ]; then
    . "$SCRIPT_DIR/node_ip.env"
fi

# Ensure standard PATH includes /usr/local/bin and /usr/local/sbin
case ":$PATH:" in
    *:/usr/local/bin:*) ;;
    *) PATH="/usr/local/bin:$PATH" ;;
esac
case ":$PATH:" in
    *:/usr/local/sbin:*) ;;
    *) PATH="/usr/local/sbin:$PATH" ;;
esac
export PATH

case "$INIT_SYSTEM" in
    systemd|openrc|procd)
        ;;
    *)
        echo "Error: unsupported init system '$INIT_SYSTEM' (supported: systemd, openrc, procd)" >&2
        exit 1
        ;;
esac

SERVICE_NAME="vproxy"
SERVICE_FILE="$(get_service_file_path "$SERVICE_NAME")"

# 1. Determine target listening address: bind to Easy42 node main IPv4 if available
LISTEN_IP="${NODE_IP%/*}"
if [ -z "$LISTEN_IP" ]; then
    LISTEN_IP="0.0.0.0"
fi
echo "Configuring vproxy to listen on ${LISTEN_IP}:1080"

# 2. Detect target CPU architecture for release binary
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64|amd64)
        TARGET_TRIPLE="x86_64-unknown-linux-musl"
        ;;
    aarch64|arm64)
        TARGET_TRIPLE="aarch64-unknown-linux-musl"
        ;;
    armv7*)
        TARGET_TRIPLE="armv7-unknown-linux-musleabihf"
        ;;
    armv6*|arm)
        TARGET_TRIPLE="arm-unknown-linux-musleabihf"
        ;;
    i386|i686)
        TARGET_TRIPLE="i686-unknown-linux-musl"
        ;;
    *)
        echo "Error: unsupported CPU architecture '$ARCH' for vproxy release binaries" >&2
        exit 1
        ;;
esac

# 3. Ensure prerequisite tools (tar and curl/wget)
if ! command -v tar >/dev/null 2>&1; then
    echo "Installing tar..."
    install_packages tar || true
fi
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    echo "Installing curl/wget..."
    install_packages curl || install_packages wget || true
fi

# 4. Determine version to download
VERSION="2.5.5"
LATEST_TAG=""
if command -v curl >/dev/null 2>&1; then
    LATEST_URL="$(curl -sIL -o /dev/null -w '%{url_effective}' --connect-timeout 5 https://github.com/0x676e67/vproxy/releases/latest 2>/dev/null || true)"
    if [ -n "$LATEST_URL" ]; then
        LATEST_TAG="$(basename "$LATEST_URL" | sed 's/^v//')"
    fi
fi
if [ -n "$LATEST_TAG" ] && [ "$LATEST_TAG" != "latest" ]; then
    VERSION="$LATEST_TAG"
fi

DOWNLOAD_URL="https://github.com/0x676e67/vproxy/releases/download/v${VERSION}/vproxy-${VERSION}-${TARGET_TRIPLE}.tar.gz"
echo "Downloading vproxy v${VERSION} for ${TARGET_TRIPLE}..."

TMP_DIR="$(mktemp -d /tmp/.vproxy_install_XXXXXX)"
cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

TAR_FILE="$TMP_DIR/vproxy.tar.gz"
if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$TAR_FILE" "$DOWNLOAD_URL"
elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$TAR_FILE" "$DOWNLOAD_URL"
else
    echo "Error: neither curl nor wget is available to download $DOWNLOAD_URL" >&2
    exit 1
fi

echo "Extracting vproxy binary..."
tar -xzf "$TAR_FILE" -C "$TMP_DIR"

if [ ! -f "$TMP_DIR/vproxy" ]; then
    echo "Error: extracted archive does not contain vproxy binary" >&2
    exit 1
fi

# 5. Install binary to /usr/local/bin
$SUDO mkdir -p /usr/local/bin
$SUDO cp -f "$TMP_DIR/vproxy" /usr/local/bin/vproxy
$SUDO chmod 755 /usr/local/bin/vproxy

# Ensure symlink in /usr/bin for environments where /usr/local/bin is not in PATH
if [ ! -e /usr/bin/vproxy ] || [ -L /usr/bin/vproxy ]; then
    $SUDO ln -sf /usr/local/bin/vproxy /usr/bin/vproxy 2>/dev/null || true
fi

INSTALLED_VER="$(/usr/local/bin/vproxy -V 2>&1 || echo "vproxy")"
echo "Installed $INSTALLED_VER to /usr/local/bin/vproxy"

# 6. Stop existing service and clean up stale units
stop_service "$SERVICE_NAME" 2>/dev/null || true
if [ "$INIT_SYSTEM" != "systemd" ] && [ -f /etc/systemd/system/vproxy.service ]; then
    $SUDO rm -f /etc/systemd/system/vproxy.service 2>/dev/null || true
fi
if [ "$INIT_SYSTEM" = "systemd" ] && [ -f /etc/init.d/vproxy ]; then
    $SUDO rm -f /etc/init.d/vproxy 2>/dev/null || true
fi
killall vproxy 2>/dev/null || true

echo "Configuring $SERVICE_NAME service for $INIT_SYSTEM..."

# 7. Install service unit based on init system
case "$INIT_SYSTEM" in
    systemd)
        $SUDO mkdir -p /etc/systemd/system
        cat << EOF | $SUDO tee "$SERVICE_FILE" >/dev/null
[Unit]
Description=vproxy - High-performance HTTP/SOCKS5 Proxy Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/vproxy run --bind ${LISTEN_IP}:1080 auto
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
        $SUDO chmod 644 "$SERVICE_FILE"
        ;;

    openrc)
        $SUDO mkdir -p /etc/init.d
        cat << EOF | $SUDO tee "$SERVICE_FILE" >/dev/null
#!/sbin/openrc-run

name="vproxy"
description="vproxy - High-performance HTTP/SOCKS5 Proxy Server"

command="/usr/local/bin/vproxy"
command_args="run --bind ${LISTEN_IP}:1080 auto"
command_background=true
pidfile="/run/vproxy.pid"
output_log="/var/log/vproxy.log"
error_log="/var/log/vproxy.log"

depend() {
    need net
    after firewall
}
EOF
        $SUDO chmod 755 "$SERVICE_FILE"
        ;;

    procd)
        $SUDO mkdir -p /etc/init.d
        cat << EOF | $SUDO tee "$SERVICE_FILE" >/dev/null
#!/bin/sh /etc/rc.common

START=95
STOP=10
USE_PROCD=1

start_service() {
    procd_open_instance
    procd_set_param command /usr/local/bin/vproxy run --bind ${LISTEN_IP}:1080 auto
    procd_set_param respawn
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}
EOF
        $SUDO chmod 755 "$SERVICE_FILE"
        ;;
esac

# 8. Enable and start service
enable_service "$SERVICE_NAME"
start_service "$SERVICE_NAME"

echo "vproxy service successfully installed, enabled, and started on ${LISTEN_IP}:1080 via $INIT_SYSTEM."
exit 0
