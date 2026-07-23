#!/bin/bash
#
# EasyTrojan - One-click Caddy-Trojan installer
# Supports: CentOS/RedHat 7+, Debian 9+, Ubuntu 16+
#
# Usage:
#   bash easytrojan.sh install --domain DOMAIN [--password PASS] [--version VER] [--skip-domain-check]
#                            [--tls-mode auto|origin] [--origin-cert PATH] [--origin-key PATH]
#                            [--tune-system]
#   bash easytrojan.sh update  [--version VER]
#   bash easytrojan.sh renew [--force]
#   bash easytrojan.sh status [--show-link] [--server ADDR] [--port PORT] [--name NAME]
#   bash easytrojan.sh doctor
#   bash easytrojan.sh link [--server ADDR] [--port PORT] [--password PASS] [--name NAME]
#   bash easytrojan.sh cert {auto|origin|status} ...
#   bash easytrojan.sh user {add|list|del} ...
#   bash easytrojan.sh hub enable|disable|status|url|token|list|remove|join|leave ...
#   bash easytrojan.sh <password> <domain>   # legacy
#
# Based on: https://github.com/imgk/caddy-trojan
# Project:  https://github.com/zhongtait/caddy-trojan

set -euo pipefail

REPO_OWNER="zhongtait"
REPO_NAME="caddy-trojan"
REPO_API="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}"
CADDY_BIN="/usr/local/bin/caddy"
SCRIPT_BIN="/usr/local/bin/easytrojan"
SCRIPT_LEGACY="/usr/local/bin/easytrojan.sh"
SHARE_DIR="/usr/local/share/easytrojan"
LIB_SHARE_DIR="${SHARE_DIR}/lib"
CADDY_DIR="/etc/caddy"
CADDY_XDG_DATA_HOME="/var/lib"
CADDY_DATA_DIR="${CADDY_XDG_DATA_HOME}/caddy"
CADDY_DATA_MARKER="${CADDY_DATA_DIR}/.easytrojan-managed"
TROJAN_DIR="${CADDY_DIR}/trojan"
PASSWD_FILE="${TROJAN_DIR}/passwd.txt"
DOMAIN_FILE="${TROJAN_DIR}/domain.txt"
TLS_MODE_FILE="${TROJAN_DIR}/tls-mode.txt"
TLS_CERT_FILE_REC="${TROJAN_DIR}/tls-cert.path"
TLS_KEY_FILE_REC="${TROJAN_DIR}/tls-key.path"
ORIGIN_CERT_DIR="${CADDY_DIR}/certs"
ORIGIN_CERT_DEFAULT="${ORIGIN_CERT_DIR}/origin.crt"
ORIGIN_KEY_DEFAULT="${ORIGIN_CERT_DIR}/origin.key"
HUB_DIR="${TROJAN_DIR}/hub"
HUB_CFG="${HUB_DIR}/config.json"
HUB_NODES="${HUB_DIR}/nodes.json"
HUB_ENABLED_FILE="${HUB_DIR}/enabled"
# Remote hub membership (this node joined another hub)
HUB_CLIENT_FILE="${TROJAN_DIR}/hub-client.json"
HUB_BIN="/usr/local/bin/easytrojan-hub"
HUB_LISTEN="127.0.0.1:2099"
HUB_UNIT="easytrojan-hub.service"
CADDYFILE="${CADDY_DIR}/Caddyfile"
MANAGED_MARKER="${CADDY_DIR}/.easytrojan-managed"
WWW_DIR="${CADDY_DIR}/www"
ADMIN_API="http://127.0.0.1:2019"
# Static camouflage site: CorentinTh/it-tools release zip (Vue SPA)
IT_TOOLS_REPO="CorentinTh/it-tools"
IT_TOOLS_VERSION="${IT_TOOLS_VERSION:-v2024.10.22-7ca5933}"

EASYTROJAN_LIB_MODULES=(
    common.sh
    tls.sh
    caddy.sh
    camouflage.sh
    system.sh
    hub.sh
    manage.sh
    install.sh
)

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

# Resolve script directory (repo checkout or /usr/local/bin)
_easytrojan_script_path() {
    readlink -f "$0" 2>/dev/null || printf '%s' "$0"
}

_easytrojan_root_from_script() {
    local src dir
    src=$(_easytrojan_script_path)
    dir=$(dirname "$src")
    if [ -d "${dir}/lib" ]; then
        printf '%s' "$dir"
        return 0
    fi
    # installed entry under /usr/local/bin -> modules in SHARE_DIR
    if [ -d "${LIB_SHARE_DIR}" ]; then
        printf '%s' "$SHARE_DIR"
        return 0
    fi
    printf '%s' "$dir"
}

EASYTROJAN_ROOT="${EASYTROJAN_ROOT:-$(_easytrojan_root_from_script)}"

_easytrojan_fetch_module() {
    local name="$1" dest="$2"
    check_cmd curl || return 1
    local stage="${EASYTROJAN_BOOTSTRAP_STAGE:-}"
    if [ -z "$stage" ]; then
        stage=$(mktemp -d)
        EASYTROJAN_BOOTSTRAP_STAGE="$stage"
        export EASYTROJAN_BOOTSTRAP_STAGE
        local bundle="${stage}/easytrojan_bundle.tar.gz" sums="${stage}/SHA256SUMS"
        local expected actual base_url repo_ref="" repo_meta="${stage}/repo.json"
        base_url="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/latest/download"
        mkdir -p "${stage}/unpack"
        if curl -fsSL --connect-timeout 15 --max-time 60 \
            "${base_url}/easytrojan_bundle.tar.gz" -o "$bundle" 2>/dev/null \
            && curl -fsSL --connect-timeout 10 --max-time 30 \
                "${base_url}/SHA256SUMS" -o "$sums" 2>/dev/null; then
            expected=$(awk '$2 == "easytrojan_bundle.tar.gz" {print $1; exit}' "$sums")
            [ -n "$expected" ] || return 1
            if check_cmd sha256sum; then actual=$(sha256sum "$bundle" | awk '{print $1}')
            elif check_cmd shasum; then actual=$(shasum -a 256 "$bundle" | awk '{print $1}')
            elif check_cmd openssl; then actual=$(openssl dgst -sha256 "$bundle" | awk '{print $NF}')
            else return 1
            fi
            [ "$actual" = "$expected" ] || return 1
            tar -tzf "$bundle" | awk '!/^(easytrojan\.sh|hub_server\.py|lib\/?|lib\/[A-Za-z0-9._-]+)$/ {bad=1} END {exit bad}' || return 1
            tar -xzf "$bundle" -C "${stage}/unpack" || return 1
        else
            rm -f "$bundle" "$sums"
            curl -fsSL --connect-timeout 10 --max-time 30 \
                -H "Accept: application/vnd.github+json" \
                -H "User-Agent: easytrojan" \
                "${REPO_API}/commits/main" -o "$repo_meta" || return 1
            repo_ref=$(sed -n 's/^[[:space:]]*"sha":[[:space:]]*"\([0-9a-fA-F]\{40\}\)".*/\1/p' "$repo_meta" | head -1)
            printf '%s' "$repo_ref" | grep -Eq '^[0-9a-fA-F]{40}$' || return 1
            info "Latest Release has no script bundle; using repository commit ${repo_ref:0:7}"
            bundle="${stage}/repository.tar.gz"
            curl -fsSL --connect-timeout 15 --max-time 120 \
                "https://github.com/${REPO_OWNER}/${REPO_NAME}/archive/${repo_ref}.tar.gz" -o "$bundle" || return 1
            tar -tzf "$bundle" | awk '/^\// || /(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' || return 1
            tar -xzf "$bundle" --strip-components=1 --no-same-owner --no-same-permissions \
                -C "${stage}/unpack" || return 1
        fi
    fi
    [ -f "${stage}/unpack/lib/${name}" ] || return 1
    cp -f "${stage}/unpack/lib/${name}" "$dest"
}

_easytrojan_fetch_bundle_file() {
    local name="$1" dest="$2" seed
    if [ -z "${EASYTROJAN_BOOTSTRAP_STAGE:-}" ]; then
        seed=$(mktemp)
        _easytrojan_fetch_module common.sh "$seed" || { rm -f "$seed"; return 1; }
        rm -f "$seed"
    fi
    local stage="${EASYTROJAN_BOOTSTRAP_STAGE}"
    [ -f "${stage}/unpack/${name}" ] || return 1
    cp -f "${stage}/unpack/${name}" "$dest"
}

# Source one module: prefer EASYTROJAN_ROOT/lib, then SHARE_DIR/lib, else download to SHARE_DIR
easytrojan_source() {
    local name="$1" path=""
    if [ -f "${EASYTROJAN_ROOT}/lib/${name}" ]; then
        path="${EASYTROJAN_ROOT}/lib/${name}"
    elif [ -f "${LIB_SHARE_DIR}/${name}" ]; then
        path="${LIB_SHARE_DIR}/${name}"
    else
        mkdir -p "$LIB_SHARE_DIR"
        if _easytrojan_fetch_module "$name" "${LIB_SHARE_DIR}/${name}"; then
            chmod 644 "${LIB_SHARE_DIR}/${name}"
            path="${LIB_SHARE_DIR}/${name}"
            # keep root pointing at share for subsequent modules
            if [ ! -d "${EASYTROJAN_ROOT}/lib" ]; then
                EASYTROJAN_ROOT="$SHARE_DIR"
            fi
        else
            error "Missing module lib/${name}. Place the complete repo beside easytrojan.sh or ensure the latest Release bundle is available"
        fi
    fi
    # shellcheck disable=SC1090
    . "$path"
}

easytrojan_load_all() {
    local m
    for m in "${EASYTROJAN_LIB_MODULES[@]}"; do
        easytrojan_source "$m"
    done
}

install_self() {
    local src src_dir m
    src=$(_easytrojan_script_path)
    if [ ! -f "$src" ]; then
        return 0
    fi
    cp -f "$src" "$SCRIPT_BIN"
    cp -f "$src" "$SCRIPT_LEGACY"
    chmod 755 "$SCRIPT_BIN" "$SCRIPT_LEGACY"

    src_dir=$(dirname "$src")
    mkdir -p "$LIB_SHARE_DIR" "$SHARE_DIR"

    # copy local lib/ if present, else ensure share modules exist (already loaded)
    if [ -d "${src_dir}/lib" ]; then
        for m in "${EASYTROJAN_LIB_MODULES[@]}"; do
            if [ -f "${src_dir}/lib/${m}" ]; then
                cp -f "${src_dir}/lib/${m}" "${LIB_SHARE_DIR}/${m}"
                chmod 644 "${LIB_SHARE_DIR}/${m}"
            fi
        done
    else
        for m in "${EASYTROJAN_LIB_MODULES[@]}"; do
            if [ ! -f "${LIB_SHARE_DIR}/${m}" ]; then
                _easytrojan_fetch_module "$m" "${LIB_SHARE_DIR}/${m}" 2>/dev/null || true
                [ -f "${LIB_SHARE_DIR}/${m}" ] && chmod 644 "${LIB_SHARE_DIR}/${m}"
            fi
        done
    fi

    if [ -f "${src_dir}/hub_server.py" ]; then
        cp -f "${src_dir}/hub_server.py" "${SHARE_DIR}/hub_server.py"
        chmod 644 "${SHARE_DIR}/hub_server.py"
    elif [ ! -f "${SHARE_DIR}/hub_server.py" ]; then
        _easytrojan_fetch_bundle_file hub_server.py "${SHARE_DIR}/hub_server.py" 2>/dev/null || true
        [ -f "${SHARE_DIR}/hub_server.py" ] && chmod 644 "${SHARE_DIR}/hub_server.py"
    fi
}

# Load modules then dispatch
easytrojan_load_all

# -------------------- entry --------------------
trojan_passwd=""
caddy_domain=""
release_version="latest"
skip_domain_check="0"
tls_mode=""
origin_cert_src=""
origin_key_src=""
tune_system="0"

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
    doctor)
        shift
        do_doctor "$@"
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
    hub|subhub|aggregate)
        shift
        do_hub "$@"
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
