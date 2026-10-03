#!/usr/bin/env bash

set -uo pipefail

########################################
# Configuration
########################################

SSH_USER="remoteadmin"
SSH_PORT=39222
SSH_TIMEOUT=10
MAX_JOBS=8
LOGFILE="./port_manager.log"

########################################
# Defaults
########################################

DEFAULT_INVENTORY="example_inventory.txt"
DEFAULT_PROFILE="ports_example.txt"
AUTO_LOAD_DEFAULTS=true

########################################
# Colors
########################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m'

########################################
# Inventory Selection
########################################

if [[ "$AUTO_LOAD_DEFAULTS" == "true" ]]; then
    INVENTORY_FILE="$DEFAULT_INVENTORY"
    PROFILE_FILE="$DEFAULT_PROFILE"
else
    # Existing selection menus
    :
fi

INVENTORY_DIR="./inventories"

if [[ ! -d "$INVENTORY_DIR" ]]; then
    echo "Inventory directory not found."
    exit 1
fi

echo
echo "Available Inventories"
echo "===================="

find "$INVENTORY_DIR" \
    -maxdepth 1 \
    -type f \
    -name "*.txt" \
    -exec basename {} \; | sort

echo

read -rp "Select inventory file [$DEFAULT_INVENTORY]: " INVENTORY_FILE
INVENTORY_FILE=${INVENTORY_FILE:-$DEFAULT_INVENTORY}

INVENTORY_PATH="${INVENTORY_DIR}/${INVENTORY_FILE}"

if [[ ! -f "$INVENTORY_PATH" ]]; then
    echo "Inventory not found: $INVENTORY_FILE"
    exit 1
fi

mapfile -t IPS < "$INVENTORY_PATH"

if [[ ${#IPS[@]} -eq 0 ]]; then
    echo "Selected inventory is empty."
    exit 1
fi

echo
echo "Selected Inventory : $(basename "$INVENTORY_PATH")"

########################################
# Port Profiles
########################################

PROFILE_DIR="./profiles"

if [[ ! -d "$PROFILE_DIR" ]]; then
    echo "Profiles directory not found: $PROFILE_DIR"
    exit 1
fi

echo
echo "Available Port Profiles"
echo "======================="

find "$PROFILE_DIR" \
    -maxdepth 1 \
    -type f \
    -name "ports_*.txt" \
    -exec basename {} \; | sort

echo
read -rp "Select profile file [$DEFAULT_PROFILE]: " PROFILE_FILE
PROFILE_FILE=${PROFILE_FILE:-$DEFAULT_PROFILE}

PROFILE_PATH="${PROFILE_DIR}/${PROFILE_FILE}"

if [[ ! -f "$PROFILE_PATH" ]]; then
    echo "Profile not found: $PROFILE_PATH"
    exit 1
fi

mapfile -t PORTS < "$PROFILE_PATH"

if [[ ${#PORTS[@]} -eq 0 ]]; then
    echo "Selected profile contains no ports."
    exit 1
fi

PORT_LIST="${PORTS[*]}"

echo
echo "Selected Inventory : $(basename "$INVENTORY_PATH")"
echo "Selected Profile   : $(basename "$PROFILE_PATH")"
echo

########################################
# Logging
########################################

log() {
    echo "[$(date '+%F %T')] $*" | tee -a "$LOGFILE"
}

########################################
# Password
########################################

read -rsp "SSH Password: " SSH_PASSWORD
echo

########################################
# SSH
########################################

run_remote() {
    local ip="$1"
    local cmd="$2"

    sshpass -p "$SSH_PASSWORD" ssh \
        -p "$SSH_PORT" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout="${SSH_TIMEOUT}" \
        "${SSH_USER}@${ip}" \
        "${cmd}"
}

########################################
# Reachability
########################################

is_reachable() {
    local ip="$1"

    timeout 2 bash -c "</dev/tcp/${ip}/${SSH_PORT}" \
        >/dev/null 2>&1
}

########################################
# Parallel Control
########################################

run_parallel() {
    while (( $(jobs -rp | wc -l) >= MAX_JOBS )); do
        sleep 0.2
    done

    "$@" &
}

########################################
# Firewall Commands
########################################

open_port_cmd() {
    local port="$1"

    cat <<EOF
sudo iptables -C INPUT -p tcp --dport ${port} -j DROP >/dev/null 2>&1 &&
sudo iptables -D INPUT -p tcp --dport ${port} -j DROP || true
EOF
}

close_port_cmd() {
    local port="$1"

    cat <<EOF
sudo iptables -C INPUT -p tcp --dport ${port} -j DROP >/dev/null 2>&1 ||
sudo iptables -A INPUT -p tcp --dport ${port} -j DROP
EOF
}

########################################
# Status
########################################

show_status_node() {
    local ip="$1"
    local result
    local line

    if ! is_reachable "$ip"; then
        printf "%-15s ${YELLOW}%-10s${NC}\n" "$ip" "OFFLINE"
        return
    fi

    result=$(run_remote "$ip" "
for port in ${PORT_LIST}
do
if sudo iptables -C INPUT -p tcp --dport \$port -j DROP >/dev/null 2>&1
then
echo CLOSED
else
echo OPEN
fi
done
" 2>/dev/null)

    line=$(printf "%-15s " "$ip")

    while read -r state; do
        if [[ "$state" == "OPEN" ]]; then
            line+=$(printf "${GREEN}%-10s${NC} " "OPEN")
        else
            line+=$(printf "${RED}%-10s${NC} " "CLOSED")
        fi
    done <<< "$result"

    printf '%b\n' "$line"
}

print_status_header() {
    printf "%-15s " "IP Address"

    for port in "${PORTS[@]}"; do
        printf "%-10s " "$port"
    done

    echo

    printf "%-15s " "----------"

    for _ in "${PORTS[@]}"; do
        printf "%-10s " "----------"
    done

    echo
}

show_status() {
    echo
    echo "================================================================================"
    echo "Cluster Firewall Status"
    echo "================================================================================"

    print_status_header

    for ip in "${IPS[@]}"; do
        run_parallel show_status_node "$ip"
    done

    wait

    echo
}

########################################
# Operations
########################################

SUCCESS_COUNT=0
FAIL_COUNT=0
FAILED_NODES=()

apply_all_ports() {
    local ip="$1"
    local action="$2"
    local cmd=""

    for port in "${PORTS[@]}"; do
        if [[ "$action" == "open" ]]; then
            cmd+=$(open_port_cmd "$port")
        else
            cmd+=$(close_port_cmd "$port")
        fi

        cmd+=$'\n'
    done

    if run_remote "$ip" "$cmd" >/dev/null 2>&1; then
        echo -e "${GREEN}[OK]${NC} $ip"
        log "$action ALL ports on $ip"
    else
        echo -e "${RED}[FAILED]${NC} $ip"
    fi
}

apply_single_port() {
    local ip="$1"
    local port="$2"
    local action="$3"
    local cmd

    if [[ "$action" == "open" ]]; then
        cmd=$(open_port_cmd "$port")
    else
        cmd=$(close_port_cmd "$port")
    fi

    if run_remote "$ip" "$cmd" >/dev/null 2>&1; then
        echo -e "${GREEN}[OK]${NC} $ip"
        log "$action port $port on $ip"
    else
        echo -e "${RED}[FAILED]${NC} $ip"
    fi
}

########################################
# Confirmation
########################################

confirm_mass_change() {
    echo
    echo -e "${YELLOW}WARNING:${NC} Multiple nodes will be modified."

    read -rp "Continue? [yes/no]: " ans

    [[ "$ans" == "yes" ]] || exit 0
}

prompt_status() {
    echo

    read -rp "Show updated status? [y/n]: " ans

    if [[ "$ans" =~ ^[Yy]$ ]]; then
        show_status
    fi
}

########################################
# UI
########################################

clear

command -v figlet >/dev/null 2>&1 && figlet "Port Manager"

show_status

echo -e "${GREEN}1${NC} - Open all ports on all nodes"
echo -e "${RED}2${NC} - Close all ports on all nodes"
echo -e "${CYAN}3${NC} - Open/Close all ports on one node"
echo -e "${PURPLE}4${NC} - Open/Close one port on all nodes"
echo -e "${YELLOW}5${NC} - Show current status"

echo

read -rp "Select option: " choice

case "$choice" in
    1)
        confirm_mass_change

        for ip in "${IPS[@]}"; do
            run_parallel apply_all_ports "$ip" "open"
        done

        wait

        prompt_status
        ;;
    2)
        confirm_mass_change

        for ip in "${IPS[@]}"; do
            run_parallel apply_all_ports "$ip" "close"
        done

        wait

        prompt_status
        ;;
    3)
        read -rp "Target IP: " target_ip
        read -rp "Action [open/close]: " action

        [[ "$action" =~ ^(open|close)$ ]] || exit 1

        apply_all_ports "$target_ip" "$action"

        prompt_status
        ;;
    4)
        read -rp "Port Number: " target_port
        read -rp "Action [open/close]: " action

        [[ "$action" =~ ^(open|close)$ ]] || exit 1

        confirm_mass_change

        for ip in "${IPS[@]}"; do
            run_parallel apply_single_port "$ip" "$target_port" "$action"
        done

        wait

        prompt_status
        ;;
    5)
        show_status
        ;;
    *)
        echo -e "${RED}Wrong Input${NC}"
        ;;
esac
