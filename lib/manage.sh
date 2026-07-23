#!/bin/bash
# EasyTrojan module: manage.sh
# shellcheck shell=bash

do_doctor() {
    require_root
    [ "$#" -eq 0 ] || error "Usage: easytrojan doctor"

    local failures=0 domain mode cert_file key_file
    doctor_ok() { ok "doctor: $*"; }
    doctor_fail() { warn "doctor: $*"; failures=$((failures + 1)); }

    if [ -f "$MANAGED_MARKER" ] || { [ -f "$DOMAIN_FILE" ] && [ -f "$PASSWD_FILE" ]; }; then
        doctor_ok "EasyTrojan management marker/state found"
    else
        doctor_fail "managed state not found; install first or inspect /etc/caddy"
    fi

    domain=$(read_installed_domain 2>/dev/null || true)
    if [ -n "$domain" ]; then
        doctor_ok "domain: ${domain}"
    else
        doctor_fail "domain record missing"
    fi

    if [ -x "$CADDY_BIN" ]; then
        if XDG_CONFIG_HOME=/etc XDG_DATA_HOME=/var/lib HOME=/var/lib/caddy \
            "$CADDY_BIN" validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1; then
            doctor_ok "Caddyfile validates"
        else
            doctor_fail "Caddyfile validation failed"
        fi
    else
        doctor_fail "Caddy binary missing: $CADDY_BIN"
    fi

    if check_cmd systemctl; then
        if systemctl is-active --quiet caddy 2>/dev/null; then
            doctor_ok "caddy.service is active"
        else
            doctor_fail "caddy.service is not active"
        fi
    fi

    mode=$(read_tls_mode)
    case "$mode" in
        origin)
            cert_file=$(read_tls_cert_path)
            key_file=$(read_tls_key_path)
            if [ -f "$cert_file" ] && [ -f "$key_file" ]; then
                doctor_ok "origin certificate and key files exist"
            else
                doctor_fail "origin certificate/key missing"
            fi
            ;;
        auto)
            if [ -d "${CADDY_DATA_DIR}/certificates" ]; then
                doctor_ok "ACME certificate storage exists"
            else
                doctor_fail "ACME certificate storage missing"
            fi
            ;;
        *) doctor_fail "invalid TLS mode: ${mode:-<empty>}" ;;
    esac

    if hub_enabled; then
        if check_cmd systemctl && systemctl is-active --quiet "$HUB_UNIT" 2>/dev/null; then
            doctor_ok "Hub service is active"
        else
            doctor_fail "Hub is enabled but service is not active"
        fi
        if check_cmd curl && curl -fsS --connect-timeout 2 --max-time 5 "http://${HUB_LISTEN}/health" >/dev/null 2>&1; then
            doctor_ok "Hub health endpoint responds"
        else
            doctor_fail "Hub health endpoint is unavailable"
        fi
    else
        doctor_ok "Hub is disabled"
    fi

    if [ "$failures" -gt 0 ]; then
        warn "doctor found ${failures} issue(s)"
        return 1
    fi
    ok "doctor: no blocking issues found"
}

do_update() {
    require_root
    if [ -f "$CADDYFILE" ] && [ ! -f "$MANAGED_MARKER" ] \
        && { [ ! -f "$DOMAIN_FILE" ] || [ ! -f "$PASSWD_FILE" ]; }; then
        error "Existing non-EasyTrojan Caddy configuration detected; refusing to update it"
    fi
    install_pkg curl
    install_pkg tar

    # Stage 0: refresh the complete, checksummed script bundle from the same release.
    if [ "${EASYTROJAN_UPDATE_STAGE:-0}" != "1" ]; then
        info "Updating easytrojan script..."
        local update_stage entry_stage dest bundle sums base_url bundle_root
        update_stage=$(mktemp -d)
        bundle="${update_stage}/easytrojan_bundle.tar.gz"
        sums="${update_stage}/SHA256SUMS"
        base_url=$(release_asset_base "${release_version:-latest}")
        if curl -fsSL --connect-timeout 15 --max-time 60 "${base_url}/easytrojan_bundle.tar.gz" -o "$bundle" \
            && curl -fsSL --connect-timeout 10 --max-time 30 "${base_url}/SHA256SUMS" -o "$sums" \
            && verify_archive_sha256 "$bundle" "$sums"; then
            mkdir -p "${update_stage}/unpack"
            if ! tar -tzf "$bundle" | awk '!/^(easytrojan\.sh|hub_server\.py|lib\/?|lib\/[A-Za-z0-9._-]+)$/ {bad=1} END {exit bad}' \
                || ! tar -xzf "$bundle" -C "${update_stage}/unpack"; then
                rm -rf "$update_stage"
                error "Downloaded EasyTrojan bundle contains unexpected paths"
            fi
            entry_stage="${update_stage}/unpack/easytrojan.sh"
            bundle_root="${update_stage}/unpack"
            [ -f "$entry_stage" ] || { rm -rf "$update_stage"; error "EasyTrojan bundle is incomplete"; }
            chmod +x "$entry_stage"
            dest="$SCRIPT_BIN"
            if [ -f "$0" ] && [ -w "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")" ] 2>/dev/null; then
                dest=$(readlink -f "$0" 2>/dev/null || echo "$SCRIPT_BIN")
            fi
            local _m
            local _mods=("${EASYTROJAN_LIB_MODULES[@]}")
            if [ "${#_mods[@]}" -eq 0 ]; then
                _mods=(common.sh tls.sh caddy.sh camouflage.sh system.sh hub.sh manage.sh install.sh)
            fi
            local _failed=0
            for _m in "${_mods[@]}"; do
                if [ ! -f "${bundle_root}/lib/${_m}" ]; then
                    warn "Bundle is missing lib/${_m}"
                    _failed=$((_failed + 1))
                fi
            done
            if [ ! -f "${bundle_root}/hub_server.py" ]; then
                warn "Bundle is missing hub_server.py"
                _failed=$((_failed + 1))
            fi
            if [ "$_failed" -gt 0 ]; then
                rm -rf "$update_stage"
                error "Update staging failed (${_failed} file(s)); installed files were not changed"
            fi
            bash -n "$entry_stage" || { rm -rf "$update_stage"; error "Downloaded entry script failed syntax validation"; }
            for _m in "${_mods[@]}"; do
                bash -n "${bundle_root}/lib/${_m}" || { rm -rf "$update_stage"; error "Downloaded lib/${_m} failed syntax validation"; }
            done
            if check_cmd python3; then
                python3 -c 'import ast,sys; ast.parse(open(sys.argv[1],encoding="utf-8").read())' "${bundle_root}/hub_server.py" \
                    || { rm -rf "$update_stage"; error "Downloaded hub_server.py failed syntax validation"; }
            fi

            # Deploy the validated bundle; install the entry last so it never leads older modules.
            mkdir -p "${LIB_SHARE_DIR:-/usr/local/share/easytrojan/lib}" /usr/local/share/easytrojan
            for _m in "${_mods[@]}"; do
                cp -f "${bundle_root}/lib/${_m}" "${LIB_SHARE_DIR}/${_m}"
                chmod 644 "${LIB_SHARE_DIR}/${_m}"
            done
            cp -f "${bundle_root}/hub_server.py" /usr/local/share/easytrojan/hub_server.py
            chmod 644 /usr/local/share/easytrojan/hub_server.py
            cp -f "$entry_stage" "$SCRIPT_BIN"
            cp -f "$entry_stage" "$SCRIPT_LEGACY"
            chmod 755 "$SCRIPT_BIN" "$SCRIPT_LEGACY"
            if [ -n "${dest:-}" ] && [ "$dest" != "$SCRIPT_BIN" ] && [ -f "$dest" ]; then
                cp -f "$entry_stage" "$dest" 2>/dev/null || true
                chmod 755 "$dest" 2>/dev/null || true
            fi
            rm -rf "$update_stage"
            ok "Script updated -> re-executing with new version"
            local reexec_args=(update)
            if [ -n "${release_version:-}" ] && [ "$release_version" != "latest" ]; then
                reexec_args+=(--version "$release_version")
            fi
            export EASYTROJAN_UPDATE_STAGE=1
            exec bash "$SCRIPT_BIN" "${reexec_args[@]}"
        else
            warn "Versioned EasyTrojan bundle unavailable; continuing with current script for Caddy update..."
            rm -rf "$update_stage"
        fi
    fi

    local old_version new_version old_digest="" new_digest backup="" unit_refresh=0
    if [ -f "$MANAGED_MARKER" ] || [ -f "$DOMAIN_FILE" ]; then
        ensure_cert_storage
        write_caddy_unit
        systemctl daemon-reload 2>/dev/null || true
        unit_refresh=1
    fi
    old_version=$("$CADDY_BIN" version 2>/dev/null | awk '{print $1}' || echo "not-installed")
    info "Current Caddy version: $old_version"
    if [ -x "$CADDY_BIN" ]; then
        old_digest=$(sha256_file "$CADDY_BIN") || error "Cannot hash installed Caddy binary"
        backup=$(mktemp)
        cp -f "$CADDY_BIN" "$backup"
    fi

    download_caddy
    new_version=$("$CADDY_BIN" version 2>/dev/null | awk '{print $1}' || echo "unknown")
    new_digest=$(sha256_file "$CADDY_BIN") || error "Cannot hash downloaded Caddy binary"
    if ! "$CADDY_BIN" version &>/dev/null; then
        if [ -n "$backup" ] && [ -f "$backup" ]; then
            mv -f "$backup" "$CADDY_BIN"
            chmod +x "$CADDY_BIN"
            error "New binary is invalid; restored previous Caddy binary"
        fi
        error "New Caddy binary is invalid"
    fi
    if [ -n "$old_digest" ] && [ "$old_digest" = "$new_digest" ]; then
        if [ "$unit_refresh" = "1" ] && systemctl is-active --quiet caddy 2>/dev/null; then
            info "Restarting Caddy to apply the current hardened service unit..."
            systemctl restart caddy.service
            wait_for_admin_api || error "Caddy did not become healthy after service unit refresh"
        fi
        ok "Caddy binary already up to date: $new_version"
    else
        if systemctl is-active --quiet caddy 2>/dev/null; then
            info "Caddy binary changed; restarting service..."
            if ! systemctl restart caddy.service || ! wait_for_admin_api; then
                if [ -n "$backup" ] && [ -f "$backup" ]; then
                    warn "Caddy update failed health check; restoring previous binary..."
                    cp -f "$backup" "$CADDY_BIN"
                    chmod 755 "$CADDY_BIN"
                    systemctl restart caddy.service || true
                    rm -f "$backup"
                    error "Caddy update rolled back because the service did not become healthy"
                fi
                error "Caddy update failed and no previous binary was available"
            fi
            assert_admin_local_only || true
            # Users come from Caddyfile `users` + caddy storage; no API re-inject needed.
        fi
        ok "Caddy updated: $old_version -> $new_version (binary changed)"
    fi
    [ -n "$backup" ] && rm -f "$backup"
    if [ -x "$CADDY_BIN" ]; then
        setup_renew_timer
    fi
    # Always refresh Caddyfile so routing/order fixes land without reinstall.
    domain=$(read_installed_domain 2>/dev/null || true)
    if [ -n "${domain:-}" ]; then
        info "Regenerating Caddyfile for ${domain}..."
        generate_caddyfile "$domain"
        if systemctl is-active --quiet caddy 2>/dev/null; then
            if ! reload_caddy; then
                warn "Caddy reload failed after Caddyfile regen; try: systemctl restart caddy"
            else
                ok "Caddyfile regenerated and reloaded"
            fi
        fi
    fi
    if hub_enabled && [ -f /usr/local/share/easytrojan/hub_server.py ]; then
        if check_cmd python3; then
            install_hub_binary
            setup_hub_unit
            systemctl restart "$HUB_UNIT" 2>/dev/null || true
            ok "Hub runtime refreshed"
            hub_sync_local_users || true
        else
            warn "Hub enabled but python3 missing; skip hub refresh"
        fi
    elif [ -f "${HUB_CLIENT_FILE:-${TROJAN_DIR}/hub-client.json}" ]; then
        # Node previously joined a remote hub: re-publish local users after binary/script update
        hub_sync_local_users || true
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
        rm -rf "${CADDY_DATA_DIR}/certificates" "${CADDY_DATA_DIR}/acme"
        ensure_cert_storage
        systemctl restart caddy.service
    else
        info "Triggering certificate maintenance (Caddy auto-renew if near expiry)..."
        if [ -x /usr/local/bin/caddy-cert-maintain ]; then
            /usr/local/bin/caddy-cert-maintain || true
        else
            # fallback if helper not installed yet
            export XDG_CONFIG_HOME=/etc XDG_DATA_HOME=/var/lib
            XDG_CONFIG_HOME=/etc XDG_DATA_HOME=/var/lib HOME=/var/lib/caddy \
                "$CADDY_BIN" reload --config "$CADDYFILE" --force || systemctl restart caddy.service
        fi
    fi

    info "Waiting for certificate material..."
    local count=0 max_wait=40
    until find "${CADDY_DATA_DIR}/certificates" -name '*.crt' -type f 2>/dev/null | grep -q .; do
        count=$((count + 1))
        if [ "$count" -gt "$max_wait" ]; then
            error "Certificate check failed. Check: journalctl -u caddy --no-pager -n 50"
        fi
        sleep 3
    done

    local cert_file expiry
    cert_file=$(find "${CADDY_DATA_DIR}/certificates" -name '*.crt' -type f 2>/dev/null | head -1 || true)
    if [ -n "$cert_file" ] && check_cmd openssl; then
        expiry=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2 || true)
        ok "Certificate present (expires: ${expiry:-unknown})"
    else
        ok "Certificate material present"
    fi
    exit 0
}

do_status() {
    local show_link=0 server_addr="" server_port="443" link_name=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --show-link|--link) show_link=1; shift ;;
            --server|--addr|--address)
                [ -n "${2:-}" ] || error "--server requires an address (IP or hostname)"
                server_addr="$2"
                show_link=1
                shift 2
                ;;
            --port)
                [ -n "${2:-}" ] || error "--port requires a value"
                server_port="$2"
                shift 2
                ;;
            --name)
                [ -n "${2:-}" ] || error "--name requires a value"
                link_name="$2"
                show_link=1
                shift 2
                ;;
            -h|--help)
                cat <<'EOF'
Usage: easytrojan status [--show-link] [--server ADDR] [--port PORT] [--name NAME]

  --show-link       Print trojan share links (passwords in URL)
  --server ADDR     Connect address for share links (e.g. Cloudflare preferred IP).
                    SNI and WS Host stay as the installed domain.
  --port PORT       Connect port for share links (default 443; CF HTTPS ports ok).
  --name NAME       Display name in the share-link fragment (URL encoded).
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
    echo -e "  ALPN   : ${CYAN}h2, http/1.1${NC}"
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
        local cert_dir="${CADDY_DATA_DIR}/certificates"
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
    if hub_enabled; then
        if systemctl is-active --quiet "$HUB_UNIT" 2>/dev/null; then
            echo -e "  Hub    : ${GREEN}enabled${NC} (running; easytrojan hub status)"
        else
            echo -e "  Hub    : ${YELLOW}enabled${NC} (stopped; easytrojan hub enable)"
        fi
    fi

    if [ "$show_link" = "1" ] && [ -f "$PASSWD_FILE" ] && [ -n "$domain" ]; then
        local passwd transport="ws"
        if [ -f "$CADDYFILE" ] && ! grep -q "websocket" "$CADDYFILE" 2>/dev/null; then
            transport="tcp"
        fi
        if [ -n "$server_addr" ]; then
            echo -e "  Server : ${CYAN}${server_addr}${NC}:${server_port}  (SNI/Host: ${domain})"
        fi
        while IFS= read -r passwd || [ -n "$passwd" ]; do
            [ -n "$passwd" ] || continue
            echo -e "  Link   : ${CYAN}$(build_share_link "$domain" "$passwd" "$transport" "$server_addr" "$server_port" "$link_name")${NC}"
        done < "$PASSWD_FILE"
        if [ -n "$server_addr" ]; then
            echo -e "  Tip    : Client address=${server_addr}:${server_port}, SNI/Host=${domain}, ALPN=h2/http1.1, WS path=/"
        fi
    elif [ -f "$PASSWD_FILE" ] && [ -n "$domain" ]; then
        echo -e "  Link   : ${YELLOW}hidden${NC} (use: easytrojan status --show-link [--server CF_IP])"
    fi
    echo ""
    exit 0
}

do_link() {
    local server_addr="" server_port="443" pass_filter="" link_name=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --server|--addr|--address)
                [ -n "${2:-}" ] || error "--server requires an address (IP or hostname)"
                server_addr="$2"
                shift 2
                ;;
            --port)
                [ -n "${2:-}" ] || error "--port requires a value"
                server_port="$2"
                shift 2
                ;;
            --password)
                [ -n "${2:-}" ] || error "--password requires a value"
                pass_filter="$2"
                shift 2
                ;;
            --name)
                [ -n "${2:-}" ] || error "--name requires a value"
                link_name="$2"
                shift 2
                ;;
            -h|--help)
                cat <<'EOF'
Usage: easytrojan link [--server ADDR] [--port PORT] [--password PASSWORD] [--name NAME]

Print trojan share links for installed users.
  --server ADDR   Use ADDR as connect host (Cloudflare preferred IP).
                  SNI and WS Host remain the installed domain.
  --port PORT     Connect port (default 443; CF HTTPS ports e.g. 2053).
  --password PASS Only print link for this password.
  --name NAME     Display name in the share-link fragment (URL encoded).
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
        build_share_link "$domain" "$passwd" "$transport" "$server_addr" "$server_port" "$link_name"
        printf '\n'
    done < "$PASSWD_FILE"
    [ "$found" -eq 1 ] || error "No matching password in passwd.txt"
    if [ -n "$server_addr" ]; then
        echo -e "${YELLOW}# address=${server_addr}:${server_port}  sni/host=${domain}  alpn=h2,http/1.1  path=/${NC}" >&2
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
            if hub_enabled; then
                hub_sync_local_users || true
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
            if hub_enabled; then
                hub_remove_local_password "$trojan_passwd" || true
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
