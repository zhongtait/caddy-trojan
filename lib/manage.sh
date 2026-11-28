#!/bin/bash
# EasyTrojan module: manage.sh
# shellcheck shell=bash

do_doctor() {
    require_root
    local network_only=0
    if [ "$#" -gt 0 ]; then
        [ "$#" -eq 1 ] && [ "$1" = "--network" ] \
            || error "Usage: easytrojan doctor [--network]"
        network_only=1
    fi

    if [ "$network_only" -eq 1 ]; then
        doctor_network
        return 0
    fi

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
        if validate_caddy_config "$CADDYFILE" >/dev/null 2>&1; then
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

    if check_cmd ss; then
        if ss -Hltn 'sport = :80 or sport = :443' 2>/dev/null | grep -q 'LISTEN'; then
            doctor_ok "ports 80/443 listening"
        else
            doctor_fail "ports 80/443 not listening"
        fi
    fi

    if check_cmd curl; then
        if curl -sf --connect-timeout 2 --max-time 5 "${ADMIN_API}/config/" >/dev/null 2>&1; then
            doctor_ok "Caddy Admin API responds"
        else
            doctor_fail "Caddy Admin API unavailable"
        fi
    fi

    mode=$(read_tls_mode)
    case "$mode" in
        origin)
            cert_file=$(read_tls_cert_path)
            key_file=$(read_tls_key_path)
            if [ -f "$cert_file" ] && [ -f "$key_file" ]; then
                doctor_ok "origin certificate and key files exist"
                if check_cmd openssl; then
                    if ! openssl x509 -checkend $((7 * 86400)) -noout -in "$cert_file" 2>/dev/null; then
                        doctor_fail "origin certificate expires in less than 7 days"
                    else
                        doctor_ok "origin certificate is valid"
                    fi
                fi
            else
                doctor_fail "origin certificate/key missing"
            fi
            ;;
        auto)
            if [ -d "${CADDY_DATA_DIR}/certificates" ]; then
                doctor_ok "ACME certificate storage exists"
                local domain_cert
                domain_cert=$(find_domain_certificate "${domain:-}" 2>/dev/null || true)
                if [ -n "$domain_cert" ] && [ -f "$domain_cert" ]; then
                    doctor_ok "ACME domain certificate found"
                    if check_cmd openssl; then
                        if ! openssl x509 -checkend $((7 * 86400)) -noout -in "$domain_cert" 2>/dev/null; then
                            doctor_fail "domain certificate expires in less than 7 days"
                        else
                            doctor_ok "domain certificate is valid"
                        fi
                    fi
                fi
            else
                doctor_fail "ACME certificate storage missing"
            fi
            ;;
        *) doctor_fail "invalid TLS mode: ${mode:-<empty>}" ;;
    esac

    if check_cmd sysctl; then
        local cc
        cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
        if [ "$cc" = "bbr" ]; then
            doctor_ok "TCP congestion control is BBR"
        elif [ -n "$cc" ]; then
            doctor_ok "TCP congestion control: ${cc}"
        fi
    fi

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

do_traffic() (
    require_root
    case "${1:-}" in
        reset)
            shift
            local reset_yes=0 reset_key=""
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --yes) reset_yes=1; shift ;;
                    --key)
                        [ -n "${2:-}" ] || error "--key requires a value"
                        reset_key="$2"; shift 2 ;;
                    -h|--help)
                        echo "Usage: easytrojan traffic reset --yes [--key SHA224]"
                        exit 0 ;;
                    *) error "Unknown traffic reset argument: $1" ;;
                esac
            done
            [ "$reset_yes" -eq 1 ] || error "Traffic reset is destructive; pass --yes"
            local reset_url="${ADMIN_API}/trojan/traffic" reset_args=()
            [ -z "$reset_key" ] || reset_args+=(--data-urlencode "key=${reset_key}")
            curl -fsS --get -X DELETE --connect-timeout 2 --max-time 180 \
                ${reset_args[@]+"${reset_args[@]}"} "$reset_url" >/dev/null \
                || error "Traffic reset request failed or timed out; Caddy may still be processing it. Check traffic before retrying"
            ok "Traffic statistics reset${reset_key:+ for ${reset_key}}"
            if declare -F restore_suspended_passwords >/dev/null 2>&1; then
                local sfile restored_count=0 domain=""
                sfile=$(suspended_passwd_file_path)
                if [ -s "$sfile" ]; then
                    restored_count=$(restore_suspended_passwords "$reset_key")
                    if [ "${restored_count:-0}" -gt 0 ]; then
                        domain=$(read_installed_domain 2>/dev/null || true)
                        if [ -n "$domain" ]; then
                            generate_caddyfile "$domain"
                            if check_cmd systemctl && systemctl is-active --quiet caddy 2>/dev/null; then
                                reload_caddy
                                wait_for_admin_api || true
                            fi
                            if declare -F hub_enabled >/dev/null 2>&1 && hub_enabled; then
                                hub_sync_local_users || true
                            fi
                        fi
                        ok "Restored ${restored_count} quota-suspended user(s)"
                    fi
                fi
            fi
            exit 0
            ;;
        prune)
            shift
            local prune_yes=0 prune_days=0 prune_max_per_user=0
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --yes) prune_yes=1; shift ;;
                    --days)
                        [ -n "${2:-}" ] || error "--days requires a non-negative integer"
                        case "$2" in ''|*[!0-9]*) error "--days must be a non-negative integer" ;; esac
                        prune_days="$2"; shift 2 ;;
                    --max-per-user)
                        [ -n "${2:-}" ] || error "--max-per-user requires a non-negative integer"
                        case "$2" in ''|*[!0-9]*) error "--max-per-user must be a non-negative integer" ;; esac
                        prune_max_per_user="$2"; shift 2 ;;
                    -h|--help)
                        echo "Usage: easytrojan traffic prune --yes [--days N] [--max-per-user N]"
                        exit 0 ;;
                    *) error "Unknown traffic prune argument: $1" ;;
                esac
            done
            [ "$prune_yes" -eq 1 ] || error "Traffic pruning is destructive; pass --yes"
            if [ "$prune_days" -eq 0 ] && [ "$prune_max_per_user" -eq 0 ]; then
                error "Specify --days N and/or --max-per-user N (> 0)"
            fi
            local prune_url="${ADMIN_API}/trojan/traffic/prune" prune_args=() prune_out="" pruned_count="0"
            [ "$prune_days" -eq 0 ] || prune_args+=(--data-urlencode "max_age_days=${prune_days}")
            [ "$prune_max_per_user" -eq 0 ] || prune_args+=(--data-urlencode "max_per_user=${prune_max_per_user}")
            prune_out=$(curl -fsS --get -X POST --connect-timeout 2 --max-time 180 \
                ${prune_args[@]+"${prune_args[@]}"} "$prune_url") \
                || error "Traffic prune API unavailable. Update/restart Caddy, then retry"
            if check_cmd python3; then
                pruned_count=$(printf '%s' "$prune_out" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("pruned", 0))' 2>/dev/null || echo 0)
            fi
            ok "Pruned ${pruned_count} persisted target traffic record(s)"
            exit 0
            ;;
        enforce-quota)
            shift
            local dry_run=0
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --dry-run) dry_run=1; shift ;;
                    -h|--help)
                        echo "Usage: easytrojan traffic enforce-quota [--dry-run]"
                        exit 0 ;;
                    *) error "Unknown enforce-quota argument: $1" ;;
                esac
            done
            check_cmd python3 || error "python3 is required for quota enforcement"
            [ -f "$PASSWD_FILE" ] || { ok "No local users configured"; exit 0; }
            local tmp_u usage_lines changed=0 line pkey quota used=""
            tmp_u=$(mktemp)
            trap 'rm -f -- "${tmp_u:-}"' EXIT
            curl -fsS --connect-timeout 2 --max-time 15 "${ADMIN_API}/trojan/users" -o "$tmp_u" \
                || error "Caddy Admin API unavailable for quota check"
            usage_lines=$(python3 - "$tmp_u" <<'PY'
import json, sys
for item in json.load(open(sys.argv[1], encoding="utf-8")):
    k = item.get("key", "")
    total = int(item.get("up", 0)) + int(item.get("down", 0))
    if k:
        print(f"{k}\t{total}")
PY
)
            local -a active_passwords=()
            while IFS= read -r line || [ -n "$line" ]; do
                [ -n "$line" ] && active_passwords+=("$line")
            done < "$PASSWD_FILE"
            for line in "${active_passwords[@]}"; do
                quota=$(get_user_quota "$line")
                [ -n "$quota" ] && [ "$quota" -gt 0 ] 2>/dev/null || continue
                pkey=$(password_key "$line" 2>/dev/null || true)
                [ -n "$pkey" ] || continue
                used=$(printf '%s\n' "$usage_lines" | awk -F '\t' -v k="$pkey" '$1 == k {print $2; exit}')
                [ -n "$used" ] || used=0
                if [ "$used" -ge "$quota" ] 2>/dev/null; then
                    if [ "$dry_run" -eq 1 ]; then
                        warn "Would suspend $(mask_secret "$line"): used $(format_size_bytes "$used") >= quota $(format_size_bytes "$quota")"
                    else
                        suspend_password_to_file "$line"
                        delete_trojan_user_storage "$line" 2>/dev/null || true
                        warn "Suspended $(mask_secret "$line"): used $(format_size_bytes "$used") >= quota $(format_size_bytes "$quota")"
                        changed=1
                    fi
                fi
            done
            if [ "$changed" -eq 1 ]; then
                local domain
                domain=$(read_installed_domain 2>/dev/null || true)
                if [ -n "$domain" ]; then
                    generate_caddyfile "$domain"
                    if check_cmd systemctl && systemctl is-active --quiet caddy 2>/dev/null; then
                        reload_caddy
                        wait_for_admin_api || true
                    fi
                    if hub_enabled; then
                        hub_sync_local_users || true
                    fi
                fi
                ok "Quota enforcement updated active users"
            else
                ok "All active users are within traffic quotas"
            fi
            exit 0
            ;;
        maintain)
            shift
            local sconf
            sconf=$(traffic_schedule_conf_path)
            [ -f "$sconf" ] || exit 0
            # shellcheck disable=SC2034
            local RESET_CALENDAR="" PRUNE_DAYS=0 MAX_TARGETS_PER_USER=0 ENFORCE_QUOTA=0
            # shellcheck disable=SC1090
            . "$sconf"
            if [ "${PRUNE_DAYS:-0}" -gt 0 ] || [ "${MAX_TARGETS_PER_USER:-0}" -gt 0 ]; then
                (do_traffic prune --yes --days "${PRUNE_DAYS:-0}" --max-per-user "${MAX_TARGETS_PER_USER:-0}") || true
            fi
            if [ "${ENFORCE_QUOTA:-0}" = "1" ]; then
                (do_traffic enforce-quota) || true
            fi
            exit 0
            ;;
        schedule)
            shift
            local ssub="${1:-status}" sconf
            sconf=$(traffic_schedule_conf_path)
            shift || true
            case "$ssub" in
                status)
                    if [ -f "$sconf" ]; then
                        cat "$sconf"
                    else
                        echo "Traffic schedule is not configured."
                    fi
                    if check_cmd systemctl; then
                        systemctl is-enabled easytrojan-traffic-reset.timer 2>/dev/null | sed 's/^/reset-timer: /' || true
                        systemctl is-enabled easytrojan-traffic-maintain.timer 2>/dev/null | sed 's/^/maintain-timer: /' || true
                    fi
                    exit 0
                    ;;
                disable)
                    rm -f -- "$sconf"
                    remove_traffic_schedule_units
                    ok "Traffic reset and maintenance schedules disabled"
                    exit 0
                    ;;
                enable)
                    local reset_cal="" prune_days=0 max_per=0 enforce_q=0 monthly_day=""
                    while [ "$#" -gt 0 ]; do
                        case "$1" in
                            --monthly-day)
                                [ -n "${2:-}" ] || error "--monthly-day requires a day (1-28)"
                                case "$2" in ''|*[!0-9]*) error "--monthly-day must be 1..28" ;; esac
                                [ "$2" -ge 1 ] && [ "$2" -le 28 ] || error "--monthly-day must be between 1 and 28"
                                printf -v monthly_day '%02d' "$2"
                                reset_cal="*-*-${monthly_day} 00:05:00"
                                shift 2 ;;
                            --daily)
                                reset_cal="daily"
                                shift ;;
                            --calendar)
                                [ -n "${2:-}" ] || error "--calendar requires a systemd OnCalendar value"
                                contains_control_chars "$2" && error "Invalid --calendar value"
                                reset_cal="$2"
                                shift 2 ;;
                            --prune-days)
                                [ -n "${2:-}" ] || error "--prune-days requires an integer"
                                case "$2" in ''|*[!0-9]*) error "--prune-days must be a non-negative integer" ;; esac
                                prune_days="$2"; shift 2 ;;
                            --max-per-user)
                                [ -n "${2:-}" ] || error "--max-per-user requires an integer"
                                case "$2" in ''|*[!0-9]*) error "--max-per-user must be a non-negative integer" ;; esac
                                max_per="$2"; shift 2 ;;
                            --enforce-quota)
                                enforce_q=1; shift ;;
                            -h|--help)
                                cat <<'EOF'
Usage: easytrojan traffic schedule enable [--monthly-day 1..28 | --daily | --calendar SPEC]
                                          [--prune-days N] [--max-per-user N] [--enforce-quota]
       easytrojan traffic schedule status
       easytrojan traffic schedule disable
EOF
                                exit 0 ;;
                            *) error "Unknown schedule argument: $1" ;;
                        esac
                    done
                    if [ -z "$reset_cal" ] && [ "$prune_days" -eq 0 ] && [ "$max_per" -eq 0 ] && [ "$enforce_q" -eq 0 ]; then
                        error "Specify at least one schedule option (--monthly-day, --daily, --calendar, --prune-days, --max-per-user, --enforce-quota)"
                    fi
                    if [ -n "$reset_cal" ] && check_cmd systemd-analyze; then
                        systemd-analyze calendar "$reset_cal" >/dev/null 2>&1 \
                            || error "Invalid systemd OnCalendar specification: $reset_cal"
                    fi
                    local has_maintain=0
                    if [ "$prune_days" -gt 0 ] || [ "$max_per" -gt 0 ] || [ "$enforce_q" -eq 1 ]; then
                        has_maintain=1
                    fi
                    mkdir -p "$(dirname "$sconf")"
                    local stmp
                    stmp=$(mktemp "$(dirname "$sconf")/.schedule.XXXXXX")
                    {
                        printf 'RESET_CALENDAR=%q\n' "$reset_cal"
                        printf 'PRUNE_DAYS=%s\n' "$prune_days"
                        printf 'MAX_TARGETS_PER_USER=%s\n' "$max_per"
                        printf 'ENFORCE_QUOTA=%s\n' "$enforce_q"
                    } > "$stmp"
                    chmod 640 "$stmp"
                    mv -f -- "$stmp" "$sconf"
                    write_traffic_schedule_units "$reset_cal" "$has_maintain"
                    if check_cmd systemctl; then
                        systemctl daemon-reload
                        if [ -n "$reset_cal" ]; then
                            systemctl enable easytrojan-traffic-reset.timer &>/dev/null
                            systemctl restart easytrojan-traffic-reset.timer &>/dev/null || systemctl start easytrojan-traffic-reset.timer &>/dev/null
                        else
                            systemctl stop easytrojan-traffic-reset.timer &>/dev/null || true
                            systemctl disable easytrojan-traffic-reset.timer &>/dev/null || true
                        fi
                        if [ "$has_maintain" = "1" ]; then
                            systemctl enable easytrojan-traffic-maintain.timer &>/dev/null
                            systemctl restart easytrojan-traffic-maintain.timer &>/dev/null || systemctl start easytrojan-traffic-maintain.timer &>/dev/null
                        else
                            systemctl stop easytrojan-traffic-maintain.timer &>/dev/null || true
                            systemctl disable easytrojan-traffic-maintain.timer &>/dev/null || true
                        fi
                    fi
                    ok "Traffic schedule updated (${sconf})"
                    exit 0
                    ;;
                *)
                    error "Unknown traffic schedule subcommand: $ssub (status|enable|disable)"
                    ;;
            esac
            ;;
    esac
    local filter_key="" filter_password="" filter_ip="" filter_target="" json=0 limit=0 offset=0 sort_by="total"
    local show_password=0 flat_mode=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --key)
                [ -n "${2:-}" ] || error "--key requires a value"
                filter_key="$2"
                shift 2
                ;;
            --password|-p)
                [ -n "${2:-}" ] || error "--password requires a value"
                filter_password="$2"
                shift 2
                ;;
            --ip)
                [ -n "${2:-}" ] || error "--ip requires a value"
                filter_ip="$2"
                shift 2
                ;;
            --target)
                [ -n "${2:-}" ] || error "--target requires a value"
                filter_target="$2"
                shift 2
                ;;
            -n|--top|--limit)
                [ -n "${2:-}" ] || error "$1 requires a positive number"
                case "$2" in
                    ''|*[!0-9]*) error "$1 must be a positive integer" ;;
                esac
                [ "$2" -gt 0 ] || error "$1 must be greater than 0"
                limit="$2"
                shift 2
                ;;
            --offset)
                [ -n "${2:-}" ] || error "--offset requires a non-negative integer"
                case "$2" in
                    ''|*[!0-9]*) error "--offset must be a non-negative integer" ;;
                esac
                offset="$2"
                shift 2
                ;;
            --sort)
                [ -n "${2:-}" ] || error "--sort requires a value (total|up|down|target|client|ip)"
                case "$2" in
                    total|up|down|target|client|ip) sort_by="$2" ;;
                    *) error "Invalid --sort value: $2 (allowed: total|up|down|target|client|ip)" ;;
                esac
                shift 2
                ;;
            --show-password|--unmask) show_password=1; shift ;;
            --flat) flat_mode=1; shift ;;
            --json) json=1; shift ;;
            -h|--help)
                cat <<'EOF'
Usage: easytrojan traffic [--key HASH] [--password PASS] [--ip CLIENT_IP] [--target HOST:PORT]
                          [--top N] [--offset N] [--sort total|up|down|target|client|ip]
                          [--show-password] [--flat] [--json]
       easytrojan traffic reset --yes [--key SHA224]
       easytrojan traffic prune --yes [--days N] [--max-per-user N]
       easytrojan traffic enforce-quota [--dry-run]
       easytrojan traffic schedule status|enable|disable [...]

Show persisted traffic grouped by User/Client, Source IP, and destination. The Admin API
remains bound to localhost; this command must be run as root.
EOF
                exit 0
                ;;
            *) error "Unknown traffic argument: $1" ;;
        esac
    done

    if [ -n "$filter_password" ] && [ -z "$filter_key" ]; then
        filter_key=$(password_key "$filter_password" || true)
        [ -n "$filter_key" ] || error "Cannot calculate SHA-224 hash for password"
    fi

    local url="${ADMIN_API}/trojan/traffic" tmp curl_args=()
    [ -z "$filter_key" ] || curl_args+=(--data-urlencode "key=${filter_key}")
    [ -z "$filter_ip" ] || curl_args+=(--data-urlencode "ip=${filter_ip}")
    [ -z "$filter_target" ] || curl_args+=(--data-urlencode "target=${filter_target}")
    if [ "$flat_mode" = "1" ] || [ "$json" = "1" ]; then
        if [ "$sort_by" != "client" ]; then
            curl_args+=(--data-urlencode "sort=${sort_by}")
            [ "$offset" -eq 0 ] || curl_args+=(--data-urlencode "offset=${offset}")
            [ "$limit" -eq 0 ] || curl_args+=(--data-urlencode "limit=${limit}")
        fi
    fi
    tmp=$(mktemp)
    trap 'rm -f -- "${tmp:-}"' EXIT
    if ! curl -fsS --get --connect-timeout 2 --max-time 10 ${curl_args[@]+"${curl_args[@]}"} "$url" -o "$tmp"; then
        error "Traffic API unavailable. Update/restart Caddy, then retry: easytrojan traffic"
        return 1
    fi
    if [ "$json" = "1" ] || ! check_cmd python3; then
        cat "$tmp"
        return 0
    fi
    python3 - "$tmp" "$PASSWD_FILE" "$REMARKS_DIR" "$sort_by" "$limit" "$show_password" "$flat_mode" <<'PY'
import hashlib
import json
import sys

rows = json.load(open(sys.argv[1], encoding="utf-8"))
passwd_file = sys.argv[2]
remarks_dir = sys.argv[3]
sort_by = sys.argv[4] if len(sys.argv) > 4 else "total"
limit = int(sys.argv[5]) if len(sys.argv) > 5 and sys.argv[5].isdigit() else 0
show_password = (sys.argv[6] == "1") if len(sys.argv) > 6 else False
flat_mode = (sys.argv[7] == "1") if len(sys.argv) > 7 else False

user_map = {}
try:
    idx = 1
    for line in open(passwd_file, encoding="utf-8"):
        raw = line.rstrip("\r\n")
        if not raw:
            continue
        pwd = raw
        if pwd:
            h = hashlib.sha224(pwd.encode()).hexdigest()
            comment = ""
            try:
                with open(f"{remarks_dir}/{h}", encoding="utf-8") as remark_file:
                    comment = remark_file.readline().rstrip("\r\n")
            except OSError:
                pass
            user_map[h] = (idx, pwd, comment)
            idx += 1
except OSError:
    pass

def mask(pwd):
    if not pwd:
        return "-"
    if show_password:
        return pwd
    n = len(pwd)
    if n <= 2:
        return pwd[0] + "*" if n == 2 else "*"
    elif n <= 4:
        return pwd[0] + "**" + pwd[-1]
    elif n <= 8:
        return pwd[0] + "***" + pwd[-1]
    else:
        return pwd[:2] + "***" + pwd[-2:]

def size(val):
    val = float(val)
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if val < 1024 or unit == "TiB":
            return f"{val:.1f} {unit}"
        val /= 1024

clients = {}
for r in rows:
    k = r.get("key", "")
    r["up_int"] = int(r.get("up", 0))
    r["down_int"] = int(r.get("down", 0))
    r["total_int"] = r["up_int"] + r["down_int"]
    r["ip_str"] = r.get("ip", "") or "-"
    if k not in clients:
        info = user_map.get(k)
        if info:
            u_idx, u_pwd, u_comment = info
            if u_comment:
                name = f"User #{u_idx}: {u_comment} ({mask(u_pwd)})"
            else:
                name = f"User #{u_idx} ({mask(u_pwd)})"
        else:
            name = f"Client {k[:16]}"
        clients[k] = {"name": name, "rows": [], "up": 0, "down": 0, "total": 0}
    clients[k]["rows"].append(r)
    clients[k]["up"] += r["up_int"]
    clients[k]["down"] += r["down_int"]
    clients[k]["total"] += r["total_int"]

if not clients:
    print("No traffic recorded yet.")
    sys.exit(0)

sorted_clients = sorted(clients.values(), key=lambda c: c["total"], reverse=True)
grand_up = sum(c["up"] for c in sorted_clients)
grand_down = sum(c["down"] for c in sorted_clients)
grand_total = grand_up + grand_down
grand_targets = sum(len(c["rows"]) for c in sorted_clients)

if flat_mode:
    all_rows = []
    for c in sorted_clients:
        for r in c["rows"]:
            r["client_name"] = c["name"]
            all_rows.append(r)
    if sort_by == "total":
        all_rows.sort(key=lambda r: r["total_int"], reverse=True)
    elif sort_by == "up":
        all_rows.sort(key=lambda r: r["up_int"], reverse=True)
    elif sort_by == "down":
        all_rows.sort(key=lambda r: r["down_int"], reverse=True)
    elif sort_by == "target":
        all_rows.sort(key=lambda r: r.get("target", "").lower())
    elif sort_by == "ip":
        all_rows.sort(key=lambda r: r["ip_str"])
    elif sort_by == "client":
        all_rows.sort(key=lambda r: (r["client_name"].lower(), -r["total_int"]))
    if limit > 0:
        all_rows = all_rows[:limit]
    print(f"{'USER / CLIENT':24} {'CLIENT IP':18} {'TARGET':38} {'UP':>11} {'DOWN':>11} {'TOTAL':>11}")
    for r in all_rows:
        print(f"{r['client_name'][:24]:24} {r['ip_str'][:18]:18} {r.get('target', '')[:38]:38} {size(r['up_int']):>11} {size(r['down_int']):>11} {size(r['total_int']):>11}")
    print("-" * 118)
    summary = f"TOTAL ({len(sorted_clients)} clients, {grand_targets} targets):"
    print(f"{summary:83} {size(grand_up):>11} {size(grand_down):>11} {size(grand_total):>11}")
else:
    if sort_by == "client":
        sorted_clients.sort(key=lambda c: c["name"].lower())
    elif sort_by == "up":
        sorted_clients.sort(key=lambda c: c["up"], reverse=True)
    elif sort_by == "down":
        sorted_clients.sort(key=lambda c: c["down"], reverse=True)
    elif sort_by == "total":
        sorted_clients.sort(key=lambda c: c["total"], reverse=True)
    display_clients = sorted_clients[:limit] if limit > 0 else sorted_clients
    for c in display_clients:
        if sort_by == "total":
            c["rows"].sort(key=lambda r: r["total_int"], reverse=True)
        elif sort_by == "up":
            c["rows"].sort(key=lambda r: r["up_int"], reverse=True)
        elif sort_by == "down":
            c["rows"].sort(key=lambda r: r["down_int"], reverse=True)
        elif sort_by == "target":
            c["rows"].sort(key=lambda r: r.get("target", "").lower())
        elif sort_by == "ip":
            c["rows"].sort(key=lambda r: r["ip_str"])
        
        target_rows = c["rows"]
        
        t_count = len(c["rows"])
        header_title = f"[{c['name']}]  Total: {size(c['total'])}  (Up: {size(c['up'])}, Down: {size(c['down'])}, {t_count} {'target' if t_count == 1 else 'targets'})"
        print("=" * 110)
        print(header_title)
        print("-" * 110)
        print(f"  {'CLIENT IP':22} {'TARGET':44} {'UP':>13} {'DOWN':>13} {'TOTAL':>13}")
        for r in target_rows:
            print(f"  {r['ip_str'][:22]:22} {r.get('target', '')[:44]:44} {size(r['up_int']):>13} {size(r['down_int']):>13} {size(r['total_int']):>13}")
        print()
    print("=" * 110)
    grand_summary = f"GRAND TOTAL ({len(sorted_clients)} clients, {grand_targets} targets):"
    print(f"{grand_summary:69} {size(grand_up):>13} {size(grand_down):>13} {size(grand_total):>13}")
PY
)

deploy_easytrojan_bundle() (
    # Stage the complete runtime tree, then swap it as one unit. The caller is
    # still running the old entry script, so this avoids a partially copied
    # module set being observed by a concurrent invocation.
    set -euo pipefail
    bundle_root="$1" entry_stage="$2" dest="$3"
    shift 3
    parent="" stage="" backup="" old_dir="" target="" tmp="" idx=0 swapped=0 success=0
    targets=() old_exists=()

    parent=$(dirname "$SHARE_DIR")
    mkdir -p "$parent"
    stage=$(mktemp -d "${parent}/.easytrojan.new.XXXXXX")
    backup="${parent}/.easytrojan.old.$$"
    old_dir=$(mktemp -d)
    targets=("$SCRIPT_BIN" "$SCRIPT_LEGACY")
    if [ -n "$dest" ] && [ "$dest" != "$SCRIPT_BIN" ] && [ "$dest" != "$SCRIPT_LEGACY" ]; then
        targets+=("$dest")
    fi

    cleanup_bundle_deploy() {
        if [ "$success" -ne 1 ] && [ "$swapped" -eq 1 ]; then
            rm -rf -- "$SHARE_DIR"
            if [ -e "$backup" ]; then
                mv -- "$backup" "$SHARE_DIR"
            fi
            idx=0
            for target in "${targets[@]}"; do
                if [ "${old_exists[$idx]}" -eq 1 ]; then
                    cp -f -- "${old_dir}/${idx}" "$target"
                    chmod 755 "$target"
                else
                    rm -f -- "$target"
                fi
                idx=$((idx + 1))
            done
        fi
        rm -rf -- "$stage" "$old_dir"
        if [ "$success" -eq 1 ] && [ -e "$backup" ]; then
            rm -rf -- "$backup"
        fi
    }
    trap cleanup_bundle_deploy EXIT

    for target in "${targets[@]}"; do
        if [ -f "$target" ]; then
            cp -f -- "$target" "${old_dir}/${idx}"
            old_exists[$idx]=1
        else
            old_exists[$idx]=0
        fi
        idx=$((idx + 1))
    done

    mkdir -p "${stage}/lib"
    for module in "$@"; do
        cp -f -- "${bundle_root}/lib/${module}" "${stage}/lib/${module}"
        chmod 644 "${stage}/lib/${module}"
    done
    cp -f -- "${bundle_root}/hub_server.py" "${stage}/hub_server.py"
    chmod 644 "${stage}/hub_server.py"

    if [ -e "$SHARE_DIR" ]; then
        mv -- "$SHARE_DIR" "$backup"
    fi
    swapped=1
    mv -- "$stage" "$SHARE_DIR"

    idx=0
    for target in "${targets[@]}"; do
        tmp=$(mktemp "${target}.new.XXXXXX")
        cp -f -- "$entry_stage" "$tmp"
        chmod 755 "$tmp"
        mv -f -- "$tmp" "$target"
        idx=$((idx + 1))
    done
    success=1
)

stage_easytrojan_update_snapshot() {
    local update_stage="$1" base_url="$2"
    # Prefer a signed Release. Repository commits are only a documented legacy
    # escape hatch and must be explicitly enabled by the operator.
    if declare -F _easytrojan_fetch_release_snapshot >/dev/null \
        && _easytrojan_fetch_release_snapshot "$update_stage" "$base_url"; then
        return 0
    fi
    if [ "${EASYTROJAN_ALLOW_UNSIGNED_RELEASE:-0}" = "1" ]; then
        warn "Signed Release unavailable; trying immutable repository snapshot because EASYTROJAN_ALLOW_UNSIGNED_RELEASE=1"
        if declare -F _easytrojan_fetch_repository_snapshot >/dev/null \
            && _easytrojan_fetch_repository_snapshot "$update_stage"; then
            return 0
        fi
    fi
    return 1
}

do_update() {
    require_root
    if [ -f "$CADDYFILE" ] && [ ! -f "$MANAGED_MARKER" ] \
        && { [ ! -f "$DOMAIN_FILE" ] || [ ! -f "$PASSWD_FILE" ]; }; then
        error "Existing non-EasyTrojan Caddy configuration detected; refusing to update it"
    fi
    install_pkg curl
    install_pkg tar

    # Stage 0: refresh a coherent script snapshot before updating Caddy.
    if [ "${EASYTROJAN_UPDATE_STAGE:-0}" != "1" ]; then
        info "Updating easytrojan script..."
        local update_stage entry_stage dest base_url bundle_root script_source_ready=0
        update_stage=$(mktemp -d)
        base_url=$(release_asset_base "${release_version:-latest}")
        # Installed updates consume the signed Release bundle first. The
        # immutable repository snapshot is retained only as an explicit legacy
        # compatibility path; otherwise a missing/invalid signature must stop
        # before any installed file or Caddy binary is changed.
        if stage_easytrojan_update_snapshot "$update_stage" "$base_url"; then
            script_source_ready=1
        else
            rm -rf "$update_stage"
            error "Signed EasyTrojan Release bundle unavailable; refusing update (set EASYTROJAN_ALLOW_UNSIGNED_RELEASE=1 only for legacy compatibility)"
        fi
        if [ "$script_source_ready" = "1" ]; then
            entry_stage="${update_stage}/unpack/easytrojan.sh"
            bundle_root="${update_stage}/unpack"
            [ -f "$entry_stage" ] || { rm -rf "$update_stage"; error "EasyTrojan bundle is incomplete"; }
            chmod +x "$entry_stage"
            dest="$SCRIPT_BIN"
            local entry_real entry_dir
            entry_real=$(readlink -f "$0" 2>/dev/null || echo "$0")
            entry_dir=$(dirname "$entry_real")
            if [ -f "$0" ] && [ -w "$entry_dir" ]; then
                dest="$entry_real"
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

            deploy_easytrojan_bundle "$bundle_root" "$entry_stage" "${dest:-}" "${_mods[@]}" \
                || { rm -rf "$update_stage"; error "Failed to atomically activate the EasyTrojan bundle; previous files were restored"; }
            rm -rf "$update_stage"
            ok "Script updated -> re-executing with new version"
            local reexec_args=(update)
            if [ -n "${release_version:-}" ] && [ "$release_version" != "latest" ]; then
                reexec_args+=(--version "$release_version")
            fi
            export EASYTROJAN_UPDATE_STAGE=1
            exec bash "$SCRIPT_BIN" "${reexec_args[@]}"
        else
            rm -rf "$update_stage"
            error "EasyTrojan update bundle is unavailable; installed files were not changed"
        fi
    fi

    local old_version new_version old_digest="" new_digest backup="" unit_refresh=0
    local legacy_sysctl_file="${CADDY_SYSCTL_FILE:-/etc/sysctl.d/99-caddy-trojan.conf}"
    local legacy_limits_file="/etc/security/limits.d/caddy-trojan.conf"
    if [ -f "$MANAGED_MARKER" ] || [ -f "$DOMAIN_FILE" ]; then
        ensure_cert_storage
        write_caddy_unit
        systemctl daemon-reload 2>/dev/null || true
        unit_refresh=1
        # Refresh BBR + proxy network tuning so existing nodes pick up newer
        # defaults without a full reinstall.
        enable_bbr || true
        if [ -f "$legacy_sysctl_file" ] \
            && grep -qF '# Caddy-Trojan system optimizations' "$legacy_sysctl_file" 2>/dev/null; then
            warn "Migrating legacy global sysctl tuning in ${legacy_sysctl_file}"
            if apply_sysctl_limits; then
                warn "Legacy runtime-only sysctl values (including tcp_notsent_lowat/tcp_tw_reuse) cannot be inferred safely; review /proc/sys or reboot before relying on the new profile"
            else
                warn "Legacy sysctl migration could not be verified; inspect ${legacy_sysctl_file} and current /proc/sys values"
            fi
            if [ -f "$legacy_limits_file" ] \
                && grep -qF '# Caddy-Trojan limits' "$legacy_limits_file" 2>/dev/null; then
                rm -f "$legacy_limits_file"
                warn "Removed the legacy PAM limits file; Caddy uses its systemd LimitNOFILE instead"
            fi
        fi
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
            if ! systemctl restart caddy.service; then
                warn "Caddy failed to start while refreshing its service unit; recent service logs follow:"
                journalctl -u caddy.service -n 40 --no-pager >&2 2>/dev/null || true
                error "Caddy did not start after service unit refresh; inspect the journal above"
            fi
            if ! wait_for_admin_api; then
                warn "Caddy started but its Admin API did not become healthy; recent service logs follow:"
                journalctl -u caddy.service -n 40 --no-pager >&2 2>/dev/null || true
                error "Caddy Admin API did not become healthy after service unit refresh"
            fi
        fi
        ok "Caddy binary already up to date: $new_version"
    else
        if systemctl is-active --quiet caddy 2>/dev/null; then
            info "Caddy binary changed; restarting service..."
            if ! systemctl restart caddy.service; then
                warn "Caddy failed to start after the binary update; recent service logs follow:"
                journalctl -u caddy.service -n 40 --no-pager >&2 2>/dev/null || true
                if [ -n "$backup" ] && [ -f "$backup" ]; then
                    warn "Restoring the previous Caddy binary..."
                    cp -f "$backup" "$CADDY_BIN"
                    chmod 755 "$CADDY_BIN"
                    systemctl restart caddy.service || true
                    rm -f "$backup"
                    error "Caddy update rolled back because the new service failed to start; inspect the journal above"
                fi
                error "Caddy update failed because the new service did not start; inspect the journal above"
            fi
            if ! wait_for_admin_api; then
                warn "Caddy started but its Admin API did not become healthy; recent service logs follow:"
                journalctl -u caddy.service -n 40 --no-pager >&2 2>/dev/null || true
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
                warn "Caddy configuration apply failed after regeneration; inspect: journalctl -u caddy -n 50 --no-pager"
            else
                ok "Caddyfile regenerated and applied"
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

    local domain
    domain=$(read_installed_domain 2>/dev/null || true)
    [ -n "$domain" ] || error "Installed domain is missing"
    info "Waiting for certificate material for ${domain}..."
    local count=0 max_wait=40 cert_file=""
    until cert_file=$(find_domain_certificate "$domain"); do
        count=$((count + 1))
        if [ "$count" -gt "$max_wait" ]; then
            error "Certificate check failed. Check: journalctl -u caddy --no-pager -n 50"
        fi
        sleep 3
    done

    local expiry
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
                validate_port "$2"
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
    echo -e "  Outbound: ${CYAN}$(read_outbound_ip_priority)${NC}"
    local active_ws_path
    active_ws_path=$(read_ws_path)
    echo -e "  WS Path: ${CYAN}${active_ws_path}${NC}"
    echo -e "  ALPN   : ${CYAN}http/1.1 only${NC}  ${YELLOW}(WebSocket client)${NC}"
    local tls_mode
    tls_mode=$(read_tls_mode)
    echo -e "  TLS    : ${CYAN}${tls_mode}${NC}"

    local cert_file="" expiry=""
    if [ "$tls_mode" = "origin" ]; then
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
            cert_file=$(find_domain_certificate "${domain:-}" 2>/dev/null || true)
            if [ -z "$cert_file" ]; then
                cert_file=$(find "$cert_dir" -name "*.crt" -type f 2>/dev/null | head -1 || true)
            fi
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
        local passwd transport
        transport=$(detect_share_transport)
        if [ -n "$server_addr" ]; then
            echo -e "  Server : ${CYAN}${server_addr}${NC}:${server_port}  (SNI/Host: ${domain})"
        fi
        while IFS= read -r passwd || [ -n "$passwd" ]; do
            [ -n "$passwd" ] || continue
            local effective_name="$link_name"
            if [ -z "$effective_name" ]; then
                local u_rem
                u_rem=$(get_user_remark "$passwd")
                [ -z "$u_rem" ] || effective_name="${domain}-${u_rem}"
            fi
            echo -e "  Link   : ${CYAN}$(build_share_link "$domain" "$passwd" "$transport" "$server_addr" "$server_port" "$effective_name")${NC}"
        done < "$PASSWD_FILE"
        if [ -n "$server_addr" ]; then
            echo -e "  Tip    : Client address=${server_addr}:${server_port}, SNI/Host=${domain}, ALPN=http/1.1, WS path=${active_ws_path}"
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
                validate_port "$2"
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

    local domain transport passwd
    domain=$(read_installed_domain 2>/dev/null || true)
    [ -n "$domain" ] || error "Domain not found. Install first: easytrojan install --domain example.com"
    [ -f "$PASSWD_FILE" ] || error "No passwords in $PASSWD_FILE"
    transport=$(detect_share_transport)

    local found=0
    while IFS= read -r passwd || [ -n "$passwd" ]; do
        [ -n "$passwd" ] || continue
        if [ -n "$pass_filter" ] && [ "$passwd" != "$pass_filter" ]; then
            continue
        fi
        found=1
        local effective_name="$link_name"
        if [ -z "$effective_name" ]; then
            local u_rem
            u_rem=$(get_user_remark "$passwd")
            [ -z "$u_rem" ] || effective_name="${domain}-${u_rem}"
        fi
        build_share_link "$domain" "$passwd" "$transport" "$server_addr" "$server_port" "$effective_name"
        printf '\n'
    done < "$PASSWD_FILE"
    [ "$found" -eq 1 ] || error "No matching password in passwd.txt"
    if [ -n "$server_addr" ]; then
        echo -e "${YELLOW}# address=${server_addr}:${server_port}  sni/host=${domain}  alpn=http/1.1  path=$(read_ws_path)${NC}" >&2
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
    [ -n "$sub" ] || error "Usage: easytrojan user {add|list|remark|del} ..."
    shift || true

    case "$sub" in
        add)
            local trojan_passwd="" remark=""
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --password)
                        [ -n "${2:-}" ] || error "--password requires a value"
                        trojan_passwd="$2"
                        shift 2
                        ;;
                    --remark|--name)
                        [ -n "${2:-}" ] || error "$1 requires a value"
                        remark="$2"
                        shift 2
                        ;;
                    -h|--help) echo "Usage: easytrojan user add [--password PASSWORD] [--remark NAME]"; exit 0 ;;
                    *) error "Unknown argument: $1" ;;
                esac
            done
            prompt_password
            local domain
            domain=$(read_installed_domain 2>/dev/null || true)
            [ -n "$domain" ] || error "Domain not found. Re-run: easytrojan install --domain example.com"
            persist_password "$trojan_passwd"
            [ -z "$remark" ] || set_user_remark "$trojan_passwd" "$remark"
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
            local i=0 line sfile="" runtime_users_json=""
            if check_cmd systemctl && systemctl is-active --quiet caddy 2>/dev/null; then
                local tmpj
                tmpj=$(mktemp)
                if curl -sf "${ADMIN_API}/trojan/users" -o "$tmpj" 2>/dev/null; then
                    runtime_users_json=$(cat "$tmpj")
                fi
                rm -f "$tmpj"
            fi
            if [ -f "$PASSWD_FILE" ]; then
                echo "  Local passwd.txt (masked):"
                while IFS= read -r line || [ -n "$line" ]; do
                    [ -n "$line" ] || continue
                    i=$((i + 1))
                    local user_remark user_quota pkey used_bytes="" meta=""
                    user_remark=$(get_user_remark "$line")
                    user_quota=$(get_user_quota "$line")
                    if [ -n "$user_remark" ]; then
                        meta="(${user_remark})"
                    fi
                    if [ -n "$user_quota" ] && [ "$user_quota" -gt 0 ] 2>/dev/null; then
                        if [ -n "$runtime_users_json" ] && check_cmd python3; then
                            pkey=$(password_key "$line" 2>/dev/null || true)
                            if [ -n "$pkey" ]; then
                                used_bytes=$(printf '%s' "$runtime_users_json" | python3 -c 'import json,sys
k=sys.argv[1]
for u in json.load(sys.stdin):
    if u.get("key")==k:
        print(int(u.get("up",0))+int(u.get("down",0))); break' "$pkey" 2>/dev/null || true)
                            fi
                        fi
                        if [ -n "$used_bytes" ]; then
                            meta="${meta:+${meta} }[quota: $(format_size_bytes "$used_bytes") / $(format_size_bytes "$user_quota")]"
                        else
                            meta="${meta:+${meta} }[quota: $(format_size_bytes "$user_quota")]"
                        fi
                    fi
                    if [ -n "$meta" ]; then
                        echo -e "    ${i}. $(mask_secret "$line")  ${meta}"
                    else
                        echo -e "    ${i}. $(mask_secret "$line")"
                    fi
                done < "$PASSWD_FILE"
            fi
            if [ "$i" -eq 0 ]; then
                echo "  (no local users)"
            fi
            sfile=$(suspended_passwd_file_path)
            if [ -s "$sfile" ]; then
                local si=0
                echo "  Quota-suspended users (masked):"
                while IFS= read -r line || [ -n "$line" ]; do
                    [ -n "$line" ] || continue
                    si=$((si + 1))
                    local user_remark user_quota meta=""
                    user_remark=$(get_user_remark "$line")
                    user_quota=$(get_user_quota "$line")
                    [ -z "$user_remark" ] || meta="(${user_remark}) "
                    [ -z "$user_quota" ] || meta="${meta}[quota: $(format_size_bytes "$user_quota")] "
                    echo -e "    ${si}. $(mask_secret "$line")  ${meta}[SUSPENDED: quota]"
                done < "$sfile"
            fi
            # Optional: runtime storage keys (hash hex, not plaintext)
            if [ -n "$runtime_users_json" ]; then
                local runtime_count
                runtime_count=$(printf '%s' "$runtime_users_json" | grep -o '"key"' 2>/dev/null | wc -l | tr -d ' ' || echo 0)
                echo "  Runtime storage keys (API): ${runtime_count:-0}"
            fi
            exit 0
            ;;
        del|delete|rm|remove)
            local trojan_passwd=""
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
            validate_password_value "$trojan_passwd"
            local domain sfile
            domain=$(read_installed_domain 2>/dev/null || true)
            [ -n "$domain" ] || error "Domain not found. Re-run install first."
            sfile=$(suspended_passwd_file_path)
            if { [ ! -f "$PASSWD_FILE" ] || ! grep -Fxq -- "$trojan_passwd" "$PASSWD_FILE" 2>/dev/null; } \
                && { [ ! -f "$sfile" ] || ! grep -Fxq -- "$trojan_passwd" "$sfile" 2>/dev/null; }; then
                warn "Password not found in local passwd.txt; still clearing storage + Caddyfile"
            fi
            remove_password_from_file "$trojan_passwd"
            remove_suspended_password_from_file "$trojan_passwd"
            delete_user_remark "$trojan_passwd"
            delete_user_quota "$trojan_passwd"
            generate_caddyfile "$domain"
            # With `memory caddy`, delete the persisted key as well as the
            # in-memory entry or it can return after a process restart.
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
        remark|rename)
            local trojan_passwd="" remark="" sfile
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --password)
                        [ -n "${2:-}" ] || error "--password requires a value"
                        trojan_passwd="$2"; shift 2 ;;
                    --name|--remark)
                        [ -n "${2:-}" ] || error "$1 requires a value"
                        remark="$2"; shift 2 ;;
                    -h|--help)
                        echo "Usage: easytrojan user remark --password PASSWORD --name NAME"
                        exit 0 ;;
                    *) error "Unknown argument: $1" ;;
                esac
            done
            [ -n "$trojan_passwd" ] || error "Password required: --password PASSWORD"
            [ -n "$remark" ] || error "Name required: --name NAME"
            sfile=$(suspended_passwd_file_path)
            { [ -f "$PASSWD_FILE" ] && grep -Fxq -- "$trojan_passwd" "$PASSWD_FILE"; } \
                || { [ -f "$sfile" ] && grep -Fxq -- "$trojan_passwd" "$sfile"; } \
                || error "Password not found in local passwd.txt"
            set_user_remark "$trojan_passwd" "$remark"
            ok "User remark updated ($(mask_secret "$trojan_passwd"))"
            ;;
        quota)
            local trojan_passwd="" limit_raw="" limit_bytes sfile
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --password)
                        [ -n "${2:-}" ] || error "--password requires a value"
                        trojan_passwd="$2"; shift 2 ;;
                    --limit|--quota)
                        [ -n "${2:-}" ] || error "$1 requires a size (e.g. 100GiB or unlimited)"
                        limit_raw="$2"; shift 2 ;;
                    -h|--help)
                        echo "Usage: easytrojan user quota --password PASSWORD --limit SIZE (e.g. 100GiB, 500GB, unlimited)"
                        exit 0 ;;
                    *) error "Unknown argument: $1" ;;
                esac
            done
            [ -n "$trojan_passwd" ] || error "Password required: --password PASSWORD"
            [ -n "$limit_raw" ] || error "Limit required: --limit SIZE (e.g. 100GiB or unlimited)"
            sfile=$(suspended_passwd_file_path)
            { [ -f "$PASSWD_FILE" ] && grep -Fxq -- "$trojan_passwd" "$PASSWD_FILE"; } \
                || { [ -f "$sfile" ] && grep -Fxq -- "$trojan_passwd" "$sfile"; } \
                || error "Password not found in local passwd.txt"
            limit_bytes=$(parse_size_bytes "$limit_raw") || error "Invalid quota size: $limit_raw (examples: 100GiB, 500GB, unlimited)"
            set_user_quota "$trojan_passwd" "$limit_bytes"
            if [ "$limit_bytes" -eq 0 ]; then
                ok "User traffic quota cleared ($(mask_secret "$trojan_passwd"))"
            else
                ok "User traffic quota set to $(format_size_bytes "$limit_bytes") ($(mask_secret "$trojan_passwd"))"
            fi
            ;;
        -h|--help|help)
            cat <<'EOF'
Usage:
  easytrojan user add [--password PASSWORD] [--remark NAME]
  easytrojan user remark --password PASSWORD --name NAME
  easytrojan user quota --password PASSWORD --limit SIZE
  easytrojan user list
  easytrojan user del --password PASSWORD

Users are stored in passwd.txt, declared in Caddyfile (users "..."),
and keyed in Caddy storage behind the memory cache. Delete clears all three.
EOF
            exit 0
            ;;
        *)
            error "Unknown user subcommand: $sub (add|list|remark|quota|del)"
            ;;
    esac
    exit 0
}

do_tune_system() {
    require_root
    info "Applying high-BDP network tuning..."
    enable_bbr || true
    if ! apply_sysctl_limits; then
        warn "Sysctl limits could not be fully applied or verified"
        return 1
    fi
    ok "System network tuning applied successfully"
    doctor_network
}

do_ws_path() {
    local sub="${1:-status}"
    case "$sub" in
        -h|--help|help)
            cat <<'EOF'
Usage: easytrojan ws-path {status|auto|reset|/CUSTOM_PATH}

Manage the WebSocket path required by the Trojan handler.
  status        Print the active WebSocket path (default: /)
  auto          Generate and apply a random stealth path (/ws-<hex>)
  reset         Restore default path (/) matching any WebSocket Upgrade path
  /CUSTOM_PATH  Restrict WebSocket upgrades strictly to /CUSTOM_PATH;
                probes to '/' receive the camouflage static site instead
EOF
            exit 0
            ;;
        status|show)
            echo ""
            echo -e "  WS Path: ${CYAN}$(read_ws_path)${NC}"
            echo ""
            exit 0
            ;;
        auto|random|reset|default|/*)
            require_root
            local domain new_path
            domain=$(read_installed_domain 2>/dev/null || true)
            [ -n "$domain" ] || error "Domain not found. Install first: easytrojan install --domain example.com"
            new_path=$(normalize_ws_path "$sub")
            # shellcheck disable=SC2034  # consumed by current_ws_path inside _generate_caddyfile
            ws_path="$new_path"
            generate_caddyfile "$domain"
            reload_caddy
            hub_sync_local_users || true
            ok "WebSocket path updated to: ${new_path}"
            echo -e "  Run ${CYAN}easytrojan link${NC} to print updated client share links."
            exit 0
            ;;
        *)
            error "Usage: easytrojan ws-path {status|auto|reset|/CUSTOM_PATH}"
            ;;
    esac
}

do_firewall() {
    local sub="${1:-status}"
    [ "$#" -gt 0 ] && shift || true

    case "$sub" in
        -h|--help|help)
            cat <<'EOF'
Usage:
  easytrojan firewall cf-only [--port PORT] [--refresh] [--dry-run]
  easytrojan firewall off
  easytrojan firewall status

Restrict inbound TCP on the HTTPS origin port (default 443) to Cloudflare IP
ranges + loopback so direct scanners against the origin IP are dropped.
  --port PORT   Protected TCP port (default 443)
  --refresh     Fetch fresh Cloudflare IPv4/IPv6 CIDR lists before applying
  --dry-run     Print planned rules/CIDRs without modifying system firewall
EOF
            exit 0
            ;;
        cf-only|cloudflare|on|enable)
            local port="${CADDY_HTTPS_PORT:-443}" refresh=0 dry_run=0
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --port)
                        [ -n "${2:-}" ] || error "--port requires a value"
                        validate_port "$2" "--port"
                        port="$2"
                        shift 2
                        ;;
                    --refresh)
                        refresh=1
                        shift
                        ;;
                    --dry-run)
                        dry_run=1
                        shift
                        ;;
                    -h|--help)
                        do_firewall --help
                        ;;
                    *)
                        error "Unknown firewall argument: $1"
                        ;;
                esac
            done
            if [ "$dry_run" -eq 0 ]; then
                require_root
                if [ "$(read_tls_mode 2>/dev/null || echo auto)" = "auto" ]; then
                    info "TLS mode is 'auto'; keeping TCP 80 untouched for ACME HTTP-01 (or switch to --tls-mode origin)."
                fi
            fi
            apply_cf_only_firewall "$port" "$refresh" "$dry_run"
            if [ "$dry_run" -eq 0 ]; then
                ok "Cloudflare origin firewall enabled on TCP port ${port}"
            fi
            exit 0
            ;;
        off|disable|reset)
            require_root
            disable_cf_firewall
            ok "Cloudflare origin firewall disabled"
            exit 0
            ;;
        status|show)
            local bin_path conf_path
            bin_path=$(cf_firewall_script_path)
            conf_path=$(cf_firewall_conf_path)
            if [ -x "$bin_path" ]; then
                CF_FIREWALL_CONF="$conf_path" "$bin_path" status
            elif [ -f "$conf_path" ]; then
                cat "$conf_path"
            else
                echo "mode=off"
                echo "active_backend=none"
            fi
            exit 0
            ;;
        *)
            error "Unknown firewall subcommand: $sub (cf-only|off|status)"
            ;;
    esac
}
