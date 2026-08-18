#!/bin/bash
# EasyTrojan module: caddy.sh
# shellcheck shell=bash

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
        error "SHA256SUMS has no entry for ${base}; refusing unverified release asset"
    fi
    local actual
    actual=$(sha256_file "$archive") || error "No sha256 tool available (sha256sum/shasum/openssl)"
    if [ "$actual" != "$expected" ]; then
        error "SHA256 mismatch for ${base}\n  expected: ${expected}\n  actual:   ${actual}"
    fi
    ok "SHA256 verified for ${base}"
}

validate_caddy_archive() {
    local archive="$1"
    # The release workflow emits one top-level regular file. Reject path
    # traversal, links, hardlinks, and auxiliary entries before extraction.
    tar -tzf "$archive" | awk '
        BEGIN { count = 0 }
        { count++; if ($0 != "caddy") bad = 1 }
        END { exit !(count == 1 && !bad) }
    ' || return 1
    tar -tvzf "$archive" | awk '
        BEGIN { count = 0 }
        { count++; if (substr($0, 1, 1) != "-") bad = 1 }
        END { exit !(count == 1 && !bad) }
    ' || return 1
}

download_caddy() (
    local arch version base_url tmp_dir archive sums
    arch=$(detect_arch)
    version="${release_version:-latest}"
    base_url=$(release_asset_base "$version")
    tmp_dir=$(mktemp -d)
    trap 'rm -rf -- "${tmp_dir:-}"' EXIT
    archive="${tmp_dir}/caddy_trojan_linux_${arch}.tar.gz"
    sums="${tmp_dir}/SHA256SUMS"
    local sigstore="${tmp_dir}/SHA256SUMS.sigstore.json"

    info "Downloading Caddy-Trojan (${arch}, version=${version})..."
    if ! curl -fsSL --connect-timeout 15 --max-time 180 \
        "${base_url}/caddy_trojan_linux_${arch}.tar.gz" -o "$archive"; then
        error "Failed to download Caddy binary from ${base_url}"
    fi

    if curl -fsSL --connect-timeout 10 --max-time 30 "${base_url}/SHA256SUMS" -o "$sums" 2>/dev/null; then
        if ! declare -F _easytrojan_verify_release_manifest >/dev/null 2>&1; then
            error "Release signature verifier is unavailable; refusing release metadata"
        fi
        curl -fsSL --connect-timeout 10 --max-time 30 \
            "${base_url}/SHA256SUMS.sigstore.json" -o "$sigstore" 2>/dev/null || true
        _easytrojan_verify_release_manifest "$sums" "$sigstore" "$tmp_dir" \
            || error "Sigstore verification failed; refusing Caddy release asset"
        verify_archive_sha256 "$archive" "$sums"
    else
        error "SHA256SUMS not found for this release; refusing unverified Caddy binary"
    fi

    validate_caddy_archive "$archive" \
        || error "Archive is not a single regular 'caddy' file; refusing extraction"
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
)

wait_for_admin_api() {
    local _
    for _ in $(seq 1 15); do
        curl -sf --connect-timeout 1 --max-time 2 "${ADMIN_API}/config/" &>/dev/null && return 0
        sleep 1
    done
    return 1
}

# Caddy provisions app modules during `validate`. The Trojan memory+caddy
# backend therefore writes users while checking a config, so validation must
# never point at the live Caddy storage (especially when invoked as root).
validate_caddy_config() (
    local config="$1" validation_root=""
    [ -x "$CADDY_BIN" ] && [ -f "$config" ] || return 1
    validation_root=$(mktemp -d) || return 1
    trap 'rm -rf -- "$validation_root"' EXIT
    mkdir -p "$validation_root/config" "$validation_root/data" "$validation_root/home"
    XDG_CONFIG_HOME="$validation_root/config" \
        XDG_DATA_HOME="$validation_root/data" \
        HOME="$validation_root/home" \
        "$CADDY_BIN" validate --config "$config" --adapter caddyfile
)

# Print the ACME certificate belonging to DOMAIN. Do not treat an unrelated
# certificate left in Caddy storage as proof that the requested site is ready.
find_domain_certificate() {
    local domain="$1" cert_dir="${CADDY_DATA_DIR}/certificates" cert=""
    [ -n "$domain" ] && [ -d "$cert_dir" ] || return 1
    cert=$(find "$cert_dir" -type f -name "${domain}.crt" 2>/dev/null | head -1 || true)
    if [ -n "$cert" ]; then
        printf '%s' "$cert"
        return 0
    fi
    # Accommodate storage layouts whose filename is not the domain when the
    # installed OpenSSL supports RFC 6125 hostname verification.
    if check_cmd openssl && openssl x509 -help 2>&1 | grep -q -- '-checkhost'; then
        while IFS= read -r cert; do
            if openssl x509 -in "$cert" -noout -checkhost "$domain" >/dev/null 2>&1; then
                printf '%s' "$cert"
                return 0
            fi
        done < <(find "$cert_dir" -type f -name '*.crt' 2>/dev/null)
    fi
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

# Serialize configuration readers/writers when flock is available. The fallback
# keeps compatibility with minimal systems; normal supported Linux packages
# provide flock through util-linux.
with_config_lock() {
    if command -v flock >/dev/null 2>&1; then
        mkdir -p "$TROJAN_DIR"
        ( flock -x 9; "$@" ) 9>"${CONFIG_LOCK_FILE:-${TROJAN_DIR}/.config.lock}"
    else
        "$@"
    fi
}

# Generate /etc/caddy/Caddyfile from domain + passwd.txt.
# Users are declared statically (imgk official style). The `memory caddy`
# upstream keeps authentication and counters on the hot path in memory while
# asynchronously persisting them to Caddy storage; delete must clear storage
# through the Admin API as well as updating passwd.txt/Caddyfile.
_generate_caddyfile() {
    local site_domain="${1:-}"
    if [ -z "$site_domain" ]; then
        site_domain=$(read_installed_domain 2>/dev/null || true)
    fi
    [ -n "$site_domain" ] || error "Domain not set; cannot generate Caddyfile"
    mkdir -p "$CADDY_DIR" "$WWW_DIR" "$TROJAN_DIR"
    chown root:caddy "$CADDY_DIR" "$TROJAN_DIR" "$WWW_DIR" 2>/dev/null || true
    chmod 750 "$CADDY_DIR" "$TROJAN_DIR"
    local users_block tls_line hub_proxy="" config_tmp outbound_ip
    local https_port="${CADDY_HTTPS_PORT:-443}" http_port="${CADDY_HTTP_PORT:-80}"
    local admin_listen="${CADDY_ADMIN_LISTEN:-127.0.0.1:2019}"
    local https_redirect_port="" https_site_label
    case "$https_port" in
        ''|*[!0-9]*) error "Invalid Caddy HTTPS port: $https_port" ;;
    esac
    case "$http_port" in
        ''|*[!0-9]*) error "Invalid Caddy HTTP port: $http_port" ;;
    esac
    [ "$https_port" -ge 1 ] && [ "$https_port" -le 65535 ] \
        || error "Invalid Caddy HTTPS port: $https_port"
    [ "$http_port" -ge 1 ] && [ "$http_port" -le 65535 ] \
        || error "Invalid Caddy HTTP port: $http_port"
    if [ "$https_port" = "443" ]; then
        https_site_label=":443, ${site_domain}"
    else
        # A bare :PORT site is a catch-all TLS automation policy. Pairing it
        # with an explicit certificate-bearing hostname at a non-default port
        # makes recent Caddy versions reject the config as conflicting policies.
        https_site_label="${site_domain}:${https_port}"
        https_redirect_port=":${https_port}"
    fi
    users_block=$(build_users_directive)
    # NOTE: $(...) strips trailing newlines; keep ${tls_line} on its own line in the heredoc.
    tls_line=$(tls_directive_line "$site_domain")
    outbound_ip=$(current_outbound_ip_priority)
    if hub_enabled; then
        # Sibling handle blocks are mutually exclusive. SPA try_files MUST live in its own
        # catch-all handle; otherwise it rewrites /sub/* and /api/* to index.html (browser 404).
        # Force no-cache on proxied /sub so CF/browser do not serve empty/stale body.
        hub_proxy="    handle /sub/* {
        reverse_proxy ${HUB_LISTEN} {
            header_down Cache-Control \"no-store, no-cache, must-revalidate, max-age=0\"
            header_down Pragma no-cache
            header_down Expires 0
        }
    }
    handle /api/* {
        reverse_proxy ${HUB_LISTEN} {
            header_down Cache-Control \"no-store, no-cache, must-revalidate, max-age=0\"
        }
    }
"
    fi

    config_tmp=$(mktemp "${CADDY_DIR}/.Caddyfile.XXXXXX")
    cat > "$config_tmp" <<EOF
# Managed by EasyTrojan. Do not edit this file manually.
{
    admin ${admin_listen}
    # Must run before catch-all SPA 'handle' (and hub handle blocks).
    # 'before file_server' is too late: after 9b4c7b0 SPA lives inside handle,
    # so WS upgrades hit file_server HTML (HTTP 200) and never Trojan.
    order trojan before handle
    https_port ${https_port}
    servers :${https_port} {
        # Browsers may use h2; Trojan WebSocket clients must offer http/1.1 only.
        protocols h2 h1
    }
    servers :${http_port} {
        protocols h1
    }
    trojan {
        memory caddy
        no_proxy ${outbound_ip}
${users_block}    }
}
${https_site_label} {
${tls_line}
    log {
        level ERROR
    }
    trojan {
        connect_method
        websocket
    }
${hub_proxy}    # Camouflage SPA (IT-Tools): only when hub routes above did not match
    handle {
        root * ${WWW_DIR}
        try_files {path} /index.html
        file_server
    }
}
# HTTP-01 ACME needs port 80; do not blanket-redirect challenge paths
:${http_port} {
    @not_acme {
        not path /.well-known/acme-challenge/*
    }
    redir @not_acme https://{host}${https_redirect_port}{uri} permanent
    root * ${WWW_DIR}
    file_server
}
EOF
    if [ ! -x "$CADDY_BIN" ]; then
        rm -f "$config_tmp"
        error "Caddy binary missing; refusing to install an unvalidated Caddyfile"
    fi
    if ! validate_caddy_config "$config_tmp" >/dev/null 2>&1; then
        rm -f "$config_tmp"
        error "Generated Caddyfile failed validation; active configuration was not changed"
    fi
    if [ -f "$CADDYFILE" ]; then
        cp -p "$CADDYFILE" "${CADDYFILE}.bak"
        chown root:caddy "${CADDYFILE}.bak" 2>/dev/null || true
        chmod 640 "${CADDYFILE}.bak"
    fi
    chown root:caddy "$config_tmp"
    chmod 640 "$config_tmp"
    mv -f "$config_tmp" "$CADDYFILE"
    printf '%s\n' "$site_domain" > "$DOMAIN_FILE"
    chown root:caddy "$DOMAIN_FILE"
    chmod 640 "$DOMAIN_FILE"
    printf '%s\n' "$outbound_ip" > "$OUTBOUND_IP_PRIORITY_FILE"
    chown root:caddy "$OUTBOUND_IP_PRIORITY_FILE" 2>/dev/null || true
    chmod 640 "$OUTBOUND_IP_PRIORITY_FILE"
    printf 'managed_by=easytrojan\nversion=1\n' > "$MANAGED_MARKER"
    chown root:caddy "$MANAGED_MARKER" 2>/dev/null || true
    chmod 640 "$MANAGED_MARKER"
}

generate_caddyfile() {
    with_config_lock _generate_caddyfile "$@"
}

# Best-effort clear of a user from caddy storage (imgk CaddyUpstream).
# Required on delete: removing from Caddyfile alone does not drop storage keys.
delete_trojan_user_storage() {
    local passwd="$1" payload
    payload=$(printf '{"password":"%s"}' "$(json_escape "$passwd")")
    # imgk/caddy-trojan: DELETE /trojan/users/delete  body: {"password":"..."}
    # Password goes through http_send_json's temp body file, never argv.
    http_send_json DELETE "${ADMIN_API}/trojan/users/delete" "" "$payload" -sf --connect-timeout 2 --max-time 8
}

_remove_password_from_file() {
    local passwd="$1"
    [ -f "$PASSWD_FILE" ] || return 0
    local tmp
    tmp=$(mktemp "${TROJAN_DIR}/.passwd.XXXXXX")
    # exact line match only
    grep -Fxv -- "$passwd" "$PASSWD_FILE" > "$tmp" || true
    mv -f "$tmp" "$PASSWD_FILE"
    chmod 640 "$PASSWD_FILE"
    chown root:caddy "$PASSWD_FILE" 2>/dev/null || true
}

remove_password_from_file() {
    with_config_lock _remove_password_from_file "$@"
}

# Echo the share/subscription transport: "tcp" when the Caddyfile has no
# websocket directive, otherwise "ws". Centralizes a check duplicated across
# status/link/hub call sites.
detect_share_transport() {
    if [ -f "$CADDYFILE" ] && ! grep -q "websocket" "$CADDYFILE" 2>/dev/null; then
        printf 'tcp'
    else
        printf 'ws'
    fi
}

caddyfile_has_trojan_listener_wrapper() {
    local file="$1"
    [ -f "$file" ] || return 1
    awk '
        /^[[:space:]]*listener_wrappers[[:space:]]*\{/ { in_wrappers = 1 }
        in_wrappers && /(^|[[:space:]{])trojan([[:space:]}]|$)/ { found = 1 }
        in_wrappers && /}/ { in_wrappers = 0 }
        END { exit(found ? 0 : 1) }
    ' "$file"
}

reload_caddy() {
    local legacy_wrapper_removed=0
    if caddyfile_has_trojan_listener_wrapper "${CADDYFILE}.bak" \
        && ! caddyfile_has_trojan_listener_wrapper "$CADDYFILE"; then
        legacy_wrapper_removed=1
    fi
    if ! systemctl is-active --quiet caddy 2>/dev/null; then
        return 0
    fi
    if [ "$legacy_wrapper_removed" -eq 1 ]; then
        # Reload can retain the old listener under Caddy's eternal grace period.
        # A full process restart is required to stop intercepting ordinary TLS.
        info "Restarting Caddy to retire the legacy Trojan listener wrapper..."
        if systemctl restart caddy.service 2>/dev/null && wait_for_admin_api; then
            return 0
        fi
        warn "Caddy restart failed after removing the legacy listener wrapper; restoring the previous configuration..."
        if [ -f "${CADDYFILE}.bak" ]; then
            cp -p "${CADDYFILE}.bak" "$CADDYFILE"
            chown root:caddy "$CADDYFILE" 2>/dev/null || true
            chmod 640 "$CADDYFILE"
            systemctl restart caddy.service 2>/dev/null || true
        fi
        return 1
    fi
    if systemctl reload caddy.service 2>/dev/null; then
        return 0
    fi
    if [ -x "$CADDY_BIN" ] && XDG_CONFIG_HOME=/etc XDG_DATA_HOME=/var/lib HOME=/var/lib/caddy \
        "$CADDY_BIN" reload --config "$CADDYFILE" --force 2>/dev/null; then
        return 0
    fi
    warn "Caddy reload failed; restoring the previous validated configuration..."
    if [ -f "${CADDYFILE}.bak" ]; then
        cp -p "${CADDYFILE}.bak" "$CADDYFILE"
        chown root:caddy "$CADDYFILE" 2>/dev/null || true
        chmod 640 "$CADDYFILE"
        systemctl reload caddy.service 2>/dev/null \
            || XDG_CONFIG_HOME=/etc XDG_DATA_HOME=/var/lib HOME=/var/lib/caddy \
                "$CADDY_BIN" reload --config "$CADDYFILE" --force 2>/dev/null \
            || warn "Previous Caddyfile was restored, but reload still failed"
    else
        warn "No previous Caddyfile backup exists; current process was left running"
    fi
    return 1
}

mask_secret() {
    local s="$1" n=${#1}
    # Fully mask short secrets; only reveal edges of clearly long ones.
    if [ "$n" -le 8 ]; then
        printf '****'
    else
        printf '%s***%s' "${s:0:2}" "${s: -2}"
    fi
}

_persist_password() {
    local passwd="$1"
    validate_password_value "$passwd"
    mkdir -p "$TROJAN_DIR"
    chown root:caddy "$TROJAN_DIR" 2>/dev/null || true
    chmod 750 "$TROJAN_DIR"
    local tmp
    tmp=$(mktemp "${TROJAN_DIR}/.passwd.XXXXXX")
    {
        [ -f "$PASSWD_FILE" ] && cat "$PASSWD_FILE"
        printf '%s\n' "$passwd"
    } | awk 'NF && !seen[$0]++' > "$tmp"
    mv -f "$tmp" "$PASSWD_FILE"
    chmod 640 "$PASSWD_FILE"
    chown root:caddy "$PASSWD_FILE" 2>/dev/null || true
}

persist_password() {
    with_config_lock _persist_password "$@"
}
