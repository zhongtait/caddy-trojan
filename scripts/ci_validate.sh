#!/usr/bin/env bash
# Offline / no-node validation for EasyTrojan (scripts + hub).
# Used by GitHub Actions (.github/workflows/ci.yml). Safe to run locally:
#   bash scripts/ci_validate.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GREEN=$'\033[0;32m'
CYAN=$'\033[0;36m'
RED=$'\033[0;31m'
NC=$'\033[0m'
pass() { echo -e "${GREEN}[OK]${NC} $*"; }
info() { echo -e "${CYAN}[INFO]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

info "Root: $ROOT"

# ---------- shell syntax ----------
info "bash -n"
bash -n easytrojan.sh || fail "bash -n easytrojan.sh"
bash -n uninstall.sh || fail "bash -n uninstall.sh"
shopt -s nullglob
mods=(lib/*.sh)
scripts=(scripts/*.sh)
[ "${#mods[@]}" -gt 0 ] || fail "no lib/*.sh found"
for f in "${mods[@]}"; do
  bash -n "$f" || fail "bash -n $f"
done
for f in "${scripts[@]}"; do
  bash -n "$f" || fail "bash -n $f"
done
pass "shell syntax (easytrojan.sh, uninstall.sh, ${#mods[@]} modules, ${#scripts[@]} scripts)"

# ---------- shellcheck static analysis (warning severity) ----------
if command -v shellcheck >/dev/null 2>&1; then
  info "shellcheck --severity=warning"
  shellcheck --severity=warning --shell=bash \
    easytrojan.sh uninstall.sh scripts/*.sh lib/*.sh \
    || fail "shellcheck reported warning-level issues"
  pass "shellcheck clean (warning severity)"
else
  info "shellcheck not installed; skipping static analysis (CI installs it)"
fi

# ---------- module list consistency ----------
info "EASYTROJAN_LIB_MODULES vs lib/"
declared=()
while IFS= read -r module; do
  declared+=("$module")
done < <(
  awk '
    /^EASYTROJAN_LIB_MODULES=\(/ {inarr=1; next}
    inarr && /^\)/ {exit}
    inarr {
      gsub(/[[:space:]]/, "")
      gsub(/"/, "")
      if ($0 != "" && $0 !~ /^#/) print $0
    }
  ' easytrojan.sh
)
[ "${#declared[@]}" -gt 0 ] || fail "could not parse EASYTROJAN_LIB_MODULES from easytrojan.sh"
for m in "${declared[@]}"; do
  [ -f "lib/${m}" ] || fail "declared module missing: lib/${m}"
done
for f in lib/*.sh; do
  base=$(basename "$f")
  found=0
  for m in "${declared[@]}"; do
    if [ "$m" = "$base" ]; then found=1; break; fi
  done
  [ "$found" -eq 1 ] || fail "lib/${base} not listed in EASYTROJAN_LIB_MODULES"
done
pass "modules: ${declared[*]}"

# ---------- release manifest signature policy (offline) ----------
info "release manifest signature policy"
bash scripts/test_release_signature.sh || fail "release manifest signature policy regression"
pass "release manifest signature policy"

# ---------- LF only ----------
info "LF line endings"
has_cr() { LC_ALL=C grep -q $'\r' "$1"; }
for f in easytrojan.sh uninstall.sh hub_server.py lib/*.sh scripts/*.sh tests/test_*.py; do
  [ -f "$f" ] || continue
  if has_cr "$f"; then
    fail "CR/CRLF found in $f (must be LF)"
  fi
done
pass "LF line endings"

# ---------- load modules + usage (no root / no network install) ----------
info "bash easytrojan.sh --help (loads lib/*.sh)"
help_out=$(bash easytrojan.sh --help 2>&1) || fail "easytrojan.sh --help failed: ${help_out}"
echo "$help_out" | grep -qiE 'install|EasyTrojan|Usage' || fail "help output unexpected: ${help_out}"
echo "$help_out" | grep -qi 'hub' || fail "help missing hub command"
pass "modules load; --help works"

# ---------- standalone entry must replace stale installed modules ----------
info "standalone entry refreshes stale installed modules"
bootstrap_tmp=$(mktemp -d)
mock_sha=1111111111111111111111111111111111111111
mkdir -p "${bootstrap_tmp}/entry" "${bootstrap_tmp}/share/lib" \
  "${bootstrap_tmp}/snapshot/caddy-trojan-main/lib" "${bootstrap_tmp}/bin"
cp easytrojan.sh "${bootstrap_tmp}/entry/easytrojan.sh"
cp easytrojan.sh hub_server.py "${bootstrap_tmp}/snapshot/caddy-trojan-main/"
cp lib/*.sh "${bootstrap_tmp}/snapshot/caddy-trojan-main/lib/"
tar -czf "${bootstrap_tmp}/main.tar.gz" -C "${bootstrap_tmp}/snapshot" caddy-trojan-main
for m in "${declared[@]}"; do
  printf '%s\n' 'return 97' > "${bootstrap_tmp}/share/lib/${m}"
done
cat > "${bootstrap_tmp}/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
url="" output=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) output="${2:-}"; shift 2 ;;
    http://*|https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
[ -n "$output" ] || exit 90
case "$url" in
  */commits/main) printf '{\n  "sha": "%s"\n}\n' "$MOCK_REPO_SHA" > "$output" ;;
  */archive/"${MOCK_REPO_SHA}".tar.gz) cp "$MOCK_MAIN_ARCHIVE" "$output" ;;
  */releases/*) exit 91 ;;
  *) exit 92 ;;
esac
EOF
chmod +x "${bootstrap_tmp}/bin/curl"
if ! PATH="${bootstrap_tmp}/bin:${PATH}" \
  MOCK_REPO_SHA="$mock_sha" MOCK_MAIN_ARCHIVE="${bootstrap_tmp}/main.tar.gz" \
  EASYTROJAN_SHARE_DIR="${bootstrap_tmp}/share" \
  bash "${bootstrap_tmp}/entry/easytrojan.sh" --help >/dev/null 2>&1; then
  rm -rf "$bootstrap_tmp"
  fail "standalone entry did not prefer the current repository snapshot"
fi
if ! cmp -s lib/common.sh "${bootstrap_tmp}/share/lib/common.sh" \
  || ! cmp -s lib/install.sh "${bootstrap_tmp}/share/lib/install.sh"; then
  rm -rf "$bootstrap_tmp"
  fail "standalone entry did not refresh the complete module set"
fi
rm -rf "$bootstrap_tmp"
pass "standalone entry refreshes one coherent module snapshot"

# ---------- atomic script bundle activation + config write lock ----------
info "atomic script bundle activation"
deploy_test_root=$(mktemp -d)
mkdir -p "${deploy_test_root}/share/lib" "${deploy_test_root}/bundle/lib" "${deploy_test_root}/bin"
printf 'old-module\n' > "${deploy_test_root}/share/lib/common.sh"
printf 'old-hub\n' > "${deploy_test_root}/share/hub_server.py"
printf 'old-entry\n' > "${deploy_test_root}/bin/easytrojan"
printf 'old-legacy\n' > "${deploy_test_root}/bin/easytrojan.sh"
printf 'new-module\n' > "${deploy_test_root}/bundle/lib/common.sh"
printf 'new-hub\n' > "${deploy_test_root}/bundle/hub_server.py"
printf 'new-entry\n' > "${deploy_test_root}/bundle/easytrojan.sh"
chmod +x "${deploy_test_root}/bundle/easytrojan.sh"
if ! bash -c '
  set -euo pipefail
  SHARE_DIR="$1/share" SCRIPT_BIN="$1/bin/easytrojan" SCRIPT_LEGACY="$1/bin/easytrojan.sh"
  . lib/manage.sh
  deploy_easytrojan_bundle "$1/bundle" "$1/bundle/easytrojan.sh" "" common.sh
  grep -qx "new-module" "$1/share/lib/common.sh"
  grep -qx "new-hub" "$1/share/hub_server.py"
  grep -qx "new-entry" "$1/bin/easytrojan"
  grep -qx "new-entry" "$1/bin/easytrojan.sh"
' _ "$deploy_test_root"; then
  rm -rf "$deploy_test_root"
  fail "atomic script bundle activation did not install the complete bundle"
fi
printf 'old-module\n' > "${deploy_test_root}/share/lib/common.sh"
printf 'old-entry\n' > "${deploy_test_root}/bin/easytrojan"
if bash -c '
  set -euo pipefail
  SHARE_DIR="$1/share" SCRIPT_BIN="$1/bin/easytrojan" SCRIPT_LEGACY="$1/bin/easytrojan.sh"
  . lib/manage.sh
  deploy_easytrojan_bundle "$1/bundle" "$1/missing-entry" "" common.sh
' _ "$deploy_test_root" >/dev/null 2>&1; then
  rm -rf "$deploy_test_root"
  fail "failed bundle activation unexpectedly succeeded"
fi
grep -qx "old-module" "${deploy_test_root}/share/lib/common.sh" \
  || { rm -rf "$deploy_test_root"; fail "failed bundle activation did not restore modules"; }
grep -qx "old-entry" "${deploy_test_root}/bin/easytrojan" \
  || { rm -rf "$deploy_test_root"; fail "failed bundle activation did not restore entry"; }
rm -rf "$deploy_test_root"
pass "script bundle activation is atomic and rollback-safe"

info "signed release is the default update source"
if ! bash -c '
  set -euo pipefail
  . lib/manage.sh
  warn() { :; }
  calls=""
  _easytrojan_fetch_release_snapshot() { calls="${calls} release"; return 1; }
  _easytrojan_fetch_repository_snapshot() { calls="${calls} repository"; return 0; }
  if stage_easytrojan_update_snapshot /tmp/easytrojan-update-test https://example.invalid; then
    exit 1
  fi
  [ "$calls" = " release" ]
  calls=""
  EASYTROJAN_ALLOW_UNSIGNED_RELEASE=1
  stage_easytrojan_update_snapshot /tmp/easytrojan-update-test https://example.invalid
  [ "$calls" = " release repository" ]
'; then
  fail "update source selection did not fail closed before the explicit legacy override"
fi
pass "signed Release is required before legacy repository fallback"

if command -v flock >/dev/null 2>&1; then
  info "concurrent passwd writes"
  lock_test_root=$(mktemp -d)
  if ! bash -c '
    set -euo pipefail
    TROJAN_DIR="$1/trojan" PASSWD_FILE="$1/trojan/passwd.txt" CONFIG_LOCK_FILE="$1/trojan/.config.lock"
    mkdir -p "$TROJAN_DIR"
    . lib/common.sh
    . lib/caddy.sh
    for i in $(seq 1 12); do persist_password "password-$i" & done
    wait
    [ "$(grep -c . "$PASSWD_FILE")" -eq 12 ]
  ' _ "$lock_test_root"; then
    rm -rf "$lock_test_root"
    fail "concurrent passwd writes lost entries"
  fi
  rm -rf "$lock_test_root"
  pass "concurrent passwd writes are serialized"
else
  info "flock unavailable; skipping concurrent passwd write test"
fi

# ---------- deterministic client/link helpers ----------
info "camouflage fallback URL + WebSocket ALPN"
asset_url=$(IT_TOOLS_REPO=CorentinTh/it-tools bash -c \
  '. lib/camouflage.sh; it_tools_direct_asset_url v2024.10.22-7ca5933')
[ "$asset_url" = "https://github.com/CorentinTh/it-tools/releases/download/v2024.10.22-7ca5933/it-tools-2024.10.22-7ca5933.zip" ] \
  || fail "unexpected pinned IT-Tools URL: $asset_url"
safe_entries=$(mktemp)
unsafe_entries=$(mktemp)
printf '%s\n' 'index.html' 'assets/app.js' 'nested/path/file.css' > "$safe_entries"
printf '%s\n' 'index.html' '../escape.txt' > "$unsafe_entries"
if ! bash -c '. lib/camouflage.sh; zip_entries_are_safe "$1"' _ "$safe_entries"; then
  rm -f "$safe_entries" "$unsafe_entries"
  fail "safe camouflage archive entries were rejected"
fi
if bash -c '. lib/camouflage.sh; zip_entries_are_safe "$1"' _ "$unsafe_entries"; then
  rm -f "$safe_entries" "$unsafe_entries"
  fail "unsafe camouflage archive entry was accepted"
fi
rm -f "$safe_entries" "$unsafe_entries"
share_link=$(bash -c \
  'error() { exit 1; }; . lib/common.sh; build_share_link example.com secret-pass ws')
echo "$share_link" | grep -qE 'alpn=http(%2[Ff]|/)1\.1' \
  || fail "WebSocket share link missing alpn=http/1.1: $share_link"
if echo "$share_link" | grep -qE 'alpn=h2(%2[Cc]|,)'; then
  fail "WebSocket share link must not advertise h2 first: $share_link"
fi
share_link_v6=$(bash -c \
  'error() { exit 1; }; . lib/common.sh; build_share_link example.com secret-pass ws 2001:db8::1')
echo "$share_link_v6" | grep -q '@\[2001:db8::1\]:443' \
  || fail "IPv6 share-link authority is not bracketed: $share_link_v6"
if bash -c 'error() { exit 1; }; . lib/common.sh; build_share_link example.com secret-pass ws bad/address' >/dev/null 2>&1; then
  fail "invalid share-link server address was accepted"
fi
if bash -c 'error() { exit 1; }; . lib/common.sh; validate_password_value "$1"' _ $'line1\nline2' >/dev/null 2>&1; then
  fail "password containing a newline was accepted"
fi
pass "pinned camouflage URL and archive paths; validated WS links/passwords"

# ---------- traffic CLI formatting, sorting, and error handling ----------
info "traffic CLI formatting and filtering"
traffic_test_root=$(mktemp -d)
if ! bash -c '
  set -euo pipefail
  test_root=$1
  PASSWD_FILE="${test_root}/passwd.txt"
  REMARKS_DIR="${test_root}/remarks"
  ADMIN_API="http://127.0.0.1:2019"
  require_root() { :; }
  error() { echo -e "[ERROR] $*" >&2; return 1; }
  check_cmd() { command -v "$1" >/dev/null 2>&1; }
  mkdir -p "$REMARKS_DIR"
  printf "%s\n" "secret_password_123#device" > "$PASSWD_FILE"
  printf "%s\n" "Clash-Mac" > "$REMARKS_DIR/74d2e688ae1f873f70155fd54846adc5bfb156ea429c44f44b5fb785"
  # Mock curl to write sample traffic json to -o target
  curl() {
    local out=""
    while [ "$#" -gt 0 ]; do
      if [ "$1" = "-o" ]; then
        out="$2"
        shift 2
      else
        shift
      fi
    done
    if [ -n "$out" ]; then
      printf "%s\n" "[{\"key\":\"74d2e688ae1f873f70155fd54846adc5bfb156ea429c44f44b5fb785\",\"ip\":\"220.181.38.10\",\"target\":\"googlevideo.com:443\",\"up\":1048576,\"down\":10485760},{\"key\":\"74d2e688ae1f873f70155fd54846adc5bfb156ea429c44f44b5fb785\",\"ip\":\"117.136.28.14\",\"target\":\"example.com:443\",\"up\":1024,\"down\":2048}]" > "$out"
    fi
  }
  . lib/manage.sh
  out=$(do_traffic)
  echo "$out" | grep -qF "Clash-Mac"
  echo "$out" | grep -qF "220.181.38.10"
  echo "$out" | grep -qF "googlevideo.com:443"
  echo "$out" | grep -qF "GRAND TOTAL (1 clients, 2 targets):"
  # verify --show-password
  unmask_out=$(do_traffic --show-password)
  echo "$unmask_out" | grep -qF "secret_password_123"
  # verify --flat
  flat_out=$(do_traffic --flat)
  echo "$flat_out" | grep -qF "USER / CLIENT"
  echo "$flat_out" | grep -qF "CLIENT IP"
  # verify --json
  json_out=$(do_traffic --json)
  echo "$json_out" | grep -qF "220.181.38.10"
  # grouped --top limits clients; flat --top limits target rows
  top_out=$(do_traffic --top 1)
  echo "$top_out" | grep -qF "googlevideo.com"
  flat_top_out=$(do_traffic --flat --top 1)
  echo "$flat_top_out" | grep -qF "googlevideo.com"
  ! echo "$flat_top_out" | grep -qF "example.com:443"
' _ "$traffic_test_root"; then
  rm -rf "$traffic_test_root"
  fail "traffic CLI formatting, sorting, or filtering failed"
fi
rm -rf "$traffic_test_root"
pass "traffic CLI supports IP tracking, remarks, grouping, and unmasking"

# ---------- install dependency package mapping ----------
info "install dependency package mapping"
dependency_calls=$(bash -c '
  set -euo pipefail
  . lib/common.sh
  installed="systemctl"
  info() { :; }
  check_cmd() {
    case " $installed " in *" $1 "*) return 0 ;; *) return 1 ;; esac
  }
  install_os_package() {
    printf "%s|%s\n" "$1" "$2"
    case "$1" in
      util-linux) installed="$installed flock" ;;
      iproute2) installed="$installed ip ss" ;;
      passwd) installed="$installed useradd groupadd" ;;
      *) installed="$installed $1" ;;
    esac
  }
  ensure_install_dependencies
') || fail "dependency preflight failed under mocked package installation"
for mapping in \
  'curl|curl' 'tar|tar' 'unzip|unzip' 'openssl|openssl' 'file|file' \
  'util-linux|util-linux' \
  'iproute2|iproute' 'passwd|shadow-utils'; do
  echo "$dependency_calls" | grep -qxF "$mapping" \
    || fail "dependency preflight missed package mapping: $mapping"
done
[ "$(echo "$dependency_calls" | grep -cxF 'iproute2|iproute')" -eq 1 ] \
  || fail "shared iproute dependency should only be installed once"
[ "$(echo "$dependency_calls" | grep -cxF 'passwd|shadow-utils')" -eq 1 ] \
  || fail "shared account-tools dependency should only be installed once"
pass "install preflight covers required Debian/RHEL package mappings"

# ---------- Caddy runtime storage ownership repair ----------
info "Caddy runtime storage ownership repair"
storage_test_root=$(mktemp -d)
if ! bash -c '
  set -euo pipefail
  test_root=$1
  CADDY_DIR="${test_root}/etc/caddy"
  TROJAN_DIR="${CADDY_DIR}/trojan"
  CADDY_DATA_DIR="${test_root}/var/lib/caddy"
  CADDY_DATA_MARKER="${CADDY_DATA_DIR}/.easytrojan-managed"
  ownership_log="${test_root}/chown.log"
  mkdir -p "$TROJAN_DIR" "${CADDY_DATA_DIR}/trojan"
  printf "root-owned-user-record\n" > "${CADDY_DATA_DIR}/trojan/user-hash"
  chown() { printf "%s\n" "$*" >> "$ownership_log"; }
  . lib/system.sh
  ensure_cert_storage
  grep -qxF -- "-R caddy:caddy ${CADDY_DATA_DIR}" "$ownership_log"
  [ "$(tail -n 1 "$ownership_log")" = "root:caddy ${CADDY_DATA_MARKER}" ]
' _ "$storage_test_root"; then
  rm -rf "$storage_test_root"
  fail "Caddy runtime storage ownership was not repaired recursively"
fi
rm -rf "$storage_test_root"
pass "Caddy runtime storage is re-owned recursively before startup"

# ---------- camouflage cleanup must be isolated from the caller ----------
info "camouflage temporary-directory cleanup"
camo_test_root=$(mktemp -d)
if ! bash -c '
  set -euo pipefail
  test_root=$1
  mock_tmp="${test_root}/download"
  WWW_DIR="${test_root}/www"
  CADDY_DIR=$test_root
  IT_TOOLS_VERSION=latest
  unset IT_TOOLS_REPO
  info() { :; }
  ok() { :; }
  warn() { :; }
  check_cmd() { [ "$1" != unzip ]; }
  install_pkg() { :; }
  mktemp() { mkdir -p "$mock_tmp"; printf "%s" "$mock_tmp"; }
  . lib/camouflage.sh
  write_camouflage_site
  [ ! -e "$mock_tmp" ]
  [ -z "$(trap -p RETURN)" ]
  [ -z "$(trap -p EXIT)" ]
  post_cleanup_probe() { :; }
  post_cleanup_probe
' _ "$camo_test_root"; then
  rm -rf "$camo_test_root"
  fail "write_camouflage_site cleanup failed or leaked a trap into its caller"
fi
rm -rf "$camo_test_root"
pass "camouflage cleanup is one-shot and nounset-safe"

# ---------- generated Caddyfile must use WS handler, not raw listener ----------
info "Caddyfile WebSocket-only listener configuration"
caddy_test_root=$(mktemp -d)
mkdir -p "${caddy_test_root}/bin" "${caddy_test_root}/www" "${caddy_test_root}/trojan"
cat > "${caddy_test_root}/bin/caddy" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = validate ]
mkdir -p "${XDG_DATA_HOME}/caddy/trojan"
printf 'validation-side-effect\n' > "${XDG_DATA_HOME}/caddy/trojan/probe"
EOF
chmod +x "${caddy_test_root}/bin/caddy"
if ! bash -c '
  set -euo pipefail
  test_root=$1
  CADDY_DIR=$test_root
  CADDYFILE="${test_root}/Caddyfile"
  CADDY_BIN="${test_root}/bin/caddy"
  CADDY_XDG_DATA_HOME="${test_root}/live-data"
  CADDY_DATA_DIR="${CADDY_XDG_DATA_HOME}/caddy"
  WWW_DIR="${test_root}/www"
  TROJAN_DIR="${test_root}/trojan"
  PASSWD_FILE="${TROJAN_DIR}/passwd.txt"
  DOMAIN_FILE="${TROJAN_DIR}/domain.txt"
  OUTBOUND_IP_PRIORITY_FILE="${TROJAN_DIR}/outbound-ip-priority.txt"
  MANAGED_MARKER="${CADDY_DIR}/.easytrojan-managed"
  HUB_LISTEN=127.0.0.1:2099
  printf "%s\n" secret-pass > "$PASSWD_FILE"
  chown() { :; }
  error() { printf "%s\n" "$*" >&2; exit 1; }
  info() { :; }
  warn() { :; }
  hub_enabled() { return 1; }
  current_outbound_ip_priority() { printf ipv4; }
  tls_directive_line() { :; }
  . lib/caddy.sh
  generate_caddyfile example.com
  [ ! -e "${CADDY_DATA_DIR}/trojan" ]
  grep -q "^[[:space:]]*websocket$" "$CADDYFILE"
  grep -q "^[[:space:]]*memory caddy$" "$CADDYFILE"
  grep -q "^[[:space:]]*no_proxy ipv4$" "$CADDYFILE"
  [ "$(cat "${TROJAN_DIR}/outbound-ip-priority.txt")" = ipv4 ]
  ! grep -q "listener_wrappers" "$CADDYFILE"
  CADDY_HTTPS_PORT=18443 CADDY_HTTP_PORT=18080 CADDY_ADMIN_LISTEN=127.0.0.1:20191 \
    generate_caddyfile example.com
  [ ! -e "${CADDY_DATA_DIR}/trojan" ]
  grep -q "^example.com:18443" "$CADDYFILE"
  grep -q "https_port 18443" "$CADDYFILE"
  grep -q "admin 127.0.0.1:20191" "$CADDYFILE"
  ! grep -q "^:18443, example.com" "$CADDYFILE"
' _ "$caddy_test_root"; then
  rm -rf "$caddy_test_root"
  fail "generated Caddyfile enabled a raw listener or omitted the WebSocket handler"
fi

cat > "${caddy_test_root}/Caddyfile.bak" <<'EOF'
{
    servers :443 {
        listener_wrappers {
            trojan
        }
    }
}
EOF
cat > "${caddy_test_root}/Caddyfile" <<'EOF'
{
    servers :443 {
        protocols h2 h1
    }
}
EOF
if ! bash -c '
  set -euo pipefail
  test_root=$1
  CADDYFILE="${test_root}/Caddyfile"
  CADDY_BIN="${test_root}/bin/caddy"
  calls="${test_root}/systemctl.calls"
  info() { :; }
  warn() { :; }
  chown() { :; }
  systemctl() {
    printf "%s\n" "$*" >> "$calls"
    return 0
  }
  . lib/caddy.sh
  wait_for_admin_api() { return 0; }
  reload_caddy
  grep -qx "is-active --quiet caddy" "$calls"
  grep -qx "restart caddy.service" "$calls"
  ! grep -q "^reload " "$calls"
' _ "$caddy_test_root"; then
  rm -rf "$caddy_test_root"
  fail "legacy Trojan listener removal did not force a full Caddy restart"
fi
rm -rf "$caddy_test_root"
pass "generated Caddyfile validation is storage-isolated; memory+caddy and WS-only routing are preserved"

info "domain-specific certificate lookup"
cert_test_root=$(mktemp -d)
mkdir -p "${cert_test_root}/certificates/acme/other.example.com"
: > "${cert_test_root}/certificates/acme/other.example.com/other.example.com.crt"
if CADDY_DATA_DIR="$cert_test_root" bash -c \
  '. lib/caddy.sh; find_domain_certificate example.com' >/dev/null 2>&1; then
  rm -rf "$cert_test_root"
  fail "certificate lookup accepted an unrelated domain certificate"
fi
mkdir -p "${cert_test_root}/certificates/acme/example.com"
: > "${cert_test_root}/certificates/acme/example.com/example.com.crt"
CADDY_DATA_DIR="$cert_test_root" bash -c \
  '. lib/caddy.sh; find_domain_certificate example.com' >/dev/null \
  || { rm -rf "$cert_test_root"; fail "certificate lookup missed the requested domain"; }
rm -rf "$cert_test_root"
pass "certificate readiness is scoped to the installed domain"

info "BBR install helper"
bbr_test_root=$(mktemp -d)
if ! BBR_SYSCTL_FILE="$bbr_test_root/bbr.conf" \
  CADDY_SYSCTL_BACKUP_FILE="$bbr_test_root/backup" bash -c '
  set -euo pipefail
  qdisc=fq_codel
  congestion=cubic
  check_cmd() { return 0; }
  modprobe() { return 0; }
  sysctl() {
    case "${1:-}:${2:-}" in
      -n:net.ipv4.tcp_available_congestion_control) echo "reno cubic bbr" ;;
      -n:net.core.default_qdisc) echo "$qdisc" ;;
      -n:net.ipv4.tcp_congestion_control) echo "$congestion" ;;
      -w:net.core.default_qdisc=fq) qdisc=fq ;;
      -w:net.ipv4.tcp_congestion_control=bbr) congestion=bbr ;;
      *) return 1 ;;
    esac
  }
  info() { :; }
  warn() { :; }
  ok() { :; }
  . lib/system.sh
  enable_bbr
  grep -q "net.ipv4.tcp_congestion_control = bbr" "$BBR_SYSCTL_FILE" \
    && grep -q "net.core.default_qdisc = fq" "$BBR_SYSCTL_FILE" \
    && ! grep -q "tcp_slow_start_after_idle\|tcp_notsent_lowat" "$BBR_SYSCTL_FILE"
  grep -Fq $'"'"'net.core.default_qdisc\tfq_codel\tfq'"'"' "$CADDY_SYSCTL_BACKUP_FILE"
  grep -Fq $'"'"'net.ipv4.tcp_congestion_control\tcubic\tbbr'"'"' "$CADDY_SYSCTL_BACKUP_FILE"
'; then
  rm -rf "$bbr_test_root"
  fail "BBR helper did not persist the expected configuration"
fi
rm -rf "$bbr_test_root"
pass "BBR helper enables BBR + fq without workload-specific global knobs"

info "sysctl backup managed-target evolution"
sysctl_target_root=$(mktemp -d)
if ! CADDY_SYSCTL_BACKUP_FILE="$sysctl_target_root/backup" bash -c '
  set -euo pipefail
  mock_current=32768
  sysctl() {
    case "${1:-}:${2:-}" in
      -n:net.core.somaxconn) echo "$mock_current" ;;
      *) return 1 ;;
    esac
  }
  warn() { :; }
  . lib/system.sh
  printf "%s\n" \
    "# EasyTrojan sysctl backup v1" \
    "# key<TAB>original<TAB>managed-target" > "$CADDY_SYSCTL_BACKUP_FILE"
  printf "%s\t%s\t%s\n" net.core.somaxconn 4096 32768 >> "$CADDY_SYSCTL_BACKUP_FILE"

  _easytrojan_capture_sysctl_backup "net.core.somaxconn|65536"
  grep -Fqx $'"'"'net.core.somaxconn\t4096\t65536'"'"' "$CADDY_SYSCTL_BACKUP_FILE"
  [ "$(grep -c "^net\\.core\\.somaxconn[[:space:]]" "$CADDY_SYSCTL_BACKUP_FILE")" = 1 ]

  mock_current=49152
  _easytrojan_capture_sysctl_backup "net.core.somaxconn|131072"
  grep -Fqx $'"'"'net.core.somaxconn\t4096\t65536'"'"' "$CADDY_SYSCTL_BACKUP_FILE"
  ! grep -Fq $'"'"'net.core.somaxconn\t4096\t131072'"'"' "$CADDY_SYSCTL_BACKUP_FILE"
'; then
  rm -rf "$sysctl_target_root"
  fail "sysctl backup target evolution lost the original value or administrator boundary"
fi
rm -rf "$sysctl_target_root"
pass "sysctl backup advances only while the previous managed target is still active"

info "dynamic TCP buffer and tcp_mem derivation"
tcp_mem_512m=$(bash -c '. lib/system.sh; _easytrojan_calc_tcp_mem 524288')
[ "$tcp_mem_512m" = "8192 16384 32768" ] || fail "tcp_mem for 512MB RAM expected '8192 16384 32768', got '$tcp_mem_512m'"
buf_512m=$(bash -c '. lib/system.sh; _easytrojan_calc_buf_max 524288')
[ "$buf_512m" = "16777216" ] || fail "buf_max for 512MB RAM expected 16777216 (16MB cap), got '$buf_512m'"
tcp_mem_1g=$(bash -c '. lib/system.sh; _easytrojan_calc_tcp_mem 1048576')
[ "$tcp_mem_1g" = "16384 32768 65536" ] || fail "tcp_mem for 1GB RAM expected '16384 32768 65536', got '$tcp_mem_1g'"
buf_1g=$(bash -c '. lib/system.sh; _easytrojan_calc_buf_max 1048576')
[ "$buf_1g" = "33554432" ] || fail "buf_max for 1GB RAM expected 33554432 (32MB cap), got '$buf_1g'"
buf_4g=$(bash -c '. lib/system.sh; _easytrojan_calc_buf_max 4194304')
[ "$buf_4g" = "39597152" ] || fail "buf_max for 4GB RAM expected 39597152 (BDP target), got '$buf_4g'"
pass "dynamic TCP buffer and tcp_mem calculations"

info "optional sysctl tuning is loaded and verified"
tune_sysctl_root=$(mktemp -d)
tune_sysctl_file="${tune_sysctl_root}/99-caddy-trojan.conf"
if ! CADDY_SYSCTL_FILE="$tune_sysctl_file" \
  CADDY_SYSCTL_BACKUP_FILE="$tune_sysctl_root/backup" \
  SYSCTL_APPLIED_FILE="$tune_sysctl_root/applied" \
  EASYTROJAN_MEM_TOTAL_KB="524288" bash -c '
  set -euo pipefail
  sysctl() {
    case "${1:-}:${2:-}" in
      -p:*) : > "$SYSCTL_APPLIED_FILE" ;;
      -n:net.core.somaxconn) [ -f "$SYSCTL_APPLIED_FILE" ] && echo 32768 || echo 4096 ;;
      -n:net.core.netdev_max_backlog) [ -f "$SYSCTL_APPLIED_FILE" ] && echo 16384 || echo 1000 ;;
      -n:net.core.rmem_max) [ -f "$SYSCTL_APPLIED_FILE" ] && echo 16777216 || echo 4194304 ;;
      -n:net.core.wmem_max) [ -f "$SYSCTL_APPLIED_FILE" ] && echo 16777216 || echo 4194304 ;;
      -n:net.ipv4.tcp_rmem) [ -f "$SYSCTL_APPLIED_FILE" ] \
        && echo "4096 131072 16777216" || echo "4096 131072 6291456" ;;
      -n:net.ipv4.tcp_wmem) [ -f "$SYSCTL_APPLIED_FILE" ] \
        && echo "4096 16384 16777216" || echo "4096 16384 4194304" ;;
      -n:net.ipv4.tcp_mem) [ -f "$SYSCTL_APPLIED_FILE" ] \
        && echo "8192 16384 32768" || echo "4096 8192 16384" ;;
      -n:net.ipv4.tcp_max_syn_backlog) [ -f "$SYSCTL_APPLIED_FILE" ] && echo 8192 || echo 4096 ;;
      -n:net.ipv4.tcp_slow_start_after_idle) [ -f "$SYSCTL_APPLIED_FILE" ] && echo 0 || echo 1 ;;
      -n:net.ipv4.tcp_mtu_probing) [ -f "$SYSCTL_APPLIED_FILE" ] && echo 1 || echo 0 ;;
      -n:net.ipv4.tcp_tw_reuse) [ -f "$SYSCTL_APPLIED_FILE" ] && echo 1 || echo 0 ;;
      -n:net.ipv4.tcp_fin_timeout) [ -f "$SYSCTL_APPLIED_FILE" ] && echo 15 || echo 60 ;;
      -n:net.ipv4.ip_local_port_range) [ -f "$SYSCTL_APPLIED_FILE" ] \
        && echo "1024 65535" || echo "32768 60999" ;;
      *) return 1 ;;
    esac
  }
  info() { :; }
  warn() { :; }
  ok() { :; }
  . lib/system.sh
  apply_sysctl_limits
  apply_sysctl_limits
  grep -q "net.core.somaxconn = 32768" "$CADDY_SYSCTL_FILE"
  grep -q "net.core.netdev_max_backlog = 16384" "$CADDY_SYSCTL_FILE"
  grep -q "net.ipv4.tcp_rmem = 4096 131072 16777216" "$CADDY_SYSCTL_FILE"
  grep -q "net.ipv4.tcp_wmem = 4096 16384 16777216" "$CADDY_SYSCTL_FILE"
  grep -q "net.ipv4.tcp_slow_start_after_idle = 0" "$CADDY_SYSCTL_FILE"
  grep -q "net.ipv4.tcp_mtu_probing = 1" "$CADDY_SYSCTL_FILE"
  grep -q "net.ipv4.tcp_tw_reuse = 1" "$CADDY_SYSCTL_FILE"
  grep -q "net.ipv4.tcp_fin_timeout = 15" "$CADDY_SYSCTL_FILE"
  grep -q "net.ipv4.ip_local_port_range = 1024 65535" "$CADDY_SYSCTL_FILE"
  ! grep -q "tcp_notsent_lowat" "$CADDY_SYSCTL_FILE"
  grep -Fq $'"'"'net.core.somaxconn\t4096\t32768'"'"' "$CADDY_SYSCTL_BACKUP_FILE"
  grep -Fq $'"'"'net.ipv4.tcp_rmem\t4096 131072 6291456\t4096 131072 16777216'"'"' \
    "$CADDY_SYSCTL_BACKUP_FILE"
  grep -Fq $'"'"'net.ipv4.tcp_slow_start_after_idle\t1\t0'"'"' "$CADDY_SYSCTL_BACKUP_FILE"
  grep -Fq $'"'"'net.ipv4.ip_local_port_range\t32768 60999\t1024 65535'"'"' "$CADDY_SYSCTL_BACKUP_FILE"
  [ "$(wc -l < "$CADDY_SYSCTL_BACKUP_FILE" | tr -d "[:space:]")" = 15 ]
'; then
  rm -rf "$tune_sysctl_root"
  fail "optional sysctl tuning did not load and verify successfully"
fi
high_sysctl_root=$(mktemp -d)
if ! CADDY_SYSCTL_FILE="$high_sysctl_root/99-caddy-trojan.conf" \
  CADDY_SYSCTL_BACKUP_FILE="$high_sysctl_root/backup" \
  EASYTROJAN_MEM_TOTAL_KB="524288" \
  bash -c '
  set -euo pipefail
  sysctl() {
    case "${1:-}:${2:-}" in
      -p:*) return 0 ;;
      -n:net.core.somaxconn) echo 65536 ;;
      -n:net.core.netdev_max_backlog) echo 32768 ;;
      -n:net.core.rmem_max) echo 33554432 ;;
      -n:net.core.wmem_max) echo 33554432 ;;
      -n:net.ipv4.tcp_rmem) echo "8192 262144 33554432" ;;
      -n:net.ipv4.tcp_wmem) echo "8192 32768 33554432" ;;
      -n:net.ipv4.tcp_mem) echo "32768 65536 131072" ;;
      -n:net.ipv4.tcp_max_syn_backlog) echo 16384 ;;
      -n:net.ipv4.tcp_slow_start_after_idle) echo 0 ;;
      -n:net.ipv4.tcp_mtu_probing) echo 2 ;;
      -n:net.ipv4.tcp_tw_reuse) echo 2 ;;
      -n:net.ipv4.tcp_fin_timeout) echo 10 ;;
      -n:net.ipv4.ip_local_port_range) echo "1000 65535" ;;
      *) return 1 ;;
    esac
  }
  info() { :; }
  warn() { :; }
  ok() { :; }
  . lib/system.sh
  apply_sysctl_limits
  grep -q "net.core.somaxconn = 65536" "$CADDY_SYSCTL_FILE"
  grep -q "net.core.netdev_max_backlog = 32768" "$CADDY_SYSCTL_FILE"
  grep -q "net.core.rmem_max = 33554432" "$CADDY_SYSCTL_FILE"
  grep -q "net.ipv4.tcp_rmem = 8192 262144 33554432" "$CADDY_SYSCTL_FILE"
  grep -q "net.ipv4.tcp_wmem = 8192 32768 33554432" "$CADDY_SYSCTL_FILE"
  grep -q "net.ipv4.tcp_mem = 32768 65536 131072" "$CADDY_SYSCTL_FILE"
  grep -q "net.ipv4.tcp_max_syn_backlog = 16384" "$CADDY_SYSCTL_FILE"
  grep -q "net.ipv4.tcp_slow_start_after_idle = 0" "$CADDY_SYSCTL_FILE"
  grep -q "net.ipv4.tcp_mtu_probing = 2" "$CADDY_SYSCTL_FILE"
  grep -q "net.ipv4.tcp_tw_reuse = 2" "$CADDY_SYSCTL_FILE"
  grep -q "net.ipv4.tcp_fin_timeout = 10" "$CADDY_SYSCTL_FILE"
  grep -q "net.ipv4.ip_local_port_range = 1000 65535" "$CADDY_SYSCTL_FILE"
'; then
  rm -rf "$tune_sysctl_root" "$high_sysctl_root"
  fail "optional sysctl tuning lowered an existing high host value"
fi
rm -rf "$high_sysctl_root"
if CADDY_SYSCTL_FILE="$tune_sysctl_root/failed.conf" \
  CADDY_SYSCTL_BACKUP_FILE="$tune_sysctl_root/failed-backup" \
  EASYTROJAN_MEM_TOTAL_KB="524288" bash -c '
  set -euo pipefail
  sysctl() {
    case "${1:-}:${2:-}" in
      -p:*) return 1 ;;
      -n:net.core.somaxconn) echo 4096 ;;
      -n:net.core.netdev_max_backlog) echo 1000 ;;
      -n:net.core.rmem_max) echo 4194304 ;;
      -n:net.core.wmem_max) echo 4194304 ;;
      -n:net.ipv4.tcp_rmem) echo "4096 131072 6291456" ;;
      -n:net.ipv4.tcp_wmem) echo "4096 16384 4194304" ;;
      -n:net.ipv4.tcp_mem) echo "4096 8192 16384" ;;
      -n:net.ipv4.tcp_max_syn_backlog) echo 4096 ;;
      -n:net.ipv4.tcp_slow_start_after_idle) echo 1 ;;
      -n:net.ipv4.tcp_mtu_probing) echo 0 ;;
      -n:net.ipv4.tcp_tw_reuse) echo 0 ;;
      -n:net.ipv4.tcp_fin_timeout) echo 60 ;;
      -n:net.ipv4.ip_local_port_range) echo "32768 60999" ;;
      *) return 1 ;;
    esac
  }
  info() { :; }
  warn() { :; }
  ok() { :; }
  . lib/system.sh
  apply_sysctl_limits
' >/dev/null 2>&1; then
  rm -rf "$tune_sysctl_root"
  fail "optional sysctl tuning reported success after a failed load"
fi
rm -rf "$tune_sysctl_root"
pass "optional sysctl tuning fails closed and verifies read-back values"

info "sysctl uninstall rollback preserves administrator changes"
sysctl_rollback_root=$(mktemp -d)
if ! CADDY_SYSCTL_BACKUP_FILE="$sysctl_rollback_root/backup" bash -c '
  set -euo pipefail
  EASYTROJAN_UNINSTALL_SOURCE_ONLY=1 . ./uninstall.sh
  qdisc=fq
  congestion=bbr
  somaxconn=16384
  warnings=""
  sysctl() {
    case "${1:-}:${2:-}" in
      -n:net.core.default_qdisc) echo "$qdisc" ;;
      -n:net.ipv4.tcp_congestion_control) echo "$congestion" ;;
      -n:net.core.somaxconn) echo "$somaxconn" ;;
      -w:net.core.default_qdisc=*) qdisc=${2#*=} ;;
      -w:net.ipv4.tcp_congestion_control=*) congestion=${2#*=} ;;
      -w:net.core.somaxconn=*) somaxconn=${2#*=} ;;
      *) return 1 ;;
    esac
  }
  warn() { warnings="${warnings}${warnings:+|}$*"; }
  ok() { :; }
  printf "%s\n" \
    "# EasyTrojan sysctl backup v1" \
    "# key<TAB>original<TAB>managed-target" > "$CADDY_SYSCTL_BACKUP_FILE"
  printf "%s\t%s\t%s\n" \
    net.core.default_qdisc fq_codel fq \
    net.ipv4.tcp_congestion_control cubic bbr \
    net.core.somaxconn 4096 32768 >> "$CADDY_SYSCTL_BACKUP_FILE"
  restore_easytrojan_sysctls "$CADDY_SYSCTL_BACKUP_FILE"
  [ "$qdisc" = fq_codel ]
  [ "$congestion" = cubic ]
  [ "$somaxconn" = 16384 ]
  [ ! -e "$CADDY_SYSCTL_BACKUP_FILE" ]
  [[ "$warnings" == *"administrator-modified sysctl net.core.somaxconn=16384"* ]]
'; then
  rm -rf "$sysctl_rollback_root"
  fail "sysctl rollback did not restore managed values safely"
fi
if ! CADDY_SYSCTL_BACKUP_FILE="$sysctl_rollback_root/failed-backup" bash -c '
  set -euo pipefail
  EASYTROJAN_UNINSTALL_SOURCE_ONLY=1 . ./uninstall.sh
  sysctl() {
    case "${1:-}:${2:-}" in
      -n:net.core.rmem_max) echo 16777216 ;;
      -w:net.core.rmem_max=*) return 1 ;;
      *) return 1 ;;
    esac
  }
  warn() { :; }
  ok() { :; }
  printf "%s\t%s\t%s\n" net.core.rmem_max 4194304 16777216 > "$CADDY_SYSCTL_BACKUP_FILE"
  if restore_easytrojan_sysctls "$CADDY_SYSCTL_BACKUP_FILE"; then
    exit 1
  fi
  [ -f "$CADDY_SYSCTL_BACKUP_FILE" ]
'; then
  rm -rf "$sysctl_rollback_root"
  fail "failed sysctl rollback did not preserve its recovery snapshot"
fi
rm -rf "$sysctl_rollback_root"
pass "sysctl rollback restores managed values and preserves administrator changes"

# ---------- GOMEMLIMIT derivation (OOM guard for small VPS) ----------
info "GOMEMLIMIT derivation (~75% RAM)"
gml_1g=$(bash -c '. lib/system.sh; derive_gomemlimit_mib 1048576')
[ "$gml_1g" = "768" ] || fail "expected 768 MiB for 1 GiB RAM, got '${gml_1g}'"
gml_zero=$(bash -c '. lib/system.sh; derive_gomemlimit_mib 0')
[ -z "$gml_zero" ] || fail "expected empty GOMEMLIMIT for undetectable RAM, got '${gml_zero}'"
gml_tiny=$(bash -c '. lib/system.sh; derive_gomemlimit_mib 65536')
[ -z "$gml_tiny" ] || fail "expected empty GOMEMLIMIT for tiny RAM, got '${gml_tiny}'"
pass "GOMEMLIMIT derivation: ~75% RAM, skips undetectable/tiny hosts"

info "read-only network doctor"
network_doctor_output=$(bash -c '
  set -euo pipefail
  info() { printf "INFO:%s\n" "$*"; }
  warn() { printf "WARN:%s\n" "$*"; }
  check_cmd() { case "$1" in sysctl|tc|nstat|ss|systemctl) return 0 ;; *) return 1 ;; esac; }
  sysctl() {
    case "${1:-}:${2:-}" in
      -n:net.ipv4.tcp_congestion_control) echo bbr ;;
      -n:net.ipv4.tcp_available_congestion_control) echo "reno cubic bbr" ;;
      -n:net.core.default_qdisc) echo fq ;;
      -n:net.core.somaxconn) echo 32768 ;;
      -n:net.core.netdev_max_backlog) echo 16384 ;;
      -n:net.core.rmem_max|-n:net.core.wmem_max) echo 16777216 ;;
      -n:net.ipv4.tcp_rmem) echo "4096 131072 16777216" ;;
      -n:net.ipv4.tcp_wmem) echo "4096 16384 16777216" ;;
      -n:net.ipv4.tcp_mem) echo "8192 16384 32768" ;;
      -n:net.ipv4.tcp_max_syn_backlog) echo 8192 ;;
      -n:net.ipv4.tcp_slow_start_after_idle) echo 0 ;;
      -n:net.ipv4.tcp_mtu_probing) echo 1 ;;
      -n:net.ipv4.tcp_tw_reuse) echo 1 ;;
      -n:net.ipv4.tcp_fin_timeout) echo 15 ;;
      -n:net.ipv4.ip_local_port_range) echo "1024 65535" ;;
      *) return 1 ;;
    esac
  }
  tc() { printf "qdisc fq 1: root\n Sent 10 bytes 1 pkt\n backlog 0b 0p\n"; }
  nstat() { printf "TcpOutSegs 100 0.0\nTcpRetransSegs 2 0.0\n"; }
  ss() { printf "TCP: 1 (estab 1, closed 0, orphaned 0, timewait 0)\n"; }
  systemctl() { return 1; }
  . lib/system.sh
  doctor_network
') || fail "doctor_network mock execution failed"
echo "$network_doctor_output" | grep -q 'TCP congestion control: bbr' \
  || fail "doctor_network omitted congestion-control output"
echo "$network_doctor_output" | grep -q 'net.ipv4.tcp_mem=8192 16384 32768' \
  || fail "doctor_network omitted tcp_mem output"
echo "$network_doctor_output" | grep -q 'nstat TcpRetransSegs=2' \
  || fail "doctor_network omitted nstat output"
pass "network doctor is read-only and reports kernel/socket counters"

# ---------- python compile ----------
info "python3 -m py_compile hub_server.py"
python3 -m py_compile hub_server.py || fail "py_compile failed"
pass "hub_server.py compiles"

# ---------- --init is the single source of truth for hub state ----------
info "hub_server.py --init creates config + nodes"
INIT_TMP=$(mktemp -d)
EASYTROJAN_HUB_DIR="$INIT_TMP" EASYTROJAN_HUB_LISTEN="127.0.0.1:2099" \
  python3 hub_server.py --init >/dev/null || { rm -rf "$INIT_TMP"; fail "--init failed"; }
{ [ -f "${INIT_TMP}/config.json" ] && [ -f "${INIT_TMP}/nodes.json" ]; } \
  || { rm -rf "$INIT_TMP"; fail "--init did not create state files"; }
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d.get("register_token") and d.get("sub_token")' \
  "${INIT_TMP}/config.json" || { rm -rf "$INIT_TMP"; fail "--init config missing tokens"; }
rm -rf "$INIT_TMP"
pass "hub_server.py --init initializes state"

# ---------- python unit tests (no sockets) ----------
info "python3 -m unittest"
python3 -m unittest discover -s tests -v || fail "python unit tests failed"
pass "python unit tests"

if command -v coverage >/dev/null 2>&1; then
  info "hub_server.py line + branch coverage"
  coverage erase
  coverage run --branch -m unittest discover -s tests >/dev/null \
    || fail "coverage test run failed"
  coverage report --include='hub_server.py' --show-missing --fail-under=100 \
    || fail "hub_server.py line/branch coverage is below 100%"
  pass "hub_server.py has 100% line and branch coverage"
else
  info "coverage is not installed; CI installs it for the release gate"
fi

# ---------- hub smoke (temp dir, ephemeral port, no caddy) ----------
info "hub_server smoke (no caddy / no node install)"
HUB_TMP=$(mktemp -d)
HUB_LOG="${HUB_TMP}/hub.log"
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
export EASYTROJAN_HUB_DIR="$HUB_TMP"
export EASYTROJAN_HUB_LISTEN="127.0.0.1:${PORT}"
python3 hub_server.py >"$HUB_LOG" 2>&1 &
HUB_PID=$!
cleanup() {
  kill "$HUB_PID" 2>/dev/null || true
  wait "$HUB_PID" 2>/dev/null || true
  rm -rf "$HUB_TMP"
}
trap cleanup EXIT

ready=0
for _ in $(seq 1 50); do
  if curl -sf "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
    ready=1
    break
  fi
  if ! kill -0 "$HUB_PID" 2>/dev/null; then
    cat "$HUB_LOG" || true
    fail "hub_server exited early"
  fi
  sleep 0.1
done
[ "$ready" -eq 1 ] || { cat "$HUB_LOG" || true; fail "hub not ready"; }
pass "hub listening on 127.0.0.1:${PORT}"

REG_TOKEN=$(python3 -c 'import json,os; print(json.load(open(os.environ["EASYTROJAN_HUB_DIR"]+"/config.json"))["register_token"])')
SUB_TOKEN=$(python3 -c 'import json,os; print(json.load(open(os.environ["EASYTROJAN_HUB_DIR"]+"/config.json"))["sub_token"])')
[ -n "$REG_TOKEN" ] && [ -n "$SUB_TOKEN" ] || fail "tokens missing"

code=$(curl -s -o "${HUB_TMP}/bad.json" -w "%{http_code}" \
  -X POST -H "Content-Type: application/json" -H "X-Hub-Token: wrong-token-length-xx" \
  -d '{"domain":"a.example","password":"p"}' \
  "http://127.0.0.1:${PORT}/api/register" || true)
[ "$code" = "401" ] || fail "expected 401 for bad register token, got ${code}"
pass "register rejects bad token"

code=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST -H "Content-Type: application/json" -H "X-Hub-Token: wrong-token-length-xx" \
  -d '{broken' "http://127.0.0.1:${PORT}/api/register" || true)
[ "$code" = "401" ] || fail "expected auth before JSON parsing, got ${code}"
pass "register authenticates before reading body"

resp=$(curl -sf -X POST -H "Content-Type: application/json" -H "X-Hub-Token: ${REG_TOKEN}" \
  -d '{"name":"n1","domain":"hk.example.com","password":"secret-pass","server":"hk.example.com","port":443,"transport":"ws"}' \
  "http://127.0.0.1:${PORT}/api/register")
echo "$resp" | grep -qE '"ok"[[:space:]]*:[[:space:]]*true' || fail "register failed: $resp"
pass "register node"

nid=$(printf '%s' "$resp" | python3 -c 'import json,sys; print(json.load(sys.stdin)["node"]["id"])')
renamed=$(curl -sf -X POST -H "Content-Type: application/json" -H "X-Hub-Token: ${REG_TOKEN}" \
  -d "{\"id\":\"${nid}\",\"name\":\"n1-renamed\"}" \
  "http://127.0.0.1:${PORT}/api/rename")
echo "$renamed" | grep -qE '"ok"[[:space:]]*:[[:space:]]*true' || fail "rename failed: $renamed"
renamed_id=$(printf '%s' "$renamed" | python3 -c 'import json,sys; print(json.load(sys.stdin)["node"]["id"])')
[ "$renamed_id" = "$nid" ] || fail "rename changed stable node id: ${nid} -> ${renamed_id}"
pass "rename node through API"

synced=$(curl -sf -X POST -H "Content-Type: application/json" -H "X-Hub-Token: ${REG_TOKEN}" \
  -d '{"domain":"hk.example.com","server":"hk.example.com","nodes":[{"name":"n1-synced","password":"secret-pass","server":"hk.example.com","port":443,"transport":"ws"}]}' \
  "http://127.0.0.1:${PORT}/api/sync")
echo "$synced" | grep -qE '"count"[[:space:]]*:[[:space:]]*1' || fail "atomic sync failed: $synced"
synced_id=$(curl -sf -H "X-Hub-Token: ${REG_TOKEN}" "http://127.0.0.1:${PORT}/api/nodes" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["nodes"][0]["id"])')
[ "$synced_id" = "$nid" ] || fail "atomic sync changed stable node id: ${nid} -> ${synced_id}"
pass "atomic domain sync preserves stable node id"

# Exercise the large-batch wire format with an expanded JSON body beyond the
# ordinary mutation endpoint's 64 KiB cap. A small follow-up sync also verifies
# that replacement remains atomic at batch granularity.
python3 - "${HUB_TMP}/large-sync.json.gz" <<'PY'
import gzip, json, sys
payload = {
    "domain": "hk.example.com",
    "server": "hk.example.com",
    "nodes": [
        {
            "name": f"n-{i}", "password": f"secret-pass-{i}",
            "server": "hk.example.com", "port": 443, "transport": "ws",
        }
        for i in range(1600)
    ],
}
raw = json.dumps(payload, separators=(",", ":")).encode()
assert len(raw) > 64 * 1024
with open(sys.argv[1], "wb") as target:
    with gzip.GzipFile(filename="", fileobj=target, mode="wb", mtime=0) as out:
        out.write(raw)
PY
large_synced=$(curl -sf -X POST -H "Content-Type: application/json" -H "Content-Encoding: gzip" \
  -H "X-Hub-Token: ${REG_TOKEN}" --data-binary "@${HUB_TMP}/large-sync.json.gz" \
  "http://127.0.0.1:${PORT}/api/sync")
echo "$large_synced" | grep -qE '"count"[[:space:]]*:[[:space:]]*1600' \
  || fail "large compressed sync failed: $large_synced"
python3 - "${HUB_TMP}/sync-passwd.txt" <<'PY'
import sys
with open(sys.argv[1], "w", encoding="utf-8") as out:
    for i in range(1600):
        out.write(f"client-password-{i}\n")
PY
if ! PASSWD_FILE="${HUB_TMP}/sync-passwd.txt" TROJAN_DIR="$HUB_TMP" SYNC_TOKEN="$REG_TOKEN" \
  bash -c '. lib/common.sh; . lib/hub.sh; hub_sync_domain "$1" "$SYNC_TOKEN" "client" "hk.example.com" "hk.example.com" 443 ws' \
  _ "http://127.0.0.1:${PORT}"; then
  fail "hub_sync_domain gzip client request failed"
fi
client_count=$(curl -sf -H "X-Hub-Token: ${REG_TOKEN}" "http://127.0.0.1:${PORT}/api/nodes" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["count"])')
[ "$client_count" = "1600" ] || fail "hub_sync_domain replaced unexpected node count: $client_count"
synced=$(curl -sf -X POST -H "Content-Type: application/json" -H "X-Hub-Token: ${REG_TOKEN}" \
  -d '{"domain":"hk.example.com","server":"hk.example.com","nodes":[{"name":"n1-synced","password":"secret-pass","server":"hk.example.com","port":443,"transport":"ws"}]}' \
  "http://127.0.0.1:${PORT}/api/sync")
echo "$synced" | grep -qE '"count"[[:space:]]*:[[:space:]]*1' \
  || fail "small sync after large batch failed: $synced"
pass "compressed Hub sync accepts expanded batches larger than 64 KiB"

sub=$(curl -sf "http://127.0.0.1:${PORT}/sub/${SUB_TOKEN}")
decoded=$(printf '%s' "$sub" | python3 -c 'import sys,base64; print(base64.b64decode(sys.stdin.read()).decode())')
echo "$decoded" | grep -q 'trojan://' || fail "subscription missing trojan:// : $decoded"
echo "$decoded" | grep -q 'hk.example.com' || fail "subscription missing domain: $decoded"
echo "$decoded" | grep -qE 'alpn=http(%2[Ff]|/)1\.1' || fail "subscription missing alpn=http/1.1: $decoded"
if echo "$decoded" | grep -qE 'alpn=h2(%2[Cc]|,)'; then
  fail "WebSocket subscription must not advertise h2 first: $decoded"
fi
pass "subscription base64 -> trojan link"

sub2=$(curl -sf "http://127.0.0.1:${PORT}/sub/${SUB_TOKEN}?server=1.2.3.4&port=2053")
decoded2=$(printf '%s' "$sub2" | python3 -c 'import sys,base64; print(base64.b64decode(sys.stdin.read()).decode())')
echo "$decoded2" | grep -q '@1.2.3.4:2053' || fail "preferred IP rewrite failed: $decoded2"
echo "$decoded2" | grep -qE 'sni=hk(\.|%2[Ee])example(\.|%2[Ee])com' || fail "sni should stay domain: $decoded2"
pass "preferred IP rewrite (?server=&port=)"

un=$(curl -sf -X POST -H "Content-Type: application/json" -H "X-Hub-Token: ${REG_TOKEN}" \
  -d '{"domain":"hk.example.com","password":"secret-pass"}' \
  "http://127.0.0.1:${PORT}/api/unregister")
echo "$un" | grep -qE '"ok"[[:space:]]*:[[:space:]]*true' || fail "unregister not ok: $un"
echo "$un" | grep -qE '"removed"[[:space:]]*:[[:space:]]*[1-9]' || fail "unregister removed count: $un"
sub3=$(curl -sf "http://127.0.0.1:${PORT}/sub/${SUB_TOKEN}")
decoded3=$(printf '%s' "$sub3" | python3 -c 'import sys,base64; raw=sys.stdin.read(); print(base64.b64decode(raw).decode() if raw.strip() else "")')
if echo "$decoded3" | grep -q 'trojan://'; then
  fail "node still present after unregister: $decoded3"
fi
pass "unregister clears subscription"

code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT}/sub/not-a-valid-token-xxx" || true)
[ "$code" = "401" ] || fail "expected 401 for bad sub token, got ${code}"
pass "subscription rejects bad token"

cc=$(curl -sI "http://127.0.0.1:${PORT}/sub/${SUB_TOKEN}" | tr -d '\r' | awk -F': ' 'tolower($1)=="cache-control"{print tolower($2)}')
echo "$cc" | grep -q 'no-store' || fail "sub missing Cache-Control no-store: $cc"
pass "subscription Cache-Control no-store"

# ---------- hub input limits ----------
code=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST -H "Content-Type: application/json" -H "X-Hub-Token: ${REG_TOKEN}" \
  -d '{"domain":"bad.example.com","password":"secret-pass","port":70000}' \
  "http://127.0.0.1:${PORT}/api/register" || true)
[ "$code" = "400" ] || fail "expected 400 for invalid port, got ${code}"
pass "register rejects invalid port"

python3 -c 'import json,sys; json.dump({"domain":"large.example.com","password":"x"*70000},open(sys.argv[1],"w"))' "${HUB_TMP}/large.json"
code=$(curl -s -o /dev/null -w "%{http_code}" \
  -X POST -H "Content-Type: application/json" -H "X-Hub-Token: ${REG_TOKEN}" \
  --data-binary "@${HUB_TMP}/large.json" "http://127.0.0.1:${PORT}/api/register" || true)
[ "$code" = "413" ] || fail "expected 413 for oversized request, got ${code}"
pass "register limits request body"

# ---------- concurrent writes ----------
info "hub concurrent registration"
pids=()
for i in $(seq 1 25); do
  curl -sf -X POST -H "Content-Type: application/json" -H "X-Hub-Token: ${REG_TOKEN}" \
    -d "{\"name\":\"n${i}\",\"domain\":\"n${i}.example.com\",\"password\":\"secret-pass-${i}\"}" \
    "http://127.0.0.1:${PORT}/api/register" >"${HUB_TMP}/concurrent-${i}.json" &
  pids+=("$!")
done
for pid in "${pids[@]}"; do
  wait "$pid" || fail "concurrent registration request failed (pid=${pid})"
done
node_count=$(curl -sf -H "X-Hub-Token: ${REG_TOKEN}" "http://127.0.0.1:${PORT}/api/nodes" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["count"])')
[ "$node_count" = "25" ] || fail "concurrent registration lost nodes: expected 25, got ${node_count}"
pass "concurrent registration keeps all nodes"

# ---------- http_send_json: secret-safe curl helper (no token/body in argv) ----------
info "http_send_json keeps token + body out of argv"
hs_get=$(bash -c '. lib/common.sh; http_send_json GET "http://127.0.0.1:'"${PORT}"'/api/nodes" "'"${REG_TOKEN}"'" "" -sf') \
  || fail "http_send_json GET failed"
echo "$hs_get" | python3 -c 'import json,sys; assert "count" in json.load(sys.stdin)' \
  || fail "http_send_json GET returned unexpected body"
hs_code=$(bash -c '. lib/common.sh; http_send_json GET "http://127.0.0.1:'"${PORT}"'/api/nodes" "wrong-token-xxxxxxxx" "" -s -o /dev/null -w "%{http_code}"')
[ "$hs_code" = "401" ] || fail "http_send_json bad token expected 401, got ${hs_code}"
hs_reg=$(bash -c '. lib/common.sh; http_send_json POST "http://127.0.0.1:'"${PORT}"'/api/register" "'"${REG_TOKEN}"'" "{\"domain\":\"hs.example.com\",\"password\":\"secret-pass-hs\"}" -sf')
echo "$hs_reg" | grep -qE '"ok"[[:space:]]*:[[:space:]]*true' || fail "http_send_json POST register failed: ${hs_reg}"
pass "http_send_json sends token header + JSON body correctly"

# ---------- semantic state validation ----------
cp "${HUB_TMP}/nodes.json" "${HUB_TMP}/nodes.valid.json"
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["nodes"][0]["password"]=42; json.dump(d,open(p,"w"))' \
  "${HUB_TMP}/nodes.json"
code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT}/sub/${SUB_TOKEN}" || true)
[ "$code" = "503" ] || fail "expected 503 for invalid node field, got ${code}"
pass "invalid node fields fail closed"
cp "${HUB_TMP}/nodes.valid.json" "${HUB_TMP}/nodes.json"

cp "${HUB_TMP}/config.json" "${HUB_TMP}/config.valid.json"
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["register_token"]=42; json.dump(d,open(p,"w"))' \
  "${HUB_TMP}/config.json"
code=$(curl -s -o /dev/null -w "%{http_code}" -H "X-Hub-Token: ${REG_TOKEN}" \
  "http://127.0.0.1:${PORT}/api/nodes" || true)
[ "$code" = "503" ] || fail "expected 503 for invalid config field, got ${code}"
pass "invalid config fields fail closed"
cp "${HUB_TMP}/config.valid.json" "${HUB_TMP}/config.json"

python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["register_token"]=""; json.dump(d,open(p,"w"))' \
  "${HUB_TMP}/config.json"
code=$(curl -s -o /dev/null -w "%{http_code}" -H "X-Hub-Token: ${REG_TOKEN}" \
  "http://127.0.0.1:${PORT}/api/nodes" || true)
[ "$code" = "503" ] || fail "expected 503 for empty persisted token, got ${code}"
pass "empty persisted tokens are not silently rotated"
cp "${HUB_TMP}/config.valid.json" "${HUB_TMP}/config.json"

# ---------- corrupt state must fail closed without leaking paths ----------
printf '{broken\n' > "${HUB_TMP}/nodes.json"
code=$(curl -s -o "${HUB_TMP}/err.json" -w "%{http_code}" "http://127.0.0.1:${PORT}/health" || true)
[ "$code" = "503" ] || fail "expected 503 for corrupt node state, got ${code}"
grep -q 'hub state unavailable' "${HUB_TMP}/err.json" || fail "503 body should be generic: $(cat "${HUB_TMP}/err.json")"
if grep -q "$HUB_TMP" "${HUB_TMP}/err.json"; then
  fail "503 body leaked a server file path: $(cat "${HUB_TMP}/err.json")"
fi
pass "corrupt node state fails closed with a generic message"

info "all checks passed (no node install)"
pass "ci_validate done"
