#!/bin/bash
#
# EasyTrojan - One-click Caddy-Trojan installer
# Supports: CentOS/RedHat 7+, Debian 9+, Ubuntu 16+
#
# Based on: https://github.com/imgk/caddy-trojan
# Project:  https://github.com/zhongtait/caddy-trojan

set -euo pipefail

# ==================== 颜色与工具函数 ====================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }

check_cmd() { command -v "$1" &>/dev/null; }

# ==================== 参数与环境检查 ====================
trojan_passwd="${1:-}"
caddy_domain="${2:-}"

[ -z "$trojan_passwd" ] && error "Usage: bash easytrojan.sh <password> [domain]"
[ "$(id -u)" != "0" ] && error "You must be root to run this script"

# 检查端口占用（排除已有的 caddy 进程，支持重装场景）
check_port=$(ss -Hlnp sport = :80 or sport = :443 | grep -v caddy || true)
if [ -n "$check_port" ]; then
    # 如果 caddy 正在运行，先停止它
    if systemctl is-active --quiet caddy 2>/dev/null; then
        info "Stopping existing Caddy service for reinstall..."
        systemctl stop caddy
    else
        error "Port 80 or 443 is already in use by another process:\n$check_port"
    fi
fi

# 获取服务器 IP（多源备用）
info "Detecting server IP..."
address_ip=""
for ip_service in "ipv4.ip.sb" "api.ipify.org" "ifconfig.me"; do
    address_ip=$(curl -s --connect-timeout 5 --max-time 10 "$ip_service" 2>/dev/null) && break
done
[ -z "$address_ip" ] && error "Failed to detect server IP. Check network connectivity."
nip_domain="${address_ip}.nip.io"
info "Server IP: $address_ip"

# 验证自定义域名
if [ -n "$caddy_domain" ]; then
    domain_ip=$(ping "${caddy_domain}" -c 1 -W 5 2>/dev/null | sed '1{s/[^(]*(//;s/).*//;q}')
    [ "$domain_ip" != "$address_ip" ] && error "Domain '$caddy_domain' resolves to '$domain_ip', expected '$address_ip'"
    nip_domain="$caddy_domain"
    info "Using custom domain: $caddy_domain"
fi

# ==================== 依赖安装 ====================
install_pkg() {
    local pkg="$1"
    if ! check_cmd "$pkg"; then
        info "Installing $pkg..."
        if check_cmd dnf; then
            dnf install -y "$pkg" &>/dev/null
        elif check_cmd yum; then
            yum install -y "$pkg" &>/dev/null
        elif check_cmd apt-get; then
            apt-get update -qq &>/dev/null
            apt-get install -y "$pkg" &>/dev/null
        else
            error "Unable to install $pkg: no supported package manager found"
        fi
    fi
}

install_pkg tar
install_pkg curl

# ==================== 下载 Caddy ====================
case $(uname -m) in
    x86_64)  arch="amd64" ;;
    aarch64) arch="arm64" ;;
    *)       error "Unsupported architecture: $(uname -m)" ;;
esac

caddy_url="https://github.com/zhongtait/caddy-trojan/releases/latest/download/caddy_trojan_linux_${arch}.tar.gz"

info "Downloading Caddy-Trojan (${arch})..."
if ! curl -fsSL --connect-timeout 15 --max-time 180 "$caddy_url" | tar -zx -C /usr/local/bin caddy; then
    error "Failed to download Caddy binary. Check network or try again."
fi
chmod +x /usr/local/bin/caddy
ok "Caddy binary installed: $(/usr/local/bin/caddy version 2>/dev/null | awk '{print $1}' || echo 'unknown')"

# ==================== 创建用户与目录 ====================
if ! id caddy &>/dev/null; then
    groupadd --system caddy
    useradd --system -g caddy -s "$(command -v nologin)" caddy
fi

mkdir -p /etc/caddy/trojan
chown -R caddy:caddy /etc/caddy
chmod 700 /etc/caddy

# 使用自定义域名时清除旧证书以重新申请
[ -n "$caddy_domain" ] && rm -rf /etc/caddy/certificates

# ==================== 伪装页面 ====================
# 创建简单的伪装页面，比直接返回 503 更隐蔽
mkdir -p /etc/caddy/www
cat > /etc/caddy/www/index.html <<'HTMLEOF'
<!DOCTYPE html>
<html>
<head><title>Welcome</title></head>
<body>
<h1>It works!</h1>
<p>This is the default web page for this server.</p>
</body>
</html>
HTMLEOF
chown -R caddy:caddy /etc/caddy/www

# ==================== 生成 Caddyfile ====================
# 参考上游 imgk/caddy-trojan 推荐配置
info "Generating Caddyfile..."
cat > /etc/caddy/Caddyfile <<EOF
{
    order trojan before file_server
    https_port 443
    servers :443 {
        listener_wrappers {
            trojan
        }
        protocols h2 h1
    }
    servers :80 {
        protocols h1
    }
    trojan {
        caddy
        no_proxy
    }
}
:443, $nip_domain {
    tls ${address_ip}@nip.io
    log {
        level ERROR
    }
    trojan {
        connect_method
        websocket
    }
    file_server {
        root /etc/caddy/www
    }
}
:80 {
    redir https://{host}{uri} permanent
}
EOF

# ==================== 生成 Systemd 服务 ====================
info "Creating systemd service..."
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
Environment=XDG_CONFIG_HOME=/etc XDG_DATA_HOME=/etc
ExecStart=/usr/local/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
AmbientCapabilities=CAP_NET_BIND_SERVICE
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# ==================== 启动服务 ====================
# 确保 loopback 接口启用
if ip link show lo | grep -q DOWN; then
    ip link set lo up
fi

info "Starting Caddy service..."
systemctl daemon-reload
systemctl restart caddy.service
systemctl enable caddy.service &>/dev/null

# 等待 Caddy Admin API 就绪
info "Waiting for Caddy API..."
api_ready=0
for i in $(seq 1 10); do
    if curl -sf http://127.0.0.1:2019/config/ &>/dev/null; then
        api_ready=1
        break
    fi
    sleep 1
done
[ "$api_ready" = "0" ] && error "Caddy API not responding. Check: journalctl -u caddy --no-pager -n 20"

# 添加 Trojan 用户
curl -sf -X POST -H "Content-Type: application/json" \
    -d "{\"password\": \"$trojan_passwd\"}" \
    http://127.0.0.1:2019/trojan/users/add || error "Failed to add trojan user via API"

# 持久化密码（去重）
echo "$trojan_passwd" >> /etc/caddy/trojan/passwd.txt
sort -u /etc/caddy/trojan/passwd.txt -o /etc/caddy/trojan/passwd.txt
ok "Trojan user added"

# ==================== 等待 SSL 证书 ====================
info "Obtaining SSL certificate (this may take up to 2 minutes)..."
count=0
max_wait=40
until [ -d /etc/caddy/certificates ]; do
    count=$((count + 1))
    if (( count > max_wait )); then
        error "Certificate application failed after $((max_wait * 3))s.\nPlease check:\n  1. TCP ports 80 and 443 are open\n  2. Domain resolves correctly\n  3. journalctl -u caddy --no-pager -n 30"
    fi
    sleep 3
done
ok "SSL certificate obtained"

# ==================== 系统优化（使用独立配置文件） ====================
info "Applying system optimizations..."

# 使用 /etc/sysctl.d/ 目录，便于管理和卸载
cat > /etc/sysctl.d/99-caddy-trojan.conf <<EOF
# Caddy-Trojan system optimizations
fs.file-max = 1048576
fs.inotify.max_user_instances = 8192
net.core.somaxconn = 32768
net.core.netdev_max_backlog = 32768
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 16384 33554432
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65000
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_max_tw_buckets = 6000
net.ipv4.route.gc_timeout = 100
net.ipv4.tcp_syn_retries = 1
net.ipv4.tcp_synack_retries = 1
net.ipv4.tcp_timestamps = 0
net.ipv4.tcp_max_orphans = 32768
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_ecn = 0
net.ipv4.tcp_frto = 0
net.ipv4.tcp_mtu_probing = 0
net.ipv4.tcp_rfc1337 = 0
net.ipv4.tcp_sack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_adv_win_scale = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.conf.all.route_localnet = 1
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.default.forwarding = 1
EOF

# BBR 拥塞控制
modprobe tcp_bbr &>/dev/null || true
if grep -wq bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    echo "net.core.default_qdisc = fq" >> /etc/sysctl.d/99-caddy-trojan.conf
    echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.d/99-caddy-trojan.conf
fi

sysctl --system &>/dev/null

# 使用 limits.d 目录，便于管理和卸载
cat > /etc/security/limits.d/caddy-trojan.conf <<EOF
# Caddy-Trojan limits optimizations
*     soft   nofile    1048576
*     hard   nofile    1048576
*     soft   nproc     1048576
*     hard   nproc     1048576
*     soft   core      1048576
*     hard   core      1048576
*     hard   memlock   unlimited
*     soft   memlock   unlimited
root  soft   nofile    1048576
root  hard   nofile    1048576
root  soft   nproc     1048576
root  hard   nproc     1048576
root  soft   core      1048576
root  hard   core      1048576
root  hard   memlock   unlimited
root  soft   memlock   unlimited
EOF

ok "System optimizations applied (BBR: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 'N/A'))"

# ==================== 验证安装 ====================
info "Verifying installation..."
sleep 2
check_http=$(curl -sL --max-time 10 "https://${nip_domain}" -k 2>/dev/null | head -c 100 || echo "")
if echo "$check_http" | grep -q "It works"; then
    ok "HTTPS verification passed"
else
    warn "HTTPS check inconclusive. Please ensure TCP ports 80 and 443 are open."
    warn "Verify by visiting: https://${nip_domain}"
fi

# ==================== 完成 ====================
clear
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║         EasyTrojan Installed Successfully!                  ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC}  Address  : ${CYAN}${nip_domain}${NC}"
echo -e "${GREEN}║${NC}  Port     : ${CYAN}443${NC}"
echo -e "${GREEN}║${NC}  Password : ${CYAN}${trojan_passwd}${NC}"
echo -e "${GREEN}║${NC}  ALPN     : ${CYAN}h2,http/1.1${NC}"
echo -e "${GREEN}║${NC}  Transport: ${CYAN}websocket${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║${NC}  Manage   : systemctl {start|stop|restart|status} caddy"
echo -e "${GREEN}║${NC}  Logs     : journalctl -u caddy --no-pager -n 50"
echo -e "${GREEN}║${NC}  Config   : /etc/caddy/Caddyfile"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
