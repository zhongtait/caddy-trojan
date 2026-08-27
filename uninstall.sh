#!/bin/bash
#
# Caddy-Trojan Uninstaller
# Cleanly removes components installed by easytrojan.sh
#
# Project: https://github.com/zhongtait/caddy-trojan

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }

normalize_sysctl_value() {
    printf '%s\n' "$1" | awk '{$1=$1; print}'
}

restore_easytrojan_sysctls() {
    local backup_file="$1" key original managed extra current restored_value
    local restored=0 preserved=0 failures=0 malformed=0

    [ -f "$backup_file" ] || return 0
    if ! command -v sysctl >/dev/null 2>&1; then
        warn "Cannot restore sysctl values because sysctl is unavailable; preserving ${backup_file}"
        return 1
    fi

    while IFS=$'\t' read -r key original managed extra || [ -n "${key:-}" ]; do
        case "$key" in
            ''|'#'*) continue ;;
            net.core.default_qdisc|net.ipv4.tcp_congestion_control|\
            net.core.somaxconn|net.core.netdev_max_backlog|net.core.rmem_max|net.core.wmem_max|\
            net.ipv4.tcp_rmem|net.ipv4.tcp_wmem|net.ipv4.tcp_mem|net.ipv4.tcp_max_syn_backlog|\
            net.ipv4.tcp_slow_start_after_idle|net.ipv4.tcp_mtu_probing|net.ipv4.tcp_tw_reuse|\
            net.ipv4.tcp_fin_timeout|net.ipv4.ip_local_port_range) ;;
            *)
                warn "Ignoring invalid sysctl backup key: ${key}"
                malformed=1
                continue
                ;;
        esac
        if [ -z "$original" ] || [ -z "$managed" ] || [ -n "${extra:-}" ]; then
            warn "Ignoring malformed sysctl backup record: ${key}"
            malformed=1
            continue
        fi

        original=$(normalize_sysctl_value "$original")
        managed=$(normalize_sysctl_value "$managed")
        current=$(sysctl -n "$key" 2>/dev/null) || {
            warn "Cannot read current sysctl value during restore: ${key}"
            failures=$((failures + 1))
            continue
        }
        current=$(normalize_sysctl_value "$current")
        if [ "$current" != "$managed" ]; then
            warn "Preserving administrator-modified sysctl ${key}=${current} (EasyTrojan target was ${managed})"
            preserved=$((preserved + 1))
            continue
        fi

        if ! sysctl -w "${key}=${original}" >/dev/null 2>&1; then
            warn "Failed to restore sysctl ${key}=${original}"
            failures=$((failures + 1))
            continue
        fi
        restored_value=$(sysctl -n "$key" 2>/dev/null || true)
        restored_value=$(normalize_sysctl_value "$restored_value")
        if [ "$restored_value" != "$original" ]; then
            warn "sysctl ${key} restore verification failed (expected '${original}', got '${restored_value:-unavailable}')"
            failures=$((failures + 1))
            continue
        fi
        restored=$((restored + 1))
    done < "$backup_file"

    if [ "$failures" -ne 0 ] || [ "$malformed" -ne 0 ]; then
        warn "Sysctl rollback was incomplete; preserving backup for manual recovery: ${backup_file}"
        return 1
    fi
    rm -f "$backup_file"
    ok "Sysctl rollback complete (${restored} restored, ${preserved} administrator-modified preserved)"
}

# Let offline tests exercise the rollback helper without running an uninstall.
if [ "${EASYTROJAN_UNINSTALL_SOURCE_ONLY:-0}" = "1" ] \
    && [ "${BASH_SOURCE[0]}" != "$0" ]; then
    return 0 2>/dev/null || exit 0
fi

echo ""
echo -e "${YELLOW}=== Caddy-Trojan Uninstaller ===${NC}"
echo ""

[ "$(id -u)" = "0" ] || error "You must be root to run this script"

managed_caddy=0
if [ -f /etc/caddy/.easytrojan-managed ]; then
    managed_caddy=1
elif [ -f /etc/caddy/trojan/domain.txt ] && [ -f /etc/caddy/trojan/passwd.txt ] \
    && grep -q 'trojan' /etc/caddy/Caddyfile 2>/dev/null; then
    # Compatibility with installations created before the marker was added.
    managed_caddy=1
fi

if [ "${1:-}" != "-y" ] && [ "${1:-}" != "--yes" ]; then
    read -rp "Are you sure you want to uninstall Caddy-Trojan? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]([Ee][Ss])?$ ]] || { echo "Cancelled."; exit 0; }
fi
echo ""

if systemctl is-active --quiet easytrojan-hub 2>/dev/null || systemctl is-active --quiet easytrojan-hub.service 2>/dev/null; then
    info "Stopping EasyTrojan hub..."
    systemctl stop easytrojan-hub.service 2>/dev/null || true
    ok "Hub stopped"
fi
if systemctl is-enabled --quiet easytrojan-hub.service 2>/dev/null; then
    systemctl disable easytrojan-hub.service &>/dev/null || true
fi

if [ "$managed_caddy" = "1" ] && systemctl is-active --quiet caddy 2>/dev/null; then
    info "Stopping Caddy service..."
    systemctl stop caddy || true
    ok "Service stopped"
fi

if [ "$managed_caddy" = "1" ] && systemctl is-enabled --quiet caddy 2>/dev/null; then
    info "Disabling Caddy service..."
    systemctl disable caddy &>/dev/null || true
    ok "Service disabled"
fi

sysctl_backup_file="${CADDY_SYSCTL_BACKUP_FILE:-/etc/caddy/.easytrojan-sysctl-backup}"
sysctl_backup_used=0
if [ -f "$sysctl_backup_file" ]; then
    sysctl_backup_used=1
    restore_easytrojan_sysctls "$sysctl_backup_file" || true
fi

info "Removing files..."

if [ "$managed_caddy" = "1" ] && [ -f /usr/local/bin/caddy ]; then
    rm -f /usr/local/bin/caddy
    ok "Binary /usr/local/bin/caddy removed"
fi

for f in /usr/local/bin/easytrojan /usr/local/bin/easytrojan.sh /usr/local/bin/caddy-cert-maintain /usr/local/bin/easytrojan-hub; do
    if [ -f "$f" ]; then
        rm -f "$f"
        ok "Removed $f"
    fi
done

if [ -d /usr/local/share/easytrojan ]; then
    rm -rf /usr/local/share/easytrojan
    ok "Removed /usr/local/share/easytrojan"
fi

if [ -f /etc/systemd/system/easytrojan-hub.service ]; then
    rm -f /etc/systemd/system/easytrojan-hub.service
    ok "Hub unit removed"
fi

if [ "$managed_caddy" = "1" ] && [ -f /etc/systemd/system/caddy.service ]; then
    rm -f /etc/systemd/system/caddy.service
    ok "Service file removed"
fi

if [ "$managed_caddy" = "1" ] && { [ -f /etc/systemd/system/caddy-renew.timer ] || [ -f /etc/systemd/system/caddy-renew.service ]; }; then
    systemctl stop caddy-renew.timer &>/dev/null || true
    systemctl disable caddy-renew.timer &>/dev/null || true
    rm -f /etc/systemd/system/caddy-renew.timer
    rm -f /etc/systemd/system/caddy-renew.service
    ok "Certificate renewal timer removed"
fi

if [ "$managed_caddy" = "1" ] && [ -d /etc/caddy ]; then
    for path in /etc/caddy/Caddyfile /etc/caddy/.easytrojan-managed /etc/caddy/trojan \
        /etc/caddy/www /etc/caddy/certs /etc/caddy/certificates /etc/caddy/acme \
        /var/lib/caddy/.easytrojan-managed /var/lib/caddy/certificates /var/lib/caddy/acme; do
        [ -e "$path" ] && rm -rf "$path"
    done
    rmdir /etc/caddy 2>/dev/null || true
    ok "EasyTrojan-managed Caddy configuration removed"
elif [ "$managed_caddy" != "1" ]; then
    warn "No EasyTrojan Caddy marker found; preserving Caddy service, binary, account, and /etc/caddy"
fi

sysctl_removed=0
for sysctl_file in /etc/sysctl.d/99-caddy-trojan.conf /etc/sysctl.d/99-easytrojan-bbr.conf; do
    if [ -f "$sysctl_file" ]; then
        rm -f "$sysctl_file"
        sysctl_removed=1
    fi
done
if [ "$sysctl_removed" = "1" ]; then
    if [ "$sysctl_backup_used" != "1" ]; then
        # Legacy installations have no original-value snapshot. Reload the
        # remaining host policy, but do not claim that absent keys were reset.
        sysctl --system &>/dev/null || true
    fi
    ok "EasyTrojan sysctl configuration removed"
fi

if [ -f /etc/security/limits.d/caddy-trojan.conf ]; then
    rm -f /etc/security/limits.d/caddy-trojan.conf
    ok "Limits optimizations removed"
fi

if grep -q "net.ipv4.tcp_congestion_control\|fs.file-max = 1048576" /etc/sysctl.conf 2>/dev/null; then
    warn "Legacy entries detected in /etc/sysctl.conf (from older install version)."
    warn "You may want to manually review: /etc/sysctl.conf"
fi

if id easytrojan-hub &>/dev/null; then
    userdel easytrojan-hub 2>/dev/null || true
    ok "User 'easytrojan-hub' removed"
fi

if getent group easytrojan-hub &>/dev/null; then
    groupdel easytrojan-hub 2>/dev/null || true
    ok "Group 'easytrojan-hub' removed"
fi

warn "The shared 'caddy' system account was preserved to avoid affecting other Caddy installations."

systemctl daemon-reload 2>/dev/null || true

echo ""
echo -e "${GREEN}Caddy-Trojan uninstalled successfully.${NC}"
echo ""
if [ "$sysctl_removed" = "1" ] && [ "$sysctl_backup_used" != "1" ]; then
    warn "This legacy installation had no sysctl snapshot; some kernel parameters may remain active until reboot."
elif [ -f "$sysctl_backup_file" ]; then
    warn "A sysctl rollback backup remains for manual recovery: ${sysctl_backup_file}"
fi
echo ""
