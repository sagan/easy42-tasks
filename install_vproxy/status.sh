#!/bin/sh
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

SERVICE_NAME="vproxy"

# Determine target listening address (Easy42 node main IPv4, fallback to 0.0.0.0)
LISTEN_IP="${NODE_IP%/*}"
if [ -z "$LISTEN_IP" ]; then
    LISTEN_IP="0.0.0.0"
fi

VPROXY_BIN=""
if command -v vproxy >/dev/null 2>&1; then
    VPROXY_BIN="$(command -v vproxy)"
elif [ -x /usr/local/bin/vproxy ]; then
    VPROXY_BIN="/usr/local/bin/vproxy"
elif [ -x /usr/bin/vproxy ]; then
    VPROXY_BIN="/usr/bin/vproxy"
fi

if [ -n "$VPROXY_BIN" ]; then
    VER="$("$VPROXY_BIN" -V 2>&1 | head -n1 || echo "vproxy")"
    if is_service_installed "$SERVICE_NAME"; then
        if is_service_running "$SERVICE_NAME"; then
            echo "vproxy is running ($VER, listening on ${LISTEN_IP}:1080, $INIT_SYSTEM)"
            exit 10
        elif is_service_enabled "$SERVICE_NAME"; then
            echo "vproxy is installed ($VER) and service is enabled ($INIT_SYSTEM), but service is stopped"
            exit 0
        else
            echo "vproxy is installed ($VER) but service is not enabled/running ($INIT_SYSTEM)"
            exit 0
        fi
    else
        echo "vproxy is installed ($VER) but service is not installed ($INIT_SYSTEM)"
        exit 0
    fi
fi

echo "vproxy is not installed"
exit 0
