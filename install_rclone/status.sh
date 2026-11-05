#!/bin/sh
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/common.sh" ]; then
    . "$SCRIPT_DIR/common.sh"
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

# Detect CPU architecture compatibility with rclone release binaries
detect_rclone_arch() {
    local arch="${SYSTEM_ARCH:-}"
    if [ -z "$arch" ]; then
        arch="$(uname -m)"
    fi

    case "$arch" in
        x86_64|amd64)
            echo "amd64"
            ;;
        i386|i486|i586|i686)
            echo "386"
            ;;
        aarch64|arm64)
            echo "arm64"
            ;;
        armv7*|armhf)
            echo "arm-v7"
            ;;
        armv6*)
            echo "arm-v6"
            ;;
        arm*)
            echo "arm"
            ;;
        mipsle|mipsel|mips*el)
            echo "mipsle"
            ;;
        mips)
            if (printf '\001\000' 2>/dev/null || echo -n -e '\x01\x00' 2>/dev/null) | hexdump -x 2>/dev/null | grep -q "0001"; then
                echo "mipsle"
            elif [ -f /etc/openwrt_release ] && grep -qi "mipsel" /etc/openwrt_release; then
                echo "mipsle"
            elif [ -f /etc/os-release ] && grep -qi "mipsel" /etc/os-release; then
                echo "mipsle"
            elif od -j 5 -N 1 -An -t x1 /bin/sh 2>/dev/null | grep -q "01"; then
                echo "mipsle"
            elif command -v lscpu >/dev/null 2>&1 && lscpu 2>/dev/null | grep -qi "Little Endian"; then
                echo "mipsle"
            else
                echo "mips"
            fi
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

ARCH="$(detect_rclone_arch)"
if [ "$ARCH" = "unknown" ]; then
    echo "Unsupported CPU architecture '$(uname -m)' for rclone binary distribution"
    exit 20
fi

fetch_text() {
    local url="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 5 -H "User-Agent: curl/7.88.1" "$url" 2>/dev/null
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 5 -U "curl/7.88.1" -O - "$url" 2>/dev/null
    fi
}

get_installed_rclone() {
    if command -v rclone >/dev/null 2>&1; then
        command -v rclone
    elif [ -x /usr/local/bin/rclone ]; then
        echo "/usr/local/bin/rclone"
    elif [ -x /usr/bin/rclone ]; then
        echo "/usr/bin/rclone"
    fi
}

RCLONE_BIN="$(get_installed_rclone)"
INSTALLED_VER=""
if [ -n "$RCLONE_BIN" ]; then
    INSTALLED_RAW="$("$RCLONE_BIN" version 2>/dev/null | head -n 1)"
    INSTALLED_VER="$(echo "$INSTALLED_RAW" | awk '{print $2}' | tr -d '\r\n')"
    case "$INSTALLED_VER" in
        v*) ;;
        [0-9]*) INSTALLED_VER="v$INSTALLED_VER" ;;
    esac
fi

LATEST_RAW="$(fetch_text "https://downloads.rclone.org/version.txt" || true)"
LATEST_VER="$(echo "$LATEST_RAW" | awk '{print $2}' | tr -d '\r\n')"
case "$LATEST_VER" in
    v*) ;;
    [0-9]*) LATEST_VER="v$LATEST_VER" ;;
esac

if [ -n "$RCLONE_BIN" ] && [ -n "$INSTALLED_VER" ]; then
    if [ -n "$LATEST_VER" ] && [ "$INSTALLED_VER" = "$LATEST_VER" ]; then
        echo "rclone is already installed and up to date ($INSTALLED_VER at $RCLONE_BIN)"
        exit 10
    elif [ -n "$LATEST_VER" ]; then
        echo "rclone is installed ($INSTALLED_VER at $RCLONE_BIN), update available to $LATEST_VER"
        exit 0
    else
        echo "rclone is installed ($INSTALLED_VER at $RCLONE_BIN)"
        exit 10
    fi
fi

if [ -n "$LATEST_VER" ]; then
    echo "rclone is not installed (latest stable version: $LATEST_VER)"
else
    echo "rclone is not installed"
fi
exit 0
