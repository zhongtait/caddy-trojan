#!/bin/bash
# EasyTrojan module: hub.sh
# shellcheck shell=bash

hub_enabled() {
    [ -f "$HUB_ENABLED_FILE" ]
}

hub_local_name_file() {
    printf '%s' "${HUB_LOCAL_NAME_FILE:-${TROJAN_DIR}/hub-local-name.txt}"
}

# Display name for this host's nodes in local hub (default: domain).
hub_read_local_name() {
    local f domain
    f=$(hub_local_name_file)
    if [ -f "$f" ]; then
        tr -d '\r\n' < "$f" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
        return 0
    fi
    domain=$(read_installed_domain 2>/dev/null || true)
    printf '%s' "$domain"
}

hub_save_local_name() {
    local name="$1" f
    name=$(printf '%s' "$name" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -n "$name" ] || return 1
    f=$(hub_local_name_file)
    mkdir -p "$(dirname "$f")"
    printf '%s\n' "$name" > "$f"
    chmod 600 "$f" 2>/dev/null || true
}

# Remove all local-hub nodes for this host's domain (+optional password), then re-register.
hub_reregister_local_named() {
    local name_base="$1" domain reg_token passwd
    domain=$(read_installed_domain 2>/dev/null || true)
    reg_token=$(hub_read_cfg_field register_token)
    [ -n "$domain" ] && [ -n "$reg_token" ] && [ -f "$PASSWD_FILE" ] || return 0
    [ -n "$name_base" ] || name_base=$(hub_read_local_name)
    [ -n "$name_base" ] || name_base="$domain"
    while IFS= read -r passwd || [ -n "$passwd" ]; do
        [ -n "$passwd" ] || continue
        curl -sf -X POST -H "Content-Type: application/json" -H "X-Hub-Token: ${reg_token}" \
            -d "$(printf '{\"domain\":\"%s\",\"password\":\"%s\"}' \
                "$(json_escape "$domain")" "$(json_escape "$passwd")")" \
            "http://${HUB_LISTEN}/api/unregister" >/dev/null 2>&1 || true
    done < "$PASSWD_FILE"
    hub_register_local "$name_base"
}

# Ensure Python 3.8+ for hub_server.py; auto-install via package manager when missing.
python3_version_ok() {
    local ver major minor
    check_cmd python3 || return 1
    ver=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || true)
    [ -n "$ver" ] || return 1
    major=${ver%%.*}
    minor=${ver#*.}
    minor=${minor%%.*}
    [ "${major:-0}" -gt 3 ] && return 0
    [ "${major:-0}" -eq 3 ] && [ "${minor:-0}" -ge 8 ]
}

# If only versioned binaries exist (python3.11), expose python3 on PATH for hub wrapper.
link_python3_from_versioned() {
    local cand path
    for cand in python3.12 python3.11 python3.10 python3.9 python39 python311 python312; do
        path=$(command -v "$cand" 2>/dev/null || true)
        [ -n "$path" ] || continue
        # Accept only if that binary is >= 3.8
        if "$path" -c 'import sys; raise SystemExit(0 if sys.version_info[:2] >= (3, 8) else 1)' 2>/dev/null; then
            mkdir -p /usr/local/bin
            ln -sfn "$path" /usr/local/bin/python3
            hash -r 2>/dev/null || true
            # Prefer /usr/local/bin when present
            export PATH="/usr/local/bin:${PATH}"
            python3_version_ok && return 0
        fi
    done
    return 1
}

install_python3_hub() {
    # Best-effort package names across apt/dnf/yum (and common aliases).
    local candidates=() pkg
    if check_cmd apt-get; then
        candidates=(python3)
    elif check_cmd dnf || check_cmd yum; then
        # Prefer plain python3; fall back to newer streams on older RHEL/CentOS.
        candidates=(python3 python39 python3.11 python3.12 python311 python312)
    else
        candidates=(python3)
    fi
    for pkg in "${candidates[@]}"; do
        info "Installing ${pkg} (required by Hub)..."
        if check_cmd dnf; then
            dnf install -y "$pkg" &>/dev/null || true
        elif check_cmd yum; then
            yum install -y "$pkg" &>/dev/null || true
        elif check_cmd apt-get; then
            apt-get update -qq &>/dev/null || true
            apt-get install -y "$pkg" &>/dev/null || true
        else
            error "Unable to install python3: no supported package manager (apt-get/dnf/yum)"
        fi
        hash -r 2>/dev/null || true
        python3_version_ok && return 0
        # Package may only provide python3.X binary
        link_python3_from_versioned && return 0
    done
    # Last chance: versioned binary already present without package install
    link_python3_from_versioned && return 0
    return 1
}

ensure_python3_hub() {
    if python3_version_ok; then
        return 0
    fi
    # Versioned install without python3 name
    if link_python3_from_versioned; then
        return 0
    fi
    if check_cmd python3; then
        local ver
        ver=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || echo unknown)
        warn "python3 ${ver} is too old for Hub (need >= 3.8); trying package manager upgrade/install..."
    else
        info "python3 not found; installing automatically for Hub..."
    fi
    if install_python3_hub && python3_version_ok; then
        local ver
        ver=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || true)
        ok "python3 ${ver} ready for Hub"
        return 0
    fi
    local ver
    ver=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || echo 'not installed')
    error "Hub requires python3 >= 3.8 (found: ${ver}). Install manually, e.g. apt install python3 / dnf install python3"
}

# Backward-compatible alias used by older call sites / docs.
require_python3_hub() {
    ensure_python3_hub
}

hub_client_file() {
    printf '%s' "${HUB_CLIENT_FILE:-${TROJAN_DIR}/hub-client.json}"
}

hub_save_client_membership() {
    local url="$1" token="$2" name="$3" server="$4" port="$5"
    local f
    f=$(hub_client_file)
    mkdir -p "$(dirname "$f")"
    python3 - "$f" "$url" "$token" "$name" "$server" "$port" <<'PY' || true
import json, os, sys, time
path, url, token, name, server, port = sys.argv[1:7]
data = {
    "url": url.rstrip("/"),
    "token": token,
    "name": name or "",
    "server": server or "",
    "port": int(port or 443),
    "updated_at": int(time.time()),
}
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
os.replace(tmp, path)
try:
    os.chmod(path, 0o600)
except OSError:
    pass
PY
    chmod 600 "$f" 2>/dev/null || true
}

hub_read_client_field() {
    local field="$1" f
    f=$(hub_client_file)
    [ -f "$f" ] || return 0
    python3 -c 'import json,sys
p,f=sys.argv[1],sys.argv[2]
try:
    print(json.load(open(p,encoding="utf-8")).get(f,""))
except Exception:
    print("")
' "$f" "$field" 2>/dev/null || true
}

install_hub_binary() {
    local src="" dest="${SHARE_DIR}/hub_server.py"
    # Prefer local repo / source tree, then already-installed share copy, then download.
    local script_src script_dir
    script_src=$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")
    script_dir=$(dirname "$script_src")
    if [ -n "${EASYTROJAN_ROOT:-}" ] && [ -f "${EASYTROJAN_ROOT}/hub_server.py" ]; then
        src="${EASYTROJAN_ROOT}/hub_server.py"
    elif [ -f "${script_dir}/hub_server.py" ]; then
        src="${script_dir}/hub_server.py"
    elif [ -f "$dest" ]; then
        src="$dest"
    fi
    if [ -z "$src" ]; then
        mkdir -p "$SHARE_DIR"
        if curl -fsSL --connect-timeout 10 --max-time 30 "${REPO_RAW}/hub_server.py" -o "$dest"; then
            chmod 644 "$dest"
            src="$dest"
            ok "Downloaded hub_server.py"
        fi
    fi
    [ -n "$src" ] || error "hub_server.py not found. Re-download repo (easytrojan.sh + hub_server.py) or re-run install/update."
    ensure_python3_hub

    mkdir -p "$SHARE_DIR"
    # Same-path cp fails on GNU coreutils and aborts under set -e (hub enable never finishes).
    if [ "$(readlink -f "$src" 2>/dev/null || printf '%s' "$src")" != "$(readlink -f "$dest" 2>/dev/null || printf '%s' "$dest")" ]; then
        cp -f "$src" "$dest"
    fi
    [ -f "$dest" ] || error "hub_server.py missing at $dest"
    chmod 644 "$dest"

    cat > "$HUB_BIN" <<'HUBWRAP'
#!/bin/bash
export EASYTROJAN_HUB_DIR="${EASYTROJAN_HUB_DIR:-/etc/caddy/trojan/hub}"
export EASYTROJAN_HUB_LISTEN="${EASYTROJAN_HUB_LISTEN:-127.0.0.1:2099}"
exec python3 /usr/local/share/easytrojan/hub_server.py
HUBWRAP
    chmod 755 "$HUB_BIN"
}

setup_hub_unit() {
    cat > "/etc/systemd/system/${HUB_UNIT}" <<EOF
[Unit]
Description=EasyTrojan Node Hub
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=EASYTROJAN_HUB_DIR=${HUB_DIR}
Environment=EASYTROJAN_HUB_LISTEN=${HUB_LISTEN}
ExecStart=${HUB_BIN}
Restart=on-failure
RestartSec=3
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$HUB_UNIT" &>/dev/null || true
}

hub_read_cfg_field() {
    local field="$1"
    [ -f "$HUB_CFG" ] || return 0
    python3 -c 'import json,sys
p,f=sys.argv[1],sys.argv[2]
try:
    print(json.load(open(p,encoding="utf-8")).get(f,""))
except Exception:
    print("")
' "$HUB_CFG" "$field" 2>/dev/null || true
}

hub_ensure_config_files() {
    mkdir -p "$HUB_DIR"
    chmod 700 "$HUB_DIR"
    EASYTROJAN_HUB_DIR="$HUB_DIR" EASYTROJAN_HUB_LISTEN="$HUB_LISTEN" python3 - <<'PY'
import json, os, secrets
from pathlib import Path
d = Path(os.environ.get("EASYTROJAN_HUB_DIR", "/etc/caddy/trojan/hub"))
d.mkdir(parents=True, exist_ok=True)
cfg_p = d / "config.json"
nodes_p = d / "nodes.json"
cfg = {}
if cfg_p.is_file():
    try:
        cfg = json.loads(cfg_p.read_text(encoding="utf-8"))
    except Exception:
        cfg = {}
changed = False
if not cfg.get("register_token"):
    cfg["register_token"] = secrets.token_urlsafe(24)
    changed = True
if not cfg.get("sub_token"):
    cfg["sub_token"] = secrets.token_urlsafe(24)
    changed = True
bind = os.environ.get("EASYTROJAN_HUB_LISTEN", "127.0.0.1:2099")
if cfg.get("bind") != bind:
    cfg["bind"] = bind
    changed = True
if changed or not cfg_p.is_file():
    cfg_p.write_text(json.dumps(cfg, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.chmod(cfg_p, 0o600)
if not nodes_p.is_file():
    nodes_p.write_text(json.dumps({"nodes": []}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    os.chmod(nodes_p, 0o600)
PY
}

hub_ensure_runtime() {
    install_hub_binary
    hub_ensure_config_files
    setup_hub_unit
}

hub_register_local() {
    local domain reg_token passwd name_base name i=0 transport="ws"
    domain=$(read_installed_domain 2>/dev/null || true)
    reg_token=$(hub_read_cfg_field register_token)
    [ -n "$domain" ] && [ -n "$reg_token" ] && [ -f "$PASSWD_FILE" ] || return 0
    if [ -f "$CADDYFILE" ] && ! grep -q "websocket" "$CADDYFILE" 2>/dev/null; then
        transport="tcp"
    fi
    name_base="${1:-$domain}"
    while IFS= read -r passwd || [ -n "$passwd" ]; do
        [ -n "$passwd" ] || continue
        i=$((i + 1))
        if [ "$i" -eq 1 ]; then
            name="$name_base"
        else
            name="${name_base}-${i}"
        fi
        local payload
        payload=$(printf '{"name":"%s","domain":"%s","password":"%s","server":"%s","port":443,"sni":"%s","host":"%s","path":"/","transport":"%s","alpn":"http/1.1"}' \
            "$(json_escape "$name")" "$(json_escape "$domain")" "$(json_escape "$passwd")" \
            "$(json_escape "$domain")" "$(json_escape "$domain")" "$(json_escape "$domain")" \
            "$(json_escape "$transport")")
        curl -sf -X POST -H "Content-Type: application/json" -H "X-Hub-Token: ${reg_token}" \
            -d "$payload" "http://${HUB_LISTEN}/api/register" >/dev/null || \
            warn "Failed to register local user into hub (${name})"
    done < "$PASSWD_FILE"
}


# Best-effort: re-seed this host's passwd users into local hub and/or remote joined hub.
hub_sync_local_users() {
    local domain local_name
    domain=$(read_installed_domain 2>/dev/null || true)
    local_name=$(hub_read_local_name)
    [ -n "$local_name" ] || local_name="$domain"
    # Local hub process
    if hub_enabled && systemctl is-active --quiet "$HUB_UNIT" 2>/dev/null; then
        hub_register_local "$local_name" || true
    fi
    # Remote hub membership (hub join)
    if [ -f "$(hub_client_file)" ]; then
        hub_reregister_to_remote || true
    fi
}

hub_reregister_to_remote() {
    local hub_url token name server port domain transport="ws" passwd i=0 reg_name payload
    hub_url=$(hub_read_client_field url)
    token=$(hub_read_client_field token)
    name=$(hub_read_client_field name)
    server=$(hub_read_client_field server)
    port=$(hub_read_client_field port)
    [ -n "$hub_url" ] && [ -n "$token" ] || return 0
    domain=$(read_installed_domain 2>/dev/null || true)
    [ -n "$domain" ] && [ -f "$PASSWD_FILE" ] || return 0
    check_cmd curl || return 0
    if [ -f "$CADDYFILE" ] && ! grep -q "websocket" "$CADDYFILE" 2>/dev/null; then
        transport="tcp"
    fi
    [ -n "$name" ] || name="$domain"
    [ -n "$server" ] || server="$domain"
    [ -n "$port" ] || port=443
    hub_url="${hub_url%/}"
    while IFS= read -r passwd || [ -n "$passwd" ]; do
        [ -n "$passwd" ] || continue
        i=$((i + 1))
        if [ "$i" -eq 1 ]; then
            reg_name="$name"
        else
            reg_name="${name}-${i}"
        fi
        payload=$(printf '{"name":"%s","domain":"%s","password":"%s","server":"%s","port":%s,"sni":"%s","host":"%s","path":"/","transport":"%s","alpn":"http/1.1"}' \
            "$(json_escape "$reg_name")" "$(json_escape "$domain")" "$(json_escape "$passwd")" \
            "$(json_escape "$server")" "$port" \
            "$(json_escape "$domain")" "$(json_escape "$domain")" \
            "$(json_escape "$transport")")
        curl -sf -X POST -H "Content-Type: application/json" -H "X-Hub-Token: ${token}" \
            -d "$payload" "${hub_url}/api/register" >/dev/null || \
            warn "Failed to re-register ${reg_name} to remote hub"
    done < "$PASSWD_FILE"
}

# Best-effort: remove one password from local hub nodes and remote joined hub.
hub_remove_local_password() {
    local passwd="$1" domain reg_token hub_url token
    [ -n "$passwd" ] || return 0
    domain=$(read_installed_domain 2>/dev/null || true)
    [ -n "$domain" ] || return 0

    # Local hub: edit nodes.json by domain+password
    if hub_enabled && [ -f "$HUB_NODES" ]; then
        python3 - "$HUB_NODES" "$domain" "$passwd" <<'PY' 2>/dev/null || true
import json, os, sys
path, domain, password = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    sys.exit(0)
nodes = data.get("nodes") or []
new = [n for n in nodes if not (n.get("domain") == domain and n.get("password") == password)]
if len(new) != len(nodes):
    data["nodes"] = new
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(tmp, path)
PY
    fi

    # Remote hub membership: unregister by domain+password (fallback: DELETE by computed node id)
    if [ -f "$(hub_client_file)" ]; then
        hub_url=$(hub_read_client_field url)
        token=$(hub_read_client_field token)
        name_hint=$(hub_read_client_field name)
        if [ -n "$hub_url" ] && [ -n "$token" ] && check_cmd curl; then
            hub_url="${hub_url%/}"
            payload=$(printf '{"domain":"%s","password":"%s"}' \
                "$(json_escape "$domain")" "$(json_escape "$passwd")")
            if ! curl -sf -X POST -H "Content-Type: application/json" -H "X-Hub-Token: ${token}" \
                -d "$payload" "${hub_url}/api/unregister" >/dev/null 2>&1; then
                # Older hub without /api/unregister: try DELETE /api/nodes/<id> for common names
                python3 - "$hub_url" "$token" "$domain" "$passwd" "${name_hint:-$domain}" <<'PY' 2>/dev/null || \
                    warn "Failed to unregister password on remote hub (${hub_url})"
import base64, sys, urllib.request
base, token, domain, password, name = sys.argv[1:6]
def nid(domain, password, name):
    raw = f"{domain}|{password}|{name}".encode("utf-8")
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")[:32]
candidates = {name, domain}
for i in range(2, 32):
    candidates.add(f"{domain}-{i}")
    if name:
        candidates.add(f"{name}-{i}")
ok_any = False
for n in candidates:
    req = urllib.request.Request(
        base.rstrip("/") + "/api/nodes/" + nid(domain, password, n),
        method="DELETE",
        headers={"X-Hub-Token": token},
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            if 200 <= resp.status < 300:
                ok_any = True
    except Exception:
        pass
sys.exit(0 if ok_any else 1)
PY
            fi
        fi
    fi
}

do_hub() {
    require_root
    local sub="${1:-}"
    [ -n "$sub" ] || error "Usage: easytrojan hub {enable|disable|status|url|token|list|remove|rename|join|leave}"
    shift || true

    case "$sub" in
        enable|on|start)
            local domain local_name=""
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --name)
                        [ -n "${2:-}" ] || error "--name requires a value"
                        local_name="$2"; shift 2
                        ;;
                    -h|--help)
                        cat <<'EOF'
Usage: easytrojan hub enable [--name NAME]

Enable local hub (subscription aggregation).
  --name NAME   Display name for THIS host in subscription (default: domain)
EOF
                        exit 0
                        ;;
                    *) error "Unknown hub enable argument: $1" ;;
                esac
            done
            domain=$(read_installed_domain 2>/dev/null || true)
            [ -n "$domain" ] || error "Install first: easytrojan install --domain example.com"
            ensure_python3_hub
            check_cmd curl || error "curl is required for hub"
            if [ -n "$local_name" ]; then
                hub_save_local_name "$local_name"
            fi
            local_name=$(hub_read_local_name)
            [ -n "$local_name" ] || local_name="$domain"

            hub_ensure_runtime
            touch "$HUB_ENABLED_FILE"
            chmod 600 "$HUB_ENABLED_FILE"
            if ! systemctl restart "$HUB_UNIT"; then
                journalctl -u "$HUB_UNIT" -n 40 --no-pager 2>/dev/null || true
                error "Failed to start ${HUB_UNIT}. Check: journalctl -u ${HUB_UNIT} -n 50 --no-pager"
            fi
            if ! systemctl is-active --quiet "$HUB_UNIT"; then
                journalctl -u "$HUB_UNIT" -n 40 --no-pager 2>/dev/null || true
                error "Hub service is not active after restart (${HUB_UNIT})"
            fi
            generate_caddyfile "$domain"
            reload_caddy
            # best-effort: seed this host's users into hub under display name
            sleep 0.5
            hub_reregister_local_named "$local_name" || hub_register_local "$local_name" || true

            local reg_token sub_token
            reg_token=$(hub_read_cfg_field register_token)
            sub_token=$(hub_read_cfg_field sub_token)
            ok "Hub enabled"
            echo ""
            echo -e "  Domain        : ${CYAN}${domain}${NC}"
            echo -e "  Local name   : ${CYAN}${local_name}${NC}"
            echo -e "  Register token: ${CYAN}${reg_token}${NC}"
            echo -e "  Subscribe URL : ${CYAN}https://${domain}/sub/${sub_token}${NC}"
            echo -e "  Preferred IP  : ${CYAN}https://${domain}/sub/${sub_token}?server=CF_IP&port=443${NC}"
            echo -e "  # ?server=&port= rewrites ALL nodes connect address for this pull"
            echo -e "  Join command  : ${CYAN}easytrojan hub join --url https://${domain} --token ${reg_token} --name my-node${NC}"
            echo ""
            exit 0
            ;;
        disable|off|stop)
            rm -f "$HUB_ENABLED_FILE"
            if systemctl list-unit-files 2>/dev/null | grep -q "^${HUB_UNIT}"; then
                systemctl stop "$HUB_UNIT" 2>/dev/null || true
                systemctl disable "$HUB_UNIT" 2>/dev/null || true
            fi
            local domain
            domain=$(read_installed_domain 2>/dev/null || true)
            if [ -n "$domain" ]; then
                generate_caddyfile "$domain"
                reload_caddy
            fi
            ok "Hub disabled (nodes.json kept under ${HUB_DIR})"
            exit 0
            ;;
        status)
            echo ""
            if hub_enabled; then
                echo -e "  Hub     : ${GREEN}enabled${NC}"
            else
                echo -e "  Hub     : ${YELLOW}disabled${NC}"
            fi
            if systemctl is-active --quiet "$HUB_UNIT" 2>/dev/null; then
                echo -e "  Service : ${GREEN}running${NC} (${HUB_UNIT})"
            else
                echo -e "  Service : ${RED}stopped${NC} (${HUB_UNIT})"
            fi
            echo -e "  Listen  : ${CYAN}${HUB_LISTEN}${NC} (local only)"
            if [ -f "$HUB_CFG" ]; then
                local sub_token domain count
                sub_token=$(hub_read_cfg_field sub_token)
                domain=$(read_installed_domain 2>/dev/null || true)
                count=$(python3 -c 'import json,sys
try:
    print(len(json.load(open(sys.argv[1],encoding="utf-8")).get("nodes",[])))
except Exception:
    print(0)
' "$HUB_NODES" 2>/dev/null || echo 0)
                echo -e "  Nodes   : ${count}"
                local lname
                lname=$(hub_read_local_name 2>/dev/null || true)
                if [ -n "$lname" ]; then
                    echo -e "  Local   : ${CYAN}${lname}${NC}  (hub rename --name ...)"
                fi
                if [ -n "$domain" ] && [ -n "$sub_token" ]; then
                    echo -e "  Sub URL : ${CYAN}https://${domain}/sub/${sub_token}${NC}"
                    echo -e "  Pref IP : ${CYAN}https://${domain}/sub/${sub_token}?server=CF_IP&port=443${NC}"
                fi
            fi
            echo ""
            exit 0
            ;;
        url|sub|subscribe)
            local domain sub_token server_q="" port_q=""
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --server|--addr|--address)
                        [ -n "${2:-}" ] || error "--server requires a value"
                        server_q="$2"; shift 2
                        ;;
                    --port)
                        [ -n "${2:-}" ] || error "--port requires a value"
                        port_q="$2"; shift 2
                        ;;
                    -h|--help)
                        cat <<'EOF'
Usage: easytrojan hub url [--server ADDR] [--port PORT]

Print subscription URL. Optional --server/--port append CF preferred-IP rewrite
(same as /sub/<token>?server=ADDR&port=PORT; rewrites ALL nodes for that pull).
EOF
                        exit 0
                        ;;
                    *) error "Unknown hub url argument: $1" ;;
                esac
            done
            domain=$(read_installed_domain 2>/dev/null || true)
            sub_token=$(hub_read_cfg_field sub_token)
            [ -n "$domain" ] || error "Domain not found"
            [ -n "$sub_token" ] || error "Hub not configured. Run: easytrojan hub enable"
            local url qs=""
            url="https://${domain}/sub/${sub_token}"
            if [ -n "$server_q" ]; then
                qs="server=$(urlencode "$server_q")"
            fi
            if [ -n "$port_q" ]; then
                [ -n "$qs" ] && qs="${qs}&"
                qs="${qs}port=$(urlencode "$port_q")"
            fi
            if [ -n "$qs" ]; then
                url="${url}?${qs}"
            fi
            echo "$url"
            exit 0
            ;;
        token|tokens)
            [ -f "$HUB_CFG" ] || error "Hub not configured. Run: easytrojan hub enable"
            local reg_token sub_token domain
            reg_token=$(hub_read_cfg_field register_token)
            sub_token=$(hub_read_cfg_field sub_token)
            domain=$(read_installed_domain 2>/dev/null || true)
            echo ""
            echo -e "  register_token : ${CYAN}${reg_token}${NC}"
            echo -e "  sub_token       : ${CYAN}${sub_token}${NC}"
            if [ -n "$domain" ]; then
                echo -e "  subscribe       : ${CYAN}https://${domain}/sub/${sub_token}${NC}"
                echo -e "  join            : ${CYAN}easytrojan hub join --url https://${domain} --token ${reg_token}${NC}"
            fi
            echo ""
            exit 0
            ;;
        list|ls)
            [ -f "$HUB_NODES" ] || error "No nodes yet"
            local reg_token
            reg_token=$(hub_read_cfg_field register_token)
            if [ -n "$reg_token" ] && systemctl is-active --quiet "$HUB_UNIT" 2>/dev/null; then
                curl -sf -H "X-Hub-Token: ${reg_token}" "http://${HUB_LISTEN}/api/nodes" | python3 -c 'import json,sys
d=json.load(sys.stdin)
print("nodes:", d.get("count", 0))
for n in d.get("nodes") or []:
    print("  -", n.get("id"), n.get("name"), "%s:%s" % (n.get("domain"), n.get("port")), "pw="+str(n.get("password")))
' || true
            else
                python3 -c 'import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
nodes=d.get("nodes") or []
print("nodes:", len(nodes))
for n in nodes:
    pw=n.get("password") or ""
    mask=(pw[:2]+"***"+pw[-2:]) if len(pw)>4 else "****"
    print("  -", n.get("id"), n.get("name"), "%s:%s" % (n.get("domain"), n.get("port")), "pw="+mask)
' "$HUB_NODES"
            fi
            exit 0
            ;;
        remove|rm|del)
            local nid=""
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --id) nid="${2:-}"; shift 2 ;;
                    *) nid="$1"; shift ;;
                esac
            done
            [ -n "$nid" ] || error "Usage: easytrojan hub remove --id NODE_ID"
            local reg_token
            reg_token=$(hub_read_cfg_field register_token)
            [ -n "$reg_token" ] || error "Hub not configured"
            if systemctl is-active --quiet "$HUB_UNIT" 2>/dev/null; then
                curl -sf -X DELETE -H "X-Hub-Token: ${reg_token}" "http://${HUB_LISTEN}/api/nodes/${nid}" >/dev/null \
                    || error "Delete failed (id not found or hub down)"
            else
                python3 -c 'import json,sys
p,nid=sys.argv[1],sys.argv[2]
d=json.load(open(p,encoding="utf-8"))
nodes=[n for n in d.get("nodes") or [] if n.get("id")!=nid]
if len(nodes)==len(d.get("nodes") or []):
    raise SystemExit(1)
d["nodes"]=nodes
open(p,"w",encoding="utf-8").write(json.dumps(d,ensure_ascii=False,indent=2)+"\n")
' "$HUB_NODES" "$nid" || error "Delete failed"
            fi
            ok "Removed node ${nid}"
            exit 0
            ;;
        leave|unjoin)
            local f
            f=$(hub_client_file)
            if [ -f "$f" ]; then
                rm -f "$f"
                ok "Removed remote hub membership ($f)"
            else
                warn "No remote hub membership file ($f)"
            fi
            exit 0
            ;;
        rename|name)
            do_hub_rename "$@"
            exit 0
            ;;
        join|register)
            do_hub_join "$@"
            exit 0
            ;;
        *)
            error "Unknown hub command: $sub (enable|disable|status|url|token|list|remove|rename|join|leave)"
            ;;
    esac
}

do_hub_rename() {
    require_root
    ensure_python3_hub
    local new_name="" nid=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --name)
                [ -n "${2:-}" ] || error "--name requires a value"
                new_name="$2"; shift 2
                ;;
            --id)
                [ -n "${2:-}" ] || error "--id requires a value"
                nid="$2"; shift 2
                ;;
            -h|--help)
                cat <<'EOF'
Usage:
  easytrojan hub rename --name NEW_NAME
      Rename THIS host local hub entries (and save as default local name).
  easytrojan hub rename --id NODE_ID --name NEW_NAME
      Rename any node on this hub host by id (see: hub list).

Display name appears in subscription (#fragment).
EOF
                exit 0
                ;;
            *) error "Unknown hub rename argument: $1" ;;
        esac
    done
    [ -n "$new_name" ] || error "--name is required"

    if [ -n "$nid" ]; then
        [ -f "$HUB_NODES" ] || error "No nodes yet. Run hub enable first."
        hub_enabled || error "Hub not enabled. Run: easytrojan hub enable"
        systemctl is-active --quiet "$HUB_UNIT" 2>/dev/null || error "Hub service not running"
        python3 - "$HUB_NODES" "$nid" "$new_name" <<'PY' || error "Rename failed (id not found?)"
import json, os, sys, base64, time
path, nid, new_name = sys.argv[1], sys.argv[2], sys.argv[3].strip()
if not new_name:
    raise SystemExit('empty name')
with open(path, encoding='utf-8') as f:
    data = json.load(f)
nodes = data.get('nodes') or []
found = False
target = None
for n in nodes:
    if n.get('id') == nid:
        domain = n.get('domain') or ''
        password = n.get('password') or ''
        n['name'] = new_name
        raw = f"{domain}|{password}|{new_name}".encode('utf-8')
        n['id'] = base64.urlsafe_b64encode(raw).decode('ascii').rstrip('=')[:32]
        n['updated_at'] = int(time.time())
        found = True
        target = n
        break
if not found:
    raise SystemExit('id not found')
data['nodes'] = nodes
data['updated_at'] = int(time.time())
tmp = path + '.tmp'
with open(tmp, 'w', encoding='utf-8') as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write('\n')
os.replace(tmp, path)
print(target.get('id'), target.get('name'))
PY
        ok "Renamed node ${nid} -> ${new_name} (hub list to verify)"
        exit 0
    fi

    local domain
    domain=$(read_installed_domain 2>/dev/null || true)
    [ -n "$domain" ] || error "Domain not found. Install first."
    hub_save_local_name "$new_name"
    if hub_enabled && systemctl is-active --quiet "$HUB_UNIT" 2>/dev/null; then
        hub_reregister_local_named "$new_name" || error "Failed to re-register local users under new name"
        ok "Local hub name -> ${new_name}"
    else
        ok "Saved local display name -> ${new_name} (enable hub to apply)"
    fi
    if [ -f "$(hub_client_file)" ]; then
        local hub_url token server port
        hub_url=$(hub_read_client_field url)
        token=$(hub_read_client_field token)
        server=$(hub_read_client_field server)
        port=$(hub_read_client_field port)
        if [ -n "$hub_url" ] && [ -n "$token" ]; then
            hub_save_client_membership "$hub_url" "$token" "$new_name" "$server" "$port"
            local passwd
            while IFS= read -r passwd || [ -n "$passwd" ]; do
                [ -n "$passwd" ] || continue
                curl -sf -X POST -H "Content-Type: application/json" -H "X-Hub-Token: ${token}" \
                    -d "$(printf '{\"domain\":\"%s\",\"password\":\"%s\"}' \
                        "$(json_escape "$domain")" "$(json_escape "$passwd")")" \
                    "${hub_url%/}/api/unregister" >/dev/null 2>&1 || true
            done < "$PASSWD_FILE"
            hub_reregister_to_remote || warn "Remote hub re-register failed; run hub join again"
            ok "Remote hub membership name -> ${new_name}"
        fi
    fi
    exit 0
}

do_hub_join() {
    require_root
    local hub_url="" token="" name="" server="" port="443"
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --url|--hub)
                [ -n "${2:-}" ] || error "--url requires a value"
                hub_url="$2"; shift 2
                ;;
            --token)
                [ -n "${2:-}" ] || error "--token requires a value"
                token="$2"; shift 2
                ;;
            --name)
                [ -n "${2:-}" ] || error "--name requires a value"
                name="$2"; shift 2
                ;;
            --server|--addr|--address)
                [ -n "${2:-}" ] || error "--server requires a value"
                server="$2"; shift 2
                ;;
            --port)
                [ -n "${2:-}" ] || error "--port requires a value"
                port="$2"; shift 2
                ;;
            -h|--help)
                cat <<'EOF'
Usage: easytrojan hub join --url URL --token TOKEN [--name NAME] [--server ADDR] [--port PORT]

Register this machine into a hub subscription.
  --url URL      Hub base URL, e.g. https://hub.example.com
  --token TOKEN  Hub register_token (from: easytrojan hub token on hub host)
  --name NAME    Display name in subscription (default: local domain)
  --server ADDR  Connect address written into node (default: local domain)
  --port PORT    Connect port (default 443; CF HTTPS ports ok)
EOF
                exit 0
                ;;
            *) error "Unknown hub join argument: $1" ;;
        esac
    done

    [ -n "$hub_url" ] || error "--url is required"
    [ -n "$token" ] || error "--token is required"
    check_cmd curl || error "curl is required"
    # membership file + re-sync helpers need python3
    ensure_python3_hub
    local domain transport="ws" passwd count=0
    domain=$(read_installed_domain 2>/dev/null || true)
    [ -n "$domain" ] || error "Local domain not found. Install first."
    [ -f "$PASSWD_FILE" ] || error "No local passwords in $PASSWD_FILE"
    if [ -f "$CADDYFILE" ] && ! grep -q "websocket" "$CADDYFILE" 2>/dev/null; then
        transport="tcp"
    fi
    [ -n "$name" ] || name="$domain"
    [ -n "$server" ] || server="$domain"
    hub_url="${hub_url%/}"

    local i=0 reg_name payload resp
    while IFS= read -r passwd || [ -n "$passwd" ]; do
        [ -n "$passwd" ] || continue
        i=$((i + 1))
        if [ "$i" -eq 1 ]; then
            reg_name="$name"
        else
            reg_name="${name}-${i}"
        fi
        payload=$(printf '{"name":"%s","domain":"%s","password":"%s","server":"%s","port":%s,"sni":"%s","host":"%s","path":"/","transport":"%s","alpn":"http/1.1"}' \
            "$(json_escape "$reg_name")" "$(json_escape "$domain")" "$(json_escape "$passwd")" \
            "$(json_escape "$server")" "$port" \
            "$(json_escape "$domain")" "$(json_escape "$domain")" \
            "$(json_escape "$transport")")
        resp=$(curl -sS -X POST -H "Content-Type: application/json" -H "X-Hub-Token: ${token}" \
            -d "$payload" "${hub_url}/api/register" 2>&1) || error "Register failed: ${resp}"
        echo "$resp" | grep -q '"ok"' || error "Register rejected: ${resp}"
        count=$((count + 1))
        ok "Registered ${reg_name} -> ${hub_url}"
    done < "$PASSWD_FILE"
    [ "$count" -gt 0 ] || error "No passwords to register"
    hub_save_client_membership "$hub_url" "$token" "$name" "$server" "$port"
    ok "Saved remote hub membership -> $(hub_client_file)"
    echo -e "  Tip: on hub host run ${CYAN}easytrojan hub list${NC} / client subscribe ${CYAN}$(printf '%s' "$hub_url" | sed 's|/*$//')/sub/<sub_token>${NC}"
    echo -e "  Tip: after ${CYAN}user add/del${NC}, this node re-syncs to remote hub automatically when membership file exists"
    exit 0
}
