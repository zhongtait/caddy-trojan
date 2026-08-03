#!/bin/bash
# EasyTrojan module: common.sh
# shellcheck shell=bash

usage() {
    cat <<'EOF'
EasyTrojan - One-click Caddy-Trojan installer

Usage:
  bash easytrojan.sh install --domain DOMAIN [--password PASSWORD] [--version VERSION] [--outbound-ip ipv4|ipv6] [--skip-domain-check]
                             [--tls-mode auto|origin] [--origin-cert PATH] [--origin-key PATH] [--tune-system]
  bash easytrojan.sh update  [--version VERSION]
  bash easytrojan.sh renew [--force]
  bash easytrojan.sh status [--show-link] [--server ADDR] [--port PORT] [--name NAME]
  bash easytrojan.sh doctor
  bash easytrojan.sh link [--server ADDR] [--port PORT] [--password PASSWORD] [--name NAME]
  bash easytrojan.sh cert auto
  bash easytrojan.sh cert origin --cert PATH --key PATH
  bash easytrojan.sh cert status
  bash easytrojan.sh user add [--password PASSWORD]
  bash easytrojan.sh user list
  bash easytrojan.sh user del --password PASSWORD
  bash easytrojan.sh hub enable [--name NAME]
  bash easytrojan.sh hub disable|status|token|list|leave
  bash easytrojan.sh hub url [--server ADDR] [--port PORT]
  bash easytrojan.sh hub rename --name NEW_NAME
  bash easytrojan.sh hub rename --id NODE_ID --name NEW_NAME
  bash easytrojan.sh hub join --url URL --token TOKEN [--name NAME] [--server ADDR] [--port PORT]
  bash easytrojan.sh hub remove --id NODE_ID
  bash easytrojan.sh help

Legacy:
  bash easytrojan.sh <password> <domain>

Examples:
  bash easytrojan.sh install --domain example.com
  bash easytrojan.sh install --domain example.com --password 'strong_password'
  bash easytrojan.sh install --domain example.com --outbound-ip ipv6
  bash easytrojan.sh install --domain example.com --tls-mode origin \
       --origin-cert /root/origin.pem --origin-key /root/origin.key --skip-domain-check
  bash easytrojan.sh cert origin --cert /root/origin.pem --key /root/origin.key
  bash easytrojan.sh update --version v2.11.3+trojan.932ef9b
  bash easytrojan.sh status
  bash easytrojan.sh status --show-link
  bash easytrojan.sh status --show-link --server 104.16.1.1
  bash easytrojan.sh link --server 104.16.1.1
  bash easytrojan.sh user add
  bash easytrojan.sh user list

Notes:
  - A real domain is required; free IP wildcard domains are not used
  - Domain A record must point to this server before install
  - Open TCP 80 and 443 (security group / firewall) before install
  - status does not print share links by default (use --show-link)
  - --server ADDR: share-link address for Cloudflare preferred IP (SNI/Host still use domain)
  - --port PORT: connect port for share links / subscription (default 443; CF HTTPS ports ok)
  - --tls-mode auto: Caddy ACME (default). origin: Cloudflare Origin / file certs
  - --outbound-ip ipv4|ipv6: prefer this address family for Trojan outbound
    connections, while retaining fallback to the other family (default: ipv4)
  - BBR + safe proxy network tuning (tcp_slow_start_after_idle, tcp_notsent_lowat)
    are enabled automatically when supported by the host kernel
  - --tune-system: opt in to additional global sysctl and security limit tuning
  - Reinstall without --tls-mode keeps previous TLS mode; origin reuses /etc/caddy/certs if present
  - Trojan WebSocket client ALPN must be http/1.1 only (do not add h2)
  - Camouflage site defaults to CorentinTh/it-tools (override: IT_TOOLS_VERSION=..., IT_TOOLS_SHA256=...)
  - hub: optional node aggregation + base64 subscription on one machine
  - subscribe preferred IP (ALL nodes rewritten for that pull):
      https://hub-domain/sub/<token>?server=IP&port=443
      or: easytrojan hub url --server IP --port 443
  - join --server/--port: per-node default connect address (independent of ?server=)
  - hub enable --name / hub rename --name: custom display name in subscription
  - hub join saves /etc/caddy/trojan/hub-client.json so user add/del can re-sync remote hub
  - hub requires python3 >= 3.8 (auto-installs via apt/dnf/yum if missing)
EOF
}

detect_arch() {
    case $(uname -m) in
        x86_64|amd64)  echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *) error "Unsupported architecture: $(uname -m)" ;;
    esac
}

is_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS=.
    # shellcheck disable=SC2086
    set -- $ip
    [ "$1" -le 255 ] && [ "$2" -le 255 ] && [ "$3" -le 255 ] && [ "$4" -le 255 ]
}

normalize_outbound_ip_priority() {
    local value
    value=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    case "$value" in
        ipv4|4) printf 'ipv4' ;;
        ipv6|6) printf 'ipv6' ;;
        *) error "--outbound-ip must be ipv4 or ipv6 (got: $1)" ;;
    esac
}

read_outbound_ip_priority() {
    local value=""
    if [ -f "$OUTBOUND_IP_PRIORITY_FILE" ]; then
        value=$(head -1 "$OUTBOUND_IP_PRIORITY_FILE" 2>/dev/null || true)
    fi
    case "$value" in
        ipv4|ipv6) printf '%s' "$value" ;;
        *) printf 'ipv4' ;;
    esac
}

current_outbound_ip_priority() {
    if [ -n "${outbound_ip_priority:-}" ]; then
        printf '%s' "$outbound_ip_priority"
    else
        read_outbound_ip_priority
    fi
}

prompt_outbound_ip_priority() {
    if [ -z "${outbound_ip_priority:-}" ] && [ -t 0 ]; then
        local choice=""
        read -rp "Trojan outbound IP family [1 IPv4 (default), 2 IPv6]: " choice
        case "$choice" in
            ""|1|4|ipv4|IPv4) outbound_ip_priority="ipv4" ;;
            2|6|ipv6|IPv6) outbound_ip_priority="ipv6" ;;
            *) error "Please choose 1 (IPv4) or 2 (IPv6)" ;;
        esac
    fi
    outbound_ip_priority=$(normalize_outbound_ip_priority "${outbound_ip_priority:-ipv4}")
}

# Send an HTTP request with curl while keeping secrets out of argv (ps auxww).
# The hub token (if any) is written to a 0600 --config file; a JSON body (if any)
# is written to a 0600 --data-binary file. Non-secret flags/URL pass through.
#
#   http_send_json <METHOD> <URL> <TOKEN> <PAYLOAD> [extra curl flags...]
#
# TOKEN or PAYLOAD may be "" to omit. Echoes curl stdout; returns curl's status.
http_send_json() {
    local method="$1" url="$2" token="$3" payload="$4"
    shift 4
    local cfg="" body="" rc
    local -a args=(-X "$method")
    if [ -n "$token" ] || [ -n "$payload" ]; then
        cfg=$(mktemp) || return 1
        chmod 600 "$cfg" 2>/dev/null || true
        : > "$cfg"
        [ -n "$payload" ] && printf 'header = "Content-Type: application/json"\n' >> "$cfg"
        [ -n "$token" ] && printf 'header = "X-Hub-Token: %s"\n' "$token" >> "$cfg"
        args+=(--config "$cfg")
    fi
    if [ -n "$payload" ]; then
        body=$(mktemp) || { rm -f "$cfg"; return 1; }
        chmod 600 "$body" 2>/dev/null || true
        printf '%s' "$payload" > "$body"
        args+=(--data-binary "@${body}")
    fi
    curl "$@" "${args[@]}" "$url"
    rc=$?
    [ -n "$cfg" ] && rm -f "$cfg"
    [ -n "$body" ] && rm -f "$body"
    return "$rc"
}

# Validate a user-supplied TCP port (1-65535); error out with a clear message.
# Ports flow unquoted into JSON payloads, so reject non-numeric input early.
validate_port() {
    local p="$1" label="${2:---port}"
    if ! [[ "$p" =~ ^[0-9]+$ ]] || [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then
        error "${label} must be a number between 1 and 65535 (got: ${p})"
    fi
}

urlencode() {
    local s="$1" out="" i c hex
    local LC_ALL=C
    for (( i = 0; i < ${#s}; i++ )); do
        c="${s:i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) out+="$c" ;;
            *)
                printf -v hex '%%%02X' "'$c"
                out+="$hex"
                ;;
        esac
    done
    printf '%s' "$out"
}

json_escape() {
    local s="$1"
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/\\r}
    s=${s//$'\t'/\\t}
    printf '%s' "$s"
}

install_os_package() {
    local apt_pkg="$1" rpm_pkg="${2:-$1}"
    if check_cmd dnf; then
        dnf install -y "$rpm_pkg" &>/dev/null \
            || error "Failed to install $rpm_pkg via dnf"
    elif check_cmd yum; then
        yum install -y "$rpm_pkg" &>/dev/null \
            || error "Failed to install $rpm_pkg via yum"
    elif check_cmd apt-get; then
        if [ "${EASYTROJAN_APT_UPDATED:-0}" != "1" ]; then
            apt-get update -qq &>/dev/null || true
            EASYTROJAN_APT_UPDATED=1
        fi
        apt-get install -y "$apt_pkg" &>/dev/null \
            || error "Failed to install $apt_pkg via apt-get"
    else
        error "Unable to install packages: no supported package manager found"
    fi
}

install_pkg() {
    local command_name="$1" apt_pkg="${2:-$1}" rpm_pkg="${3:-${2:-$1}}"
    check_cmd "$command_name" && return 0
    info "Installing dependency: $command_name..."
    install_os_package "$apt_pkg" "$rpm_pkg"
    check_cmd "$command_name" \
        || error "Installed package for $command_name, but the command is still unavailable"
}

ensure_install_dependencies() {
    check_cmd systemctl \
        || error "systemd is required, but systemctl is unavailable"

    # Network, archive, TLS, binary validation and camouflage-site tools.
    install_pkg curl
    install_pkg tar
    install_pkg unzip
    install_pkg openssl
    install_pkg file

    # ip and ss share one package, whose name differs by distribution family.
    install_pkg ip iproute2 iproute
    install_pkg ss iproute2 iproute

    # Creating the dedicated caddy account requires these commands.
    install_pkg useradd passwd shadow-utils
    install_pkg groupadd passwd shadow-utils

    # HTTPS downloads need a system trust store even when curl already exists.
    if [ ! -r /etc/ssl/certs/ca-certificates.crt ] \
        && [ ! -r /etc/pki/tls/certs/ca-bundle.crt ]; then
        info "Installing dependency: CA certificates..."
        install_os_package ca-certificates ca-certificates
    fi
}


prompt_domain() {
    if [ -z "${caddy_domain:-}" ]; then
        if [ -t 0 ]; then
            read -rp "Domain (required, A record must point to this server): " caddy_domain
        else
            error "Domain required. Use --domain example.com"
        fi
    fi
    # Normalize: strip scheme/path/port/spaces, lowercase, drop trailing dots
    caddy_domain=$(printf '%s' "${caddy_domain:-}" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    caddy_domain=${caddy_domain#http://}
    caddy_domain=${caddy_domain#https://}
    caddy_domain=${caddy_domain%%/*}
    caddy_domain=${caddy_domain%%:*}
    caddy_domain=${caddy_domain%.}
    caddy_domain=${caddy_domain%.}
    [ -n "$caddy_domain" ] || error "Domain cannot be empty"
    if ! [[ "$caddy_domain" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; then
        error "Invalid domain: $caddy_domain"
    fi
}
prompt_password() {
    if [ -z "${trojan_passwd:-}" ]; then
        if [ -t 0 ]; then
            read -rsp "Trojan password: " trojan_passwd
            echo
            read -rsp "Confirm password: " trojan_passwd2
            echo
            [ "$trojan_passwd" = "$trojan_passwd2" ] || error "Passwords do not match"
        else
            error "Password required. Use --password or run interactively."
        fi
    fi
    [ -n "$trojan_passwd" ] || error "Password cannot be empty"
    if [ "${#trojan_passwd}" -lt 12 ]; then
        warn "Password is shorter than 12 characters. A strong random password is recommended."
    fi
}

# Assigns the shared entry-point globals consumed by install/manage modules
# (those cross-module reads are invisible to per-file static analysis).
# shellcheck disable=SC2034
parse_common_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --password)
                [ -n "${2:-}" ] || error "--password requires a value"
                trojan_passwd="$2"
                shift 2
                ;;
            --domain)
                [ -n "${2:-}" ] || error "--domain requires a value"
                caddy_domain="$2"
                shift 2
                ;;
            --version)
                [ -n "${2:-}" ] || error "--version requires a value"
                release_version="$2"
                shift 2
                ;;
            --outbound-ip|--ip-priority)
                [ -n "${2:-}" ] || error "--outbound-ip requires ipv4 or ipv6"
                outbound_ip_priority=$(normalize_outbound_ip_priority "$2")
                shift 2
                ;;
            --skip-domain-check)
                skip_domain_check="1"
                shift
                ;;
            --tls-mode)
                [ -n "${2:-}" ] || error "--tls-mode requires auto or origin"
                tls_mode="$2"
                shift 2
                ;;
            --origin-cert)
                [ -n "${2:-}" ] || error "--origin-cert requires a path"
                origin_cert_src="$2"
                shift 2
                ;;
            --origin-key)
                [ -n "${2:-}" ] || error "--origin-key requires a path"
                origin_key_src="$2"
                shift 2
                ;;
            --tune-system)
                tune_system="1"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                error "Unknown argument: $1"
                ;;
        esac
    done
}

detect_public_ip() {
    local ip service
    for service in "https://ipv4.ip.sb" "https://api.ipify.org" "https://ifconfig.me" "https://icanhazip.com"; do
        ip=$(curl -fsS --connect-timeout 5 --max-time 10 "$service" 2>/dev/null | tr -d '[:space:]' || true)
        if is_ipv4 "$ip"; then
            printf '%s' "$ip"
            return 0
        fi
    done
    return 1
}

resolve_domain_ipv4_list() {
    local domain="$1" ips=""
    if check_cmd dig; then
        ips=$(dig +short A "$domain" 2>/dev/null | grep -E '^[0-9.]+$' || true)
    fi
    if [ -z "$ips" ] && check_cmd getent; then
        ips=$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u || true)
    fi
    if [ -z "$ips" ] && check_cmd host; then
        ips=$(host -t A "$domain" 2>/dev/null | awk '/has address/ {print $4}' || true)
    fi
    if [ -z "$ips" ] && check_cmd python3; then
        ips=$(python3 -c 'import socket,sys
for a in socket.getaddrinfo(sys.argv[1], None, socket.AF_INET):
    print(a[4][0])
' "$domain" 2>/dev/null | sort -u || true)
    fi
    if [ -z "$ips" ]; then
        ips=$(ping "$domain" -c 1 -W 5 2>/dev/null | sed '1{s/[^(]*(//;s/).*//;q}' || true)
    fi
    # unique keep order
    printf '%s\n' "$ips" | tr ' ' '\n' | awk 'NF && !seen[$0]++'
}

resolve_domain_ipv4() {
    resolve_domain_ipv4_list "$1" | head -n 1
}

domain_points_to_ip() {
    local domain="$1" expect="$2" ip
    while IFS= read -r ip; do
        [ "$ip" = "$expect" ] && return 0
    done < <(resolve_domain_ipv4_list "$domain")
    return 1
}

read_installed_domain() {
    if [ -f "$DOMAIN_FILE" ]; then
        head -1 "$DOMAIN_FILE"
        return 0
    fi
    if [ -f "$CADDYFILE" ]; then
        awk '
            $0 ~ /^:443,/ {
                line=$0
                sub(/^:443,[[:space:]]*/, "", line)
                sub(/[[:space:]].*$/, "", line)
                print line
                exit
            }
        ' "$CADDYFILE"
        return 0
    fi
    return 1
}

build_share_link() {
    local domain="$1" passwd="$2" transport="${3:-ws}" server="${4:-}" port="${5:-443}" name="${6:-$1}"
    local encoded display_name addr
    encoded=$(urlencode "$passwd")
    display_name=$(urlencode "$name")
    addr="${server:-$domain}"
    port="${port:-443}"
    [ -n "$addr" ] || error "Share link needs domain or --server address"
    if [ "$transport" = "ws" ]; then
        # Address may be CF anycast IP; SNI + WS Host must remain the real domain.
        # WebSocket Upgrade is HTTP/1.1; h2-first ALPN causes intermittent handshake failures.
        printf 'trojan://%s@%s:%s?security=tls&sni=%s&alpn=http%%2F1.1&type=ws&host=%s&path=%%2F#%s' \
            "$encoded" "$addr" "$port" "$domain" "$domain" "$display_name"
    else
        printf 'trojan://%s@%s:%s?security=tls&sni=%s&alpn=http%%2F1.1&type=tcp#%s' \
            "$encoded" "$addr" "$port" "$domain" "$display_name"
    fi
}
