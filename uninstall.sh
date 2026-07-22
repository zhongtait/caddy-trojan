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

if systemctl is-active --quiet caddy 2>/dev/null; then
    info "Stopping Caddy service..."
    systemctl stop caddy || true
    ok "Service stopped"
fi

if systemctl is-enabled --quiet caddy 2>/dev/null; then
    info "Disabling Caddy service..."
    systemctl disable caddy &>/dev/null || true
    ok "Service disabled"
fi

info "Removing files..."

if [ -f /usr/local/bin/caddy ]; then
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

if [ -f /etc/systemd/system/caddy.service ]; then
    rm -f /etc/systemd/system/caddy.service
    ok "Service file removed"
fi

if [ -f /etc/systemd/system/caddy-renew.timer ] || [ -f /etc/systemd/system/caddy-renew.service ]; then
    systemctl stop caddy-renew.timer &>/dev/null || true
    systemctl disable caddy-renew.timer &>/dev/null || true
    rm -f /etc/systemd/system/caddy-renew.timer
    rm -f /etc/systemd/system/caddy-renew.service
    ok "Certificate renewal timer removed"
fi

if [ -d /etc/caddy ]; then
    rm -rf /etc/caddy
    ok "Config directory /etc/caddy removed"
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

if id caddy &>/dev/null; then
    userdel caddy 2>/dev/null || true
    ok "User 'caddy' removed"
fi

if getent group caddy &>/dev/null; then
    groupdel caddy 2>/dev/null || true
    ok "Group 'caddy' removed"
fi

systemctl daemon-reload 2>/dev/null || true

echo ""
echo -e "${GREEN}Caddy-Trojan uninstalled successfully.${NC}"
echo ""
warn "Some kernel parameters remain active until next reboot."
echo ""