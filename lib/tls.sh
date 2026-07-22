#!/bin/bash
# EasyTrojan module: tls.sh
# shellcheck shell=bash

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
