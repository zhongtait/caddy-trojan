#!/bin/bash
#
# EasyTrojan - One-click Caddy-Trojan installer
# Supports: CentOS/RedHat 7+, Debian 9+, Ubuntu 16+
#
# Usage:
#   bash easytrojan.sh install --domain DOMAIN [--password PASS] [--version VER] [--skip-domain-check]
#                            [--tls-mode auto|origin] [--origin-cert PATH] [--origin-key PATH]
#   bash easytrojan.sh update  [--version VER]
#   bash easytrojan.sh renew [--force]
#   bash easytrojan.sh status [--show-link] [--server ADDR]
#   bash easytrojan.sh link [--server ADDR] [--password PASS]
#   bash easytrojan.sh cert {auto|origin|status} ...
#   bash easytrojan.sh user {add|list|del} ...
#   bash easytrojan.sh <password> <domain>   # legacy
#
# Based on: https://github.com/imgk/caddy-trojan
# Project:  https://github.com/zhongtait/caddy-trojan

set -euo pipefail

REPO_OWNER="zhongtait"
REPO_NAME="caddy-trojan"
REPO_RAW="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/main"
REPO_API="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}"
CADDY_BIN="/usr/local/bin/caddy"
SCRIPT_BIN="/usr/local/bin/easytrojan"
SCRIPT_LEGACY="/usr/local/bin/easytrojan.sh"
CADDY_DIR="/etc/caddy"
TROJAN_DIR="${CADDY_DIR}/trojan"
PASSWD_FILE="${TROJAN_DIR}/passwd.txt"
DOMAIN_FILE="${TROJAN_DIR}/domain.txt"
TLS_MODE_FILE="${TROJAN_DIR}/tls-mode.txt"
TLS_CERT_FILE_REC="${TROJAN_DIR}/tls-cert.path"
TLS_KEY_FILE_REC="${TROJAN_DIR}/tls-key.path"
ORIGIN_CERT_DIR="${CADDY_DIR}/certs"
ORIGIN_CERT_DEFAULT="${ORIGIN_CERT_DIR}/origin.crt"
ORIGIN_KEY_DEFAULT="${ORIGIN_CERT_DIR}/origin.key"
CADDYFILE="${CADDY_DIR}/Caddyfile"
WWW_DIR="${CADDY_DIR}/www"
ADMIN_API="http://127.0.0.1:2019"
# Static camouflage site: CorentinTh/it-tools release zip (Vue SPA)
IT_TOOLS_REPO="CorentinTh/it-tools"
IT_TOOLS_VERSION="${IT_TOOLS_VERSION:-latest}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

check_cmd() { command -v "$1" &>/dev/null; }
require_root() { [ "$(id -u)" = "0" ] || error "You must be root to run this script"; }

usage() {
    cat <<'EOF'
EasyTrojan - One-click Caddy-Trojan installer

Usage:
  bash easytrojan.sh install --domain DOMAIN [--password PASSWORD] [--version VERSION] [--skip-domain-check]
                             [--tls-mode auto|origin] [--origin-cert PATH] [--origin-key PATH]
  bash easytrojan.sh update  [--version VERSION]
  bash easytrojan.sh renew [--force]
  bash easytrojan.sh status [--show-link] [--server ADDR]
  bash easytrojan.sh link [--server ADDR] [--password PASSWORD]
  bash easytrojan.sh cert auto
  bash easytrojan.sh cert origin --cert PATH --key PATH
  bash easytrojan.sh cert status
  bash easytrojan.sh user add [--password PASSWORD]
  bash easytrojan.sh user list
  bash easytrojan.sh user del --password PASSWORD
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
  - --tls-mode auto: Caddy ACME (default). origin: Cloudflare Origin / file certs
  - Reinstall without --tls-mode keeps previous TLS mode; origin reuses /etc/caddy/certs if present
  - Camouflage site defaults to CorentinTh/it-tools (override: IT_TOOLS_VERSION=...)
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


read_tls_mode() {
    if [ -f "$TLS_MODE_FILE" ]; then
        tr -d '[:space:]' < "$TLS_MODE_FILE" | tr '[:upper:]' '[:lower:]'
    else
        printf 'auto'
    fi
}

read_tls_cert_path() {
    if [ -f "$TLS_CERT_FILE_REC" ]; then
        tr -d '\r\n' < "$TLS_CERT_FILE_REC"
    else
        printf '%s' "$ORIGIN_CERT_DEFAULT"
    fi
}

read_tls_key_path() {
    if [ -f "$TLS_KEY_FILE_REC" ]; then
        tr -d '\r\n' < "$TLS_KEY_FILE_REC"
    else
        printf '%s' "$ORIGIN_KEY_DEFAULT"
    fi
}

normalize_tls_mode() {
    local m
    m=$(printf '%s' "${1:-auto}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
    case "$m" in
        auto|acme|le|letsencrypt) printf 'auto' ;;
        origin|cf|cloudflare|file) printf 'origin' ;;
        *) error "Invalid tls mode: $1 (use auto or origin)" ;;
    esac
}

persist_tls_config() {
    local mode="$1" cert_path="${2:-}" key_path="${3:-}"
    mkdir -p "$TROJAN_DIR"
    chmod 700 "$TROJAN_DIR"
    printf '%s\n' "$mode" > "$TLS_MODE_FILE"
    chown caddy:caddy "$TLS_MODE_FILE" 2>/dev/null || true
    chmod 600 "$TLS_MODE_FILE"
    if [ "$mode" = "origin" ]; then
        printf '%s\n' "$cert_path" > "$TLS_CERT_FILE_REC"
        printf '%s\n' "$key_path" > "$TLS_KEY_FILE_REC"
        chown caddy:caddy "$TLS_CERT_FILE_REC" "$TLS_KEY_FILE_REC" 2>/dev/null || true
        chmod 600 "$TLS_CERT_FILE_REC" "$TLS_KEY_FILE_REC"
    else
        rm -f "$TLS_CERT_FILE_REC" "$TLS_KEY_FILE_REC"
    fi
}

# Install origin cert/key into /etc/caddy/certs (or keep absolute paths if already under CADDY_DIR)
install_origin_material() {
    local src_cert="$1" src_key="$2"
    [ -n "$src_cert" ] && [ -f "$src_cert" ] || error "Origin certificate not found: ${src_cert:-<empty>}"
    [ -n "$src_key" ] && [ -f "$src_key" ] || error "Origin private key not found: ${src_key:-<empty>}"

    mkdir -p "$ORIGIN_CERT_DIR"
    cp -f "$src_cert" "$ORIGIN_CERT_DEFAULT"
    cp -f "$src_key" "$ORIGIN_KEY_DEFAULT"
    chown caddy:caddy "$ORIGIN_CERT_DEFAULT" "$ORIGIN_KEY_DEFAULT"
    chmod 600 "$ORIGIN_CERT_DEFAULT" "$ORIGIN_KEY_DEFAULT"
    chmod 700 "$ORIGIN_CERT_DIR"
    chown caddy:caddy "$ORIGIN_CERT_DIR"

    if check_cmd openssl; then
        openssl x509 -in "$ORIGIN_CERT_DEFAULT" -noout -subject >/dev/null 2>&1             || error "Invalid certificate file: $ORIGIN_CERT_DEFAULT"
        if ! openssl pkey -in "$ORIGIN_KEY_DEFAULT" -check -noout >/dev/null 2>&1             && ! openssl rsa -in "$ORIGIN_KEY_DEFAULT" -check -noout >/dev/null 2>&1; then
            warn "Could not fully validate private key format (continuing)"
        fi
    fi
    ok "Origin certificate installed at $ORIGIN_CERT_DEFAULT"
}

tls_directive_line() {
    local mode cert_path key_path site_domain="$1"
    mode=$(read_tls_mode)
    if [ "$mode" = "origin" ]; then
        cert_path=$(read_tls_cert_path)
        key_path=$(read_tls_key_path)
        [ -f "$cert_path" ] || error "TLS origin cert missing: $cert_path (run: easytrojan cert origin --cert ... --key ...)"
        [ -f "$key_path" ] || error "TLS origin key missing: $key_path"
        printf '    tls %s %s\n' "$cert_path" "$key_path"
    else
        printf '    tls admin@%s\n' "$site_domain"
    fi
}

# Build trojan share URI.
# $1 domain (SNI/Host/remark), $2 password, $3 transport ws|tcp,
# $4 optional connect address (Cloudflare preferred IP/host). Defaults to domain.
build_share_link() {
    local domain="$1" passwd="$2" transport="${3:-ws}" server="${4:-}"
    local encoded addr
    encoded=$(urlencode "$passwd")
    addr="${server:-$domain}"
    [ -n "$addr" ] || error "Share link needs domain or --server address"
    if [ "$transport" = "ws" ]; then
        # Address may be CF anycast IP; SNI + WS Host must remain the real domain.
        printf 'trojan://%s@%s:443?security=tls&sni=%s&type=ws&host=%s&path=%%2F#%s' \
            "$encoded" "$addr" "$domain" "$domain" "$domain"
    else
        printf 'trojan://%s@%s:443?security=tls&sni=%s&type=tcp#%s' \
            "$encoded" "$addr" "$domain" "$domain"
    fi
}

release_asset_base() {
    local version="${1:-latest}"
    if [ "$version" = "latest" ] || [ -z "$version" ]; then
        printf 'https://github.com/%s/%s/releases/latest/download' "$REPO_OWNER" "$REPO_NAME"
    else
        printf 'https://github.com/%s/%s/releases/download/%s' "$REPO_OWNER" "$REPO_NAME" "$version"
    fi
}

sha256_file() {
    local file="$1"
    if check_cmd sha256sum; then
        sha256sum "$file" | awk '{print $1}'
    elif check_cmd shasum; then
        shasum -a 256 "$file" | awk '{print $1}'
    elif check_cmd openssl; then
        openssl dgst -sha256 "$file" | awk '{print $NF}'
    else
        return 1
    fi
}

verify_archive_sha256() {
    local archive="$1" sums_file="$2" expected=""
    local base
    base=$(basename "$archive")
    expected=$(awk -v f="$base" '$2 == f {print $1; exit}' "$sums_file" 2>/dev/null || true)
    if [ -z "$expected" ]; then
        # also accept "hash  filename" with leading spaces
        expected=$(grep -E "[[:space:]]${base}$" "$sums_file" 2>/dev/null | awk '{print $1; exit}' || true)
    fi
    if [ -z "$expected" ]; then
        warn "SHA256SUMS has no entry for ${base}; skipping checksum verification"
        return 0
    fi
    local actual
    actual=$(sha256_file "$archive") || error "No sha256 tool available (sha256sum/shasum/openssl)"
    if [ "$actual" != "$expected" ]; then
        error "SHA256 mismatch for ${base}\n  expected: ${expected}\n  actual:   ${actual}"
    fi
    ok "SHA256 verified for ${base}"
}

download_caddy() {
    local arch version base_url tmp_dir archive sums
    arch=$(detect_arch)
    version="${release_version:-latest}"
    base_url=$(release_asset_base "$version")
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "$tmp_dir"' RETURN
    archive="${tmp_dir}/caddy_trojan_linux_${arch}.tar.gz"
    sums="${tmp_dir}/SHA256SUMS"

    info "Downloading Caddy-Trojan (${arch}, version=${version})..."
    if ! curl -fsSL --connect-timeout 15 --max-time 180 \
        "${base_url}/caddy_trojan_linux_${arch}.tar.gz" -o "$archive"; then
        error "Failed to download Caddy binary from ${base_url}"
    fi

    if curl -fsSL --connect-timeout 10 --max-time 30 "${base_url}/SHA256SUMS" -o "$sums" 2>/dev/null; then
        verify_archive_sha256 "$archive" "$sums"
    else
        warn "SHA256SUMS not found for this release; continuing without checksum"
    fi

    if ! tar -tzf "$archive" | grep -qx 'caddy'; then
        error "Archive does not contain expected 'caddy' binary"
    fi
    if ! tar -xzf "$archive" -C "$tmp_dir" caddy; then
        error "Failed to extract Caddy binary"
    fi
    chmod +x "${tmp_dir}/caddy"
    # Smoke-test when the binary can run on this host
    if ! "${tmp_dir}/caddy" version &>/dev/null; then
        if file "${tmp_dir}/caddy" 2>/dev/null | grep -qiE 'ELF.*(executable|shared object)'; then
            warn "Downloaded caddy could not execute 'version' (continuing; may be ok under QEMU/edge cases)"
        else
            error "Extracted caddy binary looks invalid"
        fi
    fi
    mv -f "${tmp_dir}/caddy" "$CADDY_BIN"
    chmod 755 "$CADDY_BIN"
    trap - RETURN
    rm -rf "$tmp_dir"
}

wait_for_admin_api() {
    local i
    for i in $(seq 1 15); do
        curl -sf "${ADMIN_API}/config/" &>/dev/null && return 0
        sleep 1
    done
    return 1
}

assert_admin_local_only() {
    # Best-effort: ensure nothing is listening on 0.0.0.0:2019 / *:2019
    local listeners=""
    if check_cmd ss; then
        listeners=$(ss -Hltn 'sport = :2019' 2>/dev/null || true)
    elif check_cmd lsof; then
        listeners=$(lsof -iTCP:2019 -sTCP:LISTEN 2>/dev/null || true)
    fi
    if echo "$listeners" | grep -Eq '0\.0\.0\.0:2019|\*:2019|:::2019'; then
        error "Caddy Admin API appears exposed beyond localhost:\n${listeners}\nFix Caddyfile admin bind and restart."
    fi
}

# Quote a password for Caddyfile tokens (double-quoted string).
caddyfile_quote() {
    local s="$1"
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    printf '"%s"' "$s"
}

# Build users directive args: users "p1" "p2"
build_users_directive() {
    local line q args=""
    if [ -f "$PASSWD_FILE" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            [ -n "$line" ] || continue
            q=$(caddyfile_quote "$line")
            args="${args} ${q}"
        done < "$PASSWD_FILE"
    fi
    args=${args# }
    if [ -n "$args" ]; then
        printf '        users %s\n' "$args"
    fi
}

# Generate /etc/caddy/Caddyfile from domain + passwd.txt.
# Users are declared statically (imgk official style). With `caddy` upstream,
# keys also live in Caddy storage; delete must clear storage via Admin API.
generate_caddyfile() {
    local site_domain="${1:-}"
    if [ -z "$site_domain" ]; then
        site_domain=$(read_installed_domain 2>/dev/null || true)
    fi
    [ -n "$site_domain" ] || error "Domain not set; cannot generate Caddyfile"
    mkdir -p "$CADDY_DIR" "$WWW_DIR" "$TROJAN_DIR"
    local users_block tls_line
    users_block=$(build_users_directive)
    # NOTE: $(...) strips trailing newlines; keep ${tls_line} on its own line in the heredoc.
    tls_line=$(tls_directive_line "$site_domain")

    cat > "$CADDYFILE" <<EOF
{
    admin 127.0.0.1:2019
    order trojan before file_server
    https_port 443
    servers :443 {
        listener_wrappers {
            trojan
        }
        protocols h2 h1
    }
    servers :80 {
        protocols h1
    }
    trojan {
        caddy
        no_proxy
${users_block}    }
}
:443, ${site_domain} {
${tls_line}
    log {
        level ERROR
    }
    trojan {
        connect_method
        websocket
    }
    # IT-Tools is a Vue SPA: unknown paths fall back to index.html
    root * ${WWW_DIR}
    try_files {path} /index.html
    file_server
}
# HTTP-01 ACME needs port 80; do not blanket-redirect challenge paths
:80 {
    @not_acme {
        not path /.well-known/acme-challenge/*
    }
    redir @not_acme https://{host}{uri} permanent
    root * ${WWW_DIR}
    file_server
}
EOF
    chown caddy:caddy "$CADDYFILE"
    chmod 600 "$CADDYFILE"
    printf '%s\n' "$site_domain" > "$DOMAIN_FILE"
    chown caddy:caddy "$DOMAIN_FILE"
    chmod 600 "$DOMAIN_FILE"
}

# Best-effort clear of a user from caddy storage (imgk CaddyUpstream).
# Required on delete: removing from Caddyfile alone does not drop storage keys.
delete_trojan_user_storage() {
    local passwd="$1" payload
    payload=$(printf '{"password":"%s"}' "$(json_escape "$passwd")")
    # imgk/caddy-trojan: DELETE /trojan/users/delete  body: {"password":"..."}
    curl -sf -X DELETE -H "Content-Type: application/json" -d "$payload" "${ADMIN_API}/trojan/users/delete"
}

remove_password_from_file() {
    local passwd="$1"
    [ -f "$PASSWD_FILE" ] || return 0
    local tmp
    tmp=$(mktemp)
    # exact line match only
    grep -Fxv -- "$passwd" "$PASSWD_FILE" > "$tmp" || true
    mv -f "$tmp" "$PASSWD_FILE"
    chmod 600 "$PASSWD_FILE"
    chown caddy:caddy "$PASSWD_FILE" 2>/dev/null || true
}

reload_caddy() {
    if ! systemctl is-active --quiet caddy 2>/dev/null; then
        return 0
    fi
    if systemctl reload caddy.service 2>/dev/null; then
        return 0
    fi
    if [ -x "$CADDY_BIN" ] && "$CADDY_BIN" reload --config "$CADDYFILE" --force 2>/dev/null; then
        return 0
    fi
    warn "Caddy reload failed; restarting service..."
    systemctl restart caddy.service
}

mask_secret() {
    local s="$1" n=${#1}
    if [ "$n" -le 4 ]; then
        printf '****'
    else
        printf '%s***%s' "${s:0:2}" "${s: -2}"
    fi
}

persist_password() {
    local passwd="$1"
    mkdir -p "$TROJAN_DIR"
    chmod 700 "$TROJAN_DIR"
    touch "$PASSWD_FILE"
    chmod 600 "$PASSWD_FILE"
    chown caddy:caddy "$PASSWD_FILE" 2>/dev/null || true
    if ! grep -Fxq "$passwd" "$PASSWD_FILE" 2>/dev/null; then
        printf '%s\n' "$passwd" >> "$PASSWD_FILE"
    fi
    awk 'NF && !seen[$0]++' "$PASSWD_FILE" > "${PASSWD_FILE}.tmp"
    mv -f "${PASSWD_FILE}.tmp" "$PASSWD_FILE"
    chmod 600 "$PASSWD_FILE"
    chown caddy:caddy "$PASSWD_FILE" 2>/dev/null || true
}

install_self() {
    local src
    src=$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")
    if [ -f "$src" ]; then
        cp -f "$src" "$SCRIPT_BIN"
        cp -f "$src" "$SCRIPT_LEGACY"
        chmod 755 "$SCRIPT_BIN" "$SCRIPT_LEGACY"
    fi
}

write_camouflage_site() {
    mkdir -p "$WWW_DIR"
    if ! check_cmd unzip; then
        info "Installing unzip (needed for IT-Tools package)..."
        if check_cmd dnf; then dnf install -y unzip &>/dev/null || true
        elif check_cmd yum; then yum install -y unzip &>/dev/null || true
        elif check_cmd apt-get; then
            apt-get update -qq &>/dev/null || true
            apt-get install -y unzip &>/dev/null || true
        fi
    fi
    check_cmd curl || install_pkg curl

    local version="${IT_TOOLS_VERSION:-latest}"
    local api_url asset_url tmp_dir zip_path tag name extract_root
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "$tmp_dir"' RETURN

    info "Installing camouflage site: IT-Tools (${version})..."

    if [ "$version" = "latest" ]; then
        api_url="https://api.github.com/repos/${IT_TOOLS_REPO}/releases/latest"
    else
        # accept v2024... or 2024...
        case "$version" in
            v*) tag="$version" ;;
            *) tag="v${version}" ;;
        esac
        api_url="https://api.github.com/repos/${IT_TOOLS_REPO}/releases/tags/${tag}"
    fi

    if ! check_cmd unzip; then
        warn "unzip not available; using built-in fallback tools page"
        write_camouflage_fallback
        trap - RETURN
        rm -rf "$tmp_dir"
        return 0
    fi

    # Resolve zip asset URL from GitHub API (fallback to known latest pattern if API blocked)
    asset_url=""
    if curl -fsSL --connect-timeout 10 --max-time 30 \
        -H "Accept: application/vnd.github+json" \
        -H "User-Agent: easytrojan" \
        "$api_url" -o "${tmp_dir}/release.json" 2>/dev/null; then
        asset_url=$(python3 -c '
import json,sys
try:
  d=json.load(open(sys.argv[1],encoding="utf-8"))
  for a in d.get("assets") or []:
    n=a.get("name") or ""
    if n.endswith(".zip") and "it-tools" in n:
      print(a.get("browser_download_url",""))
      break
except Exception:
  pass
' "${tmp_dir}/release.json" 2>/dev/null || true)
        if [ -z "$asset_url" ]; then
            asset_url=$(grep -oE 'https://github.com/[^"]+it-tools[^"]+\.zip' "${tmp_dir}/release.json" 2>/dev/null | head -1 || true)
        fi
        tag=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1],encoding="utf-8")).get("tag_name",""))' "${tmp_dir}/release.json" 2>/dev/null || true)
    fi

    if [ -z "$asset_url" ]; then
        # Last-known public release zip (updated when project bumps default)
        asset_url="https://github.com/CorentinTh/it-tools/releases/download/v2024.10.22-7ca5933/it-tools-2024.10.22-7ca5933.zip"
        tag="v2024.10.22-7ca5933"
        warn "GitHub API unavailable; using pinned IT-Tools release ${tag}"
    fi

    zip_path="${tmp_dir}/it-tools.zip"
    if ! curl -fsSL --connect-timeout 15 --max-time 300 -L \
        -H "User-Agent: easytrojan" \
        "$asset_url" -o "$zip_path"; then
        warn "Failed to download IT-Tools zip; using built-in fallback tools page"
        write_camouflage_fallback
        trap - RETURN
        rm -rf "$tmp_dir"
        return 0
    fi

    # Clear previous site (keep dir)
    find "$WWW_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
    mkdir -p "${tmp_dir}/extract"
    if ! unzip -q "$zip_path" -d "${tmp_dir}/extract"; then
        warn "Failed to unzip IT-Tools; using built-in fallback tools page"
        write_camouflage_fallback
        trap - RETURN
        rm -rf "$tmp_dir"
        return 0
    fi

    # Zip may be flat (index.html at root) or nested in one folder
    if [ -f "${tmp_dir}/extract/index.html" ]; then
        extract_root="${tmp_dir}/extract"
    else
        local idx_html
        idx_html=$(find "${tmp_dir}/extract" -mindepth 1 -maxdepth 4 -type f -name index.html 2>/dev/null | head -1 || true)
        extract_root=$(dirname "$idx_html" 2>/dev/null || true)
    fi
    if [ -z "${extract_root:-}" ] || [ ! -f "${extract_root}/index.html" ]; then
        warn "IT-Tools archive layout unexpected; using fallback tools page"
        write_camouflage_fallback
        trap - RETURN
        rm -rf "$tmp_dir"
        return 0
    fi

    cp -a "${extract_root}/." "$WWW_DIR/"
    # Attribution for operators
    cat > "${WWW_DIR}/.it-tools-source.txt" <<EOF
source=https://github.com/${IT_TOOLS_REPO}
tag=${tag:-$version}
license=GPL-3.0
homepage=https://it-tools.tech
installed_by=easytrojan
EOF

    chown -R caddy:caddy "$WWW_DIR" 2>/dev/null || true
    find "$WWW_DIR" -type d -exec chmod 755 {} \; 2>/dev/null || true
    find "$WWW_DIR" -type f -exec chmod 644 {} \; 2>/dev/null || true
    ok "IT-Tools site installed to ${WWW_DIR} (${tag:-$version})"
    trap - RETURN
    rm -rf "$tmp_dir"
}

# Minimal offline SPA if GitHub download fails (still looks like a real tools site)
write_camouflage_fallback() {
    mkdir -p "${WWW_DIR}/assets"
    find "$WWW_DIR" -mindepth 1 -maxdepth 1 ! -name assets -exec rm -rf {} + 2>/dev/null || true
    cat > "${WWW_DIR}/assets/app.css" <<'EOF'
:root { --bg:#0b1220; --panel:#121a2b; --line:#243047; --text:#e8eefc; --muted:#93a0b8; --accent:#5b9dff; --ok:#3dd68c; --sans:ui-sans-serif,system-ui,sans-serif; --mono:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; }
* { box-sizing:border-box; } body { margin:0; font-family:var(--sans); background:radial-gradient(1000px 500px at 10% -10%,#172554 0%,transparent 50%),var(--bg); color:var(--text); min-height:100vh; }
a { color:var(--accent); text-decoration:none; } .layout { display:grid; grid-template-columns:260px 1fr; min-height:100vh; }
@media (max-width:860px){ .layout{grid-template-columns:1fr;} .sidebar{position:sticky;top:0;z-index:5;} }
.sidebar { border-right:1px solid var(--line); background:rgba(18,26,43,.92); backdrop-filter:blur(8px); padding:1rem; }
.brand { font-weight:700; letter-spacing:.02em; margin-bottom:.25rem; } .brand small { display:block; color:var(--muted); font-weight:500; font-size:.78rem; margin-top:.2rem; }
.search { width:100%; margin:1rem 0; padding:.65rem .75rem; border-radius:10px; border:1px solid var(--line); background:#0d1526; color:var(--text); }
.nav { display:flex; flex-direction:column; gap:.25rem; max-height:70vh; overflow:auto; }
.nav button { text-align:left; border:0; background:transparent; color:var(--muted); padding:.55rem .65rem; border-radius:8px; cursor:pointer; font:inherit; }
.nav button:hover,.nav button.active { background:#1a2740; color:var(--text); }
.main { padding:1.25rem 1.4rem 2rem; } .panel { background:var(--panel); border:1px solid var(--line); border-radius:14px; padding:1rem 1.1rem; }
h1 { font-size:1.35rem; margin:0 0 .35rem; } .desc { color:var(--muted); margin:0 0 1rem; font-size:.95rem; }
textarea,input,select { width:100%; border:1px solid var(--line); background:#0d1526; color:var(--text); border-radius:10px; padding:.7rem .8rem; font:inherit; }
textarea { min-height:140px; font-family:var(--mono); font-size:.9rem; resize:vertical; }
.row { display:flex; flex-wrap:wrap; gap:.6rem; margin:.75rem 0; }
button.act { border:0; border-radius:10px; background:var(--accent); color:#041018; font-weight:700; padding:.55rem .9rem; cursor:pointer; }
button.ghost { border:1px solid var(--line); background:transparent; color:var(--text); border-radius:10px; padding:.55rem .9rem; cursor:pointer; }
.out { margin-top:.8rem; white-space:pre-wrap; word-break:break-word; font-family:var(--mono); font-size:.88rem; background:#0d1526; border:1px solid var(--line); border-radius:10px; padding:.8rem; min-height:3rem; }
.muted { color:var(--muted); font-size:.85rem; }
EOF
    cat > "${WWW_DIR}/index.html" <<'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>ByteDeck — developer utilities</title>
  <meta name="description" content="Collection of handy online tools for developers: Base64, Hash, JSON, UUID, URL encode, and more.">
  <meta name="theme-color" content="#0b1220">
  <link rel="stylesheet" href="/assets/app.css">
</head>
<body>
  <div class="layout">
    <aside class="sidebar">
      <div class="brand">ByteDeck <small>developer utilities</small></div>
      <input class="search" id="filter" type="search" placeholder="Search tools..." aria-label="Search tools">
      <nav class="nav" id="nav" aria-label="Tools"></nav>
      <p class="muted" style="margin-top:1rem;">Offline fallback UI. Prefer full IT-Tools when network allows.</p>
    </aside>
    <main class="main">
      <section class="panel" id="app"></section>
    </main>
  </div>
  <script>
  const tools = [
    { id:'base64', name:'Base64 encode / decode', cat:'Conversion', run(ui){
      ui.desc('Encode or decode Base64 text in the browser.');
      ui.area('input','Text');
      ui.row([ui.btn('Encode',()=>ui.set(btoa(unescape(encodeURIComponent(ui.val('input')))))), ui.btn('Decode',()=>{try{ui.set(decodeURIComponent(escape(atob(ui.val('input')))))}catch(e){ui.set('Invalid Base64')}},'ghost')]);
      ui.out();
    }},
    { id:'url', name:'URL encode / decode', cat:'Conversion', run(ui){
      ui.desc('Percent-encoding helpers for query strings and paths.');
      ui.area('input','Text');
      ui.row([ui.btn('Encode',()=>ui.set(encodeURIComponent(ui.val('input')))), ui.btn('Decode',()=>{try{ui.set(decodeURIComponent(ui.val('input')))}catch(e){ui.set('Invalid input')}},'ghost')]);
      ui.out();
    }},
    { id:'hash', name:'SHA-256 hash', cat:'Crypto', run(ui){
      ui.desc('Compute SHA-256 using Web Crypto (local only).');
      ui.area('input','Text');
      ui.row([ui.btn('Hash', async ()=>{
        const data=new TextEncoder().encode(ui.val('input'));
        const buf=await crypto.subtle.digest('SHA-256', data);
        ui.set([...new Uint8Array(buf)].map(b=>b.toString(16).padStart(2,'0')).join(''));
      })]);
      ui.out();
    }},
    { id:'uuid', name:'UUID generator', cat:'Generators', run(ui){
      ui.desc('Generate RFC 4122 version 4 UUIDs.');
      ui.row([ui.btn('Generate',()=>ui.set(crypto.randomUUID())), ui.btn('Generate ×5',()=>ui.set(Array.from({length:5},()=>crypto.randomUUID()).join('\\n')),'ghost')]);
      ui.out();
    }},
    { id:'json', name:'JSON formatter', cat:'Development', run(ui){
      ui.desc('Pretty-print or minify JSON.');
      ui.area('input','JSON');
      ui.row([ui.btn('Pretty',()=>{try{ui.set(JSON.stringify(JSON.parse(ui.val('input')),null,2))}catch(e){ui.set(String(e))}}), ui.btn('Minify',()=>{try{ui.set(JSON.stringify(JSON.parse(ui.val('input'))))}catch(e){ui.set(String(e))}},'ghost')]);
      ui.out();
    }},
    { id:'jwt', name:'JWT decoder', cat:'Development', run(ui){
      ui.desc('Decode JWT header and payload (no signature verify).');
      ui.area('input','JWT');
      ui.row([ui.btn('Decode',()=>{
        try{
          const p=ui.val('input').trim().split('.');
          if(p.length<2) throw new Error('Not a JWT');
          const dec=s=>JSON.stringify(JSON.parse(atob(s.replace(/-/g,'+').replace(/_/g,'/'))),null,2);
          ui.set('Header\\n'+dec(p[0])+'\\n\\nPayload\\n'+dec(p[1]));
        }catch(e){ui.set(String(e))}
      })]);
      ui.out();
    }},
    { id:'timestamp', name:'Unix timestamp', cat:'Datetime', run(ui){
      ui.desc('Convert between Unix time and local datetime.');
      ui.input('ts','Unix seconds', String(Math.floor(Date.now()/1000)));
      ui.row([ui.btn('To date',()=>ui.set(new Date(Number(ui.val('ts'))*1000).toString())), ui.btn('Now',()=>{const n=Math.floor(Date.now()/1000); document.getElementById('ts').value=n; ui.set(String(n));},'ghost')]);
      ui.out();
    }},
    { id:'lorem', name:'Lorem text', cat:'Text', run(ui){
      ui.desc('Quick placeholder paragraphs.');
      const words='lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore et dolore magna aliqua'.split(' ');
      ui.row([ui.btn('3 paragraphs',()=>{
        const para=()=>Array.from({length:40},()=>words[Math.floor(Math.random()*words.length)]).join(' ');
        ui.set([para(),para(),para()].map(p=>p[0].toUpperCase()+p.slice(1)+'.').join('\\n\\n'));
      })]);
      ui.out();
    }}
  ];
  const app=document.getElementById('app');
  const nav=document.getElementById('nav');
  const filter=document.getElementById('filter');
  function uiFactory(){
    const api={
      desc(t){const p=document.createElement('p');p.className='desc';p.textContent=t;app.appendChild(p)},
      area(id,label){const l=document.createElement('div');l.className='muted';l.textContent=label;app.appendChild(l);const t=document.createElement('textarea');t.id=id;app.appendChild(t)},
      input(id,label,v=''){const l=document.createElement('div');l.className='muted';l.textContent=label;app.appendChild(l);const i=document.createElement('input');i.id=id;i.value=v;app.appendChild(i)},
      row(nodes){const d=document.createElement('div');d.className='row';nodes.forEach(n=>d.appendChild(n));app.appendChild(d)},
      btn(label,fn,cls='act'){const b=document.createElement('button');b.type='button';b.className=cls;b.textContent=label;b.onclick=fn;return b},
      out(){const o=document.createElement('div');o.className='out';o.id='out';app.appendChild(o)},
      val(id){return document.getElementById(id).value},
      set(v){document.getElementById('out').textContent=v}
    }; return api;
  }
  function renderList(){
    const q=filter.value.trim().toLowerCase();
    nav.innerHTML='';
    tools.filter(t=>!q||t.name.toLowerCase().includes(q)||t.cat.toLowerCase().includes(q)).forEach(t=>{
      const b=document.createElement('button'); b.type='button'; b.dataset.id=t.id; b.textContent=t.name;
      b.onclick=()=>openTool(t.id); nav.appendChild(b);
    });
  }
  function openTool(id){
    const t=tools.find(x=>x.id===id)||tools[0];
    [...nav.querySelectorAll('button')].forEach(b=>b.classList.toggle('active',b.dataset.id===t.id));
    app.innerHTML='';
    const h=document.createElement('h1'); h.textContent=t.name; app.appendChild(h);
    const c=document.createElement('div'); c.className='muted'; c.style.marginBottom='.8rem'; c.textContent=t.cat; app.appendChild(c);
    t.run(uiFactory());
    history.replaceState(null,'','#'+t.id);
  }
  filter.addEventListener('input', renderList);
  renderList();
  openTool((location.hash||'#base64').slice(1));
  </script>
</body>
</html>
EOF
    chown -R caddy:caddy "$WWW_DIR" 2>/dev/null || true
    find "$WWW_DIR" -type d -exec chmod 755 {} \; 2>/dev/null || true
    find "$WWW_DIR" -type f -exec chmod 644 {} \; 2>/dev/null || true
    ok "Fallback tools site written to ${WWW_DIR}"
}

apply_sysctl_limits() {
    info "Applying system optimizations..."
    cat > /etc/sysctl.d/99-caddy-trojan.conf <<'EOF'
# Caddy-Trojan system optimizations (scoped, reversible)
fs.file-max = 1048576
fs.inotify.max_user_instances = 8192
net.core.somaxconn = 32768
net.core.netdev_max_backlog = 16384
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 16384 16777216
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65000
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_notsent_lowat = 16384
EOF
    modprobe tcp_bbr &>/dev/null || true
    if grep -wq bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        {
            echo "net.core.default_qdisc = fq"
            echo "net.ipv4.tcp_congestion_control = bbr"
        } >> /etc/sysctl.d/99-caddy-trojan.conf
    fi
    sysctl --system &>/dev/null || true

    cat > /etc/security/limits.d/caddy-trojan.conf <<'EOF'
# Caddy-Trojan limits
caddy soft nofile 1048576
caddy hard nofile 1048576
caddy soft nproc  65535
caddy hard nproc  65535
root  soft nofile 1048576
root  hard nofile 1048576
EOF
    ok "System optimizations applied (BBR: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 'N/A'))"
}

ensure_cert_storage() {
    # Caddy with XDG_DATA_HOME=/etc stores ACME data under /etc/caddy
    mkdir -p "${CADDY_DIR}/certificates" "${CADDY_DIR}/acme"
    chown -R caddy:caddy "$CADDY_DIR"
    chmod 700 "$CADDY_DIR"
    # keep parent writable by caddy for renewals
    find "$CADDY_DIR" -type d -exec chmod 700 {} \; 2>/dev/null || true
}

setup_renew_timer() {
    info "Setting up certificate renewal timer..."

    # Safety net for ACME mode; origin/file certs only log remaining validity.
    cat > /usr/local/bin/caddy-cert-maintain <<'EOF'
#!/bin/bash
set -uo pipefail
export XDG_CONFIG_HOME=/etc
export XDG_DATA_HOME=/etc
export HOME=/var/lib/caddy

TLS_MODE_FILE=/etc/caddy/trojan/tls-mode.txt
TLS_CERT_REC=/etc/caddy/trojan/tls-cert.path
ORIGIN_CERT=/etc/caddy/certs/origin.crt

mkdir -p /etc/caddy/certificates /etc/caddy/acme /var/lib/caddy
chown -R caddy:caddy /etc/caddy /var/lib/caddy 2>/dev/null || true
find /etc/caddy -type d -exec chmod 700 {} \; 2>/dev/null || true

mode=auto
if [ -f "$TLS_MODE_FILE" ]; then
  mode=$(tr -d '[:space:]' < "$TLS_MODE_FILE" | tr '[:upper:]' '[:lower:]')
fi

if ! systemctl is-active --quiet caddy; then
  systemctl start caddy || true
  sleep 2
fi

if systemctl is-active --quiet caddy; then
  /usr/local/bin/caddy reload --config /etc/caddy/Caddyfile --force 2>/dev/null || true
fi

if [ "$mode" = "origin" ]; then
  CERT_FILE=""
  if [ -f "$TLS_CERT_REC" ]; then
    CERT_FILE=$(tr -d '\r\n' < "$TLS_CERT_REC")
  fi
  [ -n "$CERT_FILE" ] && [ -f "$CERT_FILE" ] || CERT_FILE="$ORIGIN_CERT"
  if [ -f "$CERT_FILE" ] && command -v openssl >/dev/null 2>&1; then
    END_RAW=$(openssl x509 -enddate -noout -in "$CERT_FILE" 2>/dev/null | cut -d= -f2 || true)
    if ! openssl x509 -checkend $((30 * 86400)) -noout -in "$CERT_FILE" 2>/dev/null; then
      logger -t caddy-cert-maintain "origin cert near expiry (${END_RAW:-unknown}); replace with: easytrojan cert origin --cert PATH --key PATH"
    else
      logger -t caddy-cert-maintain "origin cert ok; expires ${END_RAW:-unknown}"
    fi
  else
    logger -t caddy-cert-maintain "origin mode but cert file missing"
  fi
  exit 0
fi

CERT_FILE=$(find /etc/caddy/certificates -name '*.crt' -type f 2>/dev/null | head -1 || true)
if [ -n "${CERT_FILE}" ] && command -v openssl >/dev/null 2>&1; then
  if ! openssl x509 -checkend $((30 * 86400)) -noout -in "$CERT_FILE" 2>/dev/null; then
    END_RAW=$(openssl x509 -enddate -noout -in "$CERT_FILE" 2>/dev/null | cut -d= -f2 || true)
    logger -t caddy-cert-maintain "certificate near expiry (${END_RAW:-unknown}); restarting caddy for ACME renewal"
    systemctl restart caddy
    sleep 5
  else
    END_RAW=$(openssl x509 -enddate -noout -in "$CERT_FILE" 2>/dev/null | cut -d= -f2 || true)
    logger -t caddy-cert-maintain "certificate ok; expires ${END_RAW:-unknown}"
  fi
fi
exit 0
EOF
    chmod 755 /usr/local/bin/caddy-cert-maintain

    cat > /etc/systemd/system/caddy-renew.service <<'EOF'
[Unit]
Description=Caddy Certificate Maintenance / Renewal Check
After=network-online.target caddy.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/caddy-cert-maintain
Nice=10
EOF

    cat > /etc/systemd/system/caddy-renew.timer <<'EOF'
[Unit]
Description=Daily Caddy Certificate Maintenance Timer

[Timer]
# Daily is safer than twice monthly; Caddy only renews near expiry
OnCalendar=*-*-* 03:17:00
RandomizedDelaySec=2h
Persistent=true
Unit=caddy-renew.service

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable caddy-renew.timer &>/dev/null
    systemctl restart caddy-renew.timer &>/dev/null || systemctl start caddy-renew.timer &>/dev/null
    ok "Certificate maintenance timer enabled (daily)"
}

do_update() {
    require_root
    install_pkg curl
    install_pkg tar

    # Stage 0: refresh script from GitHub then re-exec so binary update uses latest logic
    if [ "${EASYTROJAN_UPDATE_STAGE:-0}" != "1" ]; then
        info "Updating easytrojan script..."
        local tmp dest
        tmp=$(mktemp)
        if curl -fsSL --connect-timeout 10 --max-time 30 "${REPO_RAW}/easytrojan.sh" -o "$tmp"; then
            chmod +x "$tmp"
            dest="$SCRIPT_BIN"
            if [ -f "$0" ] && [ -w "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")" ] 2>/dev/null; then
                dest=$(readlink -f "$0" 2>/dev/null || echo "$SCRIPT_BIN")
            fi
            # Prefer installing to standard paths always
            cp -f "$tmp" "$SCRIPT_BIN"
            cp -f "$tmp" "$SCRIPT_LEGACY"
            chmod 755 "$SCRIPT_BIN" "$SCRIPT_LEGACY"
            # Also replace source path if it is a real file outside SCRIPT_BIN
            if [ -n "${dest:-}" ] && [ "$dest" != "$SCRIPT_BIN" ] && [ -f "$dest" ]; then
                cp -f "$tmp" "$dest" 2>/dev/null || true
                chmod 755 "$dest" 2>/dev/null || true
            fi
            rm -f "$tmp"
            ok "Script updated -> re-executing with new version"
            local reexec_args=(update)
            if [ -n "${release_version:-}" ] && [ "$release_version" != "latest" ]; then
                reexec_args+=(--version "$release_version")
            fi
            export EASYTROJAN_UPDATE_STAGE=1
            exec bash "$SCRIPT_BIN" "${reexec_args[@]}"
        else
            warn "Script update failed, continuing with current script for Caddy update..."
            rm -f "$tmp"
        fi
    fi

    local old_version new_version backup=""
    old_version=$("$CADDY_BIN" version 2>/dev/null | awk '{print $1}' || echo "not-installed")
    info "Current Caddy version: $old_version"
    if [ -x "$CADDY_BIN" ]; then
        backup=$(mktemp)
        cp -f "$CADDY_BIN" "$backup"
    fi

    download_caddy
    new_version=$("$CADDY_BIN" version 2>/dev/null | awk '{print $1}' || echo "unknown")
    if ! "$CADDY_BIN" version &>/dev/null; then
        if [ -n "$backup" ] && [ -f "$backup" ]; then
            mv -f "$backup" "$CADDY_BIN"
            chmod +x "$CADDY_BIN"
            error "New binary is invalid; restored previous Caddy binary"
        fi
        error "New Caddy binary is invalid"
    fi
    [ -n "$backup" ] && rm -f "$backup"

    if [ "$old_version" = "$new_version" ]; then
        ok "Caddy already up to date: $new_version"
    else
        if systemctl is-active --quiet caddy 2>/dev/null; then
            info "Restarting Caddy service..."
            systemctl restart caddy.service
            wait_for_admin_api || warn "Caddy API not ready after update"
            assert_admin_local_only || true
            # Users come from Caddyfile `users` + caddy storage; no API re-inject needed.
        fi
        ok "Caddy updated: $old_version -> $new_version"
    fi
    if [ -x "$CADDY_BIN" ]; then
        setup_renew_timer
    fi
    exit 0
}

do_renew() {
    require_root
    local force_reissue=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --force|-f) force_reissue=1; shift ;;
            -h|--help) echo "Usage: easytrojan renew [--force]"; exit 0 ;;
            *) error "Unknown renew argument: $1" ;;
        esac
    done

    systemctl is-active --quiet caddy 2>/dev/null || error "Caddy service is not running"
    # Keep daily maintenance timer present on older installs
    if [ ! -f /etc/systemd/system/caddy-renew.timer ] || [ ! -x /usr/local/bin/caddy-cert-maintain ]; then
        setup_renew_timer
    fi

    if [ "$(read_tls_mode)" = "origin" ]; then
        local cert_file key_file expiry
        cert_file=$(read_tls_cert_path)
        key_file=$(read_tls_key_path)
        [ -f "$cert_file" ] || error "Origin cert missing: $cert_file (easytrojan cert origin --cert PATH --key PATH)"
        [ -f "$key_file" ] || error "Origin key missing: $key_file"
        if [ "$force_reissue" = "1" ]; then
            error "renew --force applies to ACME mode only. For origin certs use: easytrojan cert origin --cert PATH --key PATH"
        fi
        info "TLS mode is origin (file cert); no ACME renewal"
        if check_cmd openssl; then
            expiry=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2 || true)
            ok "Origin certificate present (expires: ${expiry:-unknown})"
            if ! openssl x509 -checkend $((30 * 86400)) -noout -in "$cert_file" 2>/dev/null; then
                warn "Origin cert expires within 30 days; re-issue in Cloudflare and run cert origin"
            fi
        else
            ok "Origin certificate present: $cert_file"
        fi
        exit 0
    fi

    ensure_cert_storage

    if [ "$force_reissue" = "1" ]; then
        warn "Force re-issue: deleting existing certificate material"
        rm -rf "${CADDY_DIR}/certificates" "${CADDY_DIR}/acme"
        ensure_cert_storage
        systemctl restart caddy.service
    else
        info "Triggering certificate maintenance (Caddy auto-renew if near expiry)..."
        if [ -x /usr/local/bin/caddy-cert-maintain ]; then
            /usr/local/bin/caddy-cert-maintain || true
        else
            # fallback if helper not installed yet
            export XDG_CONFIG_HOME=/etc XDG_DATA_HOME=/etc
            "$CADDY_BIN" reload --config "$CADDYFILE" --force || systemctl restart caddy.service
        fi
    fi

    info "Waiting for certificate material..."
    local count=0 max_wait=40
    until find "${CADDY_DIR}/certificates" -name '*.crt' -type f 2>/dev/null | grep -q .; do
        count=$((count + 1))
        if [ "$count" -gt "$max_wait" ]; then
            error "Certificate check failed. Check: journalctl -u caddy --no-pager -n 50"
        fi
        sleep 3
    done

    local cert_file expiry
    cert_file=$(find "${CADDY_DIR}/certificates" -name '*.crt' -type f 2>/dev/null | head -1 || true)
    if [ -n "$cert_file" ] && check_cmd openssl; then
        expiry=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2 || true)
        ok "Certificate present (expires: ${expiry:-unknown})"
    else
        ok "Certificate material present"
    fi
    exit 0
}

do_status() {
    local show_link=0 server_addr=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --show-link|--link) show_link=1; shift ;;
            --server|--addr|--address)
                [ -n "${2:-}" ] || error "--server requires an address (IP or hostname)"
                server_addr="$2"
                show_link=1
                shift 2
                ;;
            -h|--help)
                cat <<'EOF'
Usage: easytrojan status [--show-link] [--server ADDR]

  --show-link       Print trojan share links (passwords in URL)
  --server ADDR     Connect address for share links (e.g. Cloudflare preferred IP).
                    SNI and WS Host stay as the installed domain.
EOF
                exit 0
                ;;
            *) error "Unknown status argument: $1" ;;
        esac
    done

    echo ""
    if systemctl is-active --quiet caddy 2>/dev/null; then
        echo -e "  Service: ${GREEN}running${NC}"
    else
        echo -e "  Service: ${RED}stopped${NC}"
    fi
    if [ -x "$CADDY_BIN" ]; then
        echo -e "  Version: $($CADDY_BIN version 2>/dev/null | awk '{print $1}' || echo 'unknown')"
    else
        echo -e "  Version: ${RED}not installed${NC}"
    fi
    if [ -f "$PASSWD_FILE" ]; then
        local user_count
        user_count=$(grep -cve '^[[:space:]]*$' "$PASSWD_FILE" 2>/dev/null || true)
        echo -e "  Users  : ${user_count:-0}"
    fi
    local domain=""
    domain=$(read_installed_domain 2>/dev/null || true)
    [ -n "$domain" ] && echo -e "  Domain : ${CYAN}${domain}${NC}"
    echo -e "  TLS    : ${CYAN}$(read_tls_mode)${NC}"

    local cert_file="" expiry=""
    if [ "$(read_tls_mode)" = "origin" ]; then
        cert_file=$(read_tls_cert_path)
        if [ -f "$cert_file" ]; then
            if check_cmd openssl; then
                expiry=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)
                echo -e "  Cert   : origin file, expires ${expiry:-unknown}"
            else
                echo -e "  Cert   : ${GREEN}origin file present${NC}"
            fi
        else
            echo -e "  Cert   : ${RED}origin file missing${NC}"
        fi
    else
        local cert_dir="${CADDY_DIR}/certificates"
        if [ -d "$cert_dir" ]; then
            cert_file=$(find "$cert_dir" -name "*.crt" -type f 2>/dev/null | head -1)
            if [ -n "$cert_file" ] && check_cmd openssl; then
                expiry=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)
                echo -e "  Cert   : ACME, expires $expiry"
            elif [ -n "$cert_file" ]; then
                echo -e "  Cert   : ${GREEN}present${NC}"
            else
                echo -e "  Cert   : ${RED}not found${NC}"
            fi
        else
            echo -e "  Cert   : ${RED}not found${NC}"
        fi
    fi

    if systemctl list-timers --all 2>/dev/null | grep -q caddy-renew.timer; then
        local next
        next=$(systemctl list-timers --all 2>/dev/null | awk '/caddy-renew.timer/ {print $1" "$2" "$3" "$4" "$5; exit}')
        echo -e "  Renew  : timer active (${next:-scheduled})"
    else
        echo -e "  Renew  : ${YELLOW}timer not installed${NC}"
    fi

    if [ "$show_link" = "1" ] && [ -f "$PASSWD_FILE" ] && [ -n "$domain" ]; then
        local passwd transport="ws"
        if [ -f "$CADDYFILE" ] && ! grep -q "websocket" "$CADDYFILE" 2>/dev/null; then
            transport="tcp"
        fi
        if [ -n "$server_addr" ]; then
            echo -e "  Server : ${CYAN}${server_addr}${NC}  (SNI/Host: ${domain})"
        fi
        while IFS= read -r passwd || [ -n "$passwd" ]; do
            [ -n "$passwd" ] || continue
            echo -e "  Link   : ${CYAN}$(build_share_link "$domain" "$passwd" "$transport" "$server_addr")${NC}"
        done < "$PASSWD_FILE"
        if [ -n "$server_addr" ]; then
            echo -e "  Tip    : Client address=${server_addr}, SNI/Host=${domain}, WS path=/"
        fi
    elif [ -f "$PASSWD_FILE" ] && [ -n "$domain" ]; then
        echo -e "  Link   : ${YELLOW}hidden${NC} (use: easytrojan status --show-link [--server CF_IP])"
    fi
    echo ""
    exit 0
}

do_link() {
    local server_addr="" pass_filter=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --server|--addr|--address)
                [ -n "${2:-}" ] || error "--server requires an address (IP or hostname)"
                server_addr="$2"
                shift 2
                ;;
            --password)
                [ -n "${2:-}" ] || error "--password requires a value"
                pass_filter="$2"
                shift 2
                ;;
            -h|--help)
                cat <<'EOF'
Usage: easytrojan link [--server ADDR] [--password PASSWORD]

Print trojan share links for installed users.
  --server ADDR   Use ADDR as connect host (Cloudflare preferred IP).
                  SNI and WS Host remain the installed domain.
  --password PASS Only print link for this password.
EOF
                exit 0
                ;;
            *) error "Unknown argument: $1" ;;
        esac
    done

    local domain transport="ws" passwd
    domain=$(read_installed_domain 2>/dev/null || true)
    [ -n "$domain" ] || error "Domain not found. Install first: easytrojan install --domain example.com"
    [ -f "$PASSWD_FILE" ] || error "No passwords in $PASSWD_FILE"
    if [ -f "$CADDYFILE" ] && ! grep -q "websocket" "$CADDYFILE" 2>/dev/null; then
        transport="tcp"
    fi

    local found=0
    while IFS= read -r passwd || [ -n "$passwd" ]; do
        [ -n "$passwd" ] || continue
        if [ -n "$pass_filter" ] && [ "$passwd" != "$pass_filter" ]; then
            continue
        fi
        found=1
        build_share_link "$domain" "$passwd" "$transport" "$server_addr"
        printf '\n'
    done < "$PASSWD_FILE"
    [ "$found" -eq 1 ] || error "No matching password in passwd.txt"
    if [ -n "$server_addr" ]; then
        echo -e "${YELLOW}# address=${server_addr}  sni/host=${domain}  path=/${NC}" >&2
    fi
    exit 0
}

do_cert() {
    require_root
    local sub="${1:-}"
    [ -n "$sub" ] || error "Usage: easytrojan cert {auto|origin|status}"
    shift || true

    case "$sub" in
        status|show)
            local mode cert key domain
            mode=$(read_tls_mode)
            domain=$(read_installed_domain 2>/dev/null || true)
            echo ""
            echo -e "  TLS mode : ${CYAN}${mode}${NC}"
            [ -n "$domain" ] && echo -e "  Domain   : ${CYAN}${domain}${NC}"
            if [ "$mode" = "origin" ]; then
                cert=$(read_tls_cert_path)
                key=$(read_tls_key_path)
                echo -e "  Cert file: ${cert}"
                echo -e "  Key file : ${key}"
                if [ -f "$cert" ] && check_cmd openssl; then
                    echo -e "  Subject  : $(openssl x509 -in "$cert" -noout -subject 2>/dev/null | sed 's/^subject=//')"
                    echo -e "  Expires  : $(openssl x509 -in "$cert" -noout -enddate 2>/dev/null | cut -d= -f2)"
                fi
            else
                echo -e "  Issuer   : Caddy ACME (Let's Encrypt / ZeroSSL etc.)"
            fi
            echo ""
            exit 0
            ;;
        auto|acme)
            local domain
            domain=$(read_installed_domain 2>/dev/null || true)
            [ -n "$domain" ] || error "Domain not found; install first"
            persist_tls_config "auto"
            ensure_cert_storage
            generate_caddyfile "$domain"
            setup_renew_timer
            if systemctl is-active --quiet caddy 2>/dev/null; then
                # restart so ACME manager picks clean tls directive immediately
                systemctl restart caddy.service
                wait_for_admin_api || warn "Caddy Admin API not ready after restart"
            fi
            ok "TLS mode set to auto (Caddy ACME). Ensure ports 80/443 and DNS allow issuance."
            info "Check progress with: easytrojan status / journalctl -u caddy -n 30"
            exit 0
            ;;
        origin|cf)
            local cert_src="" key_src="" domain
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --cert|--origin-cert)
                        [ -n "${2:-}" ] || error "--cert requires a path"
                        cert_src="$2"; shift 2 ;;
                    --key|--origin-key)
                        [ -n "${2:-}" ] || error "--key requires a path"
                        key_src="$2"; shift 2 ;;
                    -h|--help)
                        echo "Usage: easytrojan cert origin --cert PATH --key PATH"
                        exit 0 ;;
                    *) error "Unknown argument: $1" ;;
                esac
            done
            [ -n "$cert_src" ] || error "Missing --cert PATH"
            [ -n "$key_src" ] || error "Missing --key PATH"
            domain=$(read_installed_domain 2>/dev/null || true)
            [ -n "$domain" ] || error "Domain not found; install first"
            install_origin_material "$cert_src" "$key_src"
            persist_tls_config "origin" "$ORIGIN_CERT_DEFAULT" "$ORIGIN_KEY_DEFAULT"
            generate_caddyfile "$domain"
            setup_renew_timer
            if systemctl is-active --quiet caddy 2>/dev/null; then
                reload_caddy
            fi
            ok "TLS mode set to origin (file cert). Cloudflare SSL should be Full (strict)."
            exit 0
            ;;
        -h|--help|help)
            cat <<'EOF'
Usage:
  easytrojan cert status
  easytrojan cert auto
  easytrojan cert origin --cert PATH --key PATH

TLS modes:
  auto    Caddy automatic HTTPS (ACME). Best for direct / DNS-only.
  origin  Cloudflare Origin Certificate or any cert/key files.
          Recommended for long-term Cloudflare orange-cloud proxy.
EOF
            exit 0
            ;;
        *)
            error "Unknown cert subcommand: $sub (auto|origin|status)"
            ;;
    esac
}

do_user() {
    require_root
    local sub="${1:-}"
    [ -n "$sub" ] || error "Usage: easytrojan user {add|list|del} ..."
    shift || true

    case "$sub" in
        add)
            trojan_passwd=""
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --password)
                        [ -n "${2:-}" ] || error "--password requires a value"
                        trojan_passwd="$2"
                        shift 2
                        ;;
                    -h|--help) echo "Usage: easytrojan user add [--password PASSWORD]"; exit 0 ;;
                    *) error "Unknown argument: $1" ;;
                esac
            done
            prompt_password
            local domain
            domain=$(read_installed_domain 2>/dev/null || true)
            [ -n "$domain" ] || error "Domain not found. Re-run: easytrojan install --domain example.com"
            persist_password "$trojan_passwd"
            info "Regenerating Caddyfile with static users..."
            generate_caddyfile "$domain"
            if systemctl is-active --quiet caddy 2>/dev/null; then
                reload_caddy
                wait_for_admin_api || warn "Caddy Admin API not ready after reload"
            else
                warn "Caddy is not running; Caddyfile updated. Start with: systemctl start caddy"
            fi
            ok "User added ($(mask_secret "$trojan_passwd"))"
            echo -e "  Share : ${CYAN}$(build_share_link "$domain" "$trojan_passwd" "ws")${NC}"
            ;;
        list)
            local i=0 line
            if [ -f "$PASSWD_FILE" ]; then
                echo "  Local passwd.txt (masked):"
                while IFS= read -r line || [ -n "$line" ]; do
                    [ -n "$line" ] || continue
                    i=$((i + 1))
                    echo -e "    ${i}. $(mask_secret "$line")"
                done < "$PASSWD_FILE"
            fi
            if [ "$i" -eq 0 ]; then
                echo "  (no local users)"
            fi
            # Optional: runtime storage keys (hash hex, not plaintext)
            if systemctl is-active --quiet caddy 2>/dev/null; then
                local runtime_count tmpj
                tmpj=$(mktemp)
                if curl -sf "${ADMIN_API}/trojan/users" -o "$tmpj" 2>/dev/null; then
                    runtime_count=$(grep -o '"key"' "$tmpj" 2>/dev/null | wc -l | tr -d ' ' || echo 0)
                    echo "  Runtime storage keys (API): ${runtime_count:-0}"
                fi
                rm -f "$tmpj"
            fi
            exit 0
            ;;
        del|delete|rm|remove)
            trojan_passwd=""
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --password)
                        [ -n "${2:-}" ] || error "--password requires a value"
                        trojan_passwd="$2"
                        shift 2
                        ;;
                    -h|--help) echo "Usage: easytrojan user del --password PASSWORD"; exit 0 ;;
                    *) error "Unknown argument: $1" ;;
                esac
            done
            if [ -z "$trojan_passwd" ]; then
                if [ -t 0 ]; then
                    read -rsp "Password to delete: " trojan_passwd
                    echo
                else
                    error "Password required: easytrojan user del --password PASSWORD"
                fi
            fi
            [ -n "$trojan_passwd" ] || error "Password cannot be empty"
            local domain
            domain=$(read_installed_domain 2>/dev/null || true)
            [ -n "$domain" ] || error "Domain not found. Re-run install first."
            if [ -f "$PASSWD_FILE" ] && ! grep -Fxq -- "$trojan_passwd" "$PASSWD_FILE" 2>/dev/null; then
                warn "Password not found in local passwd.txt; still clearing storage + Caddyfile"
            fi
            remove_password_from_file "$trojan_passwd"
            generate_caddyfile "$domain"
            # With `caddy` upstream, delete storage key or Validate still succeeds after reload.
            if systemctl is-active --quiet caddy 2>/dev/null; then
                wait_for_admin_api || true
                if delete_trojan_user_storage "$trojan_passwd"; then
                    ok "Cleared user from Caddy storage"
                else
                    warn "Admin API delete failed (user may already be gone from storage)"
                fi
                reload_caddy
            else
                warn "Caddy is not running; passwd/Caddyfile updated only"
            fi
            ok "User deleted ($(mask_secret "$trojan_passwd"))"
            ;;
        -h|--help|help)
            cat <<'EOF'
Usage:
  easytrojan user add [--password PASSWORD]
  easytrojan user list
  easytrojan user del --password PASSWORD

Users are stored in passwd.txt, declared in Caddyfile (users "..."),
and (with caddy upstream) keyed in Caddy storage. Delete clears all three.
EOF
            exit 0
            ;;
        *)
            error "Unknown user subcommand: $sub (add|list|del)"
            ;;
    esac
    exit 0
}

do_install() {
    require_root
    prompt_password
    install_pkg tar
    install_pkg curl

    local check_port=""
    if check_cmd ss; then
        check_port=$(ss -Hlnp 'sport = :80 or sport = :443' 2>/dev/null | grep -v caddy || true)
    elif check_cmd lsof; then
        check_port=$(lsof -iTCP:80 -iTCP:443 -sTCP:LISTEN 2>/dev/null | grep -v caddy || true)
    fi
    if [ -n "${check_port}" ]; then
        if systemctl is-active --quiet caddy 2>/dev/null; then
            info "Stopping existing Caddy service for reinstall..."
            systemctl stop caddy
        else
            error "Port 80 or 443 is already in use by another process:\n$check_port"
        fi
    fi

    prompt_domain

    info "Detecting server IP..."
    address_ip=$(detect_public_ip) || error "Failed to detect public IPv4. Check network connectivity."
    info "Server IP: $address_ip"
    site_domain="$caddy_domain"

    if [ "${skip_domain_check:-0}" = "1" ]; then
        warn "Skipping domain resolution check for ${site_domain}"
    else
        domain_ip=$(resolve_domain_ipv4 "$site_domain")
        [ -z "$domain_ip" ] && error "Failed to resolve domain '$site_domain'"
        if ! domain_points_to_ip "$site_domain" "$address_ip"; then
            error "Domain '$site_domain' does not resolve to this server ($address_ip). Seen: $(resolve_domain_ipv4_list "$site_domain" | tr '\n' ' ')"
        fi
        info "Domain verified: $site_domain -> $address_ip"
    fi

    warn "Ensure cloud security group / firewall allows inbound TCP 80 and 443 from the public Internet (ACME needs 80)."

    local cert_backup="" previous_domain=""
    previous_domain=$(read_installed_domain 2>/dev/null || true)
    if [ -d "${CADDY_DIR}/certificates" ]; then
        info "Backing up existing certificates..."
        cert_backup=$(mktemp -d /tmp/caddy-cert-backup.XXXXXX)
        chmod 700 "$cert_backup"
        cp -a "${CADDY_DIR}/certificates" "$cert_backup/" 2>/dev/null || true
        cp -a "${CADDY_DIR}/acme" "$cert_backup/" 2>/dev/null || true
        ok "Certificates backed up"
    fi

    download_caddy
    ok "Caddy binary installed: $($CADDY_BIN version 2>/dev/null | awk '{print $1}' || echo 'unknown')"

    if ! id caddy &>/dev/null; then
        groupadd --system caddy
        useradd --system -g caddy -s "$(command -v nologin || echo /usr/sbin/nologin)" -d /var/lib/caddy -M caddy 2>/dev/null \
            || useradd --system -g caddy -s "$(command -v nologin || echo /usr/sbin/nologin)" caddy
    fi
    mkdir -p /var/lib/caddy
    chown caddy:caddy /var/lib/caddy 2>/dev/null || true

    mkdir -p "$TROJAN_DIR" "$WWW_DIR"
    # Drop certs only when domain changes; same-domain reinstall keeps material to avoid LE rate limits
    if [ -n "$previous_domain" ] && [ "$previous_domain" = "$site_domain" ] && [ -d "${CADDY_DIR}/certificates" ]; then
        info "Same domain reinstall; keeping existing certificate material"
    else
        if [ -d "${CADDY_DIR}/certificates" ] || [ -d "${CADDY_DIR}/acme" ]; then
            info "Domain changed or first install; clearing old certificate material for re-issue"
            rm -rf "${CADDY_DIR}/certificates" "${CADDY_DIR}/acme"
        fi
    fi
    ensure_cert_storage
    chmod 700 "$TROJAN_DIR"

    write_camouflage_site

    # TLS mode: auto (ACME) or origin (Cloudflare Origin / file certs).
    # If --tls-mode omitted on reinstall, keep previous mode from tls-mode.txt.
    if [ -n "${tls_mode:-}" ]; then
        tls_mode=$(normalize_tls_mode "$tls_mode")
    else
        tls_mode=$(normalize_tls_mode "$(read_tls_mode)")
        info "TLS mode not specified; using saved/default: $tls_mode"
    fi
    if [ "$tls_mode" = "origin" ]; then
        if [ -n "${origin_cert_src:-}" ] || [ -n "${origin_key_src:-}" ]; then
            [ -n "${origin_cert_src:-}" ] || error "origin mode requires --origin-cert PATH"
            [ -n "${origin_key_src:-}" ] || error "origin mode requires --origin-key PATH"
            install_origin_material "$origin_cert_src" "$origin_key_src"
        else
            # Reinstall without new files: require existing material
            [ -f "$ORIGIN_CERT_DEFAULT" ] && [ -f "$ORIGIN_KEY_DEFAULT" ]                 || error "origin mode needs --origin-cert/--origin-key (or existing $ORIGIN_CERT_DEFAULT)"
            ok "Reusing existing origin certificate at $ORIGIN_CERT_DEFAULT"
        fi
        persist_tls_config "origin" "$ORIGIN_CERT_DEFAULT" "$ORIGIN_KEY_DEFAULT"
        info "TLS mode: origin (file certificate)"
    else
        persist_tls_config "auto"
        info "TLS mode: auto (Caddy ACME)"
    fi

    # Source of truth: passwd.txt -> Caddyfile static users (imgk style)
    persist_password "$trojan_passwd"
    info "Generating Caddyfile..."
    generate_caddyfile "$site_domain"

    info "Creating systemd service..."
    cat > /etc/systemd/system/caddy.service <<EOF
[Unit]
Description=Caddy
Documentation=https://caddyserver.com/docs/
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
User=caddy
Group=caddy
Environment=XDG_CONFIG_HOME=/etc XDG_DATA_HOME=/etc HOME=/var/lib/caddy
ExecStart=${CADDY_BIN} run --environ --config ${CADDYFILE}
ExecReload=${CADDY_BIN} reload --config ${CADDYFILE} --force
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
NoNewPrivileges=true
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    if check_cmd ip && ip link show lo 2>/dev/null | grep -q DOWN; then
        ip link set lo up || true
    fi

    info "Starting Caddy service..."
    systemctl daemon-reload
    systemctl restart caddy.service
    systemctl enable caddy.service &>/dev/null

    info "Waiting for Caddy API..."
    wait_for_admin_api || error "Caddy API not responding. Check: journalctl -u caddy --no-pager -n 20"
    assert_admin_local_only
    ok "Trojan users loaded from Caddyfile (passwd.txt)"

    if [ "$(read_tls_mode)" = "origin" ]; then
        ok "Using origin/file certificate (skip ACME wait)"
        if check_cmd openssl && [ -f "$(read_tls_cert_path)" ]; then
            info "Origin cert expires: $(openssl x509 -enddate -noout -in "$(read_tls_cert_path)" 2>/dev/null | cut -d= -f2 || echo unknown)"
        fi
    else
        info "Obtaining SSL certificate (this may take up to 2 minutes)..."
        local count=0 max_wait=40
        until find "${CADDY_DIR}/certificates" -name '*.crt' -type f 2>/dev/null | grep -q .; do
            count=$((count + 1))
            if [ "$count" -gt "$max_wait" ]; then
                if [ -n "$cert_backup" ] && [ -d "${cert_backup}/certificates" ]; then
                    warn "New certificate request failed. Restoring from backup..."
                    cp -a "${cert_backup}/certificates" "${CADDY_DIR}/" 2>/dev/null || true
                    cp -a "${cert_backup}/acme" "${CADDY_DIR}/" 2>/dev/null || true
                    chown -R caddy:caddy "$CADDY_DIR"
                    systemctl restart caddy.service
                    ok "Certificates restored from backup"
                else
                    error "Certificate application failed after $((max_wait * 3))s.\nPlease check:\n  1. TCP ports 80 and 443 are open\n  2. Domain A record points to this server\n  3. journalctl -u caddy --no-pager -n 30"
                fi
                break
            fi
            sleep 3
        done
        if find "${CADDY_DIR}/certificates" -name '*.crt' -type f 2>/dev/null | grep -q .; then
            ok "SSL certificate ready"
        fi
    fi
    [ -n "$cert_backup" ] && rm -rf "$cert_backup"

    apply_sysctl_limits
    setup_renew_timer

    info "Verifying installation..."
    sleep 2
    local check_http
    check_http=$(curl -sL --max-time 10 "https://${site_domain}" -k 2>/dev/null | head -c 400 || true)
    if echo "$check_http" | grep -qiE "it-tools|ByteDeck|IT Tools"; then
        ok "HTTPS verification passed"
    else
        warn "HTTPS check inconclusive. Ensure TCP 80/443 are open."
        warn "Verify by visiting: https://${site_domain}"
    fi

    install_self
    ok "Management command installed: easytrojan / easytrojan.sh"
    local share_link
    share_link=$(build_share_link "$site_domain" "$trojan_passwd" "ws")

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║         EasyTrojan Installed Successfully!                  ║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}  Address  : ${CYAN}${site_domain}${NC}"
    echo -e "${GREEN}║${NC}  Port     : ${CYAN}443${NC}"
    echo -e "${GREEN}║${NC}  Password : ${CYAN}${trojan_passwd}${NC}"
    echo -e "${GREEN}║${NC}  ALPN     : ${CYAN}h2,http/1.1${NC}"
    echo -e "${GREEN}║${NC}  Transport: ${CYAN}websocket${NC}"
    echo -e "${GREEN}║${NC}  TLS mode : ${CYAN}$(read_tls_mode)${NC}  (easytrojan cert status)"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}  Manage   : systemctl {start|stop|restart|status} caddy"
    echo -e "${GREEN}║${NC}  Logs     : journalctl -u caddy --no-pager -n 50"
    echo -e "${GREEN}║${NC}  Config   : ${CADDYFILE}"
    echo -e "${GREEN}║${NC}  Update   : easytrojan update"
    echo -e "${GREEN}║${NC}  Status   : easytrojan status"
    echo -e "${GREEN}║${NC}  Renew    : easytrojan renew   # or renew --force"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║${NC}  ${YELLOW}Share Link:${NC}"
    echo -e "${GREEN}║${NC}  ${CYAN}${share_link}${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

# -------------------- entry --------------------
trojan_passwd=""
caddy_domain=""
release_version="latest"
skip_domain_check="0"
tls_mode=""
origin_cert_src=""
origin_key_src=""

cmd="${1:-}"
case "$cmd" in
    install)
        shift
        parse_common_args "$@"
        do_install
        ;;
    update)
        shift
        parse_common_args "$@"
        do_update
        ;;
    renew)
        shift
        do_renew "$@"
        ;;
    status)
        shift
        do_status "$@"
        ;;
    link|share)
        shift
        do_link "$@"
        ;;
    cert|tls)
        shift
        do_cert "$@"
        ;;
    user)
        shift
        do_user "$@"
        ;;
    help|-h|--help)
        usage
        exit 0
        ;;
    "")
        usage
        error "Missing command. Example: bash easytrojan.sh install"
        ;;
    *)
        # Legacy: bash easytrojan.sh <password> <domain>
        if [[ "$cmd" == -* ]]; then
            error "Unknown option: $cmd (try: bash easytrojan.sh install --domain example.com)"
        fi
        trojan_passwd="$cmd"
        caddy_domain="${2:-}"
        [ -n "$caddy_domain" ] || error "Legacy usage requires domain: bash easytrojan.sh <password> <domain>"
        do_install
        ;;
esac