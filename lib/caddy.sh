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
    local users_block tls_line hub_proxy=""
    users_block=$(build_users_directive)
    # NOTE: $(...) strips trailing newlines; keep ${tls_line} on its own line in the heredoc.
    tls_line=$(tls_directive_line "$site_domain")
    if hub_enabled; then
        # Sibling handle blocks are mutually exclusive. SPA try_files MUST live in its own
        # catch-all handle; otherwise it rewrites /sub/* and /api/* to index.html (browser 404).
        hub_proxy="    handle /sub/* {
        reverse_proxy ${HUB_LISTEN}
    }
    handle /api/* {
        reverse_proxy ${HUB_LISTEN}
    }
"
    fi

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
${hub_proxy}    # Camouflage SPA (IT-Tools): only when hub routes above did not match
    handle {
        root * ${WWW_DIR}
        try_files {path} /index.html
        file_server
    }
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
