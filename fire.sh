#!/bin/bash

# --- CONFIG ---
BINARY_PATH="/usr/local/bin/kototelega"
CONFIG_FILE="/etc/kototelega.conf"
IMAGE="nineseconds/mtg:2"
CONTAINER_NAME="mtproto-proxy"

# --- COLORS ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# --- CONFIG HELPERS ---
save_config() {
    cat > "$CONFIG_FILE" <<EOF
PORT=$PORT
SECRET=$SECRET
EOF
}

load_config() {
    [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"
}

# --- CHECK ROOT ---
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Run with sudo/root${NC}"
        exit 1
    fi
}

# --- INSTALL DEPS ---
install_qrencode() {
    if command -v apt-get &>/dev/null; then
        apt-get update && apt-get install -y qrencode
    elif command -v yum &>/dev/null; then
        yum install -y qrencode
    elif command -v dnf &>/dev/null; then
        dnf install -y qrencode
    else
        echo -e "${RED}No package manager found${NC}"
        exit 1
    fi
}

install_deps() {
    if ! command -v docker &>/dev/null; then
        curl -fsSL https://get.docker.com | sh || exit 1
        systemctl enable --now docker
    fi

    if ! command -v qrencode &>/dev/null; then
        install_qrencode
    fi

    SCRIPT_PATH="$(realpath "$0")"
    cp "$SCRIPT_PATH" "$BINARY_PATH"
    chmod +x "$BINARY_PATH"
}

# --- HELPERS ---
is_container_running() {
    docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"
}

is_autoupdate_enabled() {
    crontab -l 2>/dev/null | grep -q "$BINARY_PATH --auto-update"
}

is_healthcheck_enabled() {
    crontab -l 2>/dev/null | grep -q "$BINARY_PATH --health-check"
}

# --- STATUS ---
get_status() {
    if is_container_running; then
        echo -e "${GREEN}RUNNING${NC}"
    else
        echo -e "${RED}STOPPED${NC}"
    fi
}

get_autoupdate_status() {
    if is_autoupdate_enabled; then
        echo -e "${GREEN}ON${NC}"
    else
        echo -e "${YELLOW}OFF${NC}"
    fi
}

get_healthcheck_status() {
    if is_healthcheck_enabled; then
        echo -e "${GREEN}ON${NC}"
    else
        echo -e "${YELLOW}OFF${NC}"
    fi
}

# --- NETWORK ---
get_ip() {
    curl -s -4 --max-time 5 https://api.ipify.org || echo "0.0.0.0"
}

# --- DOCKER ---
run_container() {
    docker rm -f "$CONTAINER_NAME" &>/dev/null
    docker run -d --name "$CONTAINER_NAME" --restart always -p "$PORT":"$PORT" \
        "$IMAGE" simple-run -n 1.1.1.1 -i prefer-ipv4 0.0.0.0:"$PORT" "$SECRET" > /dev/null
}

# --- VALIDATION ---
validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

# --- FEATURES ---
show_config() {
    load_config

    if ! is_container_running; then
        echo -e "${RED}Proxy not running${NC}"
        return
    fi

    if [ -z "$PORT" ] || [ -z "$SECRET" ]; then
        echo -e "${RED}Config missing${NC}"
        return
    fi

    IP=$(get_ip)
    LINK="tg://proxy?server=$IP&port=$PORT&secret=$SECRET"

    echo "IP: $IP"
    echo "Port: $PORT"
    echo "Secret: $SECRET"
    echo "Link: $LINK"

    qrencode -t ANSIUTF8 "$LINK"
}

install_proxy() {
    read -p "Enter port (default 443): " PORT
    PORT=${PORT:-443}

    if ! validate_port "$PORT"; then
        echo -e "${RED}Invalid port${NC}"
        return
    fi

    docker pull "$IMAGE" || return

    SECRET=$(docker run --rm "$IMAGE" generate-secret --hex google.com)

    save_config
    run_container
    show_config
}

change_port() {
    load_config

    if [ -z "$SECRET" ]; then
        echo -e "${RED}No existing config${NC}"
        return
    fi

    read -p "Enter new port: " NEW_PORT

    if ! validate_port "$NEW_PORT"; then
        echo -e "${RED}Invalid port${NC}"
        return
    fi

    PORT=$NEW_PORT
    save_config
    run_container

    echo "Port updated"
}

update_image() {
    load_config

    docker pull "$IMAGE" || return

    if is_container_running; then
        run_container
        echo "Updated"
    else
        echo -e "${YELLOW}Container not running${NC}"
    fi
}

remove_proxy() {
    read -p "Remove proxy? [y/N]: " confirm
    if [[ "$confirm" == "y" ]]; then
        docker rm -f "$CONTAINER_NAME" &>/dev/null
        rm -f "$CONFIG_FILE"
        echo "Removed"
    fi
}

# --- CRON ---
setup_autoupdate() {
    CRON_JOB="0 4 * * * $BINARY_PATH --auto-update"
    HEALTH_JOB="*/5 * * * * $BINARY_PATH --health-check"

    (crontab -l 2>/dev/null | grep -v "$BINARY_PATH"; echo "$CRON_JOB"; echo "$HEALTH_JOB") | crontab -

    echo "Cron enabled"
}

remove_autoupdate() {
    crontab -l 2>/dev/null | grep -v "$BINARY_PATH" | crontab -
    echo "Cron disabled"
}

# --- AUTO MODES ---
if [[ "$1" == "--auto-update" ]]; then
    load_config
    docker pull "$IMAGE" && run_container
    exit 0
fi

if [[ "$1" == "--health-check" ]]; then
    load_config

    if ! is_container_running; then
        if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
            docker restart "$CONTAINER_NAME"
        else
            run_container
        fi
    fi
    exit 0
fi

# --- MAIN ---
check_root
install_deps

while true; do
    clear

    echo "Status: $(get_status)"
    echo "Auto-update: $(get_autoupdate_status)"
    echo "Health-check: $(get_healthcheck_status)"

    echo "1) Install / Reinstall proxy"
    echo "2) Show connection info"
    echo "3) Update Docker image"
    echo "4) Change port"

    if is_autoupdate_enabled; then
        echo "5) Disable auto-update"
    else
        echo "5) Enable auto-update"
    fi

    echo "7) Remove proxy"
    echo "0) Exit"

    read -p "Select: " opt

    case $opt in
        1) install_proxy ;;
        2) show_config ;;
        3) update_image ;;
        4) change_port ;;
        5)
            if is_autoupdate_enabled; then
                remove_autoupdate
            else
                setup_autoupdate
            fi
            ;;
        7) remove_proxy ;;
        0) exit 0 ;;
        *) echo -e "${RED}Invalid option${NC}" ;;
    esac

    read -p "Press Enter..."
done
