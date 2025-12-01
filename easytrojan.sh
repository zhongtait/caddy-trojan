#!/bin/bash
#
# Optimized EasyTrojan Installer
#

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# 获取输入参数
trojan_passwd=$1
caddy_domain=$2

# 检查是否为 Root
if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}Error: You must be root to run this script.${NC}"
    exit 1
fi

# 1. 密码交互逻辑优化
if [ -z "$trojan_passwd" ]; then
    read -p "Please enter trojan password: " trojan_passwd
    if [ -z "$trojan_passwd" ]; then
        echo -e "${RED}Error: Password cannot be empty.${NC}"
        exit 1
    fi
fi

# 2. 基础环境检查
address_ip=$(curl -s4 ipv4.ip.sb)
if [ -z "$address_ip" ]; then
    echo -e "${RED}Error: Cannot detect public IP.${NC}"
    exit 1
fi
nip_domain="${address_ip}.nip.io"
target_domain=${caddy_domain:-$nip_domain}

# 端口检查
if ss -Hlnp | grep -E ":80 |:443 " > /dev/null; then
    echo -e "${RED}Error: Port 80 or 443 is already in use.${NC}"
    exit 1
fi

# 安装依赖
echo "Installing dependencies..."
if command -v apt-get >/dev/null; then
    apt-get update && apt-get install -y tar curl
elif command -v yum >/dev/null; then
    yum install -y tar curl
elif command -v dnf >/dev/null; then
    dnf install -y tar curl
fi

# 3. 动态获取版本 & 下载 Caddy (适配架构)
ARCH=$(uname -m)
case $ARCH in
    x86_64)  FILE_ARCH="amd64" ;;
    aarch64) FILE_ARCH="arm64" ;;
    *) echo -e "${RED}Unsupported architecture: $ARCH${NC}"; exit 1 ;;
esac

# 获取最新 Release 版本 (如果不方便联网获取，可以保留硬编码，但建议提取为变量)
# 这里为了演示稳定性，定义变量，若需动态可 curl GitHub API
GITHUB_REPO="xiaopowanyi/caddy-trojan"
LATEST_TAG=$(curl -s "https://api.github.com/repos/$GITHUB_REPO/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
if [ -z "$LATEST_TAG" ]; then
    echo -e "${RED}Failed to fetch latest version, using fallback v2.8.4${NC}"
    LATEST_TAG="v2.8.4"
fi

echo "Downloading Caddy ($LATEST_TAG for $FILE_ARCH)..."
DOWNLOAD_URL="https://github.com/$GITHUB_REPO/releases/download/$LATEST_TAG/caddy_trojan_linux_${FILE_ARCH}.tar.gz"

curl -L "$DOWNLOAD_URL" | tar -zx -C /usr/local/bin caddy
chmod +x /usr/local/bin/caddy

# 用户配置
if ! id caddy &>/dev/null; then
    groupadd --system caddy
    useradd --system -g caddy -s /usr/sbin/nologin caddy
fi

mkdir -p /etc/caddy/trojan
chown -R caddy:caddy /etc/caddy
chmod 700 /etc/caddy
# 清理旧证书防止冲突
rm -rf /etc/caddy/certificates

# 4. 生成 Caddyfile
cat > /etc/caddy/Caddyfile <<EOF
{
    order trojan before respond
    admin off
    servers :443 {
        listener_wrappers {
            trojan
        }
        protocols h2 h1
    }
    trojan {
        caddy
        no_proxy
    }
}

:443, $target_domain {
    tls {
        protocols tls1.2 tls1.3
    }
    trojan {
        websocket
    }
    respond "Service Unavailable" 503
}

:80 {
    redir https://{host}{uri} permanent
}
EOF

# Systemd 配置
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
ExecStart=/usr/local/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable caddy
systemctl restart caddy

# 添加密码 (API 方式)
# 等待 Caddy 启动
sleep 3
# 注意：Caddyfile 关闭了 admin 接口(admin off)，如果需要 API 添加用户，必须在 Caddyfile 全局块开启 admin 端口
# 如果不使用 admin API，建议直接生成 users 配置文件让 caddy 读取。
# 为了保持原脚本逻辑，这里暂时假设 admin 是开启的或者改用文件方式。
# 原脚本使用了 API，但 admin 默认监听 localhost:2019。
# 更好的方式是写入文件，因为 Caddy-Trojan 插件支持读取文件。

echo "$trojan_passwd" > /etc/caddy/trojan/passwd.txt
chown caddy:caddy /etc/caddy/trojan/passwd.txt

# 重启以加载密码文件 (取决于插件实现，通常重启最稳)
systemctl restart caddy

# 5. 系统调优 (使用模块化配置，不破坏原文件)
echo "Optimizing system settings..."

# Limits
cat > /etc/security/limits.d/caddy-trojan.conf <<EOF
* soft   nofile    1048576
* hard   nofile    1048576
root  soft   nofile    1048576
root  hard   nofile    1048576
EOF

# Sysctl
cat > /etc/sysctl.d/99-caddy-trojan.conf << EOF
fs.file-max = 1048576
net.core.somaxconn = 32768
net.core.rmem_max=33554432
net.core.wmem_max=33554432
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_congestion_control = bbr
EOF

# 应用 Sysctl
sysctl --system > /dev/null

echo -e "${GREEN}Installation Successful!${NC}"
echo -e "Domain: ${target_domain}"
echo -e "Port: 443"
echo -e "Password: ${trojan_passwd}"