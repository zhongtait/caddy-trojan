#!/bin/bash
#
# Caddy-Trojan Uninstaller
# Cleanly removes all components installed by easytrojan.sh
#
# Project: https://github.com/zhongtait/caddy-trojan

set -euo pipefail

# 颜色定义
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

# 1. 检查 Root 权限
[ "$(id -u)" != "0" ] && error "You must be root to run this script"

# 2. 确认卸载
read -rp "Are you sure you want to uninstall Caddy-Trojan? [y/N] " confirm
[[ ! "$confirm" =~ ^[Yy]$ ]] && { echo "Cancelled."; exit 0; }
echo ""

# 3. 停止并禁用服务
if systemctl is-active --quiet caddy 2>/dev/null; then
    info "Stopping Caddy service..."
    systemctl stop caddy
    ok "Service stopped"
fi

if systemctl is-enabled --quiet caddy 2>/dev/null; then
    info "Disabling Caddy service..."
    systemctl disable caddy &>/dev/null
    ok "Service disabled"
fi

# 4. 删除文件和目录
info "Removing files..."

# 删除二进制文件
if [ -f /usr/local/bin/caddy ]; then
    rm -f /usr/local/bin/caddy
    ok "Binary /usr/local/bin/caddy removed"
fi

# 删除服务文件
if [ -f /etc/systemd/system/caddy.service ]; then
    rm -f /etc/systemd/system/caddy.service
    ok "Service file removed"
fi

# 删除配置文件目录（包含证书、密码、伪装页面）
if [ -d /etc/caddy ]; then
    rm -rf /etc/caddy
    ok "Config directory /etc/caddy removed"
fi

# 5. 删除系统优化配置（新版安装脚本使用独立文件）
if [ -f /etc/sysctl.d/99-caddy-trojan.conf ]; then
    rm -f /etc/sysctl.d/99-caddy-trojan.conf
    sysctl --system &>/dev/null || true
    ok "Sysctl optimizations removed"
fi

if [ -f /etc/security/limits.d/caddy-trojan.conf ]; then
    rm -f /etc/security/limits.d/caddy-trojan.conf
    ok "Limits optimizations removed"
fi

# 兼容旧版安装脚本：检测直接写入 sysctl.conf 的配置
if grep -q "net.ipv4.tcp_congestion_control\|fs.file-max = 1048576" /etc/sysctl.conf 2>/dev/null; then
    warn "Legacy entries detected in /etc/sysctl.conf (from older install version)."
    warn "You may want to manually review: /etc/sysctl.conf"
fi

# 兼容旧版安装脚本：检测直接写入 limits.conf 的配置
if grep -q "# End of file" /etc/security/limits.conf 2>/dev/null; then
    warn "Legacy entries may exist in /etc/security/limits.conf"
fi

# 6. 删除用户和组
if id caddy &>/dev/null; then
    userdel caddy 2>/dev/null || true
    ok "User 'caddy' removed"
fi

if getent group caddy &>/dev/null; then
    groupdel caddy 2>/dev/null || true
    ok "Group 'caddy' removed"
fi

# 7. 刷新 systemd
systemctl daemon-reload

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║     Caddy-Trojan Uninstalled Successfully!              ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
warn "Some kernel parameters remain active until next reboot."
echo ""
