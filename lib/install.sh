#!/bin/bash
# EasyTrojan module: install.sh
# shellcheck shell=bash

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
    echo -e "${GREEN}║${NC}  ALPN     : ${CYAN}h2, http/1.1${NC}"
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
    echo -e "${GREEN}║${NC}  ${YELLOW}Client:${NC} ALPN=h2,http/1.1; SNI/Host=domain; path=/"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}
