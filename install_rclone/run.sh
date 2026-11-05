#!/bin/sh
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/common.sh" ]; then
    . "$SCRIPT_DIR/common.sh"
fi

# Capture node's original PATH before modifications
ORIG_PATH="${PATH:-}"

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

# Ensure SUDO is defined if common.sh was not loaded
if [ -z "${SUDO+x}" ]; then
    SUDO=""
    if [ "$(id -u)" -ne 0 ]; then
        if command -v sudo >/dev/null 2>&1; then
            SUDO="sudo"
        else
            echo "Error: root privileges required but sudo is not available" >&2
            exit 1
        fi
    fi
fi

# Fallback package installer if common.sh was not loaded
if ! command -v install_packages >/dev/null 2>&1; then
    install_packages() {
        if command -v opkg >/dev/null 2>&1; then
            $SUDO opkg update && $SUDO opkg install "$@"
        elif command -v apt-get >/dev/null 2>&1; then
            export DEBIAN_FRONTEND=noninteractive
            $SUDO apt-get update -qq && $SUDO apt-get install -y -qq "$@"
        elif command -v apk >/dev/null 2>&1; then
            $SUDO apk update && $SUDO apk add "$@"
        elif command -v dnf >/dev/null 2>&1; then
            $SUDO dnf install -y -q "$@"
        elif command -v yum >/dev/null 2>&1; then
            $SUDO yum install -y -q "$@"
        elif command -v pacman >/dev/null 2>&1; then
            $SUDO pacman -Sy --noconfirm "$@"
        else
            echo "Error: No supported package manager found to install $*" >&2
            return 1
        fi
    }
fi

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
    echo "Error: Unsupported CPU architecture '$(uname -m)' for rclone binary distribution" >&2
    exit 1
fi

# Ensure curl or wget is installed
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    echo "Neither curl nor wget found. Attempting to install curl/wget..."
    install_packages curl || install_packages wget || true
fi

fetch_text() {
    local url="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 10 -H "User-Agent: curl/7.88.1" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -U "curl/7.88.1" -O - "$url"
    else
        return 1
    fi
}

download_file() {
    local url="$1"
    local dest="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 15 -H "User-Agent: curl/7.88.1" -o "$dest" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -U "curl/7.88.1" -O "$dest" "$url"
    else
        return 1
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

# 1. Fetch latest stable rclone version from version.txt
echo "Checking latest stable rclone version from https://downloads.rclone.org/version.txt..."
LATEST_RAW="$(fetch_text "https://downloads.rclone.org/version.txt" 2>/dev/null || true)"
LATEST_VER="$(echo "$LATEST_RAW" | awk '{print $2}' | tr -d '\r\n')"
case "$LATEST_VER" in
    v*) ;;
    [0-9]*) LATEST_VER="v$LATEST_VER" ;;
esac

if [ -z "$LATEST_VER" ]; then
    echo "Error: Failed to fetch latest rclone version from https://downloads.rclone.org/version.txt" >&2
    exit 1
fi
echo "Latest stable rclone version: $LATEST_VER"

# 2. Check currently installed rclone version
RCLONE_BIN="$(get_installed_rclone)"
if [ -n "$RCLONE_BIN" ]; then
    INSTALLED_RAW="$("$RCLONE_BIN" version 2>/dev/null | head -n 1)"
    INSTALLED_VER="$(echo "$INSTALLED_RAW" | awk '{print $2}' | tr -d '\r\n')"
    case "$INSTALLED_VER" in
        v*) ;;
        [0-9]*) INSTALLED_VER="v$INSTALLED_VER" ;;
    esac
    echo "Currently installed rclone version: $INSTALLED_VER ($RCLONE_BIN)"

    # If rclone is already installed and is up to date. Do nothing.
    if [ "$INSTALLED_VER" = "$LATEST_VER" ]; then
        echo "rclone is already installed and is up to date ($INSTALLED_VER at $RCLONE_BIN). Nothing to do."
        exit 0
    fi
    echo "Updating rclone from $INSTALLED_VER to $LATEST_VER..."
else
    echo "rclone is not installed. Proceeding with installation of $LATEST_VER..."
fi

# 3. Ensure unzip is installed using system package manager if not present
if ! command -v unzip >/dev/null 2>&1; then
    echo "unzip not found. Attempting to install unzip using system package manager..."
    install_packages unzip || true
fi

if ! command -v unzip >/dev/null 2>&1; then
    echo "Error: unzip command is required to extract rclone archive, but it is not installed." >&2
    exit 1
fi

# 4. Determine target install directory:
# put rclone to /usr/local/bin (if it exists and is in PATH) or /usr/bin
TARGET_DIR="/usr/bin"
if [ -d /usr/local/bin ]; then
    case ":$ORIG_PATH:" in
        *:/usr/local/bin:*)
            TARGET_DIR="/usr/local/bin"
            ;;
    esac
fi
echo "Target installation location: $TARGET_DIR/rclone"

# 5. Download and extract rclone zip archive
DOWNLOAD_URL="https://downloads.rclone.org/${LATEST_VER}/rclone-${LATEST_VER}-linux-${ARCH}.zip"
echo "Downloading $DOWNLOAD_URL..."

TMP_DIR="$(mktemp -d /tmp/.rclone_install_XXXXXX)"
cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

ZIP_FILE="$TMP_DIR/rclone.zip"
download_file "$DOWNLOAD_URL" "$ZIP_FILE"

if [ ! -s "$ZIP_FILE" ]; then
    echo "Error: Downloaded rclone archive is empty or missing" >&2
    exit 1
fi

echo "Extracting rclone archive..."
unzip -q -o "$ZIP_FILE" -d "$TMP_DIR"

EXTRACTED_BIN=""
if [ -f "$TMP_DIR/rclone-${LATEST_VER}-linux-${ARCH}/rclone" ]; then
    EXTRACTED_BIN="$TMP_DIR/rclone-${LATEST_VER}-linux-${ARCH}/rclone"
elif command -v find >/dev/null 2>&1; then
    EXTRACTED_BIN="$(find "$TMP_DIR" -type f -name rclone | head -n 1)"
else
    for f in "$TMP_DIR"/*/rclone "$TMP_DIR"/rclone; do
        if [ -f "$f" ]; then
            EXTRACTED_BIN="$f"
            break
        fi
    done
fi

if [ -z "$EXTRACTED_BIN" ] || [ ! -f "$EXTRACTED_BIN" ]; then
    echo "Error: Failed to find rclone executable inside extracted archive" >&2
    exit 1
fi

# 6. Put rclone into target directory
$SUDO mkdir -p "$TARGET_DIR"
$SUDO cp -f "$EXTRACTED_BIN" "$TARGET_DIR/rclone"
$SUDO chmod 755 "$TARGET_DIR/rclone"

# Clean up stale binary at alternate path to avoid version mismatch / PATH conflict
if [ "$TARGET_DIR" = "/usr/local/bin" ] && [ -f /usr/bin/rclone ] && [ ! /usr/bin/rclone -ef /usr/local/bin/rclone ]; then
    $SUDO rm -f /usr/bin/rclone 2>/dev/null || true
elif [ "$TARGET_DIR" = "/usr/bin" ] && [ -f /usr/local/bin/rclone ] && [ ! /usr/local/bin/rclone -ef /usr/bin/rclone ]; then
    $SUDO rm -f /usr/local/bin/rclone 2>/dev/null || true
fi

FINAL_VER="$("$TARGET_DIR/rclone" version 2>&1 | head -n 1 || true)"
echo "rclone successfully installed: $FINAL_VER ($TARGET_DIR/rclone)"
exit 0
