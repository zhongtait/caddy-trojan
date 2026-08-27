#!/bin/bash
# EasyTrojan module: system.sh
# shellcheck shell=bash

_easytrojan_detect_ram_kib() {
    local mem_kb="${1:-}"
    if [ -z "$mem_kb" ]; then
        mem_kb=$(awk '/^MemTotal:/{print $2; exit}' /proc/meminfo 2>/dev/null || true)
    fi
    mem_kb=${mem_kb//[^0-9]/}
    if [ -n "$mem_kb" ] && [ "$mem_kb" -gt 0 ] 2>/dev/null; then
        printf '%s' "$mem_kb"
    fi
}

_easytrojan_calc_tcp_mem() {
    local mem_kb="${1:-0}"
    awk -v m="$mem_kb" 'BEGIN{
        pg = int(m / 4);
        low = int(pg / 16);
        pres = int(pg / 8);
        high = int(pg / 4);
        if (low < 4096) low = 4096;
        if (pres < 8192) pres = 8192;
        if (high < 16384) high = 16384;
        printf "%d %d %d", low, pres, high
    }'
}

_easytrojan_calc_buf_max() {
    local mem_kb="${1:-0}"
    # Baseline: 1000 Mbps @ 150ms RTT cross-border proxy BDP = ~18.75 MB
    # Target buffer = 2 * BDP + 2 MiB = 39,597,152 bytes (~37.76 MiB)
    # Cap = RAM / 32 (in bytes) = mem_kb * 1024 / 32 = mem_kb * 32
    # Floor: 4 MiB (4194304 bytes), Ceiling: 256 MiB (268435456 bytes)
    awk -v m="$mem_kb" 'BEGIN{
        target = 39597152;
        if (m > 0) {
            cap = int(m * 32);
            if (cap > 268435456) cap = 268435456;
            if (target > cap) target = cap;
        }
        if (target < 4194304) target = 4194304;
        if (target > 268435456) target = 268435456;
        printf "%d", target
    }'
}

_easytrojan_sysctl_bbr_specs() {
    printf '%s\n' \
        'net.core.default_qdisc|fq' \
        'net.ipv4.tcp_congestion_control|bbr'
}

_easytrojan_sysctl_tuning_specs() {
    local mem_kb buf_max tcp_mem_target
    local key current target min default max extra baseline
    local c_low c_pres c_high t_low t_pres t_high f_low f_pres f_high
    local c_min_port c_max_port t_min_port t_max_port
    local -a keys=(
        net.core.somaxconn
        net.core.netdev_max_backlog
        net.core.rmem_max
        net.core.wmem_max
        net.ipv4.tcp_rmem
        net.ipv4.tcp_wmem
        net.ipv4.tcp_mem
        net.ipv4.tcp_max_syn_backlog
        net.ipv4.tcp_slow_start_after_idle
        net.ipv4.tcp_mtu_probing
        net.ipv4.tcp_tw_reuse
        net.ipv4.tcp_fin_timeout
        net.ipv4.ip_local_port_range
    )

    mem_kb=$(_easytrojan_detect_ram_kib "${1:-}")
    if [ -n "$mem_kb" ]; then
        buf_max=$(_easytrojan_calc_buf_max "$mem_kb")
        tcp_mem_target=$(_easytrojan_calc_tcp_mem "$mem_kb")
    else
        buf_max=16777216
        tcp_mem_target=$(_easytrojan_calc_tcp_mem 0)
    fi

    for key in "${keys[@]}"; do
        current=$(sysctl -n "$key" 2>/dev/null) || return 1
        current=$(_easytrojan_sysctl_normalize "$current")
        case "$key" in
            net.ipv4.tcp_rmem|net.ipv4.tcp_wmem)
                read -r min default max extra <<< "$current"
                if [ -z "${min:-}" ] || [ -z "${default:-}" ] || [ -z "${max:-}" ] \
                    || [ -n "${extra:-}" ] \
                    || ! [[ "$min" =~ ^[0-9]+$ && "$default" =~ ^[0-9]+$ && "$max" =~ ^[0-9]+$ ]]; then
                    return 1
                fi
                if [ "$max" -lt "$buf_max" ]; then
                    max=$buf_max
                fi
                target="${min} ${default} ${max}"
                ;;
            net.ipv4.tcp_mem)
                read -r c_low c_pres c_high extra <<< "$current"
                if [ -z "${c_low:-}" ] || [ -z "${c_pres:-}" ] || [ -z "${c_high:-}" ] \
                    || [ -n "${extra:-}" ] \
                    || ! [[ "$c_low" =~ ^[0-9]+$ && "$c_pres" =~ ^[0-9]+$ && "$c_high" =~ ^[0-9]+$ ]]; then
                    return 1
                fi
                if [ -n "$tcp_mem_target" ]; then
                    read -r t_low t_pres t_high <<< "$tcp_mem_target"
                    f_low=$(( c_low > t_low ? c_low : t_low ))
                    f_pres=$(( c_pres > t_pres ? c_pres : t_pres ))
                    f_high=$(( c_high > t_high ? c_high : t_high ))
                    target="${f_low} ${f_pres} ${f_high}"
                else
                    target="${c_low} ${c_pres} ${c_high}"
                fi
                ;;
            net.core.rmem_max|net.core.wmem_max)
                if ! [[ "$current" =~ ^[0-9]+$ ]]; then
                    return 1
                fi
                if [ "$current" -lt "$buf_max" ]; then
                    target=$buf_max
                else
                    target=$current
                fi
                ;;
            net.core.somaxconn)
                if ! [[ "$current" =~ ^[0-9]+$ ]]; then return 1; fi
                baseline=32768
                target=$(( current > baseline ? current : baseline ))
                ;;
            net.core.netdev_max_backlog)
                if ! [[ "$current" =~ ^[0-9]+$ ]]; then return 1; fi
                baseline=16384
                target=$(( current > baseline ? current : baseline ))
                ;;
            net.ipv4.tcp_max_syn_backlog)
                if ! [[ "$current" =~ ^[0-9]+$ ]]; then return 1; fi
                baseline=8192
                target=$(( current > baseline ? current : baseline ))
                ;;
            net.ipv4.tcp_slow_start_after_idle)
                if ! [[ "$current" =~ ^[0-9]+$ ]]; then return 1; fi
                target=0
                ;;
            net.ipv4.tcp_mtu_probing)
                if ! [[ "$current" =~ ^[0-9]+$ ]]; then return 1; fi
                target=$(( current > 1 ? current : 1 ))
                ;;
            net.ipv4.tcp_tw_reuse)
                if ! [[ "$current" =~ ^[0-9]+$ ]]; then return 1; fi
                target=$(( current > 1 ? current : 1 ))
                ;;
            net.ipv4.tcp_fin_timeout)
                if ! [[ "$current" =~ ^[0-9]+$ ]]; then return 1; fi
                target=$(( current < 15 ? current : 15 ))
                ;;
            net.ipv4.ip_local_port_range)
                read -r c_min_port c_max_port extra <<< "$current"
                if [ -z "${c_min_port:-}" ] || [ -z "${c_max_port:-}" ] \
                    || [ -n "${extra:-}" ] \
                    || ! [[ "$c_min_port" =~ ^[0-9]+$ && "$c_max_port" =~ ^[0-9]+$ ]]; then
                    return 1
                fi
                t_min_port=$(( c_min_port < 1024 ? c_min_port : 1024 ))
                t_max_port=$(( c_max_port > 65535 ? c_max_port : 65535 ))
                target="${t_min_port} ${t_max_port}"
                ;;
            *) return 1 ;;
        esac
        printf '%s|%s\n' "$key" "$target"
    done
}

_easytrojan_sysctl_normalize() {
    printf '%s\n' "$1" | awk '{$1=$1; print}'
}

# Save each key's first observed value and EasyTrojan's target value. The
# original value is immutable. A managed target may advance only while the
# current kernel value still matches the previous target; otherwise an
# administrator has changed the key and the old rollback boundary is retained.
_easytrojan_capture_sysctl_backup() {
    local backup_file="${CADDY_SYSCTL_BACKUP_FILE:-/etc/caddy/.easytrojan-sysctl-backup}"
    local backup_dir backup_tmp rewrite_tmp spec key target current
    local record record_status existing_original existing_target
    local -a specs=("$@")

    [ "${#specs[@]}" -gt 0 ] || return 0
    backup_dir=$(dirname "$backup_file")
    if ! mkdir -p "$backup_dir" 2>/dev/null; then
        warn "Cannot create sysctl backup directory: ${backup_dir}"
        return 1
    fi
    backup_tmp=$(mktemp "${backup_file}.tmp.XXXXXX" 2>/dev/null) || {
        warn "Cannot stage sysctl backup: ${backup_file}"
        return 1
    }
    if [ -f "$backup_file" ]; then
        if ! cp -f "$backup_file" "$backup_tmp"; then
            rm -f "$backup_tmp"
            warn "Cannot read sysctl backup: ${backup_file}"
            return 1
        fi
    else
        printf '%s\n' \
            '# EasyTrojan sysctl backup v1' \
            '# key<TAB>original<TAB>managed-target' > "$backup_tmp" || {
            rm -f "$backup_tmp"
            warn "Cannot initialize sysctl backup: ${backup_file}"
            return 1
        }
    fi

    for spec in "${specs[@]}"; do
        key=${spec%%|*}
        target=${spec#*|}
        target=$(_easytrojan_sysctl_normalize "$target")
        current=$(sysctl -n "$key" 2>/dev/null) || {
            rm -f "$backup_tmp"
            warn "Cannot read current sysctl value for backup: ${key}"
            return 1
        }
        current=$(_easytrojan_sysctl_normalize "$current")

        record_status=0
        record=$(awk -F '\t' -v wanted="$key" '
            $1 == wanted {
                count++
                if (NF != 3 || $2 == "" || $3 == "") invalid=1
                if (count == 1) record=$2 "\t" $3
            }
            END {
                if (invalid || count > 1) exit 2
                if (count == 0) exit 1
                print record
            }
        ' "$backup_tmp") || record_status=$?
        if [ "$record_status" -gt 1 ]; then
            rm -f "$backup_tmp"
            warn "Invalid sysctl backup record for ${key}: ${backup_file}"
            return 1
        fi
        if [ "$record_status" -eq 0 ]; then
            existing_original=${record%%$'\t'*}
            existing_target=${record#*$'\t'}
            existing_original=$(_easytrojan_sysctl_normalize "$existing_original")
            existing_target=$(_easytrojan_sysctl_normalize "$existing_target")
            if [ "$current" = "$existing_target" ] && [ "$target" != "$existing_target" ]; then
                rewrite_tmp=$(mktemp "${backup_file}.rewrite.XXXXXX" 2>/dev/null) || {
                    rm -f "$backup_tmp"
                    warn "Cannot stage sysctl backup target update: ${key}"
                    return 1
                }
                if ! awk -F '\t' -v OFS='\t' -v wanted="$key" -v replacement="$target" '
                    $1 == wanted { $3=replacement; updated=1 }
                    { print }
                    END { if (!updated) exit 1 }
                ' "$backup_tmp" > "$rewrite_tmp" || ! mv -f "$rewrite_tmp" "$backup_tmp"; then
                    rm -f "$rewrite_tmp" "$backup_tmp"
                    warn "Cannot update managed sysctl target in backup: ${key}"
                    return 1
                fi
            fi
            continue
        fi
        printf '%s\t%s\t%s\n' "$key" "$current" "$target" >> "$backup_tmp" || {
            rm -f "$backup_tmp"
            warn "Cannot append sysctl backup record: ${key}"
            return 1
        }
    done
    if ! chmod 600 "$backup_tmp" 2>/dev/null || ! mv -f "$backup_tmp" "$backup_file"; then
        rm -f "$backup_tmp"
        warn "Cannot persist sysctl backup: ${backup_file}"
        return 1
    fi
}

enable_bbr() {
    local config_file="${BBR_SYSCTL_FILE:-/etc/sysctl.d/99-easytrojan-bbr.conf}"
    local config_tmp available current spec

    info "Enabling BBR congestion control and proxy network tuning..."
    if check_cmd modprobe; then
        modprobe tcp_bbr &>/dev/null || true
        modprobe sch_fq &>/dev/null || true
    fi
    available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
    if ! printf '%s\n' "$available" | grep -qw bbr; then
        warn "BBR is not available on this kernel; continuing with the current congestion control"
        return 0
    fi
    local -a bbr_specs=()
    while IFS= read -r spec; do
        [ -n "$spec" ] && bbr_specs+=("$spec")
    done < <(_easytrojan_sysctl_bbr_specs)
    if ! _easytrojan_capture_sysctl_backup "${bbr_specs[@]}"; then
        # Do not mutate global kernel state when its original values cannot be
        # recorded; a later uninstall could not safely put the host back.
        warn "Could not save original BBR sysctl values; leaving runtime tuning unchanged"
        return 0
    fi
    if ! sysctl -w net.core.default_qdisc=fq &>/dev/null; then
        warn "Failed to enable the fq queue discipline; BBR was not changed"
        return 0
    fi
    if ! sysctl -w net.ipv4.tcp_congestion_control=bbr &>/dev/null; then
        warn "Failed to enable BBR; continuing with the current congestion control"
        return 0
    fi
    # Keep the default profile limited to the congestion-control selection.
    # tcp_notsent_lowat and tcp_slow_start_after_idle are workload-dependent
    # global knobs; changing them here can increase wakeups or burst loss on
    # high-RTT links. Advanced users can opt into them outside the installer.
    if ! mkdir -p "$(dirname "$config_file")" 2>/dev/null; then
        warn "BBR is active for this boot but its sysctl directory is unavailable"
        return 0
    fi
    config_tmp=$(mktemp "${config_file}.tmp.XXXXXX" 2>/dev/null) || {
        warn "BBR is active for this boot but its sysctl file could not be staged"
        return 0
    }
    if ! printf '%s\n' \
        '# Managed by EasyTrojan' \
        'net.core.default_qdisc = fq' \
        'net.ipv4.tcp_congestion_control = bbr' > "$config_tmp" \
        || ! chmod 644 "$config_tmp" 2>/dev/null \
        || ! mv -f "$config_tmp" "$config_file"; then
        rm -f "$config_tmp"
        warn "BBR is active for this boot but could not be persisted to ${config_file}"
        return 0
    fi
    current=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
    if [ "$current" = "bbr" ]; then
        ok "BBR enabled and persisted (${config_file})"
    else
        warn "BBR did not become active; current congestion control: ${current:-unknown}"
    fi
}

apply_sysctl_limits() {
    local config_file="${CADDY_SYSCTL_FILE:-/etc/sysctl.d/99-caddy-trojan.conf}"
    local config_tmp load_output key expected actual failed=0 spec specs_output
    local -a tuning_specs=()

    if ! specs_output=$(_easytrojan_sysctl_tuning_specs); then
        warn "Cannot derive safe non-decreasing sysctl targets from the current host values"
        return 1
    fi
    while IFS= read -r spec; do
        [ -n "$spec" ] && tuning_specs+=("$spec")
    done <<< "$specs_output"

    info "Applying optional system optimizations..."
    _easytrojan_capture_sysctl_backup "${tuning_specs[@]}" \
        || { warn "Optional system tuning was not applied because its rollback snapshot failed"; return 1; }
    if ! mkdir -p "$(dirname "$config_file")" 2>/dev/null; then
        warn "Cannot create sysctl configuration directory: $(dirname "$config_file")"
        return 1
    fi
    config_tmp=$(mktemp "${config_file}.tmp.XXXXXX" 2>/dev/null) || {
        warn "Cannot stage sysctl configuration: ${config_file}"
        return 1
    }
    if ! cat > "$config_tmp" <<'EOF'
# Caddy-Trojan optional high-BDP / connection-rate tuning.
# Values are applied only when --tune-system is explicitly requested.
EOF
    then
        rm -f "$config_tmp"
        warn "Cannot write sysctl configuration: ${config_file}"
        return 1
    fi
    # Write the dynamically computed targets. Scalar values never decrease;
    # TCP min/default windows are preserved while only the max is raised.
    for spec in "${tuning_specs[@]}"; do
        key=${spec%%|*}
        expected=${spec#*|}
        printf '%s = %s\n' "$key" "$expected" >> "$config_tmp" || {
            rm -f "$config_tmp"
            warn "Cannot write sysctl target: ${key}"
            return 1
        }
    done
    if ! chmod 644 "$config_tmp" 2>/dev/null || ! mv -f "$config_tmp" "$config_file"; then
        rm -f "$config_tmp"
        warn "Cannot persist sysctl configuration: ${config_file}"
        return 1
    fi

    load_output=$(sysctl -p "$config_file" 2>&1) || {
        failed=1
        warn "One or more optional sysctl values could not be loaded"
        [ -n "$load_output" ] && warn "$load_output"
    }

    # sysctl -p can report success even when a later config overrides a value,
    # so read every managed key back from /proc/sys and compare normalized data.
    for spec in "${tuning_specs[@]}"; do
        key=${spec%%|*}
        expected=${spec#*|}
        actual=$(sysctl -n "$key" 2>/dev/null || true)
        actual=$(_easytrojan_sysctl_normalize "$actual")
        if [ "$actual" != "$expected" ]; then
            warn "sysctl ${key} did not take effect (expected '${expected}', got '${actual:-unavailable}')"
            failed=1
        fi
    done

    if [ "$failed" -ne 0 ]; then
        warn "Optional system optimizations were not fully applied; inspect ${config_file}"
        return 1
    fi
    ok "Optional system optimizations applied and verified (${config_file})"
}

# Print read-only network counters and service limits. This intentionally does
# not reset nstat counters or change qdisc/sysctl state; operators can run it
# repeatedly while comparing a short measurement window from the host.
doctor_network() {
    local key value line cc available qdisc_summary ss_summary nstat_output
    local pid fd_count nofile_limit softnet_drop=0 softnet_squeeze=0 drops squeeze
    local mem_kb buf_max

    info "Network diagnostics (read-only)"

    mem_kb=$(_easytrojan_detect_ram_kib)
    if [ -n "$mem_kb" ]; then
        buf_max=$(_easytrojan_calc_buf_max "$mem_kb")
        info "Host memory: $(( mem_kb / 1024 )) MiB (dynamic socket buffer target: $(( buf_max / 1048576 )) MiB)"
    fi

    if check_cmd sysctl; then
        cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
        available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
        [ -n "$cc" ] && info "TCP congestion control: ${cc}"
        [ -n "$available" ] && info "TCP algorithms available: ${available}"
        for key in net.core.default_qdisc net.core.somaxconn net.core.netdev_max_backlog \
            net.core.rmem_max net.core.wmem_max net.ipv4.tcp_rmem net.ipv4.tcp_wmem \
            net.ipv4.tcp_mem net.ipv4.tcp_max_syn_backlog net.ipv4.tcp_slow_start_after_idle \
            net.ipv4.tcp_mtu_probing net.ipv4.tcp_tw_reuse net.ipv4.tcp_fin_timeout \
            net.ipv4.ip_local_port_range; do
            value=$(sysctl -n "$key" 2>/dev/null || true)
            [ -n "$value" ] && info "${key}=${value}"
        done
    else
        warn "sysctl is unavailable; kernel network settings were not inspected"
    fi

    if check_cmd tc; then
        qdisc_summary=$(tc -s qdisc show 2>/dev/null | awk '
            /^qdisc / || /^ Sent / || /^ backlog / || / dropped [0-9]+/ || / requeues [0-9]+/ {print}
        ' | head -24 || true)
        if [ -n "$qdisc_summary" ]; then
            while IFS= read -r line; do
                [ -n "$line" ] && info "qdisc: $line"
            done <<< "$qdisc_summary"
        else
            warn "tc returned no qdisc statistics"
        fi
    else
        warn "tc is unavailable; actual interface qdisc was not inspected"
    fi

    if check_cmd nstat; then
        nstat_output=$(nstat -az 2>/dev/null || true)
        info "nstat counters below are cumulative; compare two snapshots for a measurement window"
        for key in TcpInSegs TcpOutSegs TcpRetransSegs TcpExtTCPTimeouts \
            TcpExtTCPSynRetrans TcpExtTCPBacklogDrop TcpExtTCPRcvQDrop \
            TcpExtListenOverflows TcpExtListenDrops; do
            value=$(awk -v wanted="$key" '$1 == wanted {print $2; exit}' <<< "$nstat_output")
            [ -n "$value" ] && info "nstat ${key}=${value}"
        done
    else
        warn "nstat is unavailable; TCP counters were not inspected"
    fi

    if [ -r /proc/net/softnet_stat ]; then
        while read -r _ drops squeeze _; do
            [[ "$drops" =~ ^[[:xdigit:]]+$ ]] || continue
            [[ "$squeeze" =~ ^[[:xdigit:]]+$ ]] || continue
            softnet_drop=$((softnet_drop + 16#$drops))
            softnet_squeeze=$((softnet_squeeze + 16#$squeeze))
        done < /proc/net/softnet_stat
        info "softnet drops=${softnet_drop} time_squeeze=${softnet_squeeze} (cumulative)"
    fi

    if check_cmd ss; then
        ss_summary=$(ss -s 2>/dev/null || true)
        while IFS= read -r line; do
            [ -n "$line" ] && info "sockets: $line"
        done <<< "$ss_summary"
    fi

    if check_cmd systemctl; then
        nofile_limit=$(systemctl show caddy.service -p LimitNOFILE --value 2>/dev/null || true)
        pid=$(systemctl show caddy.service -p MainPID --value 2>/dev/null || true)
        [ -n "$nofile_limit" ] && info "caddy LimitNOFILE=${nofile_limit}"
        if [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 0 ] && [ -d "/proc/${pid}/fd" ]; then
            fd_count=$(find "/proc/${pid}/fd" -mindepth 1 -maxdepth 1 -type l 2>/dev/null | wc -l | tr -d '[:space:]')
            [ -n "$fd_count" ] && info "caddy open file descriptors=${fd_count} (pid ${pid})"
        fi
    fi
}

# Echo a soft GOMEMLIMIT value in MiB (~75% of RAM), or nothing when RAM is
# undetectable or tiny (<170MB total). Optional arg overrides MemTotal (kB) for tests.
# shellcheck disable=SC2120  # optional arg is exercised by tests, not this module
derive_gomemlimit_mib() {
    local mem_kb
    mem_kb=$(_easytrojan_detect_ram_kib "${1:-}")
    [ -n "$mem_kb" ] || return 0
    local limit_mib=$(( mem_kb * 3 / 4 / 1024 ))
    [ "$limit_mib" -ge 128 ] || return 0
    printf '%s' "$limit_mib"
}

write_caddy_unit() {
    # Soft memory cap (~75% of RAM) as an OOM guard for small VPS. GOMEMLIMIT is a
    # soft target: normal single-client load never nears it, but a leak/spike makes
    # Go's GC reclaim harder instead of the box OOM-killing Caddy. Omitted if RAM
    # is undetectable or tiny.
    local gomemlimit_env="" limit_mib
    local unit_file="${CADDY_UNIT_FILE:-/etc/systemd/system/caddy.service}"
    local xdg_config_home="${CADDY_XDG_CONFIG_HOME:-/etc}"
    local xdg_data_home="${CADDY_XDG_DATA_HOME:-/var/lib}"
    local data_dir="${CADDY_DATA_DIR:-${xdg_data_home}/caddy}"
    limit_mib=$(derive_gomemlimit_mib)
    [ -n "$limit_mib" ] && gomemlimit_env="Environment=GOMEMLIMIT=${limit_mib}MiB"
    mkdir -p "$(dirname "$unit_file")"
    cat > "$unit_file" <<EOF
[Unit]
# Managed by EasyTrojan
Description=Caddy
Documentation=https://caddyserver.com/docs/
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
User=caddy
Group=caddy
Environment=XDG_CONFIG_HOME=${xdg_config_home} XDG_DATA_HOME=${xdg_data_home} HOME=${data_dir}
${gomemlimit_env}
ExecStart=${CADDY_BIN} run --environ --config ${CADDYFILE}
ExecReload=${CADDY_BIN} reload --config ${CADDYFILE} --force
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=${data_dir}
NoNewPrivileges=true
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

ensure_cert_storage() {
    # Keep all runtime state writable by Caddy, while configuration stays root-owned.
    # Older installs (or a root-run `caddy validate/run`) may have created the
    # trojan storage tree as root.  Caddy then fails during startup when it
    # tries to load a persisted user record from that tree.
    local data_dir="${CADDY_DATA_DIR:-/var/lib/caddy}"
    if [ -d "${CADDY_DIR}/certificates" ] && [ ! -d "${data_dir}/certificates" ]; then
        mkdir -p "$data_dir"
        cp -a "${CADDY_DIR}/certificates" "$data_dir/"
    fi
    if [ -d "${CADDY_DIR}/acme" ] && [ ! -d "${data_dir}/acme" ]; then
        mkdir -p "$data_dir"
        cp -a "${CADDY_DIR}/acme" "$data_dir/"
    fi
    mkdir -p "$data_dir/certificates" "$data_dir/acme" "$CADDY_DIR" "$TROJAN_DIR"
    chown root:caddy "$CADDY_DIR" "$TROJAN_DIR" 2>/dev/null || true
    chmod 750 "$CADDY_DIR" "$TROJAN_DIR"
    # The whole data tree belongs to the service user: besides certificates and
    # ACME state, the Trojan memory+caddy app persists records under
    # $data_dir/trojan.  Re-own existing files so reinstalls are idempotent.
    chown -R caddy:caddy "$data_dir" 2>/dev/null || true
    chmod 700 "$data_dir" "$data_dir/certificates" "$data_dir/acme"
    printf 'managed_by=easytrojan\nversion=1\n' > "${CADDY_DATA_MARKER:-$data_dir/.easytrojan-managed}"
    chown root:caddy "${CADDY_DATA_MARKER:-$data_dir/.easytrojan-managed}" 2>/dev/null || true
    chmod 640 "${CADDY_DATA_MARKER:-$data_dir/.easytrojan-managed}"
}

setup_renew_timer() {
    info "Setting up certificate renewal timer..."

    # Safety net for ACME mode; origin/file certs only log remaining validity.
    cat > /usr/local/bin/caddy-cert-maintain <<'EOF'
#!/bin/bash
set -uo pipefail
export XDG_CONFIG_HOME=/etc
export XDG_DATA_HOME=/var/lib
export HOME=/var/lib/caddy

TLS_MODE_FILE=/etc/caddy/trojan/tls-mode.txt
TLS_CERT_REC=/etc/caddy/trojan/tls-cert.path
ORIGIN_CERT=/etc/caddy/certs/origin.crt

mkdir -p /var/lib/caddy/certificates /var/lib/caddy/acme
chown caddy:caddy /var/lib/caddy /var/lib/caddy/certificates /var/lib/caddy/acme 2>/dev/null || true
chmod 700 /var/lib/caddy /var/lib/caddy/certificates /var/lib/caddy/acme 2>/dev/null || true

mode=auto
if [ -f "$TLS_MODE_FILE" ]; then
  mode=$(tr -d '[:space:]' < "$TLS_MODE_FILE" | tr '[:upper:]' '[:lower:]')
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

CERT_FILE=$(find /var/lib/caddy/certificates -name '*.crt' -type f 2>/dev/null | head -1 || true)
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
