#!/usr/bin/env bash
set -Eeuo pipefail

trap 'rc=$?; printf "\n\033[0;31m[!] Error on line %s (exit code %s).\033[0m\n" "$LINENO" "$rc" >&2; exit "$rc"' ERR

# ============================================================
# WireSmith
# WireGuard Automated Server Manager
# ============================================================
#
# Features:
#
#   1. New WireGuard server
#   2. Add client
#   3. Manage existing clients
#   4. Edit server configuration
#   5. Show status
#   6. Restart / synchronize WireGuard
#   7. Completely remove WireGuard setup
#
# Supports:
#   - Debian / Ubuntu
#   - Fedora / RHEL-like
#   - Arch
#   - Alpine
#
# IMPORTANT:
#   Option 7 removes the WireGuard configuration and networking
#   created by WireSmith.
#
#   It then asks whether WireGuard packages should also be removed.
#
# ============================================================

readonly WG_INTERFACE="wg0"
readonly WG_DIR="/etc/wireguard"
readonly CLIENT_DIR="/root/wireguard-clients"
readonly SYSCTL_FILE="/etc/sysctl.d/99-wireguard-forwarding.conf"
readonly UFW_RULE_FILE="/etc/ufw/before.rules"

readonly RED=$'\033[0;31m'
readonly GREEN=$'\033[0;32m'
readonly YELLOW=$'\033[1;33m'
readonly BLUE=$'\033[0;34m'
readonly MAGENTA=$'\033[0;35m'
readonly CYAN=$'\033[0;36m'
readonly WHITE=$'\033[1;37m'
readonly NC=$'\033[0m'

readonly BOLD=$'\033[1m'

SERVER_CONF=""
VPN_CIDR=""
VPN_NETWORK=""
VPN_PREFIX=""
SERVER_VPN_IP=""

WG_PORT=""
WAN_IF=""
ENDPOINT=""

CLIENT_NAME=""
CLIENT_CONF=""
CLIENT_IP=""
CLIENT_ALLOWED_IPS=""
CLIENT_DNS=""

SERVER_PRIVATE_KEY=""
SERVER_PUBLIC_KEY=""
CLIENT_PRIVATE_KEY=""
CLIENT_PUBLIC_KEY=""

EXISTING_CONFIG=0


# ============================================================
# Output helpers
# ============================================================

ok() {
    printf "%b[+]%b %s\n" "$GREEN" "$NC" "$*"
}

info() {
    printf "%b[*]%b %s\n" "$CYAN" "$NC" "$*"
}

warn() {
    printf "%b[!]%b %s\n" "$YELLOW" "$NC" "$*" >&2
}

fail() {
    printf "%b[-]%b %s\n" "$RED" "$NC" "$*" >&2
    exit 1
}

section() {
    printf "\n%b============================================================%b\n" "$CYAN" "$NC"
    printf "%b%s%b\n" "$WHITE" "$*" "$NC"
    printf "%b============================================================%b\n" "$CYAN" "$NC"
}

highlight() {
    printf "%b%s%b" "$GREEN" "$*" "$NC"
}

highlight_cyan() {
    printf "%b%s%b" "$CYAN" "$*" "$NC"
}

highlight_yellow() {
    printf "%b%s%b" "$YELLOW" "$*" "$NC"
}

highlight_magenta() {
    printf "%b%s%b" "$MAGENTA" "$*" "$NC"
}

print_key() {
    printf "%b%s%b\n" "$GREEN" "$1" "$NC"
}

print_path() {
    printf "%b%s%b\n" "$CYAN" "$1" "$NC"
}

print_command() {
    printf "%b%s%b\n" "$YELLOW" "$1" "$NC"
}

print_port() {
    printf "%b%s%b" "$MAGENTA" "$1" "$NC"
}


# ============================================================
# Banner
# ============================================================

banner() {
    clear 2>/dev/null || true

    cat <<'EOF'

██╗    ██╗    ██╗    ██████╗     ███████╗    ███████╗    ███╗   ███╗    ██╗    ████████╗    ██╗  ██╗
██║    ██║    ██║    ██╔══██╗    ██╔════╝    ██╔════╝    ████╗ ████║    ██║    ╚══██╔══╝    ██║  ██║
██║ █╗ ██║    ██║    ██████╔╝    █████╗      ███████╗    ██╔████╔██║    ██║       ██║       ███████║
██║███╗██║    ██║    ██╔══██╗    ██╔══╝      ╚════██║    ██║╚██╔╝██║    ██║       ██║       ██╔══██║
╚███╔███╔╝    ██║    ██║  ██║    ███████╗    ███████║    ██║ ╚═╝ ██║    ██║       ██║       ██║  ██║
 ╚══╝╚══╝     ╚═╝    ╚═╝  ╚═╝    ╚══════╝    ╚══════╝    ╚═╝     ╚═╝    ╚═╝       ╚═╝       ╚═╝  ╚═╝
                                                                                                    
                         W I R E S M I T H
                 WireGuard Automated Server Manager
EOF

    printf "\n"
}


# ============================================================
# Basic helpers
# ============================================================

require_root() {
    [[ "${EUID}" -eq 0 ]] ||
        fail "Run this script as root: sudo bash $0"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

require_command() {
    command_exists "$1" ||
        fail "Required command not found: $1"
}


# ============================================================
# Validation
# ============================================================

valid_name() {
    [[ "$1" =~ ^[a-zA-Z0-9._-]+$ ]]
}

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] &&
        (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

valid_ipv4_cidr() {
    python3 - "$1" <<'PY'
import ipaddress
import sys

try:
    net = ipaddress.ip_network(sys.argv[1], strict=False)
    sys.exit(0 if net.version == 4 else 1)
except ValueError:
    sys.exit(1)
PY
}

valid_ipv4_address() {
    python3 - "$1" <<'PY'
import ipaddress
import sys

try:
    ip = ipaddress.ip_address(sys.argv[1])
    sys.exit(0 if ip.version == 4 else 1)
except ValueError:
    sys.exit(1)
PY
}

ip_is_inside_network() {
    python3 - "$1" "$2" <<'PY'
import ipaddress
import sys

try:
    ip = ipaddress.ip_address(sys.argv[1])
    net = ipaddress.ip_network(sys.argv[2], strict=False)

    if ip.version != 4 or net.version != 4:
        sys.exit(1)

    sys.exit(0 if ip in net else 1)

except ValueError:
    sys.exit(1)
PY
}

network_from_cidr() {
    python3 - "$1" <<'PY'
import ipaddress
import sys

net = ipaddress.ip_network(sys.argv[1], strict=False)
print(f"{net.network_address}/{net.prefixlen}")
PY
}

address_from_cidr() {
    python3 - "$1" <<'PY'
import ipaddress
import sys

iface = ipaddress.ip_interface(sys.argv[1])
print(iface.ip)
PY
}

prefix_from_cidr() {
    python3 - "$1" <<'PY'
import ipaddress
import sys

net = ipaddress.ip_network(sys.argv[1], strict=False)
print(net.prefixlen)
PY
}

network_contains_usable_client_ip() {
    python3 - "$1" <<'PY'
import ipaddress
import sys

net = ipaddress.ip_network(sys.argv[1], strict=False)

# /31 and /32 are deliberately rejected.
# WireSmith expects a normal subnet with usable client addresses.
sys.exit(0 if net.version == 4 and net.prefixlen <= 30 else 1)
PY
}

valid_allowed_ips() {
    local input="$1"
    local entry
    local -a entries

    [[ -n "$input" ]] || return 1

    IFS=',' read -r -a entries <<< "$input"

    for entry in "${entries[@]}"; do
        entry="${entry//[[:space:]]/}"

        [[ -n "$entry" ]] || return 1

        valid_ipv4_cidr "$entry" || return 1
    done
}

normalize_allowed_ips() {
    local input="$1"
    local entry
    local -a entries
    local -a normalized=()

    IFS=',' read -r -a entries <<< "$input"

    for entry in "${entries[@]}"; do
        entry="${entry//[[:space:]]/}"
        normalized+=("$entry")
    done

    local IFS=', '
    printf '%s' "${normalized[*]}"
}

valid_dns_servers() {
    local input="$1"
    local entry
    local -a entries

    [[ -n "$input" ]] || return 1

    IFS=',' read -r -a entries <<< "$input"

    for entry in "${entries[@]}"; do
        entry="${entry//[[:space:]]/}"

        [[ -n "$entry" ]] || return 1

        valid_ipv4_address "$entry" || return 1
    done
}

normalize_dns_servers() {
    local input="$1"
    local entry
    local -a entries
    local -a normalized=()

    IFS=',' read -r -a entries <<< "$input"

    for entry in "${entries[@]}"; do
        entry="${entry//[[:space:]]/}"
        normalized+=("$entry")
    done

    local IFS=', '
    printf '%s' "${normalized[*]}"
}


# ============================================================
# Network detection
# ============================================================

detect_wan_interface() {
    ip route get 1.1.1.1 2>/dev/null |
        awk '
            {
                for (i = 1; i <= NF; i++) {
                    if ($i == "dev") {
                        print $(i + 1)
                        exit
                    }
                }
            }
        '
}

detect_endpoint() {
    local detected=""

    if command_exists curl; then
        detected="$(
            curl \
                -4 \
                -fsS \
                --max-time 5 \
                https://api.ipify.org \
                2>/dev/null || true
        )"
    fi

    printf '%s\n' "$detected"
}


# ============================================================
# Backup helper
# ============================================================

backup_file() {
    local file="$1"
    local timestamp
    local backup

    [[ -f "$file" ]] || return 0

    timestamp="$(date +%Y%m%d%H%M%S)"
    backup="${file}.backup.${timestamp}"

    cp -a "$file" "$backup"

    printf '%s\n' "$backup"
}


# ============================================================
# Package detection
# ============================================================

wireguard_packages_installed() {
    command_exists wg ||
        command_exists wg-quick
}

install_packages() {
    if command_exists wg &&
       command_exists wg-quick &&
       command_exists ip &&
       command_exists python3; then

        ok "Required dependencies are already installed."
        return
    fi

    info "Installing required packages..."

    if command_exists apt-get; then

        export DEBIAN_FRONTEND=noninteractive

        apt-get update

        apt-get install -y \
            wireguard \
            wireguard-tools \
            iproute2 \
            python3 \
            curl \
            ufw

    elif command_exists dnf; then

        dnf install -y \
            wireguard-tools \
            iproute \
            python3 \
            curl

    elif command_exists yum; then

        yum install -y \
            wireguard-tools \
            iproute \
            python3 \
            curl

    elif command_exists pacman; then

        pacman -Sy --noconfirm \
            wireguard-tools \
            iproute2 \
            python \
            curl

    elif command_exists apk; then

        apk add \
            wireguard-tools \
            iproute2 \
            python3 \
            curl

    else
        fail "Unsupported package manager."
    fi

    require_command wg
    require_command wg-quick
    require_command ip
    require_command python3

    ok "Required packages are installed."
}


# ============================================================
# Current network information
# ============================================================

show_current_network_state() {
    section "Current Network State"

    printf "\n%bIP addresses%b\n" "$WHITE" "$NC"
    ip -br addr

    printf "\n%bRoutes%b\n" "$WHITE" "$NC"
    ip route

    printf "\n%bWireGuard interfaces%b\n" "$WHITE" "$NC"

    if command_exists wg &&
       wg show 2>/dev/null | grep -q '^interface:'; then

        wg show
    else
        printf "No active WireGuard interfaces found.\n"
    fi

    printf "\n"
}


# ============================================================
# Existing WireGuard configuration
# ============================================================

extract_existing_server_config() {
    info "Reading existing WireGuard configuration..."

    SERVER_PRIVATE_KEY="$(
        awk '
            /^\[Interface\]/ {
                in_interface = 1
                next
            }

            /^\[/ {
                in_interface = 0
            }

            in_interface && /^[[:space:]]*PrivateKey[[:space:]]*=/ {
                line = $0

                sub(/^[^=]*=[[:space:]]*/, "", line)
                gsub(/[[:space:]]+$/, "", line)

                print line
                exit
            }
        ' "$SERVER_CONF"
    )"

    [[ -n "$SERVER_PRIVATE_KEY" ]] ||
        fail "Could not read PrivateKey from existing configuration."

    [[ "$SERVER_PRIVATE_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] ||
        fail "The existing WireGuard PrivateKey has an invalid format."

    if ! SERVER_PUBLIC_KEY="$(
        printf '%s\n' "$SERVER_PRIVATE_KEY" | wg pubkey
    )"; then
        fail "The existing WireGuard PrivateKey could not be parsed by wg."
    fi

    [[ "$SERVER_PUBLIC_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] ||
        fail "Could not derive a valid server public key."

    local address_line

    address_line="$(
        awk '
            /^\[Interface\]/ {
                in_interface = 1
                next
            }

            /^\[/ {
                in_interface = 0
            }

            in_interface && /^[[:space:]]*Address[[:space:]]*=/ {
                line = $0

                sub(/^[^=]*=[[:space:]]*/, "", line)
                gsub(/[[:space:]]+$/, "", line)

                print line
                exit
            }
        ' "$SERVER_CONF"
    )"

    [[ -n "$address_line" ]] ||
        fail "Could not read Address from existing configuration."

    address_line="${address_line%%,*}"
    address_line="${address_line//[[:space:]]/}"

    valid_ipv4_cidr "$address_line" ||
        fail "Existing server Address is not a valid IPv4 CIDR: $address_line"

    VPN_CIDR="$address_line"
    SERVER_VPN_IP="$(address_from_cidr "$VPN_CIDR")"
    VPN_PREFIX="$(prefix_from_cidr "$VPN_CIDR")"
    VPN_NETWORK="$(network_from_cidr "$VPN_CIDR")"

    network_contains_usable_client_ip "$VPN_CIDR" ||
        fail "Existing VPN network ${VPN_CIDR} is too small for WireSmith."

    WG_PORT="$(
        awk '
            /^\[Interface\]/ {
                in_interface = 1
                next
            }

            /^\[/ {
                in_interface = 0
            }

            in_interface && /^[[:space:]]*ListenPort[[:space:]]*=/ {
                line = $0

                sub(/^[^=]*=[[:space:]]*/, "", line)
                gsub(/[[:space:]]+$/, "", line)

                print line
                exit
            }
        ' "$SERVER_CONF"
    )"

    [[ -n "$WG_PORT" ]] || WG_PORT="51820"

    valid_port "$WG_PORT" ||
        fail "Invalid ListenPort in existing configuration: $WG_PORT"

    ok "Existing WireGuard configuration loaded."
}


# ============================================================
# Existing client detection
# ============================================================

client_ip_exists_in_config() {
    local ip="$1"
    local escaped_ip

    escaped_ip="${ip//./\\.}"

    grep -Eq \
        "^[[:space:]]*AllowedIPs[[:space:]]*=[[:space:]]*${escaped_ip}/32([[:space:]]*,|[[:space:]]*$)" \
        "$SERVER_CONF"
}

client_name_exists_in_config() {
    local name="$1"

    grep -Fq "# Client: ${name}" "$SERVER_CONF"
}


# ============================================================
# Server configuration creation
# ============================================================

generate_new_server_config() {
    info "Generating server keys..."

    SERVER_PRIVATE_KEY="$(wg genkey)"

    SERVER_PUBLIC_KEY="$(
        printf '%s\n' "$SERVER_PRIVATE_KEY" |
            wg pubkey
    )"

    [[ "$SERVER_PRIVATE_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] ||
        fail "Generated server private key has an unexpected format."

    [[ "$SERVER_PUBLIC_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] ||
        fail "Generated server public key has an unexpected format."

    cat >"$SERVER_CONF" <<EOF
[Interface]
Address = ${VPN_CIDR}
ListenPort = ${WG_PORT}
PrivateKey = ${SERVER_PRIVATE_KEY}
EOF

    chmod 600 "$SERVER_CONF"

    ok "New server configuration created."
}


# ============================================================
# Add client to server configuration
# ============================================================

append_client_to_server_config() {
    local backup

    if client_ip_exists_in_config "$CLIENT_IP"; then
        fail "The client IP ${CLIENT_IP} already appears in the server configuration."
    fi

    if client_name_exists_in_config "$CLIENT_NAME"; then
        fail "A client named '${CLIENT_NAME}' already exists in the server configuration."
    fi

    backup="$(backup_file "$SERVER_CONF")"

    if [[ -n "$backup" ]]; then
        info "Backed up server configuration to: $backup"
    fi

    cat >>"$SERVER_CONF" <<EOF

# Client: ${CLIENT_NAME}
[Peer]
PublicKey = ${CLIENT_PUBLIC_KEY}
AllowedIPs = ${CLIENT_IP}/32
EOF

    chmod 600 "$SERVER_CONF"

    ok "Client added to server configuration."
}


# ============================================================
# Client keys/configuration
# ============================================================

generate_client_keys() {
    info "Generating client keys..."

    CLIENT_PRIVATE_KEY="$(wg genkey)"

    CLIENT_PUBLIC_KEY="$(
        printf '%s\n' "$CLIENT_PRIVATE_KEY" |
            wg pubkey
    )"

    [[ "$CLIENT_PRIVATE_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] ||
        fail "Generated client private key has an unexpected format."

    [[ "$CLIENT_PUBLIC_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] ||
        fail "Generated client public key has an unexpected format."
}

generate_client_config() {
    cat >"$CLIENT_CONF" <<EOF
[Interface]
PrivateKey = ${CLIENT_PRIVATE_KEY}
Address = ${CLIENT_IP}/32
DNS = ${CLIENT_DNS}

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
Endpoint = ${ENDPOINT}:${WG_PORT}
AllowedIPs = ${CLIENT_ALLOWED_IPS}
PersistentKeepalive = 25
EOF

    chmod 600 "$CLIENT_CONF"

    ok "Client configuration created."
}


# ============================================================
# IPv4 forwarding
# ============================================================

configure_sysctl() {
    info "Enabling IPv4 forwarding..."

    cat >"$SYSCTL_FILE" <<'EOF'
net.ipv4.ip_forward=1
EOF

    sysctl --system >/dev/null

    [[ "$(sysctl -n net.ipv4.ip_forward)" == "1" ]] ||
        fail "IPv4 forwarding could not be enabled."

    ok "IPv4 forwarding enabled."
}


# ============================================================
# UFW NAT
# ============================================================

replace_ufw_nat_block() {
    local vpn_network="$1"
    local wan_if="$2"

    local file="$UFW_RULE_FILE"
    local backup
    local tmp
    local new_file

    [[ -f "$file" ]] ||
        fail "UFW rules file not found: $file"

    backup="$(backup_file "$file")"

    if [[ -n "$backup" ]]; then
        info "Backed up UFW rules to: $backup"
    fi

    tmp="$(mktemp)"
    new_file="$(mktemp)"

    awk '
        /^# WG-AUTOMATED-NAT-BEGIN$/ {
            skip = 1
            next
        }

        /^# WG-AUTOMATED-NAT-END$/ {
            skip = 0
            next
        }

        !skip {
            print
        }
    ' "$file" >"$tmp"

    cat >"$new_file" <<EOF
# WG-AUTOMATED-NAT-BEGIN
*nat
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -s ${vpn_network} -o ${wan_if} -j MASQUERADE
COMMIT
# WG-AUTOMATED-NAT-END

EOF

    cat "$tmp" >>"$new_file"

    chmod --reference="$file" "$new_file" 2>/dev/null || chmod 644 "$new_file"
    chown --reference="$file" "$new_file" 2>/dev/null || true

    mv "$new_file" "$file"

    rm -f "$tmp"

    ok "UFW NAT rule updated."
}


# ============================================================
# Remove WireSmith UFW NAT
# ============================================================

remove_ufw_nat_block() {
    local file="$UFW_RULE_FILE"
    local tmp
    local backup

    [[ -f "$file" ]] || return 0

    if ! grep -q '^# WG-AUTOMATED-NAT-BEGIN$' "$file"; then
        return 0
    fi

    backup="$(backup_file "$file")"

    if [[ -n "$backup" ]]; then
        info "Backed up UFW rules before cleanup:"
        printf "    "
        print_path "$backup"
    fi

    tmp="$(mktemp)"

    awk '
        /^# WG-AUTOMATED-NAT-BEGIN$/ {
            skip = 1
            next
        }

        /^# WG-AUTOMATED-NAT-END$/ {
            skip = 0
            next
        }

        !skip {
            print
        }
    ' "$file" >"$tmp"

    chmod --reference="$file" "$tmp" 2>/dev/null || chmod 644 "$tmp"
    chown --reference="$file" "$tmp" 2>/dev/null || true

    mv "$tmp" "$file"

    ok "WireSmith NAT rules removed from UFW."
}


# ============================================================
# UFW configuration
# ============================================================

configure_ufw() {
    local wg_port="$1"
    local wan_if="$2"
    local vpn_network="$3"

    if ! command_exists ufw; then
        warn "UFW is not installed."
        warn "You must manually allow UDP ${wg_port} and configure NAT."
        return
    fi

    info "Configuring UFW..."

    ufw allow \
        "${wg_port}/udp" \
        comment "WireGuard VPN"

    ufw route allow \
        in on "$WG_INTERFACE" \
        out on "$wan_if" \
        from "$vpn_network"

    ufw route allow \
        in on "$wan_if" \
        out on "$WG_INTERFACE" \
        to "$vpn_network"

    replace_ufw_nat_block "$vpn_network" "$wan_if"

    ufw reload

    ok "UFW configuration completed."
}


# ============================================================
# WireGuard activation
# ============================================================

sync_wireguard_interface() {
    if ip link show "$WG_INTERFACE" >/dev/null 2>&1; then

        info "Synchronizing active WireGuard interface..."

        wg syncconf \
            "$WG_INTERFACE" \
            <(
                wg-quick strip "$WG_INTERFACE"
            )

        ok "Active WireGuard interface synchronized."

    else

        info "Starting WireGuard interface..."

        wg-quick up "$WG_INTERFACE"

        ok "WireGuard interface started."
    fi
}


# ============================================================
# Systemd
# ============================================================

enable_wireguard_service() {
    if command_exists systemctl; then

        systemctl enable "wg-quick@${WG_INTERFACE}"

        ok "WireGuard service enabled at boot."

    else

        warn "systemctl is not available."
        warn "Enable WireGuard startup manually."
    fi
}


# ============================================================
# New server prompts
# ============================================================

prompt_new_server_settings() {
    while true; do

        printf "\n"
        printf "%bVPN server address%b\n" "$WHITE" "$NC"
        printf "Enter the VPN server address in CIDR notation.\n"
        printf "Example: %b10.8.0.1/24%b\n" "$GREEN" "$NC"
        printf "Example: %b10.10.0.1/24%b\n" "$GREEN" "$NC"
        printf "\n"

        read -r -p "VPN server address [10.8.0.1/24]: " VPN_CIDR

        VPN_CIDR="${VPN_CIDR:-10.8.0.1/24}"

        if ! valid_ipv4_cidr "$VPN_CIDR"; then
            warn "That is not a valid IPv4 CIDR."
            warn "Use an address such as 10.8.0.1/24."
            continue
        fi

        if ! network_contains_usable_client_ip "$VPN_CIDR"; then
            warn "That subnet is too small."
            warn "WireSmith needs at least a /30 network."
            warn "Recommended: /24, for example 10.8.0.1/24."
            continue
        fi

        SERVER_VPN_IP="$(address_from_cidr "$VPN_CIDR")"
        VPN_PREFIX="$(prefix_from_cidr "$VPN_CIDR")"
        VPN_NETWORK="$(network_from_cidr "$VPN_CIDR")"

        break
    done

    while true; do

        printf "\n"
        printf "WireGuard normally uses UDP port %b51820%b.\n" "$MAGENTA" "$NC"
        printf "Example ports: %b51820%b, %b443%b, %b53%b\n" \
            "$MAGENTA" "$NC" \
            "$MAGENTA" "$NC" \
            "$MAGENTA" "$NC"

        read -r -p "WireGuard UDP port [51820]: " WG_PORT

        WG_PORT="${WG_PORT:-51820}"

        if valid_port "$WG_PORT"; then
            break
        fi

        warn "Invalid port."
        warn "Enter a number between 1 and 65535."
        warn "Example: 51820"
    done
}


# ============================================================
# WAN / endpoint prompts
# ============================================================

prompt_endpoint_and_wan() {

    while true; do

        printf "\n"

        WAN_IF="$(detect_wan_interface || true)"

        read -r \
            -p "Public/WAN interface [${WAN_IF:-auto-detect}]: " \
            WAN_INPUT

        WAN_IF="${WAN_INPUT:-$WAN_IF}"

        if [[ -z "$WAN_IF" ]]; then
            warn "Could not determine the WAN interface."
            warn "Examples: eth0, ens3, enp1s0"
            continue
        fi

        if ! ip link show "$WAN_IF" >/dev/null 2>&1; then
            warn "Network interface '$WAN_IF' does not exist."
            warn "Run: ip -br link"
            continue
        fi

        break
    done

    while true; do

        printf "\n"

        ENDPOINT_DEFAULT="$(detect_endpoint || true)"

        printf "The endpoint is the public address clients use to reach this server.\n"
        printf "Examples:\n"
        printf "  %b203.0.113.10%b\n" "$GREEN" "$NC"
        printf "  %bvpn.example.com%b\n" "$GREEN" "$NC"

        read -r \
            -p "Server public IP or DNS name [${ENDPOINT_DEFAULT:-enter manually}]: " \
            ENDPOINT

        ENDPOINT="${ENDPOINT:-$ENDPOINT_DEFAULT}"

        if [[ -z "$ENDPOINT" ]]; then
            warn "Endpoint cannot be empty."
            warn "Enter your public IPv4 address or DNS hostname."
            continue
        fi

        if [[ "$ENDPOINT" =~ [[:space:]] ]]; then
            warn "Endpoint cannot contain spaces."
            continue
        fi

        if [[ "$ENDPOINT" == *:* ]]; then
            warn "IPv6 endpoints are not supported by this version."
            warn "Use an IPv4 address or DNS hostname."
            continue
        fi

        break
    done
}


# ============================================================
# Client prompts
# ============================================================

prompt_client_settings() {

    while true; do

        printf "\n"
        printf "%bClient name%b\n" "$WHITE" "$NC"
        printf "Examples: %blaptop%b, %bphone%b, %bwindows-pc%b\n" \
            "$GREEN" "$NC" \
            "$GREEN" "$NC" \
            "$GREEN" "$NC"

        read -r -p "Client name: " CLIENT_NAME

        if [[ -z "$CLIENT_NAME" ]]; then
            warn "Client name cannot be empty."
            continue
        fi

        if ! valid_name "$CLIENT_NAME"; then
            warn "Invalid client name."
            warn "Only letters, numbers, dots, underscores and hyphens are allowed."
            warn "Example: laptop-01"
            continue
        fi

        CLIENT_CONF="${CLIENT_DIR}/${CLIENT_NAME}.conf"

        if [[ -e "$CLIENT_CONF" ]]; then
            warn "A client configuration already exists:"
            printf "    "
            print_path "$CLIENT_CONF"
            continue
        fi

        break
    done


    local default_client_ip

    default_client_ip="$(
        python3 - "$VPN_NETWORK" <<'PY'
import ipaddress
import sys

net = ipaddress.ip_network(sys.argv[1], strict=False)

candidate = net.network_address + 2

if candidate not in net:
    raise SystemExit("No default client address is available.")

print(candidate)
PY
    )"


    while true; do

        printf "\n"
        printf "%bClient VPN address%b\n" "$WHITE" "$NC"
        printf "The client must be inside the VPN network.\n"
        printf "Server: "
        highlight "$SERVER_VPN_IP"
        printf "\nNetwork: "
        highlight "$VPN_NETWORK"
        printf "\nExample client: "
        highlight "10.8.0.2"
        printf "\n\n"

        read -r \
            -p "Client VPN IPv4 address [${default_client_ip}]: " \
            CLIENT_IP

        CLIENT_IP="${CLIENT_IP:-$default_client_ip}"

        if ! valid_ipv4_address "$CLIENT_IP"; then
            warn "That is not a valid IPv4 address."
            warn "Example: 10.8.0.2"
            continue
        fi

        if ! ip_is_inside_network "$CLIENT_IP" "$VPN_CIDR"; then
            warn "That IP is outside the VPN network."
            printf "The VPN network is: "
            highlight "$VPN_NETWORK"
            printf "\n"
            printf "For example, if the network is "
            highlight "10.8.0.0/24"
            printf ", use something like "
            highlight "10.8.0.2"
            printf ".\n"
            continue
        fi

        if [[ "$CLIENT_IP" == "$SERVER_VPN_IP" ]]; then
            warn "That IP belongs to the WireGuard server."
            printf "Server address: "
            highlight "$SERVER_VPN_IP"
            printf "\nChoose another address, for example: "
            highlight "10.8.0.2"
            printf "\n"
            continue
        fi

        if client_ip_exists_in_config "$CLIENT_IP" 2>/dev/null; then
            warn "That client IP is already used."
            continue
        fi

        if python3 - "$CLIENT_IP" "$VPN_NETWORK" <<'PY'
import ipaddress
import sys

ip = ipaddress.ip_address(sys.argv[1])
net = ipaddress.ip_network(sys.argv[2], strict=False)

if net.prefixlen <= 30 and ip == net.broadcast_address:
    raise SystemExit(1)
PY
        then
            break
        else
            warn "That address is the broadcast address."
            warn "Choose a normal client address such as 10.8.0.2."
        fi

    done


    while true; do

        printf "\n"
        printf "%bClient AllowedIPs%b\n" "$WHITE" "$NC"
        printf "This controls what traffic uses the VPN.\n\n"

        printf "Full tunnel:   "
        highlight "0.0.0.0/0"
        printf "\n"

        printf "VPN only:      "
        highlight "$VPN_NETWORK"
        printf "\n\n"

        read -r \
            -p "Client AllowedIPs [0.0.0.0/0]: " \
            CLIENT_ALLOWED_IPS

        CLIENT_ALLOWED_IPS="${CLIENT_ALLOWED_IPS:-0.0.0.0/0}"

        if valid_allowed_ips "$CLIENT_ALLOWED_IPS"; then
            CLIENT_ALLOWED_IPS="$(
                normalize_allowed_ips "$CLIENT_ALLOWED_IPS"
            )"
            break
        fi

        warn "Invalid IPv4 CIDR list."
        warn "Examples:"
        printf "  "
        highlight "0.0.0.0/0"
        printf "\n  "
        highlight "$VPN_NETWORK"
        printf "\n  "
        highlight "10.8.0.0/24, 192.168.1.0/24"
        printf "\n"
    done


    while true; do

        printf "\n"
        printf "%bDNS server%b\n" "$WHITE" "$NC"
        printf "Examples: "
        highlight "1.1.1.1"
        printf ", "
        highlight "8.8.8.8"
        printf "\n"

        read -r \
            -p "DNS server(s) for the client [1.1.1.1]: " \
            CLIENT_DNS

        CLIENT_DNS="${CLIENT_DNS:-1.1.1.1}"

        if valid_dns_servers "$CLIENT_DNS"; then
            CLIENT_DNS="$(
                normalize_dns_servers "$CLIENT_DNS"
            )"
            break
        fi

        warn "Invalid DNS address."
        warn "Examples: 1.1.1.1 or 1.1.1.1,8.8.8.8"
    done
}


# ============================================================
# Existing server confirmation
# ============================================================

confirm_existing_server() {
    printf "\n"

    warn "Existing WireGuard configuration found:"
    printf "  "
    print_path "$SERVER_CONF"

    printf "\n"
    printf "WireSmith can manage this configuration.\n\n"

    printf "Current VPN network: "
    highlight "$VPN_NETWORK"
    printf "\n"

    printf "Current server address: "
    highlight "$SERVER_VPN_IP"
    printf "\n"

    printf "Current UDP port: "
    print_port "$WG_PORT"
    printf "\n"

    printf "\n"
    printf "The existing server private key will be preserved.\n"

    while true; do

        read -r \
            -p "Continue managing this WireGuard server? [Y/n]: " \
            APPEND_EXISTING

        APPEND_EXISTING="${APPEND_EXISTING:-Y}"

        if [[ "$APPEND_EXISTING" =~ ^[Yy]$ ]]; then
            return
        fi

        if [[ "$APPEND_EXISTING" =~ ^[Nn]$ ]]; then
            fail "Aborted. Existing configuration was not modified."
        fi

        warn "Please answer Y or N."
    done
}


# ============================================================
# Show server information
# ============================================================

show_server_information() {
    section "WireSmith Server Information"

    printf "\nServer configuration:\n  "
    print_path "$SERVER_CONF"

    printf "\nVPN network:\n  "
    highlight "$VPN_NETWORK"
    printf "\n"

    printf "Server VPN IP:\n  "
    highlight "$SERVER_VPN_IP"
    printf "\n"

    printf "WireGuard UDP port:\n  "
    print_port "$WG_PORT"
    printf "\n"

    printf "Server public key:\n  "
    print_key "$SERVER_PUBLIC_KEY"

    if [[ -n "$ENDPOINT" ]]; then
        printf "\nEndpoint:\n  "
        highlight "$ENDPOINT"
        printf "\n"
    fi
}


# ============================================================
# Status
# ============================================================

show_status() {
    section "WireGuard Status"

    if ! command_exists wg; then
        warn "WireGuard command is not installed."
        return
    fi

    if ip link show "$WG_INTERFACE" >/dev/null 2>&1; then
        wg show "$WG_INTERFACE"
    else
        warn "WireGuard interface ${WG_INTERFACE} is not active."
    fi

    printf "\nConfiguration:\n  "
    print_path "$SERVER_CONF"
}


# ============================================================
# Restart / synchronize
# ============================================================

restart_wireguard() {
    [[ -f "$SERVER_CONF" ]] ||
        fail "WireGuard configuration does not exist."

    section "Restart WireGuard"

    if command_exists systemctl; then

        info "Restarting wg-quick@${WG_INTERFACE}..."

        if systemctl restart "wg-quick@${WG_INTERFACE}"; then
            ok "WireGuard service restarted."
        else
            warn "WireGuard service could not be restarted."
            warn "The configuration or a related networking command may be invalid."

            printf "\n"
            printf "%bService status%b\n" "$WHITE" "$NC"
            systemctl status \
                "wg-quick@${WG_INTERFACE}" \
                --no-pager \
                --full \
                2>&1 || true

            printf "\n%bRecent service log%b\n" "$WHITE" "$NC"
            journalctl \
                -u "wg-quick@${WG_INTERFACE}" \
                -n 30 \
                --no-pager \
                2>&1 || true

            return 0
        fi

    else

        if ip link show "$WG_INTERFACE" >/dev/null 2>&1; then
            wg-quick down "$WG_INTERFACE" || true
        fi

        wg-quick up "$WG_INTERFACE"

        ok "WireGuard interface restarted."
    fi
}


# ============================================================
# List clients
# ============================================================

list_clients() {
    section "Configured Clients"

    if [[ ! -f "$SERVER_CONF" ]]; then
        warn "No WireGuard server configuration exists."
        return
    fi

    local found=0
    local current_name=""
    local public_key=""
    local allowed_ips=""

    while IFS= read -r line; do

        if [[ "$line" =~ ^#\ Client:\ (.+)$ ]]; then

            if [[ -n "$current_name" ]]; then
                printf "\n"
                printf "%bClient:%b %s\n" "$WHITE" "$NC" "$current_name"
                printf "  Public key: "
                print_key "$public_key"
                printf "  Allowed IPs: "
                highlight "$allowed_ips"
                printf "\n"
            fi

            current_name="${BASH_REMATCH[1]}"
            public_key=""
            allowed_ips=""
            found=1

        elif [[ "$line" =~ ^PublicKey[[:space:]]*=[[:space:]]*(.+)$ ]]; then

            public_key="${BASH_REMATCH[1]}"

        elif [[ "$line" =~ ^AllowedIPs[[:space:]]*=[[:space:]]*(.+)$ ]]; then

            allowed_ips="${BASH_REMATCH[1]}"

        fi

    done < "$SERVER_CONF"

    if [[ -n "$current_name" ]]; then
        printf "\n"
        printf "%bClient:%b %s\n" "$WHITE" "$NC" "$current_name"
        printf "  Public key: "
        print_key "$public_key"
        printf "  Allowed IPs: "
        highlight "$allowed_ips"
        printf "\n"
    fi

    if [[ "$found" -eq 0 ]]; then
        printf "No clients are currently configured.\n"
    fi

    return 0
}


# ============================================================
# Remove a client
# ============================================================

remove_client() {
    section "Remove Client"

    local clients=()
    local name
    local selected
    local backup
    local tmp

    while IFS= read -r name; do
        [[ -n "$name" ]] && clients+=("$name")
    done < <(
        grep '^# Client: ' "$SERVER_CONF" 2>/dev/null |
            sed 's/^# Client: //'
    )

    if [[ "${#clients[@]}" -eq 0 ]]; then
        warn "No clients found."
        return
    fi

    printf "\nConfigured clients:\n\n"

    local i=1

    for name in "${clients[@]}"; do
        printf "  %b%s%b) %s\n" "$CYAN" "$i" "$NC" "$name"
        ((i += 1))
    done

    printf "\n"

    while true; do

        read -r -p "Enter client number to remove: " selected

        if [[ "$selected" =~ ^[0-9]+$ ]] &&
           (( selected >= 1 && selected <= ${#clients[@]} )); then
            break
        fi

        warn "Invalid selection."
        warn "Choose a number from 1 to ${#clients[@]}."
    done

    name="${clients[$((selected - 1))]}"

    printf "\nYou selected: "
    highlight "$name"
    printf "\n"

    while true; do

        read -r \
            -p "Permanently remove this client? [y/N]: " \
            confirm

        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            break
        fi

        if [[ "$confirm" =~ ^[Nn]$ || -z "$confirm" ]]; then
            info "Client removal cancelled."
            return
        fi

        warn "Please answer Y or N."
    done

    backup="$(backup_file "$SERVER_CONF")"

    [[ -n "$backup" ]] && {
        info "Server configuration backed up:"
        printf "  "
        print_path "$backup"
    }

    tmp="$(mktemp)"

    awk -v client="$name" '
        BEGIN {
            skip = 0
        }

        /^# Client: / {
            if ($0 == "# Client: " client) {
                skip = 1
                next
            }

            if (skip) {
                skip = 0
            }
        }

        skip && /^\[Peer\]/ {
            next
        }

        skip && /^PublicKey[[:space:]]*=/ {
            next
        }

        skip && /^AllowedIPs[[:space:]]*=/ {
            next
        }

        skip && /^$/ {
            skip = 0
            next
        }

        !skip {
            print
        }
    ' "$SERVER_CONF" >"$tmp"

    mv "$tmp" "$SERVER_CONF"
    chmod 600 "$SERVER_CONF"

    rm -f "${CLIENT_DIR}/${name}.conf"

    ok "Client '${name}' removed."
}


# ============================================================
# Completely remove WireSmith WireGuard setup
# ============================================================

remove_wireguard_setup() {
    section "Remove WireGuard Setup"

    printf "\n"
    printf "%bWARNING%b\n" "$RED" "$NC"
    printf "This operation removes the WireGuard configuration created by WireSmith.\n\n"

    printf "It will remove:\n"
    printf "  - WireGuard interface: "
    highlight "$WG_INTERFACE"
    printf "\n"
    printf "  - Server configuration: "
    print_path "$SERVER_CONF"
    printf "\n"
    printf "  - Client configurations: "
    print_path "$CLIENT_DIR"
    printf "\n"
    printf "  - WireSmith NAT rules\n"
    printf "  - WireSmith IPv4 forwarding configuration\n"
    printf "  - WireGuard systemd startup configuration\n"
    printf "\n"

    printf "%bThis does NOT automatically remove WireGuard packages.%b\n" "$YELLOW" "$NC"

    while true; do

        read -r \
            -p "Are you absolutely sure you want to remove the WireGuard setup? [y/N]: " \
            confirm

        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            break
        fi

        if [[ "$confirm" =~ ^[Nn]$ || -z "$confirm" ]]; then
            info "Removal cancelled."
            return
        fi

        warn "Please answer Y or N."
    done


    # --------------------------------------------------------
    # Backup before destruction
    # --------------------------------------------------------

    if [[ -f "$SERVER_CONF" ]]; then

        local backup

        backup="$(backup_file "$SERVER_CONF")"

        if [[ -n "$backup" ]]; then
            info "A final backup was created:"
            printf "  "
            print_path "$backup"
        fi
    fi


    # --------------------------------------------------------
    # Stop systemd service
    # --------------------------------------------------------

    if command_exists systemctl; then

        info "Disabling WireGuard startup..."

        systemctl disable \
            "wg-quick@${WG_INTERFACE}" \
            >/dev/null 2>&1 || true

        systemctl stop \
            "wg-quick@${WG_INTERFACE}" \
            >/dev/null 2>&1 || true

        ok "WireGuard startup service disabled."
    fi


    # --------------------------------------------------------
    # Remove active interface
    # --------------------------------------------------------

    if ip link show "$WG_INTERFACE" >/dev/null 2>&1; then

        info "Removing active WireGuard interface..."

        if command_exists wg-quick; then
            wg-quick down "$WG_INTERFACE" \
                >/dev/null 2>&1 || true
        fi

        if ip link show "$WG_INTERFACE" >/dev/null 2>&1; then
            ip link delete "$WG_INTERFACE" \
                >/dev/null 2>&1 || true
        fi

        ok "WireGuard interface removed."

    else

        info "WireGuard interface is not active."
    fi


    # --------------------------------------------------------
    # Remove server configuration
    # --------------------------------------------------------

    if [[ -f "$SERVER_CONF" ]]; then

        info "Removing server configuration:"
        printf "  "
        print_path "$SERVER_CONF"

        rm -f "$SERVER_CONF"

        ok "Server configuration removed."

    else

        info "Server configuration does not exist."
    fi


    # --------------------------------------------------------
    # Remove client configurations
    # --------------------------------------------------------

    if [[ -d "$CLIENT_DIR" ]]; then

        info "Removing WireSmith client configurations:"
        printf "  "
        print_path "$CLIENT_DIR"

        rm -rf "$CLIENT_DIR"

        ok "Client configurations removed."
    fi


    # --------------------------------------------------------
    # Remove sysctl forwarding
    # --------------------------------------------------------

    if [[ -f "$SYSCTL_FILE" ]]; then

        info "Removing WireSmith IPv4 forwarding configuration."

        rm -f "$SYSCTL_FILE"

        if command_exists sysctl; then
            sysctl --system >/dev/null 2>&1 || true
        fi

        ok "IPv4 forwarding configuration removed."
    fi


    # --------------------------------------------------------
    # Remove UFW NAT
    # --------------------------------------------------------

    if command_exists ufw; then

        info "Removing WireSmith UFW NAT configuration..."

        remove_ufw_nat_block

        ufw reload >/dev/null 2>&1 || true

        ok "UFW configuration cleaned."
    fi


    # --------------------------------------------------------
    # Remove systemd runtime leftovers
    # --------------------------------------------------------

    if command_exists systemctl; then
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi


    # --------------------------------------------------------
    # Remove empty WireSmith client directory
    # --------------------------------------------------------

    rmdir "$CLIENT_DIR" 2>/dev/null || true


    # --------------------------------------------------------
    # Package removal question
    # --------------------------------------------------------

    printf "\n"
    section "WireGuard Packages"

    printf "The WireGuard configuration and network setup are now removed.\n\n"

    printf "Do you also want to remove the WireGuard software packages?\n\n"

    printf "Choose %bN%b if you may use WireGuard again later.\n" \
        "$GREEN" "$NC"

    printf "Choose %bY%b if this machine should no longer have WireGuard installed.\n" \
        "$RED" "$NC"

    while true; do

        read -r \
            -p "Remove WireGuard packages too? [y/N]: " \
            remove_packages

        if [[ "$remove_packages" =~ ^[Nn]$ || -z "$remove_packages" ]]; then

            printf "\n"
            ok "WireGuard packages were kept installed."
            printf "You can use them again later.\n"
            break

        fi

        if [[ "$remove_packages" =~ ^[Yy]$ ]]; then

            remove_wireguard_packages
            break
        fi

        warn "Please answer Y or N."
    done


    printf "\n"
    section "WireSmith Cleanup Complete"

    printf "\nThe WireGuard server setup has been removed.\n"
    printf "The active "
    highlight "$WG_INTERFACE"
    printf " interface is gone.\n"

    printf "\n"
    printf "No WireSmith client configurations remain.\n"

    printf "\n"
    printf "%bNote:%b backups created before removal are intentionally preserved.\n"
    printf "This lets you recover the previous configuration if necessary.\n"
}


# ============================================================
# Remove WireGuard packages
# ============================================================

remove_wireguard_packages() {

    section "Removing WireGuard Packages"

    if command_exists apt-get; then

        info "Removing Debian/Ubuntu WireGuard packages..."

        export DEBIAN_FRONTEND=noninteractive

        apt-get remove -y \
            wireguard \
            wireguard-tools \
            2>/dev/null || true

        apt-get autoremove -y \
            2>/dev/null || true

        ok "WireGuard packages removed."

    elif command_exists dnf; then

        info "Removing WireGuard packages..."

        dnf remove -y \
            wireguard-tools \
            2>/dev/null || true

        ok "WireGuard packages removed."

    elif command_exists yum; then

        info "Removing WireGuard packages..."

        yum remove -y \
            wireguard-tools \
            2>/dev/null || true

        ok "WireGuard packages removed."

    elif command_exists pacman; then

        info "Removing WireGuard packages..."

        pacman -Rns --noconfirm \
            wireguard-tools \
            2>/dev/null || true

        ok "WireGuard packages removed."

    elif command_exists apk; then

        info "Removing WireGuard packages..."

        apk del \
            wireguard-tools \
            2>/dev/null || true

        ok "WireGuard packages removed."

    else

        warn "Could not determine the package manager."
        warn "WireGuard packages were not automatically removed."
    fi
}


# ============================================================
# Menu
# ============================================================

show_menu() {

    banner

    printf "%bWireSmith Main Menu%b\n\n" "$WHITE" "$NC"

    if [[ -f "$SERVER_CONF" ]]; then

        printf "  %b1%b) Add a new client\n" "$CYAN" "$NC"
        printf "  %b2%b) List clients\n" "$CYAN" "$NC"
        printf "  %b3%b) Remove a client\n" "$CYAN" "$NC"
        printf "  %b4%b) Edit server configuration\n" "$CYAN" "$NC"
        printf "  %b5%b) Show WireGuard status\n" "$CYAN" "$NC"
        printf "  %b6%b) Restart / synchronize WireGuard\n" "$CYAN" "$NC"
        printf "  %b7%b) Completely remove WireGuard setup\n" "$RED" "$NC"
        printf "  %b8%b) Show server information\n" "$CYAN" "$NC"
        printf "  %b9%b) Exit\n" "$CYAN" "$NC"

    else

        printf "  %b1%b) Create new WireGuard server\n" "$CYAN" "$NC"
        printf "  %b2%b) Show network information\n" "$CYAN" "$NC"
        printf "  %b3%b) Exit\n" "$CYAN" "$NC"

    fi

    printf "\n"
}


# ============================================================
# Edit server configuration
# ============================================================

edit_server_configuration() {

    section "Edit WireGuard Server"

    printf "\n"
    printf "WireSmith can safely change selected server settings.\n"
    printf "A backup will be created before modifications.\n\n"

    printf "Current server VPN address: "
    highlight "$SERVER_VPN_IP"
    printf "\n"

    printf "Current VPN network: "
    highlight "$VPN_NETWORK"
    printf "\n"

    printf "Current UDP port: "
    print_port "$WG_PORT"
    printf "\n"

    printf "\n"
    printf "Available changes:\n\n"

    printf "  %b1%b) Change VPN server IP / subnet\n" "$CYAN" "$NC"
    printf "  %b2%b) Change WireGuard UDP port\n" "$CYAN" "$NC"
    printf "  %b3%b) Cancel\n" "$CYAN" "$NC"

    printf "\n"

    local choice

    while true; do

        read -r -p "Select an option: " choice

        case "$choice" in

            1)
                edit_server_network
                return
                ;;

            2)
                edit_server_port
                return
                ;;

            3)
                info "Edit cancelled."
                return
                ;;

            *)
                warn "Invalid option."
                warn "Choose 1, 2 or 3."
                ;;

        esac

    done
}


# ============================================================
# Edit server network
# ============================================================

edit_server_network() {

    printf "\n"
    printf "%bChanging the VPN network%b\n" "$WHITE" "$NC"
    printf "\n"

    printf "Current network: "
    highlight "$VPN_NETWORK"
    printf "\n"

    printf "Example new server address:\n"
    highlight "10.20.0.1/24"
    printf "\n\n"

    local new_cidr
    local new_network
    local new_server_ip
    local backup
    local tmp

    while true; do

        read -r \
            -p "New VPN server address [10.20.0.1/24]: " \
            new_cidr

        new_cidr="${new_cidr:-10.20.0.1/24}"

        if ! valid_ipv4_cidr "$new_cidr"; then
            warn "Invalid IPv4 CIDR."
            warn "Example: 10.20.0.1/24"
            continue
        fi

        if ! network_contains_usable_client_ip "$new_cidr"; then
            warn "Subnet is too small."
            warn "Use /30 or larger, preferably /24."
            continue
        fi

        new_network="$(network_from_cidr "$new_cidr")"
        new_server_ip="$(address_from_cidr "$new_cidr")"

        break
    done

    printf "\nNew network will be:\n  "
    highlight "$new_network"
    printf "\nNew server IP will be:\n  "
    highlight "$new_server_ip"
    printf "\n\n"

    warn "Changing the VPN subnet requires updating existing clients."

    while true; do

        read -r \
            -p "Continue with this network change? [y/N]: " \
            confirm

        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            break
        fi

        if [[ "$confirm" =~ ^[Nn]$ || -z "$confirm" ]]; then
            info "Network change cancelled."
            return
        fi

        warn "Please answer Y or N."
    done

    backup="$(backup_file "$SERVER_CONF")"

    [[ -n "$backup" ]] && {
        info "Backup created:"
        printf "  "
        print_path "$backup"
    }

    tmp="$(mktemp)"

    sed \
        "s|^[[:space:]]*Address[[:space:]]*=.*|Address = ${new_cidr}|" \
        "$SERVER_CONF" >"$tmp"

    mv "$tmp" "$SERVER_CONF"
    chmod 600 "$SERVER_CONF"

    VPN_CIDR="$new_cidr"
    VPN_NETWORK="$new_network"
    SERVER_VPN_IP="$new_server_ip"
    VPN_PREFIX="$(prefix_from_cidr "$new_cidr")"

    ok "Server VPN network changed."

    printf "\n"
    warn "Existing client configurations still contain their old VPN addresses."
    warn "Regenerate or manually update clients after changing the subnet."

    sync_wireguard_interface
}


# ============================================================
# Edit server port
# ============================================================

edit_server_port() {

    printf "\n"
    printf "Current UDP port: "
    print_port "$WG_PORT"
    printf "\n\n"

    printf "Example ports: "
    print_port "51820"
    printf ", "
    print_port "443"
    printf ", "
    print_port "53"
    printf "\n\n"

    local new_port
    local backup
    local tmp

    while true; do

        read -r \
            -p "New WireGuard UDP port [51820]: " \
            new_port

        new_port="${new_port:-51820}"

        if valid_port "$new_port"; then
            break
        fi

        warn "Invalid port."
        warn "Use a number from 1 to 65535."
    done

    backup="$(backup_file "$SERVER_CONF")"

    [[ -n "$backup" ]] && {
        info "Backup created:"
        printf "  "
        print_path "$backup"
    }

    tmp="$(mktemp)"

    sed \
        "s|^[[:space:]]*ListenPort[[:space:]]*=.*|ListenPort = ${new_port}|" \
        "$SERVER_CONF" >"$tmp"

    mv "$tmp" "$SERVER_CONF"
    chmod 600 "$SERVER_CONF"

    WG_PORT="$new_port"

    ok "WireGuard UDP port changed."

    if command_exists ufw; then
        info "Updating UFW firewall rule..."

        ufw allow \
            "${WG_PORT}/udp" \
            comment "WireGuard VPN" \
            >/dev/null 2>&1 || true

        ufw reload >/dev/null 2>&1 || true
    fi

    sync_wireguard_interface
}


# ============================================================
# Add client workflow
# ============================================================

add_client_workflow() {

    section "Add WireGuard Client"

    prompt_endpoint_and_wan
    prompt_client_settings

    generate_client_keys

    append_client_to_server_config

    generate_client_config

    configure_sysctl

    configure_ufw \
        "$WG_PORT" \
        "$WAN_IF" \
        "$VPN_NETWORK"

    sync_wireguard_interface

    enable_wireguard_service

    printf "\n"
    section "Client Created Successfully"

    printf "\nClient name:\n  "
    highlight "$CLIENT_NAME"
    printf "\n"

    printf "Client IP:\n  "
    highlight "$CLIENT_IP"
    printf "\n"

    printf "Client public key:\n  "
    print_key "$CLIENT_PUBLIC_KEY"

    printf "\nClient configuration:\n  "
    print_path "$CLIENT_CONF"

    printf "\n"
    printf "%bKeep this configuration private.%b\n" "$YELLOW" "$NC"
}


# ============================================================
# New server workflow
# ============================================================

new_server_workflow() {

    section "Create WireGuard Server"

    prompt_new_server_settings

    mkdir -p \
        "$WG_DIR" \
        "$CLIENT_DIR"

    chmod 700 \
        "$WG_DIR" \
        "$CLIENT_DIR"

    SERVER_CONF="${WG_DIR}/${WG_INTERFACE}.conf"

    generate_new_server_config

    prompt_endpoint_and_wan

    prompt_client_settings

    generate_client_keys

    append_client_to_server_config

    generate_client_config

    configure_sysctl

    configure_ufw \
        "$WG_PORT" \
        "$WAN_IF" \
        "$VPN_NETWORK"

    sync_wireguard_interface

    enable_wireguard_service

    printf "\n"
    section "WireSmith Setup Completed"

    printf "\nServer public key:\n  "
    print_key "$SERVER_PUBLIC_KEY"

    printf "\nClient public key:\n  "
    print_key "$CLIENT_PUBLIC_KEY"

    printf "\nServer configuration:\n  "
    print_path "$SERVER_CONF"

    printf "\nClient configuration:\n  "
    print_path "$CLIENT_CONF"

    printf "\nWireGuard UDP port:\n  "
    print_port "$WG_PORT"
    printf "\n"
}


# ============================================================
# Existing server menu
# ============================================================

existing_server_menu() {

    while true; do

        show_menu

        local choice

        read -r -p "Select an option: " choice

        case "$choice" in

            1)
                add_client_workflow
                read -r -p "Press Enter to continue..."
                ;;

            2)
                list_clients
                read -r -p "Press Enter to continue..."
                ;;

            3)
                remove_client
                read -r -p "Press Enter to continue..."
                ;;

            4)
                edit_server_configuration
                read -r -p "Press Enter to continue..."
                ;;

            5)
                show_status
                read -r -p "Press Enter to continue..."
                ;;

            6)
                restart_wireguard
                read -r -p "Press Enter to continue..."
                ;;

            7)
                remove_wireguard_setup
                return
                ;;

            8)
                show_server_information
                read -r -p "Press Enter to continue..."
                ;;

            9)
                printf "\n"
                ok "Goodbye."
                exit 0
                ;;

            *)
                warn "Invalid menu option."
                warn "Choose a number from 1 to 9."
                sleep 1
                ;;

        esac

    done
}


# ============================================================
# Main
# ============================================================

main() {

    require_root

    umask 077

    banner

    # --------------------------------------------------------
    # Existing WireGuard configuration
    # --------------------------------------------------------

    if [[ -f "${WG_DIR}/${WG_INTERFACE}.conf" ]]; then

        SERVER_CONF="${WG_DIR}/${WG_INTERFACE}.conf"
        EXISTING_CONFIG=1

        if ! command_exists wg || ! command_exists wg-quick; then
            info "WireGuard configuration exists but required commands are missing."
            install_packages
        fi

        extract_existing_server_config

        existing_server_menu

        exit 0
    fi


    # --------------------------------------------------------
    # No existing configuration
    # --------------------------------------------------------

    printf "%bNo WireGuard server configuration was found.%b\n\n" \
        "$YELLOW" "$NC"

    printf "  %b1%b) Create new WireGuard server\n" "$CYAN" "$NC"
    printf "  %b2%b) Show current network information\n" "$CYAN" "$NC"
    printf "  %b3%b) Exit\n" "$CYAN" "$NC"

    printf "\n"

    while true; do

        local choice

        read -r -p "Select an option: " choice

        case "$choice" in

            1)
                install_packages

                mkdir -p \
                    "$WG_DIR" \
                    "$CLIENT_DIR"

                chmod 700 \
                    "$WG_DIR" \
                    "$CLIENT_DIR"

                SERVER_CONF="${WG_DIR}/${WG_INTERFACE}.conf"

                new_server_workflow

                printf "\n"
                printf "You can now run this script again to manage the server.\n"
                exit 0
                ;;

            2)
                install_packages
                show_current_network_state
                read -r -p "Press Enter to continue..."
                ;;

            3)
                printf "\n"
                ok "Goodbye."
                exit 0
                ;;

            *)
                warn "Invalid menu option."
                warn "Choose 1, 2 or 3."
                ;;

        esac

    done
}


main "$@"