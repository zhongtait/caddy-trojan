#!/bin/bash
# EasyTrojan module: system.sh
# shellcheck shell=bash

# shellcheck disable=SC2120  # optional arg is exercised by tests, not this module
_easytrojan_detect_ram_kib() {
    local mem_kb="${1:-${EASYTROJAN_MEM_TOTAL_KB:-}}"
    if [ -z "$mem_kb" ]; then
        mem_kb=$(awk '/^MemTotal:/{print $2; exit}' /proc/meminfo 2>/dev/null || true)
    fi
    mem_kb=${mem_kb//[^0-9]/}
    if [ -n "$mem_kb" ] && [ "$mem_kb" -gt 0 ] 2>/dev/null; then
        printf '%s' "$mem_kb"
    fi
}

_easytrojan_detect_cgroup_limit_kib_hierarchical() {
    local path current_path file value limit_kb min_kb=""
    local -a files=()

    if [ -n "${EASYTROJAN_CGROUP_V2_MEMORY_MAX_FILE:-}" ]; then
        files+=("$EASYTROJAN_CGROUP_V2_MEMORY_MAX_FILE")
    else
        path=$(awk -F: '$1 == 0 { print $3; exit }' /proc/self/cgroup 2>/dev/null || true)
        current_path="$path"
        while [ -n "$current_path" ]; do
            files+=("/sys/fs/cgroup$current_path/memory.max")
            [ "$current_path" != "/" ] || break
            current_path=$(dirname "$current_path")
            [ "$current_path" != "." ] || current_path="/"
        done
        files+=(/sys/fs/cgroup/memory.max)
    fi
    if [ -n "${EASYTROJAN_CGROUP_V1_MEMORY_LIMIT_FILE:-}" ]; then
        files+=("$EASYTROJAN_CGROUP_V1_MEMORY_LIMIT_FILE")
    else
        path=$(awk -F: '$2 ~ /(^|,)memory(,|$)/ { print $3; exit }' /proc/self/cgroup 2>/dev/null || true)
        current_path="$path"
        while [ -n "$current_path" ]; do
            files+=("/sys/fs/cgroup/memory$current_path/memory.limit_in_bytes")
            [ "$current_path" != "/" ] || break
            current_path=$(dirname "$current_path")
            [ "$current_path" != "." ] || current_path="/"
        done
        files+=(/sys/fs/cgroup/memory/memory.limit_in_bytes)
    fi
    if [ "$#" -gt 0 ]; then
        files=("$@")
    fi

    for file in "${files[@]}"; do
        [ -r "$file" ] || continue
        value=$(tr -d '[:space:]' < "$file" 2>/dev/null || true)
        [[ "$value" =~ ^[0-9]+$ ]] || continue # cgroup v2 uses "max" for unlimited.
        [ "$value" -gt 0 ] 2>/dev/null || continue
        if [[ "$file" == */memory.limit_in_bytes ]] && [ "$value" -ge 1152921504606846976 ] 2>/dev/null; then
            continue # cgroup v1's unlimited sentinel.
        fi
        limit_kb=$((value / 1024))
        if [ -z "$min_kb" ] || [ "$limit_kb" -lt "$min_kb" ]; then
            min_kb=$limit_kb
        fi
    done
    [ -n "$min_kb" ] && printf '%s' "$min_kb"
    return 0
}

_easytrojan_detect_effective_ram_kib() {
    local mem_kb cgroup_kb
    # Explicit input is reserved for deterministic host-RAM unit tests.
    mem_kb=$(_easytrojan_detect_ram_kib "${1:-}")
    if [ -z "${1:-}" ]; then
        cgroup_kb=$(_easytrojan_detect_cgroup_limit_kib_hierarchical)
        if [ -n "$cgroup_kb" ] && { [ -z "$mem_kb" ] || [ "$cgroup_kb" -lt "$mem_kb" ]; }; then
            mem_kb=$cgroup_kb
        fi
    fi
    printf '%s' "$mem_kb"
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

    mem_kb=$(_easytrojan_detect_ram_kib)
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
        apply_fq_qdisc_to_default_iface || true
        ok "BBR enabled and persisted (${config_file})"
    else
        warn "BBR did not become active; current congestion control: ${current:-unknown}"
    fi
}

apply_fq_qdisc_to_default_iface() {
    check_cmd tc && check_cmd ip || return 0
    local ifaces iface updated=0
    ifaces=$(
        {
            ip route show default 2>/dev/null || true
            ip -6 route show default 2>/dev/null || true
        } | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | awk 'NF && !seen[$0]++'
    )
    [ -n "$ifaces" ] || return 0
    while IFS= read -r iface; do
        [ -n "$iface" ] || continue
        if tc qdisc replace dev "$iface" root fq 2>/dev/null; then
            ok "Active interface (${iface}) qdisc updated to fq"
            updated=1
        fi
    done <<< "$ifaces"
    [ "$updated" -eq 1 ] || return 0
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

# Echo a soft GOMEMLIMIT value in MiB (~75% of effective RAM), or nothing when
# RAM is undetectable or tiny (<170MB total). Effective RAM is capped by cgroups.
# Optional arg overrides MemTotal (kB) for deterministic tests.
# shellcheck disable=SC2120  # optional arg is exercised by tests, not this module
derive_gomemlimit_mib() {
    local mem_kb
    mem_kb=$(_easytrojan_detect_effective_ram_kib "${1:-}")
    [ -n "$mem_kb" ] || return 0
    local limit_mib=$(( mem_kb * 3 / 4 / 1024 ))
    [ "$limit_mib" -ge 128 ] || return 0
    printf '%s' "$limit_mib"
}

write_caddy_unit() {
    # Soft memory cap (~75% of effective RAM, including cgroup limits) as an OOM guard. GOMEMLIMIT is a
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
# Caddy synchronously restores persisted Trojan traffic records before it
# notifies systemd that the service is ready. Large histories can exceed the
# systemd default start timeout.
TimeoutStartSec=5min
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

DOMAIN_FILE=/etc/caddy/trojan/domain.txt
DOMAIN=""
if [ -f "$DOMAIN_FILE" ]; then
  DOMAIN=$(head -1 "$DOMAIN_FILE" 2>/dev/null | tr -d '[:space:]')
fi
CERT_FILE=""
if [ -n "$DOMAIN" ]; then
  CERT_FILE=$(find /var/lib/caddy/certificates -name "${DOMAIN}.crt" -type f 2>/dev/null | head -1 || true)
fi
if [ -z "$CERT_FILE" ]; then
  CERT_FILE=$(find /var/lib/caddy/certificates -name '*.crt' -type f 2>/dev/null | head -1 || true)
fi
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

write_traffic_schedule_units() {
    local reset_calendar="${1:-}" has_maintain="${2:-0}"
    local reset_service="${TRAFFIC_RESET_SERVICE_FILE:-/etc/systemd/system/easytrojan-traffic-reset.service}"
    local reset_timer="${TRAFFIC_RESET_TIMER_FILE:-/etc/systemd/system/easytrojan-traffic-reset.timer}"
    local maint_service="${TRAFFIC_MAINTAIN_SERVICE_FILE:-/etc/systemd/system/easytrojan-traffic-maintain.service}"
    local maint_timer="${TRAFFIC_MAINTAIN_TIMER_FILE:-/etc/systemd/system/easytrojan-traffic-maintain.timer}"
    local script_bin="${SCRIPT_BIN:-/usr/local/bin/easytrojan}"

    mkdir -p "$(dirname "$reset_service")"
    if [ -n "$reset_calendar" ]; then
        cat > "$reset_service" <<EOF
[Unit]
Description=EasyTrojan Scheduled Traffic Reset
After=network-online.target caddy.service
Wants=caddy.service

[Service]
Type=oneshot
ExecStart=${script_bin} traffic reset --yes
Nice=10
EOF
        cat > "$reset_timer" <<EOF
[Unit]
Description=EasyTrojan Scheduled Traffic Reset Timer

[Timer]
OnCalendar=${reset_calendar}
Persistent=true
Unit=easytrojan-traffic-reset.service

[Install]
WantedBy=timers.target
EOF
    else
        rm -f -- "$reset_timer" "$reset_service"
    fi

    if [ "$has_maintain" = "1" ]; then
        cat > "$maint_service" <<EOF
[Unit]
Description=EasyTrojan Traffic Maintenance (Prune / Quota)
After=network-online.target caddy.service
Wants=caddy.service

[Service]
Type=oneshot
ExecStart=${script_bin} traffic maintain
Nice=10
EOF
        cat > "$maint_timer" <<'EOF'
[Unit]
Description=EasyTrojan Traffic Maintenance Timer

[Timer]
OnBootSec=5min
OnUnitActiveSec=15min
Persistent=true
Unit=easytrojan-traffic-maintain.service

[Install]
WantedBy=timers.target
EOF
    else
        rm -f -- "$maint_timer" "$maint_service"
    fi
}

remove_traffic_schedule_units() {
    local reset_service="${TRAFFIC_RESET_SERVICE_FILE:-/etc/systemd/system/easytrojan-traffic-reset.service}"
    local reset_timer="${TRAFFIC_RESET_TIMER_FILE:-/etc/systemd/system/easytrojan-traffic-reset.timer}"
    local maint_service="${TRAFFIC_MAINTAIN_SERVICE_FILE:-/etc/systemd/system/easytrojan-traffic-maintain.service}"
    local maint_timer="${TRAFFIC_MAINTAIN_TIMER_FILE:-/etc/systemd/system/easytrojan-traffic-maintain.timer}"

    if check_cmd systemctl; then
        systemctl stop easytrojan-traffic-reset.timer easytrojan-traffic-maintain.timer &>/dev/null || true
        systemctl disable easytrojan-traffic-reset.timer easytrojan-traffic-maintain.timer &>/dev/null || true
    fi
    rm -f -- "$reset_timer" "$reset_service" "$maint_timer" "$maint_service"
    if check_cmd systemctl; then
        systemctl daemon-reload 2>/dev/null || true
    fi
}

cf_firewall_script_path() {
    printf '%s' "${CF_FIREWALL_BIN:-/usr/local/bin/easytrojan-cf-firewall}"
}

cf_firewall_unit_path() {
    printf '%s' "${CF_FIREWALL_SERVICE_FILE:-/etc/systemd/system/${CF_FIREWALL_UNIT:-easytrojan-cf-firewall.service}}"
}

cf_firewall_conf_path() {
    printf '%s' "${CF_FIREWALL_CONF:-${TROJAN_DIR}/cf-firewall.conf}"
}

resolve_cloudflare_cidrs() {
    local family="$1" refresh="${2:-0}" fallback="" url="" fetched="" valid="" line="" count=0
    if [ "$family" = "4" ]; then
        fallback=$(cloudflare_ipv4_cidrs)
        url="https://www.cloudflare.com/ips-v4"
    else
        fallback=$(cloudflare_ipv6_cidrs)
        url="https://www.cloudflare.com/ips-v6"
    fi

    if [ "$refresh" = "1" ] && check_cmd curl; then
        fetched=$(curl -fsS --connect-timeout 3 --max-time 8 "$url" 2>/dev/null || true)
        if [ -n "$fetched" ]; then
            while IFS= read -r line; do
                line=$(printf '%s' "$line" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                [ -n "$line" ] || continue
                if [ "$family" = "4" ] && [[ "$line" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
                    valid="${valid:+${valid} }${line}"
                    count=$((count + 1))
                elif [ "$family" = "6" ] && [[ "$line" =~ ^[0-9a-fA-F:]+/[0-9]{1,3}$ ]]; then
                    valid="${valid:+${valid} }${line}"
                    count=$((count + 1))
                else
                    valid=""
                    count=0
                    break
                fi
            done <<< "$fetched"
        fi
        if [ "$count" -ge 5 ] && [ -n "$valid" ]; then
            printf '%s' "$valid"
            return 0
        fi
        warn "Failed to refresh Cloudflare IPv${family} list; using built-in CIDRs"
    fi
    printf '%s' "$fallback"
}

write_cf_firewall_helper() {
    local bin_path="$1"
    local bin_dir tmp_bin
    bin_dir=$(dirname "$bin_path")
    mkdir -p "$bin_dir"
    tmp_bin=$(mktemp "${bin_path}.tmp.XXXXXX")
    cat > "$tmp_bin" <<'EOF'
#!/bin/bash
set -euo pipefail

CONF="${CF_FIREWALL_CONF:-/etc/caddy/trojan/cf-firewall.conf}"
MODE="off"
PORT="443"
V4_CIDRS=""
V6_CIDRS=""

load_conf() {
    [ -f "$CONF" ] || return 0
    local k v
    while IFS='=' read -r k v; do
        case "$k" in
            ''|\#*) continue ;;
            MODE) MODE="$v" ;;
            PORT) PORT="$v" ;;
            V4_CIDRS) V4_CIDRS="$v" ;;
            V6_CIDRS) V6_CIDRS="$v" ;;
        esac
    done < "$CONF"
}

select_backend() {
    if [ -n "${CF_FIREWALL_BACKEND:-}" ]; then
        printf '%s' "$CF_FIREWALL_BACKEND"
        return 0
    fi
    if command -v nft >/dev/null 2>&1 && nft list tables >/dev/null 2>&1; then
        printf 'nft'
        return 0
    fi
    if command -v iptables >/dev/null 2>&1; then
        printf 'iptables'
        return 0
    fi
    return 1
}

remove_iptables_chain() {
    local cmd="$1" w_flag="" rule_args=""
    command -v "$cmd" >/dev/null 2>&1 || return 0
    if "$cmd" -w -L INPUT >/dev/null 2>&1; then
        w_flag="-w"
    fi
    while IFS= read -r rule_args; do
        [ -n "$rule_args" ] || continue
        # shellcheck disable=SC2086
        "$cmd" $w_flag -D $rule_args 2>/dev/null || true
    done < <("$cmd" $w_flag -S INPUT 2>/dev/null | awk '/-j EASYTROJAN_CF/ { sub(/^-A /, ""); print }')
    "$cmd" $w_flag -F EASYTROJAN_CF 2>/dev/null || true
    "$cmd" $w_flag -X EASYTROJAN_CF 2>/dev/null || true
}

remove_all() {
    if command -v nft >/dev/null 2>&1 && nft list table inet easytrojan_cf >/dev/null 2>&1; then
        nft delete table inet easytrojan_cf 2>/dev/null || true
    fi
    remove_iptables_chain iptables
    remove_iptables_chain ip6tables
}

apply_nft() {
    local v4_csv="" v6_csv="" c
    for c in $V4_CIDRS; do
        [[ "$c" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || continue
        v4_csv="${v4_csv:+${v4_csv}, }${c}"
    done
    for c in $V6_CIDRS; do
        [[ "$c" =~ ^[0-9a-fA-F:]+/[0-9]{1,3}$ ]] || continue
        v6_csv="${v6_csv:+${v6_csv}, }${c}"
    done
    [ -n "$v4_csv" ] || return 1

    remove_all
    {
        printf 'table inet easytrojan_cf {\n'
        printf '    set cf_v4 {\n        type ipv4_addr\n        flags interval\n        elements = { %s }\n    }\n' "$v4_csv"
        if [ -n "$v6_csv" ]; then
            printf '    set cf_v6 {\n        type ipv6_addr\n        flags interval\n        elements = { %s }\n    }\n' "$v6_csv"
        fi
        printf '    chain input {\n'
        printf '        type filter hook input priority -10; policy accept;\n'
        printf '        iifname "lo" accept\n'
        printf '        ct state established,related accept\n'
        printf '        tcp dport != %s accept\n' "$PORT"
        printf '        ip saddr @cf_v4 accept\n'
        if [ -n "$v6_csv" ]; then
            printf '        ip6 saddr @cf_v6 accept\n'
        fi
        printf '        counter drop\n'
        printf '    }\n'
        printf '}\n'
    } | nft -f -
}

apply_iptables_family() {
    local cmd="$1" cidrs="$2" w_flag="" c added=0
    command -v "$cmd" >/dev/null 2>&1 || return 0
    if "$cmd" -w -L INPUT >/dev/null 2>&1; then
        w_flag="-w"
    fi
    "$cmd" $w_flag -N EASYTROJAN_CF
    "$cmd" $w_flag -A EASYTROJAN_CF -i lo -j RETURN
    "$cmd" $w_flag -A EASYTROJAN_CF -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN 2>/dev/null \
        || "$cmd" $w_flag -A EASYTROJAN_CF -m state --state ESTABLISHED,RELATED -j RETURN 2>/dev/null \
        || true
    for c in $cidrs; do
        [ -n "$c" ] || continue
        "$cmd" $w_flag -A EASYTROJAN_CF -s "$c" -j RETURN
        added=$((added + 1))
    done
    [ "$added" -gt 0 ] || return 1
    "$cmd" $w_flag -A EASYTROJAN_CF -j DROP
    "$cmd" $w_flag -I INPUT 1 -p tcp --dport "$PORT" -j EASYTROJAN_CF
}

apply_rules() {
    load_conf
    if [ "$MODE" != "cf-only" ]; then
        remove_all
        return 0
    fi
    if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
        echo "Invalid firewall port: $PORT" >&2
        return 1
    fi
    local backend
    backend=$(select_backend) || { echo "Neither nft nor iptables is available" >&2; return 1; }
    if [ "$backend" = "nft" ]; then
        apply_nft
    else
        remove_all
        apply_iptables_family iptables "$V4_CIDRS"
        if [ -n "$V6_CIDRS" ]; then
            apply_iptables_family ip6tables "$V6_CIDRS"
        fi
    fi
}

status_rules() {
    load_conf
    echo "mode=${MODE}"
    echo "port=${PORT}"
    if command -v nft >/dev/null 2>&1 && nft list table inet easytrojan_cf >/dev/null 2>&1; then
        echo "active_backend=nft"
        nft list table inet easytrojan_cf 2>/dev/null
    elif command -v iptables >/dev/null 2>&1 && iptables -S EASYTROJAN_CF >/dev/null 2>&1; then
        echo "active_backend=iptables"
        iptables -S EASYTROJAN_CF 2>/dev/null || true
        ip6tables -S EASYTROJAN_CF 2>/dev/null || true
    else
        echo "active_backend=none"
    fi
}

case "${1:-apply}" in
    apply) apply_rules ;;
    remove|off) remove_all ;;
    status) status_rules ;;
    *)
        echo "Usage: $0 {apply|remove|status}" >&2
        exit 1
        ;;
esac
EOF
    chmod 755 "$tmp_bin"
    mv -f "$tmp_bin" "$bin_path"
}

write_cf_firewall_unit() {
    local unit_path="$1" bin_path="$2" conf_path="$3"
    local unit_dir tmp_unit
    unit_dir=$(dirname "$unit_path")
    mkdir -p "$unit_dir"
    tmp_unit=$(mktemp "${unit_path}.tmp.XXXXXX")
    cat > "$tmp_unit" <<EOF
[Unit]
Description=EasyTrojan Cloudflare Origin Firewall (TCP port protection)
After=network-pre.target nftables.service netfilter-persistent.service ufw.service
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=CF_FIREWALL_CONF=${conf_path}
ExecStart=${bin_path} apply
ExecStop=${bin_path} remove

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$tmp_unit"
    mv -f "$tmp_unit" "$unit_path"
}

apply_cf_only_firewall() {
    local port="${1:-443}" refresh="${2:-0}" dry_run="${3:-0}"
    local v4_cidrs v6_cidrs conf_path bin_path unit_path tmp_conf
    validate_port "$port" "--port"
    v4_cidrs=$(resolve_cloudflare_cidrs 4 "$refresh")
    v6_cidrs=$(resolve_cloudflare_cidrs 6 "$refresh")

    if [ "$dry_run" = "1" ]; then
        echo "mode=cf-only"
        echo "port=${port}"
        echo "v4_cidrs=${v4_cidrs}"
        echo "v6_cidrs=${v6_cidrs}"
        return 0
    fi

    conf_path=$(cf_firewall_conf_path)
    bin_path=$(cf_firewall_script_path)
    unit_path=$(cf_firewall_unit_path)

    mkdir -p "$(dirname "$conf_path")"
    tmp_conf=$(mktemp "${conf_path}.tmp.XXXXXX")
    {
        printf 'MODE=cf-only\n'
        printf 'PORT=%s\n' "$port"
        printf 'V4_CIDRS=%s\n' "$v4_cidrs"
        printf 'V6_CIDRS=%s\n' "$v6_cidrs"
    } > "$tmp_conf"
    chmod 640 "$tmp_conf"
    mv -f "$tmp_conf" "$conf_path"

    write_cf_firewall_helper "$bin_path"
    write_cf_firewall_unit "$unit_path" "$bin_path" "$conf_path"

    if [ "${CF_FIREWALL_SKIP_APPLY:-0}" != "1" ]; then
        CF_FIREWALL_CONF="$conf_path" "$bin_path" apply
        if check_cmd systemctl; then
            systemctl daemon-reload &>/dev/null || true
            systemctl enable "$(basename "$unit_path")" &>/dev/null || true
            systemctl restart "$(basename "$unit_path")" &>/dev/null || true
        fi
    fi
}

disable_cf_firewall() {
    local conf_path bin_path unit_path unit_name
    conf_path=$(cf_firewall_conf_path)
    bin_path=$(cf_firewall_script_path)
    unit_path=$(cf_firewall_unit_path)
    unit_name=$(basename "$unit_path")

    if [ "${CF_FIREWALL_SKIP_APPLY:-0}" != "1" ]; then
        if [ -x "$bin_path" ]; then
            CF_FIREWALL_CONF="$conf_path" "$bin_path" remove || true
        fi
        if check_cmd systemctl; then
            systemctl stop "$unit_name" &>/dev/null || true
            systemctl disable "$unit_name" &>/dev/null || true
        fi
    fi
    rm -f -- "$conf_path" "$unit_path" "$bin_path"
    if [ "${CF_FIREWALL_SKIP_APPLY:-0}" != "1" ] && check_cmd systemctl; then
        systemctl daemon-reload &>/dev/null || true
    fi
}
