#!/bin/bash
# EasyTrojan module: common.sh
# shellcheck shell=bash

usage() {
    cat <<'EOF'
EasyTrojan - One-click Caddy-Trojan installer

Usage:
  bash easytrojan.sh install --domain DOMAIN [--password PASSWORD] [--version VERSION] [--skip-domain-check]
                             [--tls-mode auto|origin] [--origin-cert PATH] [--origin-key PATH]
  bash easytrojan.sh update  [--version VERSION]
  bash easytrojan.sh renew [--force]
  bash easytrojan.sh status [--show-link] [--server ADDR] [--port PORT]
  bash easytrojan.sh link [--server ADDR] [--port PORT] [--password PASSWORD]
  bash easytrojan.sh cert auto
  bash easytrojan.sh cert origin --cert PATH --key PATH
  bash easytrojan.sh cert status
  bash easytrojan.sh user add [--password PASSWORD]
  bash easytrojan.sh user list
  bash easytrojan.sh user del --password PASSWORD
  bash easytrojan.sh hub enable|disable|status|url|token|list|remove|join|leave
  bash easytrojan.sh hub join --url URL --token TOKEN [--name NAME] [--server ADDR] [--port PORT]
  bash easytrojan.sh hub leave
  bash easytrojan.sh help

Legacy:
  bash easytrojan.sh <password> <domain>

Examples:
  bash easytrojan.sh install --domain example.com
  bash easytrojan.sh install --domain example.com --password 'strong_password'
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
  - Reinstall without --tls-mode keeps previous TLS mode; origin reuses /etc/caddy/certs if present
  - Camouflage site defaults to CorentinTh/it-tools (override: IT_TOOLS_VERSION=...)
  - hub: optional node aggregation + base64 subscription on one machine
  - subscribe with preferred IP: https://hub-domain/sub/<token>?server=IP&port=443
  - hub join saves /etc/caddy/trojan/hub-client.json so user add/del can re-sync remote hub
  - hub requires python3 >= 3.8
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

install_pkg() {
    local pkg="$1"
    check_cmd "$pkg" && return 0
    info "Installing $pkg..."
    if check_cmd dnf; then
        dnf install -y "$pkg" &>/dev/null || error "Failed to install $pkg via dnf"
    elif check_cmd yum; then
        yum install -y "$pkg" &>/dev/null || error "Failed to install $pkg via yum"
    elif check_cmd apt-get; then
        apt-get update -qq &>/dev/null || true
        apt-get install -y "$pkg" &>/dev/null || error "Failed to install $pkg via apt-get"
    else
        error "Unable to install $pkg: no supported package manager found"
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
    local domain="$1" passwd="$2" transport="${3:-ws}" server="${4:-}" port="${5:-443}"
    local encoded addr
    encoded=$(urlencode "$passwd")
    addr="${server:-$domain}"
    port="${port:-443}"
    [ -n "$addr" ] || error "Share link needs domain or --server address"
    if [ "$transport" = "ws" ]; then
        # Address may be CF anycast IP; SNI + WS Host must remain the real domain.
        printf 'trojan://%s@%s:%s?security=tls&sni=%s&type=ws&host=%s&path=%%2F#%s' \
            "$encoded" "$addr" "$port" "$domain" "$domain" "$domain"
    else
        printf 'trojan://%s@%s:%s?security=tls&sni=%s&type=tcp#%s' \
            "$encoded" "$addr" "$port" "$domain" "$domain"
    fi
}
