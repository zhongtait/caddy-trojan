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

write_caddy_unit() {
    cat > /etc/systemd/system/caddy.service <<EOF
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
Environment=XDG_CONFIG_HOME=/etc XDG_DATA_HOME=/var/lib HOME=/var/lib/caddy
ExecStart=${CADDY_BIN} run --environ --config ${CADDYFILE}
ExecReload=${CADDY_BIN} reload --config ${CADDYFILE} --force
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=/var/lib/caddy
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
    # Keep runtime/ACME state writable by Caddy, while configuration stays root-owned.
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
    chown caddy:caddy "$data_dir" "$data_dir/certificates" "$data_dir/acme" 2>/dev/null || true
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
