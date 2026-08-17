#!/bin/bash
#
# EasyTrojan - One-click Caddy-Trojan installer
# Supports: CentOS/RedHat 7+, Debian 9+, Ubuntu 16+
#
# Usage:
#   bash easytrojan.sh install --domain DOMAIN [--password PASS] [--version VER] [--outbound-ip ipv4|ipv6] [--skip-domain-check]
#                            [--tls-mode auto|origin] [--origin-cert PATH] [--origin-key PATH]
#                            [--tune-system]
#   bash easytrojan.sh update  [--version VER]
#   bash easytrojan.sh renew [--force]
#   bash easytrojan.sh status [--show-link] [--server ADDR] [--port PORT] [--name NAME]
#   bash easytrojan.sh doctor [--network]
#   bash easytrojan.sh link [--server ADDR] [--port PORT] [--password PASS] [--name NAME]
#   bash easytrojan.sh cert {auto|origin|status} ...
#   bash easytrojan.sh user {add|list|del} ...
#   bash easytrojan.sh hub enable|disable|status|url|token|list|remove|join|leave ...
#   bash easytrojan.sh <password> <domain>   # legacy
#
# Based on: https://github.com/imgk/caddy-trojan
# Project:  https://github.com/zhongtait/caddy-trojan

# This file defines the shared config constants and entry-point variables that
# the dynamically-sourced lib/*.sh modules consume; shellcheck cannot follow that
# indirection, so its "unused variable" check is a false positive here.
# shellcheck disable=SC2034

set -euo pipefail

REPO_OWNER="zhongtait"
REPO_NAME="caddy-trojan"
REPO_API="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}"
CADDY_BIN="/usr/local/bin/caddy"
SCRIPT_BIN="/usr/local/bin/easytrojan"
SCRIPT_LEGACY="/usr/local/bin/easytrojan.sh"
SHARE_DIR="${EASYTROJAN_SHARE_DIR:-/usr/local/share/easytrojan}"
LIB_SHARE_DIR="${SHARE_DIR}/lib"
CADDY_DIR="/etc/caddy"
CADDY_XDG_DATA_HOME="/var/lib"
CADDY_DATA_DIR="${CADDY_XDG_DATA_HOME}/caddy"
CADDY_DATA_MARKER="${CADDY_DATA_DIR}/.easytrojan-managed"
TROJAN_DIR="${CADDY_DIR}/trojan"
PASSWD_FILE="${TROJAN_DIR}/passwd.txt"
CONFIG_LOCK_FILE="${TROJAN_DIR}/.config.lock"
DOMAIN_FILE="${TROJAN_DIR}/domain.txt"
OUTBOUND_IP_PRIORITY_FILE="${TROJAN_DIR}/outbound-ip-priority.txt"
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
IT_TOOLS_PINNED_VERSION="v2024.10.22-7ca5933"
IT_TOOLS_PINNED_SHA256="eef276d675db6053bdc65cd8482a566785561c70eed5035a0e05b0e627b0989d"
IT_TOOLS_VERSION="${IT_TOOLS_VERSION:-$IT_TOOLS_PINNED_VERSION}"

# Release manifests are signed by the main GitHub Actions workflow. Keep the
# cosign bootstrap immutable before a release bundle is sourced as root.
EASYTROJAN_COSIGN_VERSION="v3.1.3"
EASYTROJAN_COSIGN_LINUX_AMD64_SHA256="4629c757b7618056f8ddd7e2625ae9fdd94c0372a65049520bc7d9df9efc7f71"
EASYTROJAN_COSIGN_LINUX_ARM64_SHA256="c5d324e091826b0d7a78eb16fef316450b4eb9aaec045611c08ba06f5e73220a"
EASYTROJAN_RELEASE_OIDC_ISSUER="https://token.actions.githubusercontent.com"
EASYTROJAN_RELEASE_SIGNER_IDENTITY="https://github.com/${REPO_OWNER}/${REPO_NAME}/.github/workflows/release.yml@refs/heads/main"

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
    # Only installed entries may reuse installed modules. A newly downloaded
    # entry must refresh the complete module set instead of mixing versions.
    if { [ "$src" = "$SCRIPT_BIN" ] || [ "$src" = "$SCRIPT_LEGACY" ]; } \
        && [ -d "${LIB_SHARE_DIR}" ]; then
        printf '%s' "$SHARE_DIR"
        return 0
    fi
    printf '%s' "$dir"
}

EASYTROJAN_ROOT="${EASYTROJAN_ROOT:-$(_easytrojan_root_from_script)}"

_easytrojan_is_installed_entry() {
    local src
    src=$(_easytrojan_script_path)
    [ "$src" = "$SCRIPT_BIN" ] || [ "$src" = "$SCRIPT_LEGACY" ]
}

_easytrojan_sha256_file() {
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

_easytrojan_cosign_arch() {
    case "$(uname -s 2>/dev/null)" in
        Linux) ;;
        *) return 1 ;;
    esac
    case "$(uname -m 2>/dev/null)" in
        x86_64|amd64)
            printf '%s\t%s\n' amd64 "$EASYTROJAN_COSIGN_LINUX_AMD64_SHA256"
            ;;
        aarch64|arm64)
            printf '%s\t%s\n' arm64 "$EASYTROJAN_COSIGN_LINUX_ARM64_SHA256"
            ;;
        *) return 1 ;;
    esac
}

_easytrojan_resolve_cosign() (
    local stage="${1:-}" arch expected cache_dir target tmp
    # A test-only binary hook keeps offline regression tests deterministic. It
    # is intentionally unavailable to normal invocations so production always
    # executes the pinned, hash-verified cosign release below.
    if [ "${EASYTROJAN_SOURCE_ONLY_ACTIVE:-0}" = "1" ] \
        && [ -n "${EASYTROJAN_COSIGN_BIN:-}" ]; then
        [ -x "$EASYTROJAN_COSIGN_BIN" ] || return 1
        printf '%s\n' "$EASYTROJAN_COSIGN_BIN"
        return 0
    fi
    IFS=$'\t' read -r arch expected < <(_easytrojan_cosign_arch) || return 1

    # Keep the verifier inside the caller's private mktemp directory. A
    # persistent cache could be replaced between hashing and execution.
    cache_dir="${stage:-}"
    [ -n "$cache_dir" ] || return 1
    target="${cache_dir}/cosign-${EASYTROJAN_COSIGN_VERSION}-${arch}"
    if [ -x "$target" ] && [ "$(_easytrojan_sha256_file "$target" 2>/dev/null || true)" = "$expected" ]; then
        printf '%s\n' "$target"
        return 0
    fi

    [ -d "$cache_dir" ] && [ -w "$cache_dir" ] || return 1
    tmp=$(mktemp "${target}.tmp.XXXXXX") || return 1
    trap 'rm -f -- "${tmp:-}"' EXIT
    curl -fsSL --connect-timeout 15 --max-time 240 \
        "https://github.com/sigstore/cosign/releases/download/${EASYTROJAN_COSIGN_VERSION}/cosign-linux-${arch}" \
        -o "$tmp" || return 1
    [ "$(_easytrojan_sha256_file "$tmp" 2>/dev/null || true)" = "$expected" ] || return 1
    chmod 755 "$tmp"
    mv -f -- "$tmp" "$target"
    trap - EXIT
    printf '%s\n' "$target"
)

_easytrojan_verify_release_manifest() {
    local manifest="$1" bundle="$2" stage="${3:-}" cosign
    if [ ! -s "$bundle" ]; then
        if [ "${EASYTROJAN_ALLOW_UNSIGNED_RELEASE:-0}" = "1" ]; then
            warn "Release has no Sigstore bundle; accepting legacy unsigned metadata because EASYTROJAN_ALLOW_UNSIGNED_RELEASE=1"
            return 0
        fi
        warn "Release is missing ${bundle##*/}; refusing unsigned release metadata"
        return 1
    fi
    cosign=$(_easytrojan_resolve_cosign "$stage") || {
        warn "Unable to bootstrap the pinned cosign verifier"
        return 1
    }
    if ! "$cosign" verify-blob \
        --bundle "$bundle" \
        --certificate-identity "$EASYTROJAN_RELEASE_SIGNER_IDENTITY" \
        --certificate-oidc-issuer "$EASYTROJAN_RELEASE_OIDC_ISSUER" \
        "$manifest" >/dev/null 2>&1; then
        warn "Sigstore verification failed for ${manifest##*/}; refusing release metadata"
        return 1
    fi
    ok "Sigstore verified ${manifest##*/}"
}

_easytrojan_fetch_repository_snapshot() {
    local stage="$1"
    local repo_meta="${stage}/repo.json" archive="${stage}/repository.tar.gz"
    local repo_ref=""

    mkdir -p "$stage"
    if ! curl -fsSL --connect-timeout 10 --max-time 30 \
        -H "Accept: application/vnd.github+json" \
        -H "User-Agent: easytrojan" \
        "${REPO_API}/commits/main" -o "$repo_meta" 2>/dev/null; then
        # Never execute a mutable branch snapshot. The caller will fall back to
        # the checksummed Release bundle when immutable commit metadata is unavailable.
        return 1
    fi
    repo_ref=$(sed -n 's/^[[:space:]]*"sha":[[:space:]]*"\([0-9a-fA-F]\{40\}\)".*/\1/p' "$repo_meta" | head -1)
    printf '%s' "$repo_ref" | grep -Eq '^[0-9a-fA-F]{40}$' || return 1

    if ! curl -fsSL --connect-timeout 15 --max-time 120 \
        "https://github.com/${REPO_OWNER}/${REPO_NAME}/archive/${repo_ref}.tar.gz" -o "$archive"; then
        return 1
    fi
    tar -tzf "$archive" | awk '/^\// || /(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' || return 1
    # Git archives may contain symlinks. Only regular files/directories are safe
    # here because the extracted modules are subsequently copied and sourced as root.
    tar -tvzf "$archive" | awk 'substr($0,1,1) !~ /^[-d]$/ {bad=1} END {exit bad}' || return 1
    rm -rf "${stage}/unpack"
    mkdir -p "${stage}/unpack"
    tar -xzf "$archive" --strip-components=1 --no-same-owner --no-same-permissions \
        -C "${stage}/unpack" || return 1
    [ -f "${stage}/unpack/easytrojan.sh" ] || return 1
    [ -f "${stage}/unpack/lib/common.sh" ] || return 1
    info "Loading EasyTrojan modules from repository commit ${repo_ref:0:7}"
}

_easytrojan_fetch_release_snapshot() {
    local stage="$1" base_url="${2:-https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/latest/download}"
    local bundle="${stage}/easytrojan_bundle.tar.gz" sums="${stage}/SHA256SUMS"
    local sigstore="${stage}/SHA256SUMS.sigstore.json"
    local expected actual

    mkdir -p "$stage"
    if ! curl -fsSL --connect-timeout 15 --max-time 60 \
        "${base_url}/easytrojan_bundle.tar.gz" -o "$bundle" 2>/dev/null \
        || ! curl -fsSL --connect-timeout 10 --max-time 30 \
            "${base_url}/SHA256SUMS" -o "$sums" 2>/dev/null; then
        return 1
    fi
    # A present signature is never bypassed. The explicit compatibility flag
    # only permits old releases that predate Sigstore and have no bundle.
    curl -fsSL --connect-timeout 10 --max-time 30 \
        "${base_url}/SHA256SUMS.sigstore.json" -o "$sigstore" 2>/dev/null || true
    _easytrojan_verify_release_manifest "$sums" "$sigstore" "$stage" || return 1
    expected=$(awk '$2 == "easytrojan_bundle.tar.gz" {print $1; exit}' "$sums")
    [ -n "$expected" ] || return 1
    if check_cmd sha256sum; then actual=$(sha256sum "$bundle" | awk '{print $1}')
    elif check_cmd shasum; then actual=$(shasum -a 256 "$bundle" | awk '{print $1}')
    elif check_cmd openssl; then actual=$(openssl dgst -sha256 "$bundle" | awk '{print $NF}')
    else return 1
    fi
    [ "$actual" = "$expected" ] || return 1
    tar -tzf "$bundle" | awk '!/^(easytrojan\.sh|hub_server\.py|lib\/?|lib\/[A-Za-z0-9._-]+)$/ {bad=1} END {exit bad}' || return 1
    tar -tvzf "$bundle" | awk 'substr($0,1,1) !~ /^[-d]$/ {bad=1} END {exit bad}' || return 1
    rm -rf "${stage}/unpack"
    mkdir -p "${stage}/unpack"
    tar -xzf "$bundle" -C "${stage}/unpack" || return 1
    info "Loading EasyTrojan modules from the checksummed Release bundle"
}

_easytrojan_fetch_module() {
    local name="$1" dest="$2"
    check_cmd curl || return 1
    local stage="${EASYTROJAN_BOOTSTRAP_STAGE:-}"
    if [ -z "$stage" ]; then
        stage=$(mktemp -d)
        EASYTROJAN_BOOTSTRAP_STAGE="$stage"
        export EASYTROJAN_BOOTSTRAP_STAGE
        if ! _easytrojan_fetch_repository_snapshot "$stage"; then
            warn "Current repository snapshot unavailable; trying the latest Release bundle"
            _easytrojan_fetch_release_snapshot "$stage" || return 1
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

_easytrojan_copy_if_different() {
    local src="$1" dest="$2"
    if [ -e "$dest" ] && [ "$src" -ef "$dest" ]; then
        return 0
    fi
    cp -f "$src" "$dest"
}

# Repository checkouts use sibling modules. Installed entries use SHARE_DIR.
# Any other standalone entry refreshes every module from one coherent snapshot.
easytrojan_source() {
    local name="$1" path=""
    if [ -f "${EASYTROJAN_ROOT}/lib/${name}" ]; then
        path="${EASYTROJAN_ROOT}/lib/${name}"
    elif _easytrojan_is_installed_entry && [ -f "${LIB_SHARE_DIR}/${name}" ]; then
        path="${LIB_SHARE_DIR}/${name}"
    else
        mkdir -p "$LIB_SHARE_DIR"
        if _easytrojan_fetch_module "$name" "${LIB_SHARE_DIR}/${name}"; then
            chmod 644 "${LIB_SHARE_DIR}/${name}"
            path="${LIB_SHARE_DIR}/${name}"
        else
            error "Missing module lib/${name}. Place the complete repo beside easytrojan.sh or ensure the repository/Release snapshot is reachable"
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
    if [ -n "${EASYTROJAN_BOOTSTRAP_STAGE:-}" ] \
        && [ -f "${EASYTROJAN_BOOTSTRAP_STAGE}/unpack/easytrojan.sh" ]; then
        src="${EASYTROJAN_BOOTSTRAP_STAGE}/unpack/easytrojan.sh"
    fi
    if [ ! -f "$src" ]; then
        return 0
    fi
    _easytrojan_copy_if_different "$src" "$SCRIPT_BIN"
    _easytrojan_copy_if_different "$src" "$SCRIPT_LEGACY"
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
    elif [ -n "${EASYTROJAN_BOOTSTRAP_STAGE:-}" ]; then
        _easytrojan_fetch_bundle_file hub_server.py "${SHARE_DIR}/hub_server.py" 2>/dev/null || true
        [ -f "${SHARE_DIR}/hub_server.py" ] && chmod 644 "${SHARE_DIR}/hub_server.py"
    elif [ ! -f "${SHARE_DIR}/hub_server.py" ]; then
        _easytrojan_fetch_bundle_file hub_server.py "${SHARE_DIR}/hub_server.py" 2>/dev/null || true
        [ -f "${SHARE_DIR}/hub_server.py" ] && chmod 644 "${SHARE_DIR}/hub_server.py"
    fi
}

# Test harnesses can source the bootstrap verifier without loading modules or
# entering the command dispatcher. This does not affect normal invocations.
if [ "${EASYTROJAN_SOURCE_ONLY:-0}" = "1" ] \
    && [ "${BASH_SOURCE[0]}" != "$0" ]; then
    EASYTROJAN_SOURCE_ONLY_ACTIVE=1
    return 0 2>/dev/null || exit 0
fi

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
outbound_ip_priority=""

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
