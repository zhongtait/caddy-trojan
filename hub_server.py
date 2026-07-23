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
import ipaddress
import json
import os
import re
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
MAX_BODY_BYTES = 64 * 1024
MAX_NODES = 10_000
MAX_NAME_LENGTH = 128
MAX_PASSWORD_LENGTH = 512
MAX_PATH_LENGTH = 2048
MAX_HOST_LENGTH = 253
HOST_RE = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$")


class DataStoreError(RuntimeError):
    """The hub state is missing or invalid and must not be replaced silently."""


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
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise DataStoreError(f"invalid hub state: {path}") from exc


def _save_json(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    with tmp.open("w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())
    if path.is_file():
        try:
            backup = path.with_suffix(path.suffix + ".bak")
            with path.open("rb") as src, backup.open("wb") as dst:
                dst.write(src.read())
                dst.flush()
                os.fsync(dst.fileno())
            os.chmod(backup, 0o600)
        except OSError:
            pass
    os.replace(tmp, path)
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass


def _load_nodes_unlocked() -> list[dict]:
    data = _load_json(NODES_FILE, {"nodes": []})
    if not isinstance(data, dict) or not isinstance(data.get("nodes"), list):
        raise DataStoreError(f"invalid node state: {NODES_FILE}")
    nodes = list(data["nodes"])
    if len(nodes) > MAX_NODES:
        raise DataStoreError(f"too many nodes: {len(nodes)}")
    if any(not isinstance(node, dict) for node in nodes):
        raise DataStoreError(f"invalid node entry: {NODES_FILE}")
    return nodes


def _save_nodes_unlocked(nodes: list[dict]) -> None:
    if len(nodes) > MAX_NODES:
        raise DataStoreError(f"too many nodes: {len(nodes)}")
    _save_json(NODES_FILE, {"nodes": nodes, "updated_at": _now()})


def ensure_config() -> dict:
    with LOCK:
        cfg = _load_json(CFG_FILE, {})
        if not isinstance(cfg, dict):
            raise DataStoreError(f"invalid hub config: {CFG_FILE}")
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
        if not NODES_FILE.is_file():
            _save_nodes_unlocked([])
        else:
            _load_nodes_unlocked()
        return cfg


def load_nodes() -> list[dict]:
    with LOCK:
        return _load_nodes_unlocked()


def save_nodes(nodes: list[dict]) -> None:
    with LOCK:
        _save_nodes_unlocked(nodes)


def new_node_id() -> str:
    """Return an opaque stable identifier; it must not change when a node is renamed."""
    return secrets.token_urlsafe(18)


def _text(value: Any, field: str, default: str = "", maximum: int = MAX_HOST_LENGTH) -> str:
    if value is None:
        value = default
    if not isinstance(value, str):
        raise ValueError(f"{field} must be a string")
    value = value.strip()
    if not value or len(value) > maximum or any(ord(ch) < 0x20 or ord(ch) == 0x7F for ch in value):
        raise ValueError(f"invalid {field}")
    return value


def _host(value: Any, field: str, default: str = "") -> str:
    value = _text(value, field, default, MAX_HOST_LENGTH)
    candidate = value.strip("[]")
    try:
        ipaddress.ip_address(candidate)
        return candidate
    except ValueError:
        if not HOST_RE.fullmatch(candidate) or len(candidate) > MAX_HOST_LENGTH:
            raise ValueError(f"invalid {field}")
        return candidate.lower()


def _port(value: Any, field: str = "port") -> int:
    if isinstance(value, bool):
        raise ValueError(f"invalid {field}")
    try:
        port = int(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"invalid {field}") from exc
    if not 1 <= port <= 65535:
        raise ValueError(f"invalid {field}")
    return port


def upsert_node(payload: dict) -> dict:
    if not isinstance(payload, dict):
        raise ValueError("invalid payload")
    domain = _host(payload.get("domain"), "domain")
    password = _text(payload.get("password"), "password", maximum=MAX_PASSWORD_LENGTH)
    name = _text(payload.get("name"), "name", domain, MAX_NAME_LENGTH)
    server = _host(payload.get("server"), "server", domain)
    sni = _host(payload.get("sni"), "sni", domain)
    host = _host(payload.get("host"), "host", domain)
    path = _text(payload.get("path"), "path", "/", MAX_PATH_LENGTH)
    if not path.startswith("/"):
        path = "/" + path
    transport = _text(payload.get("transport"), "transport", "ws", 16).lower()
    if transport not in ("ws", "tcp"):
        raise ValueError("transport must be ws or tcp")
    alpn = _text(payload.get("alpn"), "alpn", "h2,http/1.1", 128)
    if any(not re.fullmatch(r"[A-Za-z0-9._/-]+", item.strip()) for item in alpn.split(",")):
        raise ValueError("invalid alpn")
    enabled = payload.get("enabled", True)
    if not isinstance(enabled, bool):
        raise ValueError("enabled must be boolean")
    supplied_id = payload.get("id")
    if supplied_id is not None and (not isinstance(supplied_id, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", supplied_id)):
        raise ValueError("invalid id")

    node = {
        "id": str(supplied_id or new_node_id()),
        "name": name,
        "domain": domain,
        "password": password,
        "server": server,
        "port": _port(payload.get("port", 443)),
        "sni": sni,
        "host": host,
        "path": path,
        "transport": transport,
        "alpn": alpn,
        "enabled": enabled,
        "updated_at": _now(),
    }
    if payload.get("created_at"):
        node["created_at"] = payload["created_at"]

    with LOCK:
        nodes = _load_nodes_unlocked()
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
        _save_nodes_unlocked(nodes)
    return node


def delete_node(nid: str) -> bool:
    with LOCK:
        nodes = _load_nodes_unlocked()
        new_nodes = [n for n in nodes if n.get("id") != nid]
        if len(new_nodes) == len(nodes):
            return False
        _save_nodes_unlocked(new_nodes)
        return True


def rename_node(nid: str, name: str) -> dict | None:
    name = _text(name, "name", maximum=MAX_NAME_LENGTH)
    with LOCK:
        nodes = _load_nodes_unlocked()
        for node in nodes:
            if node.get("id") == nid:
                node["name"] = name
                node["updated_at"] = _now()
                _save_nodes_unlocked(nodes)
                return node
    return None


def delete_by_credentials(domain: str, password: str, name: str | None = None) -> int:
    """Remove nodes matching domain+password (optional exact name). Returns count removed."""
    domain = (domain or "").strip().lower()
    password = password or ""
    name = (name or "").strip()
    if not domain or not password:
        return 0
    with LOCK:
        nodes = _load_nodes_unlocked()
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
            _save_nodes_unlocked(new_nodes)
        return removed


def qe(s: str) -> str:
    return urllib.parse.quote(str(s), safe="")


def build_link(node: dict, server: str | None = None, port: int | None = None) -> str:
    if not node.get("enabled", True):
        return ""
    domain = _host(node.get("domain"), "domain")
    password = _text(node.get("password"), "password", maximum=MAX_PASSWORD_LENGTH)
    name = _text(node.get("name"), "name", domain, MAX_NAME_LENGTH)
    addr = _host(server or node.get("server"), "server", domain)
    p = _port(port if port is not None else (node.get("port") or 443))
    authority_addr = f"[{addr}]" if ":" in addr else addr
    sni = _host(node.get("sni"), "sni", domain)
    host = _host(node.get("host"), "host", domain)
    path = _text(node.get("path"), "path", "/", MAX_PATH_LENGTH)
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
            f"trojan://{user}@{authority_addr}:{p}"
            f"?security=tls&sni={qe(sni)}&alpn={qe(alpn)}&type=ws&host={qe(host)}&path={qe(path)}#{frag}"
        )
    return f"trojan://{user}@{authority_addr}:{p}?security=tls&sni={qe(sni)}&alpn={qe(alpn)}&type=tcp#{frag}"


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

    def _auth_register(self) -> bool | None:
        try:
            cfg = ensure_config()
        except DataStoreError as exc:
            self._json(503, {"error": str(exc)})
            return None
        auth = self.headers.get("Authorization", "") or ""
        if auth.lower().startswith("bearer "):
            auth = auth[7:]
        token = self.headers.get("X-Hub-Token") or auth.strip()
        return _token_ok(token, cfg.get("register_token", ""))

    def do_GET(self) -> None:  # noqa: N802
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path.rstrip("/") or "/"
        qs = urllib.parse.parse_qs(parsed.query)
        try:
            cfg = ensure_config()
        except DataStoreError as exc:
            self._json(503, {"error": str(exc)})
            return

        if path in ("/", "/health"):
            try:
                node_count = len(load_nodes())
            except DataStoreError as exc:
                self._json(503, {"error": str(exc)})
                return
            self._json(200, {"ok": True, "service": "easytrojan-hub", "nodes": node_count})
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
                    port = _port(port_raw)
                except ValueError:
                    self._json(400, {"error": "invalid port"})
                    return
            try:
                if server is not None:
                    server = _host(server, "server")
                body = subscription_body(server=server, port=port)
            except (DataStoreError, ValueError) as exc:
                self._json(503 if isinstance(exc, DataStoreError) else 400, {"error": str(exc)})
                return
            # clients expect plain base64 text; profile headers help apps refresh reliably
            extra = {
                "Profile-Update-Interval": "1",
                "Subscription-Userinfo": "upload=0; download=0; total=0; expire=0",
            }
            self._text(200, body, "text/plain; charset=utf-8", extra_headers=extra)
            return

        if path == "/api/nodes":
            if (auth_ok := self._auth_register()) is not True:
                if auth_ok is None:
                    return
                self._json(401, {"error": "unauthorized"})
                return
            try:
                nodes = load_nodes()
            except DataStoreError as exc:
                self._json(503, {"error": str(exc)})
                return
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
            if (auth_ok := self._auth_register()) is not True:
                if auth_ok is None:
                    return
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
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            self._json(400, {"error": "invalid content length"})
            return
        if length < 0 or length > MAX_BODY_BYTES:
            self._json(413, {"error": "request body too large"})
            return
        raw = self.rfile.read(length) if length > 0 else b"{}"
        try:
            payload = json.loads(raw.decode("utf-8") or "{}")
        except (UnicodeDecodeError, json.JSONDecodeError):
            self._json(400, {"error": "invalid json"})
            return

        if path == "/api/register":
            if (auth_ok := self._auth_register()) is not True:
                if auth_ok is None:
                    return
                self._json(401, {"error": "unauthorized"})
                return
            try:
                node = upsert_node(payload if isinstance(payload, dict) else {})
            except ValueError as e:
                self._json(400, {"error": str(e)})
                return
            except DataStoreError as e:
                self._json(503, {"error": str(e)})
                return
            self._json(200, {"ok": True, "node": {"id": node["id"], "name": node["name"], "domain": node["domain"]}})
            return

        if path == "/api/delete":
            if (auth_ok := self._auth_register()) is not True:
                if auth_ok is None:
                    return
                self._json(401, {"error": "unauthorized"})
                return
            if not isinstance(payload, dict):
                self._json(400, {"error": "invalid payload"})
                return
            nid = str(payload.get("id") or "")
            if not nid:
                self._json(400, {"error": "id required"})
                return
            try:
                ok = delete_node(nid)
            except DataStoreError as exc:
                self._json(503, {"error": str(exc)})
                return
            self._json(200 if ok else 404, {"ok": ok})
            return

        if path == "/api/rename":
            if (auth_ok := self._auth_register()) is not True:
                if auth_ok is None:
                    return
                self._json(401, {"error": "unauthorized"})
                return
            if not isinstance(payload, dict):
                self._json(400, {"error": "invalid payload"})
                return
            nid = str(payload.get("id") or "")
            try:
                node = rename_node(nid, payload.get("name"))
            except (DataStoreError, ValueError) as exc:
                self._json(503 if isinstance(exc, DataStoreError) else 400, {"error": str(exc)})
                return
            self._json(200 if node else 404, {"ok": bool(node), "node": {"id": node["id"], "name": node["name"]} if node else None})
            return

        if path in ("/api/unregister", "/api/delete_by_password"):
            if (auth_ok := self._auth_register()) is not True:
                if auth_ok is None:
                    return
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
            try:
                removed = delete_by_credentials(domain, password, name)
            except DataStoreError as exc:
                self._json(503, {"error": str(exc)})
                return
            self._json(200, {"ok": True, "removed": removed})
            return

        self._json(404, {"error": "not found"})

    def do_DELETE(self) -> None:  # noqa: N802
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path.rstrip("/") or "/"
        if path.startswith("/api/nodes/"):
            if (auth_ok := self._auth_register()) is not True:
                if auth_ok is None:
                    return
                self._json(401, {"error": "unauthorized"})
                return
            nid = path[len("/api/nodes/") :].strip("/")
            try:
                ok = delete_node(nid)
            except DataStoreError as exc:
                self._json(503, {"error": str(exc)})
                return
            self._json(200 if ok else 404, {"ok": ok})
            return
        self._json(404, {"error": "not found"})


class LimitedThreadingHTTPServer(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 64

    def __init__(self, server_address: tuple[str, int], handler: type[BaseHTTPRequestHandler]) -> None:
        self._slots = threading.BoundedSemaphore(64)
        super().__init__(server_address, handler)

    def get_request(self) -> tuple[Any, Any]:
        request, client_address = super().get_request()
        request.settimeout(15)
        return request, client_address

    def process_request(self, request: Any, client_address: Any) -> None:
        if not self._slots.acquire(blocking=False):
            self.shutdown_request(request)
            return

        def worker() -> None:
            try:
                self.finish_request(request, client_address)
            except Exception:
                self.handle_error(request, client_address)
            finally:
                self.shutdown_request(request)
                self._slots.release()

        threading.Thread(target=worker, daemon=True).start()


def main() -> None:
    cfg = ensure_config()
    bind = os.environ.get("EASYTROJAN_HUB_LISTEN") or cfg.get("bind") or LISTEN
    host, _, port_s = bind.partition(":")
    host = host or "127.0.0.1"
    port = int(port_s or "2099")
    httpd = LimitedThreadingHTTPServer((host, port), Handler)
    print(f"easytrojan-hub listening on {host}:{port}", flush=True)
    print(f"config: {CFG_FILE}", flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
