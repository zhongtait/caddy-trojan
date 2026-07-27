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
import sys
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
# Cache the parsed+validated node list and the rendered default subscription body,
# keyed on the nodes file identity (mtime/size/inode). Repeated subscription pulls
# then skip a full JSON parse, per-node regex validation, and base64 render while
# nodes.json is unchanged. All access happens under LOCK.
_nodes_cache_key: tuple | None = None
_nodes_cache: list[dict] | None = None
_sub_cache_key: tuple | None = None
_sub_cache_body: bytes | None = None
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
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
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
    except OSError as exc:
        # Turn disk/permission failures into a clean 503 instead of an uncaught
        # exception that drops the connection with no HTTP response.
        try:
            tmp.unlink()
        except OSError:
            pass
        raise DataStoreError(f"cannot persist hub state: {path}") from exc
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass


def _nodes_stat_key() -> tuple | None:
    """Identity of the nodes file for cache validation; None if it is missing."""
    try:
        st = NODES_FILE.stat()
    except OSError:
        return None
    return (st.st_mtime_ns, st.st_size, st.st_ino)


def _load_nodes_unlocked() -> list[dict]:
    global _nodes_cache_key, _nodes_cache
    key = _nodes_stat_key()
    if key is not None and key == _nodes_cache_key and _nodes_cache is not None:
        # Hand out an independent copy so callers that mutate in place
        # (rename/upsert) never touch cached state.
        return [dict(n) for n in _nodes_cache]
    data = _load_json(NODES_FILE, {"nodes": []})
    if not isinstance(data, dict) or not isinstance(data.get("nodes"), list):
        raise DataStoreError(f"invalid node state: {NODES_FILE}")
    nodes = list(data["nodes"])
    if len(nodes) > MAX_NODES:
        raise DataStoreError(f"too many nodes: {len(nodes)}")
    for index, node in enumerate(nodes):
        try:
            _validate_node(node)
        except ValueError as exc:
            raise DataStoreError(f"invalid node entry {index}: {NODES_FILE}") from exc
    _nodes_cache = [dict(n) for n in nodes]
    _nodes_cache_key = key
    return [dict(n) for n in nodes]


def _save_nodes_unlocked(nodes: list[dict]) -> None:
    global _nodes_cache_key, _nodes_cache
    if len(nodes) > MAX_NODES:
        raise DataStoreError(f"too many nodes: {len(nodes)}")
    for index, node in enumerate(nodes):
        try:
            _validate_node(node)
        except ValueError as exc:
            raise DataStoreError(f"invalid node entry {index}") from exc
    _save_json(NODES_FILE, {"nodes": nodes, "updated_at": _now()})
    # Refresh the cache from the just-written state (os.replace gives a new inode,
    # so reads after this see a fresh key and the next read is a cache hit).
    _nodes_cache = [dict(n) for n in nodes]
    _nodes_cache_key = _nodes_stat_key()


def ensure_config() -> dict:
    with LOCK:
        cfg = _load_json(CFG_FILE, {})
        if not isinstance(cfg, dict):
            raise DataStoreError(f"invalid hub config: {CFG_FILE}")
        changed = False
        if "register_token" not in cfg:
            cfg["register_token"] = secrets.token_urlsafe(24)
            changed = True
        if "sub_token" not in cfg:
            cfg["sub_token"] = secrets.token_urlsafe(24)
            changed = True
        if "bind" not in cfg:
            cfg["bind"] = LISTEN
            changed = True
        _validate_config(cfg)
        if changed:
            _save_json(CFG_FILE, cfg)
        # Only guarantee the nodes file exists here; every request that actually
        # reads nodes validates them via load_nodes(), so re-validating the whole
        # set on each ensure_config() call (twice per /sub hit) is wasted work.
        if not NODES_FILE.is_file():
            _save_nodes_unlocked([])
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
    if isinstance(value, int):
        port = value
    elif isinstance(value, str) and re.fullmatch(r"[0-9]+", value.strip()):
        port = int(value.strip())
    else:
        raise ValueError(f"invalid {field}")
    if not 1 <= port <= 65535:
        raise ValueError(f"invalid {field}")
    return port


def _validate_config(cfg: dict) -> None:
    for field in ("register_token", "sub_token"):
        value = cfg.get(field)
        if not isinstance(value, str) or not value.strip():
            raise DataStoreError(f"invalid hub config field: {field}")
        if any(ord(ch) < 0x20 or ord(ch) == 0x7F for ch in value):
            raise DataStoreError(f"invalid hub config field: {field}")
    try:
        _parse_bind(cfg.get("bind"))
    except ValueError as exc:
        raise DataStoreError("invalid hub config field: bind") from exc


def _parse_bind(value: Any) -> tuple[str, int]:
    if not isinstance(value, str) or not value.strip():
        raise ValueError("invalid bind")
    value = value.strip()
    if any(ord(ch) < 0x20 or ord(ch) == 0x7F for ch in value):
        raise ValueError("invalid bind")
    if value.startswith("["):
        match = re.fullmatch(r"\[([^]]+)](?::([0-9]+))?", value)
        if not match:
            raise ValueError("invalid bind")
        host, port_raw = match.groups()
        try:
            if ipaddress.ip_address(host).version != 6:
                raise ValueError("invalid bind")
        except ValueError as exc:
            raise ValueError("invalid bind") from exc
    else:
        if value.count(":") > 1:
            raise ValueError("IPv6 bind addresses must use brackets")
        host, separator, port_raw = value.partition(":")
        if not separator:
            port_raw = ""
    if not host or any(ch.isspace() for ch in host):
        raise ValueError("invalid bind")
    return host, _port(port_raw or 2099, "bind port")


def _validate_node(node: Any) -> None:
    if not isinstance(node, dict):
        raise ValueError("node must be an object")
    node_id = _text(node.get("id"), "id", maximum=64)
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", node_id):
        raise ValueError("invalid id")
    domain = _host(node.get("domain"), "domain")
    _text(node.get("password"), "password", maximum=MAX_PASSWORD_LENGTH)
    _text(node.get("name"), "name", domain, MAX_NAME_LENGTH)
    _host(node.get("server"), "server", domain)
    _port(node.get("port", 443))
    _host(node.get("sni"), "sni", domain)
    _host(node.get("host"), "host", domain)
    _text(node.get("path"), "path", "/", MAX_PATH_LENGTH)
    transport = _text(node.get("transport"), "transport", "ws", 16).lower()
    if transport not in ("ws", "tcp"):
        raise ValueError("transport must be ws or tcp")
    alpn = _text(node.get("alpn"), "alpn", "http/1.1", 128)
    if any(not re.fullmatch(r"[A-Za-z0-9._/-]+", item.strip()) for item in alpn.split(",")):
        raise ValueError("invalid alpn")
    if not isinstance(node.get("enabled", True), bool):
        raise ValueError("enabled must be boolean")
    for field in ("created_at", "updated_at"):
        value = node.get(field)
        if value is not None and (isinstance(value, bool) or not isinstance(value, int) or value < 0):
            raise ValueError(f"invalid {field}")


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
    alpn = _text(payload.get("alpn"), "alpn", "http/1.1", 128)
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
    alpn_raw = str(node.get("alpn") or "http/1.1").strip() or "http/1.1"
    parts = [x.strip() for x in alpn_raw.split(",") if x.strip()]
    if transport == "ws" or "http/1.1" in parts:
        alpn = "http/1.1"
    else:
        alpn = parts[0] if parts else "http/1.1"
    if transport == "ws":
        return (
            f"trojan://{user}@{authority_addr}:{p}"
            f"?security=tls&sni={qe(sni)}&alpn={qe(alpn)}&type=ws&host={qe(host)}&path={qe(path)}#{frag}"
        )
    return f"trojan://{user}@{authority_addr}:{p}?security=tls&sni={qe(sni)}&alpn={qe(alpn)}&type=tcp#{frag}"


def _encode_subscription(nodes: list[dict], server: str | None, port: int | None) -> bytes:
    links = []
    for n in nodes:
        link = build_link(n, server=server, port=port)
        if link:
            links.append(link)
    text = "\n".join(links) + ("\n" if links else "")
    return base64.b64encode(text.encode("utf-8"))


def subscription_body(server: str | None = None, port: int | None = None) -> bytes:
    global _sub_cache_key, _sub_cache_body
    # Only the unmodified (no ?server/?port rewrite) pull is cacheable; that is the
    # common polling path. Override pulls render fresh.
    if server is None and port is None:
        with LOCK:
            key = _nodes_stat_key()
            if key is not None and key == _sub_cache_key and _sub_cache_body is not None:
                return _sub_cache_body
            body = _encode_subscription(_load_nodes_unlocked(), None, None)
            _sub_cache_body = body
            _sub_cache_key = key
            return body
    return _encode_subscription(load_nodes(), server, port)


class Handler(BaseHTTPRequestHandler):
    server_version = "EasyTrojanHub/1.0"
    # Reuse connections for the hot GET /sub path (Caddy reverse-proxies with
    # keep-alive), cutting per-pull TCP/thread setup. All responses set
    # Content-Length; write verbs force-close to avoid any unread-body desync.
    protocol_version = "HTTP/1.1"

    def log_request(self, code: Any = "-", size: Any = "-") -> None:  # noqa: N802
        # Access logs stay out of the journal; errors still reach it via log_error().
        return

    def _audit(self, msg: str) -> None:
        # Minimal audit line to stderr (journald) for auth failures, without the
        # per-request access-log noise. Guarded so it never raises mid-handler.
        try:
            client = self.client_address[0] if getattr(self, "client_address", None) else "-"
        except Exception:
            client = "-"
        sys.stderr.write(f"easytrojan-hub: {msg} from {client}\n")
        sys.stderr.flush()

    def _fail_state(self, exc: Exception) -> None:
        # Internal state problems: detail to the log, generic message to the client
        # so unauthenticated callers never learn server file paths.
        self.log_error("hub state error: %s", exc)
        self._json(503, {"error": "hub state unavailable"})

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

    def _require_register_auth(self, cfg: dict | None = None) -> bool:
        if cfg is None:
            try:
                cfg = ensure_config()
            except DataStoreError as exc:
                self._fail_state(exc)
                return False
        auth = self.headers.get("Authorization", "") or ""
        if auth.lower().startswith("bearer "):
            auth = auth[7:]
        token = self.headers.get("X-Hub-Token") or auth.strip()
        if not _token_ok(token, cfg["register_token"]):
            self._audit(f"unauthorized {getattr(self, 'command', '?')} {getattr(self, 'path', '?')}")
            self._json(401, {"error": "unauthorized"})
            return False
        return True

    def _read_json_object(self) -> dict | None:
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            self._json(400, {"error": "invalid content length"})
            return None
        if length < 0:
            self._json(400, {"error": "invalid content length"})
            return None
        if length > MAX_BODY_BYTES:
            self._json(413, {"error": "request body too large"})
            return None
        raw = self.rfile.read(length) if length > 0 else b"{}"
        try:
            payload = json.loads(raw.decode("utf-8") or "{}")
        except (UnicodeDecodeError, json.JSONDecodeError):
            self._json(400, {"error": "invalid json"})
            return None
        if not isinstance(payload, dict):
            self._json(400, {"error": "invalid payload"})
            return None
        return payload

    def do_GET(self) -> None:  # noqa: N802
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path.rstrip("/") or "/"
        qs = urllib.parse.parse_qs(parsed.query)
        try:
            cfg = ensure_config()
        except DataStoreError as exc:
            self._fail_state(exc)
            return

        if path in ("/", "/health"):
            try:
                node_count = len(load_nodes())
            except DataStoreError as exc:
                self._fail_state(exc)
                return
            self._json(200, {"ok": True, "service": "easytrojan-hub", "nodes": node_count})
            return

        if path.startswith("/sub/"):
            token = path[len("/sub/") :].strip("/")
            if not _token_ok(token, cfg.get("sub_token", "")):
                self._audit(f"invalid subscription token {self.path}")
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
            except DataStoreError as exc:
                self._fail_state(exc)
                return
            except ValueError as exc:
                self._json(400, {"error": str(exc)})
                return
            # clients expect plain base64 text; profile headers help apps refresh reliably
            extra = {
                "Profile-Update-Interval": "1",
                "Subscription-Userinfo": "upload=0; download=0; total=0; expire=0",
            }
            self._text(200, body, "text/plain; charset=utf-8", extra_headers=extra)
            return

        if path == "/api/nodes":
            if not self._require_register_auth(cfg):
                return
            try:
                nodes = load_nodes()
            except DataStoreError as exc:
                self._fail_state(exc)
                return
            # Return operator metadata without exposing complete passwords.
            safe = []
            for n in nodes:
                item = dict(n)
                pw = item.get("password") or ""
                # Only reveal edges of clearly long passwords; short ones (<=8) that
                # would expose half their characters are fully masked.
                item["password"] = (pw[:2] + "***" + pw[-2:]) if len(pw) > 8 else "****"
                safe.append(item)
            self._json(200, {"nodes": safe, "count": len(safe)})
            return

        if path == "/api/config":
            if not self._require_register_auth(cfg):
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
        # Write verbs may respond before consuming the body (auth/size errors);
        # close the connection so a keep-alive peer never reads a stale body.
        self.close_connection = True
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path.rstrip("/") or "/"
        routes = {
            "/api/register",
            "/api/delete",
            "/api/rename",
            "/api/unregister",
            "/api/delete_by_password",
        }
        if path not in routes:
            self._json(404, {"error": "not found"})
            return
        if not self._require_register_auth():
            return
        payload = self._read_json_object()
        if payload is None:
            return

        if path == "/api/register":
            try:
                node = upsert_node(payload)
            except ValueError as e:
                self._json(400, {"error": str(e)})
                return
            except DataStoreError as e:
                self._fail_state(e)
                return
            self._json(200, {"ok": True, "node": {"id": node["id"], "name": node["name"], "domain": node["domain"]}})
            return

        if path == "/api/delete":
            nid = str(payload.get("id") or "")
            if not nid:
                self._json(400, {"error": "id required"})
                return
            try:
                ok = delete_node(nid)
            except DataStoreError as exc:
                self._fail_state(exc)
                return
            self._json(200 if ok else 404, {"ok": ok})
            return

        if path == "/api/rename":
            nid = str(payload.get("id") or "")
            try:
                node = rename_node(nid, payload.get("name"))
            except DataStoreError as exc:
                self._fail_state(exc)
                return
            except ValueError as exc:
                self._json(400, {"error": str(exc)})
                return
            self._json(200 if node else 404, {"ok": bool(node), "node": {"id": node["id"], "name": node["name"]} if node else None})
            return

        if path in ("/api/unregister", "/api/delete_by_password"):
            domain = str(payload.get("domain") or "").strip()
            password = str(payload.get("password") or "")
            name = str(payload.get("name") or "").strip() or None
            if not domain or not password:
                self._json(400, {"error": "domain and password are required"})
                return
            try:
                removed = delete_by_credentials(domain, password, name)
            except DataStoreError as exc:
                self._fail_state(exc)
                return
            self._json(200, {"ok": True, "removed": removed})
            return

    def do_DELETE(self) -> None:  # noqa: N802
        self.close_connection = True
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path.rstrip("/") or "/"
        if path.startswith("/api/nodes/"):
            if not self._require_register_auth():
                return
            nid = path[len("/api/nodes/") :].strip("/")
            try:
                ok = delete_node(nid)
            except DataStoreError as exc:
                self._fail_state(exc)
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
    if len(sys.argv) > 1 and sys.argv[1] == "--init":
        # Single source of truth for hub state creation/validation: the installer
        # calls this instead of maintaining a second, non-atomic Python snippet.
        ensure_config()
        print(f"initialized hub config: {CFG_FILE}", flush=True)
        return
    cfg = ensure_config()
    bind = os.environ.get("EASYTROJAN_HUB_LISTEN") or cfg.get("bind") or LISTEN
    host, port = _parse_bind(bind)
    httpd = LimitedThreadingHTTPServer((host, port), Handler)
    print(f"easytrojan-hub listening on {host}:{port}", flush=True)
    print(f"config: {CFG_FILE}", flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
