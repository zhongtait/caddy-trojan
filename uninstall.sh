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
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }
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

if [ -f /etc/sysctl.d/99-caddy-trojan.conf ]; then
    rm -f /etc/sysctl.d/99-caddy-trojan.conf
    sysctl --system &>/dev/null || true
    ok "Sysctl optimizations removed"
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
warn "Some kernel parameters remain active until next reboot."
echo ""
