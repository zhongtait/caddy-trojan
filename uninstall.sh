#!/bin/bash
#
# Caddy-Trojan Uninstaller
#

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

echo -e "${YELLOW}Starting Uninstallation...${NC}"

# 1. 检查 Root 权限
if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}Error: You must be root to run this script.${NC}"
    exit 1
fi

# 2. 停止并禁用服务
if systemctl is-active --quiet caddy; then
    echo "Stopping Caddy service..."
    systemctl stop caddy
    systemctl disable caddy
fi

# 3. 删除文件和目录
echo "Removing files..."

# 删除二进制文件
rm -f /usr/local/bin/caddy

# 删除服务文件
rm -f /etc/systemd/system/caddy.service

# 删除配置文件目录 (包含证书和密码)
if [ -d "/etc/caddy" ]; then
    rm -rf /etc/caddy
    echo "Config directory /etc/caddy removed."
fi

# 4. 删除系统优化配置 (对应优化版安装脚本)
# 删除 sysctl 配置
if [ -f "/etc/sysctl.d/99-caddy-trojan.conf" ]; then
    rm -f /etc/sysctl.d/99-caddy-trojan.conf
    echo "System optimization config removed."
fi

# 删除 limits 配置
if [ -f "/etc/security/limits.d/caddy-trojan.conf" ]; then
    rm -f /etc/security/limits.d/caddy-trojan.conf
    echo "Limits optimization config removed."
fi

# 5. 删除用户和组
if id caddy &>/dev/null; then
    userdel caddy
    echo "User 'caddy' removed."
fi

# 6. 刷新系统状态
systemctl daemon-reload
echo -e "${GREEN}Uninstallation Complete.${NC}"
echo -e "${YELLOW}Note: Some system kernel parameters (sysctl) applied during installation remain active until the next reboot.${NC}"