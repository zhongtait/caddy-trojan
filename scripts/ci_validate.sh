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

# ---------- module list consistency ----------
info "EASYTROJAN_LIB_MODULES vs lib/"
mapfile -t declared < <(
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
for f in easytrojan.sh uninstall.sh hub_server.py lib/*.sh scripts/ci_validate.sh; do
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

# ---------- python compile ----------
info "python3 -m py_compile hub_server.py"
python3 -m py_compile hub_server.py || fail "py_compile failed"
pass "hub_server.py compiles"

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
echo "$decoded" | grep -qE 'alpn=h2(%2[Cc]|,)http(%2[Ff]|/)1\.1' || fail "subscription missing alpn=h2,http/1.1: $decoded"
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

# ---------- corrupt state must fail closed ----------
printf '{broken\n' > "${HUB_TMP}/nodes.json"
code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT}/health" || true)
[ "$code" = "503" ] || fail "expected 503 for corrupt node state, got ${code}"
pass "corrupt node state fails closed"

info "all checks passed (no node install)"
pass "ci_validate done"
