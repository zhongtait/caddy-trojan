#!/bin/bash
# EasyTrojan module: system.sh
# shellcheck shell=bash

apply_sysctl_limits() {
    info "Applying system optimizations..."
    cat > /etc/sysctl.d/99-caddy-trojan.conf <<'EOF'
# Caddy-Trojan system optimizations (scoped, reversible)
fs.file-max = 1048576
fs.inotify.max_user_instances = 8192
net.core.somaxconn = 32768
net.core.netdev_max_backlog = 16384
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 16384 16777216
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65000
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_notsent_lowat = 16384
EOF
    modprobe tcp_bbr &>/dev/null || true
    if grep -wq bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        {
            echo "net.core.default_qdisc = fq"
            echo "net.ipv4.tcp_congestion_control = bbr"
        } >> /etc/sysctl.d/99-caddy-trojan.conf
    fi
    sysctl --system &>/dev/null || true

    cat > /etc/security/limits.d/caddy-trojan.conf <<'EOF'
# Caddy-Trojan limits
caddy soft nofile 1048576
caddy hard nofile 1048576
caddy soft nproc  65535
caddy hard nproc  65535
root  soft nofile 1048576
root  hard nofile 1048576
EOF
    ok "System optimizations applied (BBR: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 'N/A'))"
}

ensure_cert_storage() {
    # Caddy with XDG_DATA_HOME=/etc stores ACME data under /etc/caddy
    mkdir -p "${CADDY_DIR}/certificates" "${CADDY_DIR}/acme"
    chown -R caddy:caddy "$CADDY_DIR"
    chmod 700 "$CADDY_DIR"
    # keep parent writable by caddy for renewals
    find "$CADDY_DIR" -type d -exec chmod 700 {} \; 2>/dev/null || true
}

setup_renew_timer() {
    info "Setting up certificate renewal timer..."

    # Safety net for ACME mode; origin/file certs only log remaining validity.
    cat > /usr/local/bin/caddy-cert-maintain <<'EOF'
#!/bin/bash
set -uo pipefail
export XDG_CONFIG_HOME=/etc
export XDG_DATA_HOME=/etc
export HOME=/var/lib/caddy

TLS_MODE_FILE=/etc/caddy/trojan/tls-mode.txt
TLS_CERT_REC=/etc/caddy/trojan/tls-cert.path
ORIGIN_CERT=/etc/caddy/certs/origin.crt

mkdir -p /etc/caddy/certificates /etc/caddy/acme /var/lib/caddy
chown -R caddy:caddy /etc/caddy /var/lib/caddy 2>/dev/null || true
find /etc/caddy -type d -exec chmod 700 {} \; 2>/dev/null || true

mode=auto
if [ -f "$TLS_MODE_FILE" ]; then
  mode=$(tr -d '[:space:]' < "$TLS_MODE_FILE" | tr '[:upper:]' '[:lower:]')
fi

if ! systemctl is-active --quiet caddy; then
  systemctl start caddy || true
  sleep 2
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

CERT_FILE=$(find /etc/caddy/certificates -name '*.crt' -type f 2>/dev/null | head -1 || true)
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
