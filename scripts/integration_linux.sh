#!/usr/bin/env bash
# Real Caddy/systemd integration test for a disposable Linux CI runner.
# Module configuration variables are consumed by the sourced EasyTrojan files.
# shellcheck disable=SC2034

set -euo pipefail

log() {
    printf '[integration] %s\n' "$*"
}

die() {
    printf '[integration] ERROR: %s\n' "$*" >&2
    exit 1
}

[ "${EASYTROJAN_INTEGRATION_TEST:-}" = "1" ] \
    || die "refusing to modify systemd without EASYTROJAN_INTEGRATION_TEST=1"
if [ "${CI:-}" != "true" ] && [ "${EASYTROJAN_ALLOW_LOCAL_INTEGRATION:-}" != "1" ]; then
    die "integration test is restricted to CI (set EASYTROJAN_ALLOW_LOCAL_INTEGRATION=1 for a disposable VM)"
fi
[ "$(id -u)" -eq 0 ] || die "run this test as root on a disposable Linux host"
[ "$(ps -p 1 -o comm= 2>/dev/null | tr -d '[:space:]')" = "systemd" ] \
    || die "PID 1 is not systemd"

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
caddy_source="${CADDY_UNDER_TEST:-}"
[ -n "$caddy_source" ] && [ -x "$caddy_source" ] \
    || die "CADDY_UNDER_TEST must point to an executable Caddy binary"

for command_name in curl openssl ss systemctl systemd-analyze journalctl getent groupadd useradd userdel groupdel install; do
    command -v "$command_name" >/dev/null 2>&1 \
        || die "required command is unavailable: $command_name"
done

unit_name="easytrojan-integration-caddy.service"
unit_file="/run/systemd/system/${unit_name}"
if [ -e "$unit_file" ] || systemctl cat "$unit_name" >/dev/null 2>&1; then
    die "integration unit already exists: $unit_name"
fi

https_port="${EASYTROJAN_TEST_HTTPS_PORT:-18443}"
http_port="${EASYTROJAN_TEST_HTTP_PORT:-18080}"
admin_port="${EASYTROJAN_TEST_ADMIN_PORT:-20191}"
for port in "$https_port" "$http_port" "$admin_port"; do
    case "$port" in
        ''|*[!0-9]*) die "invalid integration port: $port" ;;
    esac
    [ "$port" -ge 1024 ] && [ "$port" -le 65535 ] \
        || die "integration ports must be between 1024 and 65535: $port"
    listening_ports=$(ss -Hltn | awk '{ print $4 }')
    if grep -Eq ":${port}$" <<<"$listening_ports"; then
        die "integration port is already in use: $port"
    fi
done

config_root=$(mktemp -d /etc/easytrojan-integration.XXXXXX)
data_parent=$(mktemp -d /var/lib/easytrojan-integration.XXXXXX)
binary_root=$(mktemp -d /usr/local/lib/easytrojan-integration.XXXXXX)
created_caddy_user=0
created_caddy_group=0

cleanup() {
    local rc=$?
    set +e
    if [ "$rc" -ne 0 ]; then
        journalctl -u "$unit_name" --no-pager -n 100 >&2
        systemctl status "$unit_name" --no-pager >&2
    fi
    systemctl stop "$unit_name" >/dev/null 2>&1
    systemctl reset-failed "$unit_name" >/dev/null 2>&1
    rm -f -- "$unit_file"
    systemctl daemon-reload >/dev/null 2>&1
    rm -rf -- "$config_root" "$data_parent" "$binary_root"
    if [ "$created_caddy_user" -eq 1 ]; then
        userdel caddy >/dev/null 2>&1
    fi
    if [ "$created_caddy_group" -eq 1 ]; then
        groupdel caddy >/dev/null 2>&1
    fi
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

if ! getent group caddy >/dev/null 2>&1; then
    groupadd --system caddy
    created_caddy_group=1
fi
if ! id caddy >/dev/null 2>&1; then
    useradd --system -g caddy -s "$(command -v nologin || printf /usr/sbin/nologin)" \
        -d "$data_parent/caddy" -M caddy
    created_caddy_user=1
fi

# mktemp -d defaults to 0700. Grant only the service user access to the
# disposable data tree and make the test binary traversable by caddy.
chown caddy:caddy "$data_parent"
chmod 0750 "$data_parent"
chmod 0755 "$binary_root"

CADDY_BIN="${binary_root}/caddy"
install -m 0755 "$caddy_source" "$CADDY_BIN"
module_list=$("$CADDY_BIN" list-modules)
grep -qi trojan <<<"$module_list" \
    || die "Caddy binary does not include a Trojan module"

CADDY_DIR="$config_root/caddy"
CADDYFILE="$CADDY_DIR/Caddyfile"
TROJAN_DIR="$CADDY_DIR/trojan"
PASSWD_FILE="$TROJAN_DIR/passwd.txt"
CONFIG_LOCK_FILE="$TROJAN_DIR/.config.lock"
DOMAIN_FILE="$TROJAN_DIR/domain.txt"
OUTBOUND_IP_PRIORITY_FILE="$TROJAN_DIR/outbound-ip-priority.txt"
TLS_MODE_FILE="$TROJAN_DIR/tls-mode.txt"
TLS_CERT_FILE_REC="$TROJAN_DIR/tls-cert.path"
TLS_KEY_FILE_REC="$TROJAN_DIR/tls-key.path"
ORIGIN_CERT_DIR="$CADDY_DIR/certs"
ORIGIN_CERT_DEFAULT="$ORIGIN_CERT_DIR/origin.crt"
ORIGIN_KEY_DEFAULT="$ORIGIN_CERT_DIR/origin.key"
MANAGED_MARKER="$CADDY_DIR/.easytrojan-managed"
WWW_DIR="$CADDY_DIR/www"
CADDY_XDG_CONFIG_HOME="$config_root/xdg-config"
CADDY_XDG_DATA_HOME="$data_parent"
CADDY_DATA_DIR="$data_parent/caddy"
CADDY_DATA_MARKER="$CADDY_DATA_DIR/.easytrojan-managed"
CADDY_UNIT_FILE="$unit_file"
CADDY_HTTPS_PORT="$https_port"
CADDY_HTTP_PORT="$http_port"
CADDY_ADMIN_LISTEN="127.0.0.1:${admin_port}"
ADMIN_API="http://127.0.0.1:${admin_port}"
HUB_LISTEN="127.0.0.1:2099"
test_domain="integration.easytrojan.invalid"

info() { log "$*"; }
warn() { log "WARN: $*"; }
ok() { log "$*"; }
error() { die "$*"; }
check_cmd() { command -v "$1" >/dev/null 2>&1; }
hub_enabled() { return 1; }

# shellcheck source=../lib/common.sh
. "$repo_root/lib/common.sh"
# shellcheck source=../lib/tls.sh
. "$repo_root/lib/tls.sh"
# shellcheck source=../lib/caddy.sh
. "$repo_root/lib/caddy.sh"
# shellcheck source=../lib/system.sh
. "$repo_root/lib/system.sh"

mkdir -p "$ORIGIN_CERT_DIR" "$WWW_DIR" "$TROJAN_DIR" \
    "$CADDY_XDG_CONFIG_HOME" "$CADDY_DATA_DIR"
printf '<!doctype html><title>EasyTrojan integration</title><p>integration-v1</p>\n' \
    > "$WWW_DIR/index.html"
mkdir -p "$WWW_DIR/.well-known/acme-challenge"
printf 'integration-http-v1\n' > "$WWW_DIR/.well-known/acme-challenge/health"
openssl req -x509 -newkey rsa:2048 -nodes -days 7 \
    -subj "/CN=${test_domain}" \
    -addext "subjectAltName=DNS:${test_domain}" \
    -keyout "$ORIGIN_KEY_DEFAULT" -out "$ORIGIN_CERT_DEFAULT" >/dev/null 2>&1
chown -R root:caddy "$config_root"
chmod 0750 "$config_root" "$CADDY_DIR" "$TROJAN_DIR" "$WWW_DIR" "$ORIGIN_CERT_DIR"
chmod 0640 "$ORIGIN_CERT_DEFAULT" "$ORIGIN_KEY_DEFAULT" "$WWW_DIR/index.html"

ensure_cert_storage
persist_tls_config origin "$ORIGIN_CERT_DEFAULT" "$ORIGIN_KEY_DEFAULT"
persist_password integration-initial-password
generate_caddyfile "$test_domain"

log "validating generated Caddyfile with the real plugin binary"
validate_caddy_config "$CADDYFILE"
[ ! -e "$CADDY_DATA_DIR/trojan" ] \
    || die "Caddyfile validation mutated the live Caddy storage"
grep -q "admin 127.0.0.1:${admin_port}" "$CADDYFILE" \
    || die "generated config did not use the isolated Admin API port"
grep -q "servers :${https_port}" "$CADDYFILE" \
    || die "generated config did not use the isolated HTTPS port"
grep -q '^[[:space:]]*memory caddy$' "$CADDYFILE" \
    || die "generated config did not enable the memory+caddy upstream"

write_caddy_unit
systemd-analyze verify "$unit_file"
grep -q '^Type=notify$' "$unit_file" || die "systemd unit lost Type=notify"
grep -q '^User=caddy$' "$unit_file" || die "systemd unit lost its service user"
grep -q '^NoNewPrivileges=true$' "$unit_file" || die "systemd hardening is missing"
grep -Fq "ExecReload=${CADDY_BIN} reload --config ${CADDYFILE} --force" "$unit_file" \
    || die "systemd unit has an unexpected reload command"
grep -Fq "ReadWritePaths=${CADDY_DATA_DIR}" "$unit_file" \
    || die "systemd unit does not grant access to its isolated data directory"

log "starting the isolated systemd service"
systemctl daemon-reload
systemctl start "$unit_name"
systemctl is-active --quiet "$unit_name" || die "Caddy service is not active"
wait_for_admin_api || die "Caddy Admin API did not become healthy"

http_body=$(curl -fsS "http://127.0.0.1:${http_port}/.well-known/acme-challenge/health")
grep -q integration-http-v1 <<<"$http_body" || die "HTTP challenge endpoint is unhealthy"
site_url="https://${test_domain}:${https_port}/"
site_body=$(curl -kfsS --http1.1 --resolve "${test_domain}:${https_port}:127.0.0.1" "$site_url")
grep -q integration-v1 <<<"$site_body" || die "HTTPS camouflage endpoint is unhealthy"
admin_config=$(curl -fsS "${ADMIN_API}/config/")
grep -q integration-initial-password <<<"$admin_config" \
    || die "running Caddy config is missing the initial Trojan user"

dynamic_keys_file="$config_root/dynamic-user-keys.txt"
: > "$dynamic_keys_file"
dynamic_pids=()
for index in $(seq 1 32); do
    dynamic_password="integration-persisted-password-${index}"
    dynamic_key=$(printf '%s' "$dynamic_password" | openssl dgst -sha224 | awk '{print $NF}')
    printf '%s\n' "$dynamic_key" >> "$dynamic_keys_file"
    curl -fsS -X POST -H 'Content-Type: application/json' \
        --data "{\"password\":\"${dynamic_password}\"}" \
        "${ADMIN_API}/trojan/users/add" >/dev/null &
    dynamic_pids+=("$!")
done
dynamic_add_failed=0
for dynamic_pid in "${dynamic_pids[@]}"; do
    wait "$dynamic_pid" || dynamic_add_failed=1
done
[ "$dynamic_add_failed" -eq 0 ] || die "one or more dynamic Trojan users could not be added"
dynamic_key=$(tail -n 1 "$dynamic_keys_file")
dynamic_ready=0
for _ in $(seq 1 20); do
    if curl -fsS "${ADMIN_API}/trojan/users" | grep -q "$dynamic_key"; then
        dynamic_ready=1
        break
    fi
    sleep 0.1
done
[ "$dynamic_ready" -eq 1 ] || die "memory upstream did not expose the dynamically added user"

log "restarting Caddy to verify memory+caddy persistence"
systemctl restart "$unit_name"
wait_for_admin_api || die "Caddy Admin API did not recover after restart"
dynamic_users=$(curl -fsS "${ADMIN_API}/trojan/users")
while IFS= read -r dynamic_key; do
    grep -q "$dynamic_key" <<<"$dynamic_users" \
        || die "dynamically added Trojan user was not restored from Caddy storage"
done < "$dynamic_keys_file"

pid_before=$(systemctl show "$unit_name" --property MainPID --value)
[ -n "$pid_before" ] && [ "$pid_before" -gt 0 ] || die "Caddy has no MainPID"
persist_password integration-reload-password
generate_caddyfile "$test_domain"

log "reloading through the generated systemd ExecReload command"
systemctl reload "$unit_name"
wait_for_admin_api || die "Caddy Admin API did not recover after reload"
pid_after=$(systemctl show "$unit_name" --property MainPID --value)
[ "$pid_after" = "$pid_before" ] || die "reload unexpectedly replaced the Caddy process"
admin_config=$(curl -fsS "${ADMIN_API}/config/")
grep -q integration-reload-password <<<"$admin_config" \
    || die "reloaded Caddy config is missing the added Trojan user"
site_body=$(curl -kfsS --http1.1 --resolve "${test_domain}:${https_port}:127.0.0.1" "$site_url")
grep -q integration-v1 <<<"$site_body" || die "HTTPS endpoint failed after reload"

log "real Linux + systemd + Caddy validation passed"
