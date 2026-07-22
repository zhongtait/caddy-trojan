#!/usr/bin/env python3
"""EasyTrojan node hub: register nodes and serve base64 subscription.

Subscribe:
  GET /sub/<token>
  GET /sub/<token>?server=IP&port=443   # rewrite connect address (CF preferred IP)
  GET /sub/<token>?server=IP&port=2053

Register (nodes):
  POST /api/register
  Header: X-Hub-Token: <register_token>
  Body JSON: {"name","domain","password","server"?,"port"?,"sni"?,"host"?,"path"?,"transport"?,"alpn"?,"enabled"?}

Unregister:
  POST /api/unregister
  Header: X-Hub-Token: <register_token>
  Body JSON: {"domain","password","name"?}
"""
from __future__ import annotations

import base64
import json
import os
import secrets
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

HUB_DIR = Path(os.environ.get("EASYTROJAN_HUB_DIR", "/etc/caddy/trojan/hub"))
NODES_FILE = HUB_DIR / "nodes.json"
CFG_FILE = HUB_DIR / "config.json"
LISTEN = os.environ.get("EASYTROJAN_HUB_LISTEN", "127.0.0.1:2099")
LOCK = threading.RLock()


def _token_ok(provided: str | None, expected: str | None) -> bool:
    """Constant-time compare that never raises on length mismatch."""
    a = (provided or "").encode("utf-8")
    b = (expected or "").encode("utf-8")
    if not a or not b or len(a) != len(b):
        secrets.compare_digest(a, a)
        return False
    return secrets.compare_digest(a, b)


def _now() -> int:
    return int(time.time())


def _load_json(path: Path, default: Any) -> Any:
    if not path.is_file():
        return default
    try:
        with path.open("r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return default


def _save_json(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(tmp, path)
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass


def ensure_config() -> dict:
    with LOCK:
        cfg = _load_json(CFG_FILE, {})
        changed = False
        if not cfg.get("register_token"):
            cfg["register_token"] = secrets.token_urlsafe(24)
            changed = True
        if not cfg.get("sub_token"):
            cfg["sub_token"] = secrets.token_urlsafe(24)
            changed = True
        if "bind" not in cfg:
            cfg["bind"] = LISTEN
            changed = True
        if changed:
            _save_json(CFG_FILE, cfg)
        nodes = _load_json(NODES_FILE, {"nodes": []})
        if "nodes" not in nodes:
            nodes = {"nodes": []}
            _save_json(NODES_FILE, nodes)
        return cfg


def load_nodes() -> list[dict]:
    with LOCK:
        data = _load_json(NODES_FILE, {"nodes": []})
        return list(data.get("nodes") or [])


def save_nodes(nodes: list[dict]) -> None:
    with LOCK:
        _save_json(NODES_FILE, {"nodes": nodes, "updated_at": _now()})


def node_id(domain: str, password: str, name: str) -> str:
    raw = f"{domain}|{password}|{name}".encode("utf-8")
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")[:32]


def upsert_node(payload: dict) -> dict:
    domain = str(payload.get("domain") or "").strip().lower()
    password = str(payload.get("password") or "")
    name = str(payload.get("name") or domain or "node").strip()
    if not domain or not password:
        raise ValueError("domain and password are required")

    node = {
        "id": str(payload.get("id") or node_id(domain, password, name)),
        "name": name,
        "domain": domain,
        "password": password,
        "server": str(payload.get("server") or domain).strip(),
        "port": int(payload.get("port") or 443),
        "sni": str(payload.get("sni") or domain).strip(),
        "host": str(payload.get("host") or domain).strip(),
        "path": str(payload.get("path") or "/").strip() or "/",
        "transport": str(payload.get("transport") or "ws").strip().lower(),
        "alpn": str(payload.get("alpn") or "h2,http/1.1").strip(),
        "enabled": bool(payload.get("enabled", True)),
        "updated_at": _now(),
    }
    if payload.get("created_at"):
        node["created_at"] = payload["created_at"]

    nodes = load_nodes()
    found = False
    for i, n in enumerate(nodes):
        if n.get("id") == node["id"] or (
            n.get("domain") == node["domain"] and n.get("password") == node["password"] and n.get("name") == node["name"]
        ):
            node["created_at"] = n.get("created_at") or node.get("created_at") or _now()
            node["id"] = n.get("id") or node["id"]
            nodes[i] = node
            found = True
            break
    if not found:
        node["created_at"] = _now()
        nodes.append(node)
    save_nodes(nodes)
    return node


def delete_node(nid: str) -> bool:
    nodes = load_nodes()
    new_nodes = [n for n in nodes if n.get("id") != nid]
    if len(new_nodes) == len(nodes):
        return False
    save_nodes(new_nodes)
    return True


def delete_by_credentials(domain: str, password: str, name: str | None = None) -> int:
    """Remove nodes matching domain+password (optional exact name). Returns count removed."""
    domain = (domain or "").strip().lower()
    password = password or ""
    name = (name or "").strip()
    if not domain or not password:
        return 0
    nodes = load_nodes()
    new_nodes = []
    removed = 0
    for n in nodes:
        if n.get("domain") == domain and n.get("password") == password:
            if name and (n.get("name") or "") != name:
                new_nodes.append(n)
                continue
            removed += 1
            continue
        new_nodes.append(n)
    if removed:
        save_nodes(new_nodes)
    return removed


def qe(s: str) -> str:
    return urllib.parse.quote(str(s), safe="")


def build_link(node: dict, server: str | None = None, port: int | None = None) -> str:
    if not node.get("enabled", True):
        return ""
    domain = node.get("domain") or ""
    password = node.get("password") or ""
    name = node.get("name") or domain
    addr = (server or node.get("server") or domain).strip()
    p = int(port if port is not None else (node.get("port") or 443))
    sni = node.get("sni") or domain
    host = node.get("host") or domain
    path = node.get("path") or "/"
    if not path.startswith("/"):
        path = "/" + path
    transport = (node.get("transport") or "ws").lower()
    user = qe(password)
    frag = qe(name)
    # Keep configured ALPN list (default both h2 and http/1.1).
    alpn_raw = str(node.get("alpn") or "h2,http/1.1").strip() or "h2,http/1.1"
    parts = [x.strip() for x in alpn_raw.split(",") if x.strip()]
    alpn = ",".join(parts) if parts else "h2,http/1.1"
    if transport == "ws":
        return (
            f"trojan://{user}@{addr}:{p}"
            f"?security=tls&sni={qe(sni)}&alpn={qe(alpn)}&type=ws&host={qe(host)}&path={qe(path)}#{frag}"
        )
    return f"trojan://{user}@{addr}:{p}?security=tls&sni={qe(sni)}&alpn={qe(alpn)}&type=tcp#{frag}"


def subscription_body(server: str | None = None, port: int | None = None) -> bytes:
    links = []
    for n in load_nodes():
        link = build_link(n, server=server, port=port)
        if link:
            links.append(link)
    text = "\n".join(links) + ("\n" if links else "")
    return base64.b64encode(text.encode("utf-8"))


class Handler(BaseHTTPRequestHandler):
    server_version = "EasyTrojanHub/1.0"

    def log_message(self, fmt: str, *args: Any) -> None:
        # keep journal clean
        sys_stderr = getattr(self, "_quiet", True)
        if not sys_stderr:
            super().log_message(fmt, *args)

    def _no_cache_headers(self) -> None:
        # Strong no-cache for subscription clients and any reverse proxy (Cloudflare).
        self.send_header("Cache-Control", "no-store, no-cache, must-revalidate, max-age=0")
        self.send_header("Pragma", "no-cache")
        self.send_header("Expires", "0")

    def _json(self, code: int, obj: Any) -> None:
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self._no_cache_headers()
        self.end_headers()
        if not getattr(self, "_head_only", False):
            self.wfile.write(body)

    def _text(self, code: int, body: bytes, content_type: str, extra_headers: dict | None = None) -> None:
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self._no_cache_headers()
        if extra_headers:
            for k, v in extra_headers.items():
                self.send_header(k, v)
        self.end_headers()
        if not getattr(self, "_head_only", False):
            self.wfile.write(body)

    def _auth_register(self) -> bool:
        cfg = ensure_config()
        auth = self.headers.get("Authorization", "") or ""
        if auth.lower().startswith("bearer "):
            auth = auth[7:]
        token = self.headers.get("X-Hub-Token") or auth.strip()
        return _token_ok(token, cfg.get("register_token", ""))

    def do_GET(self) -> None:  # noqa: N802
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path.rstrip("/") or "/"
        qs = urllib.parse.parse_qs(parsed.query)
        cfg = ensure_config()

        if path in ("/", "/health"):
            self._json(200, {"ok": True, "service": "easytrojan-hub", "nodes": len(load_nodes())})
            return

        if path.startswith("/sub/"):
            token = path[len("/sub/") :].strip("/")
            if not _token_ok(token, cfg.get("sub_token", "")):
                self._json(401, {"error": "invalid subscription token"})
                return
            server = (qs.get("server") or qs.get("ip") or [None])[0]
            port_raw = (qs.get("port") or [None])[0]
            port = None
            if port_raw:
                try:
                    port = int(port_raw)
                except ValueError:
                    self._json(400, {"error": "invalid port"})
                    return
            body = subscription_body(server=server, port=port)
            # clients expect plain base64 text; profile headers help apps refresh reliably
            extra = {
                "Profile-Update-Interval": "1",
                "Subscription-Userinfo": "upload=0; download=0; total=0; expire=0",
            }
            self._text(200, body, "text/plain; charset=utf-8", extra_headers=extra)
            return

        if path == "/api/nodes":
            if not self._auth_register():
                self._json(401, {"error": "unauthorized"})
                return
            nodes = load_nodes()
            # do not strip passwords for authenticated operator; mark count only in public health
            safe = []
            for n in nodes:
                item = dict(n)
                pw = item.get("password") or ""
                item["password"] = (pw[:2] + "***" + pw[-2:]) if len(pw) > 4 else "****"
                safe.append(item)
            self._json(200, {"nodes": safe, "count": len(safe)})
            return

        if path == "/api/config":
            if not self._auth_register():
                self._json(401, {"error": "unauthorized"})
                return
            self._json(
                200,
                {
                    "register_token": cfg.get("register_token"),
                    "sub_token": cfg.get("sub_token"),
                    "bind": cfg.get("bind"),
                    "subscribe_path": f"/sub/{cfg.get('sub_token')}",
                },
            )
            return

        self._json(404, {"error": "not found"})

    def do_HEAD(self) -> None:  # noqa: N802
        """Same headers as GET (curl -I / proxy probes); no body."""
        self._head_only = True
        try:
            self.do_GET()
        finally:
            self._head_only = False

    def do_POST(self) -> None:  # noqa: N802
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path.rstrip("/") or "/"
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length > 0 else b"{}"
        try:
            payload = json.loads(raw.decode("utf-8") or "{}")
        except json.JSONDecodeError:
            self._json(400, {"error": "invalid json"})
            return

        if path == "/api/register":
            if not self._auth_register():
                self._json(401, {"error": "unauthorized"})
                return
            try:
                node = upsert_node(payload if isinstance(payload, dict) else {})
            except ValueError as e:
                self._json(400, {"error": str(e)})
                return
            self._json(200, {"ok": True, "node": {"id": node["id"], "name": node["name"], "domain": node["domain"]}})
            return

        if path == "/api/delete":
            if not self._auth_register():
                self._json(401, {"error": "unauthorized"})
                return
            nid = str((payload or {}).get("id") or "")
            if not nid:
                self._json(400, {"error": "id required"})
                return
            ok = delete_node(nid)
            self._json(200 if ok else 404, {"ok": ok})
            return

        if path in ("/api/unregister", "/api/delete_by_password"):
            if not self._auth_register():
                self._json(401, {"error": "unauthorized"})
                return
            if not isinstance(payload, dict):
                self._json(400, {"error": "invalid payload"})
                return
            domain = str(payload.get("domain") or "").strip()
            password = str(payload.get("password") or "")
            name = str(payload.get("name") or "").strip() or None
            if not domain or not password:
                self._json(400, {"error": "domain and password are required"})
                return
            removed = delete_by_credentials(domain, password, name)
            self._json(200, {"ok": True, "removed": removed})
            return

        self._json(404, {"error": "not found"})

    def do_DELETE(self) -> None:  # noqa: N802
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path.rstrip("/") or "/"
        if path.startswith("/api/nodes/"):
            if not self._auth_register():
                self._json(401, {"error": "unauthorized"})
                return
            nid = path[len("/api/nodes/") :].strip("/")
            ok = delete_node(nid)
            self._json(200 if ok else 404, {"ok": ok})
            return
        self._json(404, {"error": "not found"})


def main() -> None:
    cfg = ensure_config()
    bind = os.environ.get("EASYTROJAN_HUB_LISTEN") or cfg.get("bind") or LISTEN
    host, _, port_s = bind.partition(":")
    host = host or "127.0.0.1"
    port = int(port_s or "2099")
    httpd = ThreadingHTTPServer((host, port), Handler)
    print(f"easytrojan-hub listening on {host}:{port}", flush=True)
    print(f"config: {CFG_FILE}", flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
