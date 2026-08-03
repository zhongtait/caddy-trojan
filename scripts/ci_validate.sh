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
[ "${#mods[@]}" -gt 0 ] || fail "no lib/*.sh found"
for f in "${mods[@]}"; do
  bash -n "$f" || fail "bash -n $f"
done
pass "shell syntax (easytrojan.sh, uninstall.sh, ${#mods[@]} modules)"

# ---------- shellcheck static analysis (warning severity) ----------
if command -v shellcheck >/dev/null 2>&1; then
  info "shellcheck --severity=warning"
  shellcheck --severity=warning --shell=bash \
    easytrojan.sh uninstall.sh scripts/ci_validate.sh lib/*.sh \
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

# ---------- LF only ----------
info "LF line endings"
has_cr() { LC_ALL=C grep -q $'\r' "$1"; }
for f in easytrojan.sh uninstall.sh hub_server.py lib/*.sh scripts/ci_validate.sh tests/test_*.py; do
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
pass "pinned camouflage URL and archive paths; WebSocket ALPN=http/1.1"

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
      iproute2) installed="$installed ip ss" ;;
      passwd) installed="$installed useradd groupadd" ;;
      *) installed="$installed $1" ;;
    esac
  }
  ensure_install_dependencies
') || fail "dependency preflight failed under mocked package installation"
for mapping in \
  'curl|curl' 'tar|tar' 'unzip|unzip' 'openssl|openssl' 'file|file' \
  'iproute2|iproute' 'passwd|shadow-utils'; do
  echo "$dependency_calls" | grep -qxF "$mapping" \
    || fail "dependency preflight missed package mapping: $mapping"
done
[ "$(echo "$dependency_calls" | grep -cxF 'iproute2|iproute')" -eq 1 ] \
  || fail "shared iproute dependency should only be installed once"
[ "$(echo "$dependency_calls" | grep -cxF 'passwd|shadow-utils')" -eq 1 ] \
  || fail "shared account-tools dependency should only be installed once"
pass "install preflight covers required Debian/RHEL package mappings"

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
EOF
chmod +x "${caddy_test_root}/bin/caddy"
if ! bash -c '
  set -euo pipefail
  test_root=$1
  CADDY_DIR=$test_root
  CADDYFILE="${test_root}/Caddyfile"
  CADDY_BIN="${test_root}/bin/caddy"
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
  grep -q "^[[:space:]]*websocket$" "$CADDYFILE"
  grep -q "^[[:space:]]*no_proxy ipv4$" "$CADDYFILE"
  [ "$(cat "${TROJAN_DIR}/outbound-ip-priority.txt")" = ipv4 ]
  ! grep -q "listener_wrappers" "$CADDYFILE"
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
pass "generated Caddyfile is WS-only; legacy listener migration forces restart"

info "BBR install helper"
bbr_test_file=$(mktemp)
if ! BBR_SYSCTL_FILE="$bbr_test_file" bash -c '
  check_cmd() { return 0; }
  modprobe() { return 0; }
  sysctl() {
    case "$*" in
      "-n net.ipv4.tcp_available_congestion_control") echo "reno cubic bbr" ;;
      "-n net.ipv4.tcp_congestion_control") echo "bbr" ;;
      -w\ *) return 0 ;;
      *) return 1 ;;
    esac
  }
  info() { :; }
  warn() { :; }
  ok() { :; }
  . lib/system.sh
  enable_bbr
  grep -q "net.ipv4.tcp_congestion_control = bbr" "$BBR_SYSCTL_FILE" \
    && grep -q "net.ipv4.tcp_slow_start_after_idle = 0" "$BBR_SYSCTL_FILE" \
    && grep -q "net.ipv4.tcp_notsent_lowat = 16384" "$BBR_SYSCTL_FILE"
'; then
  rm -f "$bbr_test_file"
  fail "BBR helper did not persist the expected configuration"
fi
rm -f "$bbr_test_file"
pass "BBR helper enables BBR + proxy network tuning and persists them"

# ---------- GOMEMLIMIT derivation (OOM guard for small VPS) ----------
info "GOMEMLIMIT derivation (~75% RAM)"
gml_1g=$(bash -c '. lib/system.sh; derive_gomemlimit_mib 1048576')
[ "$gml_1g" = "768" ] || fail "expected 768 MiB for 1 GiB RAM, got '${gml_1g}'"
gml_zero=$(bash -c '. lib/system.sh; derive_gomemlimit_mib 0')
[ -z "$gml_zero" ] || fail "expected empty GOMEMLIMIT for undetectable RAM, got '${gml_zero}'"
gml_tiny=$(bash -c '. lib/system.sh; derive_gomemlimit_mib 65536')
[ -z "$gml_tiny" ] || fail "expected empty GOMEMLIMIT for tiny RAM, got '${gml_tiny}'"
pass "GOMEMLIMIT derivation: ~75% RAM, skips undetectable/tiny hosts"

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
