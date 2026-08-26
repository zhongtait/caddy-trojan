import base64
import gzip
import http.client
import io
import json
import os
import runpy
import socket
import tempfile
import threading
import time
import unittest
from email.message import Message
from pathlib import Path
from unittest import mock

import hub_server as hub


class HubStateTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        root = Path(self.tempdir.name)
        self.original_paths = (hub.HUB_DIR, hub.CFG_FILE, hub.NODES_FILE)
        hub.HUB_DIR = root
        hub.CFG_FILE = root / "config.json"
        hub.NODES_FILE = root / "nodes.json"
        hub._nodes_cache_key = None
        hub._nodes_cache = None
        hub._sub_cache_key = None
        hub._sub_cache_body = None
        hub._rate_limit_buckets.clear()
        hub._last_prune_time = 0.0

    def tearDown(self):
        hub.HUB_DIR, hub.CFG_FILE, hub.NODES_FILE = self.original_paths
        hub._nodes_cache_key = None
        hub._nodes_cache = None
        hub._sub_cache_key = None
        hub._sub_cache_body = None
        hub._rate_limit_buckets.clear()
        hub._last_prune_time = 0.0
        self.tempdir.cleanup()

    def test_upsert_creates_valid_persistent_node(self):
        hub.ensure_config()
        node = hub.upsert_node({"domain": "example.com", "password": "secret-pass"})

        self.assertEqual(node["id"], hub.load_nodes()[0]["id"])
        self.assertEqual("example.com", node["server"])
        self.assertEqual("http/1.1", node["alpn"])

    def test_websocket_link_forces_http_1_1_for_legacy_node(self):
        hub.ensure_config()
        node = hub.upsert_node(
            {
                "domain": "example.com",
                "password": "secret-pass",
                "transport": "ws",
                "alpn": "h2,http/1.1",
            }
        )

        link = hub.build_link(node)
        self.assertIn("alpn=http%2F1.1", link)
        self.assertNotIn("alpn=h2", link)

    def test_validation_helpers_reject_invalid_values(self):
        self.assertFalse(hub._token_ok("", "token"))
        self.assertFalse(hub._token_ok("short", "long"))
        self.assertTrue(hub._token_ok("token", "token"))
        for value in (True, 0, 65536, "0", "65536", "not-a-port"):
            with self.subTest(port=value), self.assertRaises(ValueError):
                hub._port(value)
        for value in (None, "", "bad host", "[::1", "[::1]:bad", "x\ny"):
            with self.subTest(bind=value), self.assertRaises(ValueError):
                hub._parse_bind(value)
        with self.assertRaises(ValueError):
            hub._text("\x7f", "value")
        with self.assertRaises(ValueError):
            hub._host("bad_host", "host")

        base = {
            "id": "id-1", "domain": "example.com", "password": "pw",
            "name": "name", "server": "example.com", "port": 443,
            "sni": "example.com", "host": "example.com", "path": "/",
            "transport": "ws", "alpn": "http/1.1", "enabled": True,
        }
        invalid_nodes = [
            1,
            {**base, "id": "bad id"},
            {**base, "transport": "udp"},
            {**base, "alpn": "bad space"},
            {**base, "enabled": "yes"},
            {**base, "created_at": -1},
        ]
        for node in invalid_nodes:
            with self.subTest(node=node), self.assertRaises(ValueError):
                hub._validate_node(node)

        invalid_payloads = [
            1,
            {"domain": "example.com", "password": "pw", "path": "relative", "transport": "udp"},
            {"domain": "example.com", "password": "pw", "alpn": "bad space"},
            {"domain": "example.com", "password": "pw", "enabled": 1},
            {"domain": "example.com", "password": "pw", "id": "bad id"},
        ]
        for payload in invalid_payloads:
            with self.subTest(payload=payload), self.assertRaises(ValueError):
                hub._node_from_payload(payload)
        self.assertEqual(
            "/relative",
            hub._node_from_payload(
                {"domain": "example.com", "password": "pw", "path": "relative"}
            )["path"],
        )
        with self.assertRaisesRegex(ValueError, "nodes must be an array"):
            hub.sync_domain_nodes(None)
        with mock.patch.object(hub, "MAX_NODES", 0):
            with self.assertRaisesRegex(ValueError, "too many nodes"):
                hub.sync_domain_nodes(
                    {"domain": "example.com", "server": "example.com", "nodes": [{}]}
                )

    def test_state_error_paths_and_upsert_replacement(self):
        invalid = Path(self.tempdir.name) / "invalid.json"
        invalid.write_bytes(b"\xff")
        with self.assertRaises(hub.DataStoreError):
            hub._load_json(invalid, {})

        hub.ensure_config()
        first = hub.upsert_node({"domain": "example.com", "password": "pw", "name": "one"})
        replaced = hub.upsert_node(
            {"id": first["id"], "domain": "example.com", "password": "pw2", "name": "two"}
        )
        self.assertEqual(first["id"], replaced["id"])
        self.assertEqual("two", hub.load_nodes()[0]["name"])
        self.assertEqual(0, hub.delete_node("missing"))
        self.assertIsNone(hub.rename_node("missing", "new"))
        self.assertEqual(0, hub.delete_by_credentials("", ""))
        self.assertEqual(0, hub.delete_by_credentials("example.com", "does-not-exist"))

        with mock.patch.object(hub, "MAX_NODES", 0):
            with self.assertRaises(hub.DataStoreError):
                hub.save_nodes([replaced])
        with self.assertRaises(hub.DataStoreError):
            hub._save_nodes_unlocked([{"not": "a node"}])

        hub.NODES_FILE.write_text(json.dumps({"nodes": {}}), encoding="utf-8")
        with self.assertRaises(hub.DataStoreError):
            hub.load_nodes()
        hub.NODES_FILE.write_text(json.dumps({"nodes": [replaced]}), encoding="utf-8")
        hub._nodes_cache_key = None
        hub._nodes_cache = None
        self.assertEqual(1, len(hub._load_nodes_unlocked()))
        hub._nodes_cache_key = None
        hub._nodes_cache = None
        with mock.patch.object(hub, "MAX_NODES", 0):
            with self.assertRaises(hub.DataStoreError):
                hub.load_nodes()

    def test_config_and_atomic_write_error_paths(self):
        hub.ensure_config()
        with mock.patch.object(hub.os, "chmod", side_effect=OSError):
            hub.save_nodes([])
        cfg = json.loads(hub.CFG_FILE.read_text(encoding="utf-8"))
        cfg["register_token"] = "bad\n"
        hub.CFG_FILE.write_text(json.dumps(cfg), encoding="utf-8")
        with self.assertRaises(hub.DataStoreError):
            hub.ensure_config()
        cfg["register_token"] = "valid"
        cfg["bind"] = "[127.0.0.1]"
        hub.CFG_FILE.write_text(json.dumps(cfg), encoding="utf-8")
        with self.assertRaises(hub.DataStoreError):
            hub.ensure_config()
        hub.CFG_FILE.write_text("[]", encoding="utf-8")
        with self.assertRaises(hub.DataStoreError):
            hub.ensure_config()

        with mock.patch.object(Path, "stat", side_effect=OSError):
            self.assertIsNone(hub._nodes_stat_key())
        with mock.patch.object(hub.os, "name", "nt"):
            hub.save_nodes([])

    def test_subscription_cache_and_link_variants(self):
        hub.ensure_config()
        node = hub.upsert_node(
            {
                "domain": "example.com", "password": "pw", "name": "n",
                "transport": "tcp", "alpn": "h2",
            }
        )
        self.assertEqual(hub.subscription_body(), hub.subscription_body())
        self.assertIn("alpn=h2", hub.build_link(node))
        self.assertIn("@example.com:443", hub.build_link(node, port=443))
        self.assertIn(
            "path=%2Frelative",
            hub.build_link({**node, "transport": "ws", "path": "relative"}),
        )
        self.assertEqual(b"", hub._encode_subscription([{**node, "enabled": False}], None, None))

    def test_invalid_node_field_fails_closed(self):
        hub.ensure_config()
        hub.upsert_node({"domain": "example.com", "password": "secret-pass"})
        data = json.loads(hub.NODES_FILE.read_text(encoding="utf-8"))
        data["nodes"][0]["password"] = 42
        hub.NODES_FILE.write_text(json.dumps(data), encoding="utf-8")

        with self.assertRaises(hub.DataStoreError):
            hub.load_nodes()

    def test_invalid_persisted_token_is_not_rotated(self):
        hub.ensure_config()
        data = json.loads(hub.CFG_FILE.read_text(encoding="utf-8"))
        data["register_token"] = ""
        hub.CFG_FILE.write_text(json.dumps(data), encoding="utf-8")

        with self.assertRaises(hub.DataStoreError):
            hub.ensure_config()
        persisted = json.loads(hub.CFG_FILE.read_text(encoding="utf-8"))
        self.assertEqual("", persisted["register_token"])

    def test_bind_parser_supports_ipv4_hostname_and_ipv6(self):
        self.assertEqual(("127.0.0.1", 2099), hub._parse_bind("127.0.0.1:2099"))
        self.assertEqual(("localhost", 2099), hub._parse_bind("localhost"))
        self.assertEqual(("::1", 8443), hub._parse_bind("[::1]:8443"))
        with self.assertRaises(ValueError):
            hub._parse_bind("::1:8443")

    def test_port_rejects_lossy_numeric_conversion(self):
        self.assertEqual(443, hub._port(443))
        self.assertEqual(443, hub._port("443"))
        with self.assertRaises(ValueError):
            hub._port(443.9)

    def test_save_failure_surfaces_as_datastore_error(self):
        # Parent is a regular file, so mkdir/replace fail with OSError; the store
        # must convert that into DataStoreError (clean 503) rather than propagate.
        blocker = Path(self.tempdir.name) / "blocker"
        blocker.write_text("x", encoding="utf-8")
        hub.NODES_FILE = blocker / "nodes.json"
        with self.assertRaises(hub.DataStoreError):
            hub.save_nodes([])

    def test_build_link_tcp_and_ipv6_and_overrides(self):
        node = {
            "domain": "example.com",
            "password": "secret-pass",
            "name": "n1",
            "transport": "tcp",
        }
        link = hub.build_link(node)
        self.assertIn("type=tcp", link)
        self.assertNotIn("type=ws", link)

        # IPv6 connect address must be bracketed in the authority.
        v6 = hub.build_link(node, server="2606:4700:4700::1111", port=2053)
        self.assertIn("@[2606:4700:4700::1111]:2053", v6)

        # A disabled node yields no link.
        self.assertEqual("", hub.build_link({**node, "enabled": False}))

    def test_delete_by_credentials_respects_name_filter(self):
        hub.ensure_config()
        hub.upsert_node({"domain": "hk.example.com", "password": "pw", "name": "a"})
        hub.upsert_node({"domain": "hk.example.com", "password": "pw", "name": "b"})

        # Name filter only removes the matching entry.
        self.assertEqual(1, hub.delete_by_credentials("hk.example.com", "pw", "a"))
        remaining = [n["name"] for n in hub.load_nodes()]
        self.assertEqual(["b"], remaining)

        # Without a name filter, all domain+password matches go.
        self.assertEqual(1, hub.delete_by_credentials("hk.example.com", "pw"))
        self.assertEqual([], hub.load_nodes())

    def test_nodes_cache_serves_copies_and_reflects_writes(self):
        hub.ensure_config()
        hub.upsert_node({"domain": "example.com", "password": "secret-pass", "name": "a"})

        first = hub.load_nodes()
        first[0]["name"] = "mutated-by-caller"
        # A caller mutating the returned list must not corrupt cached state.
        self.assertEqual("a", hub.load_nodes()[0]["name"])

        # A subsequent write is reflected on the next read (cache invalidated).
        hub.upsert_node({"domain": "example.com", "password": "secret-pass", "name": "b"})
        self.assertEqual({"a", "b"}, {n["name"] for n in hub.load_nodes()})

    def test_subscription_body_is_base64_of_links(self):
        hub.ensure_config()
        hub.upsert_node({"domain": "hk.example.com", "password": "secret-pass"})
        decoded = base64.b64decode(hub.subscription_body()).decode("utf-8")
        self.assertIn("trojan://", decoded)
        self.assertIn("hk.example.com", decoded)

        # ?server= rewrite changes the authority but keeps sni/host on the domain.
        decoded_ip = base64.b64decode(
            hub.subscription_body(server="1.2.3.4", port=2053)
        ).decode("utf-8")
        self.assertIn("@1.2.3.4:2053", decoded_ip)
        self.assertIn("sni=hk.example.com", decoded_ip)

    def test_sync_domain_nodes_is_atomic_and_preserves_stable_id(self):
        hub.ensure_config()
        first = hub.upsert_node(
            {"domain": "example.com", "password": "pw-1", "name": "old-name"}
        )
        hub.upsert_node(
            {"domain": "example.com", "password": "pw-2", "name": "removed"}
        )
        other = hub.upsert_node(
            {"domain": "other.example.com", "password": "other", "name": "other"}
        )

        synced = hub.sync_domain_nodes(
            {
                "domain": "example.com",
                "server": "example.com",
                "nodes": [{"password": "pw-1", "name": "new-name"}],
            }
        )

        self.assertEqual(1, len(synced))
        nodes = hub.load_nodes()
        current = next(n for n in nodes if n["domain"] == "example.com")
        self.assertEqual(first["id"], current["id"])
        self.assertEqual("new-name", current["name"])
        self.assertEqual({current["id"], other["id"]}, {n["id"] for n in nodes})

        before = hub.load_nodes()
        with self.assertRaises(ValueError):
            hub.sync_domain_nodes(
                {"domain": "example.com", "nodes": [{"password": "", "name": "bad"}]}
            )
        self.assertEqual(before, hub.load_nodes())

    def test_sync_scope_does_not_reuse_another_servers_id(self):
        hub.ensure_config()
        other_scope = hub.upsert_node(
            {
                "domain": "example.com",
                "server": "edge-a.example.com",
                "password": "shared-password",
                "name": "same-name",
            }
        )

        synced = hub.sync_domain_nodes(
            {
                "domain": "example.com",
                "server": "edge-b.example.com",
                "nodes": [
                    {
                        "server": "edge-b.example.com",
                        "password": "shared-password",
                        "name": "same-name",
                    }
                ],
            }
        )

        self.assertNotEqual(other_scope["id"], synced[0]["id"])
        self.assertEqual(2, len(hub.load_nodes()))

    def test_sync_scope_treats_legacy_missing_server_as_domain(self):
        hub.ensure_config()
        legacy = hub.upsert_node(
            {"domain": "example.com", "password": "legacy-password", "name": "old"}
        )
        persisted = json.loads(hub.NODES_FILE.read_text(encoding="utf-8"))
        persisted["nodes"][0].pop("server")
        hub.NODES_FILE.write_text(json.dumps(persisted), encoding="utf-8")
        hub._nodes_cache_key = None
        hub._nodes_cache = None

        synced = hub.sync_domain_nodes(
            {
                "domain": "example.com",
                "server": "example.com",
                "nodes": [{"password": "legacy-password", "name": "new"}],
            }
        )
        self.assertEqual(legacy["id"], synced[0]["id"])
        self.assertEqual(["new"], [n["name"] for n in hub.load_nodes()])

    def test_sync_rejects_duplicate_and_non_object_nodes_without_mutation(self):
        hub.ensure_config()
        before = hub.load_nodes()
        duplicate = {
            "domain": "example.com",
            "server": "example.com",
            "nodes": [
                {"password": "same", "name": "same"},
                {"password": "same", "name": "same"},
            ],
        }
        with self.assertRaisesRegex(ValueError, "duplicate"):
            hub.sync_domain_nodes(duplicate)
        with self.assertRaisesRegex(ValueError, "object"):
            hub.sync_domain_nodes(
                {"domain": "example.com", "server": "example.com", "nodes": [42]}
            )
        with self.assertRaisesRegex(ValueError, "sync scope"):
            hub.sync_domain_nodes(
                {
                    "domain": "example.com",
                    "server": "example.com",
                    "nodes": [{"server": "other.example.com", "password": "pw", "name": "other"}],
                }
            )
        self.assertEqual(before, hub.load_nodes())


class HubHandlerTests(unittest.TestCase):
    @staticmethod
    def make_reader(body=b"{}", **headers):
        handler = object.__new__(hub.Handler)
        handler.headers = Message()
        handler.headers["Content-Length"] = str(len(body))
        for name, value in headers.items():
            handler.headers[name.replace("_", "-")] = str(value)
        handler.rfile = io.BytesIO(body)
        handler.responses = []
        handler._json = lambda code, payload: handler.responses.append((code, payload))
        return handler

    def test_unauthorized_post_does_not_read_body(self):
        handler = object.__new__(hub.Handler)
        handler.path = "/api/register"
        handler.headers = Message()
        handler.headers["X-Hub-Token"] = "wrong-token"
        handler.headers["Content-Length"] = "7"
        handler.rfile = io.BytesIO(b"{broken")
        responses = []
        handler._json = lambda code, body: responses.append((code, body))
        handler._require_register_auth = lambda: hub.Handler._require_register_auth(
            handler,
            {"register_token": "correct-token"},
        )

        hub.Handler.do_POST(handler)

        self.assertEqual(401, responses[0][0])
        self.assertEqual(0, handler.rfile.tell())

    def test_audit_and_failure_helpers_are_defensive(self):
        class BrokenClient:
            @property
            def client_address(self):
                raise RuntimeError("no peer")

        handler = object.__new__(hub.Handler)
        handler.client_address = ("127.0.0.1", 1)
        hub.Handler._audit(handler, "test")
        broken = BrokenClient()
        hub.Handler._audit(broken, "test")

        failed = object.__new__(hub.Handler)
        failed.log_error = mock.Mock()
        failed._json = mock.Mock()
        hub.Handler._fail_state(failed, RuntimeError("internal"))
        failed.log_error.assert_called_once()
        failed._json.assert_called_once_with(503, {"error": "hub state unavailable"})

    def test_json_and_text_response_helpers_cover_head_and_optional_headers(self):
        handler = object.__new__(hub.Handler)
        handler.send_response = mock.Mock()
        handler.send_header = mock.Mock()
        handler.end_headers = mock.Mock()
        handler.wfile = io.BytesIO()
        handler._head_only = True
        hub.Handler._json(handler, 200, {"ok": True})
        hub.Handler._text(handler, 200, b"text", "text/plain")
        handler._head_only = False
        hub.Handler._text(handler, 200, b"text", "text/plain", {"X-Test": "yes"})
        self.assertEqual(b"text", handler.wfile.getvalue())

    def test_gzip_json_reader_accepts_large_sync_body(self):
        payload = {
            "domain": "large.example.com",
            "server": "large.example.com",
            "nodes": [
                {"name": f"node-{i}", "password": f"secret-{i}"}
                for i in range(1_600)
            ],
        }
        raw = json.dumps(payload).encode()
        self.assertGreater(len(raw), hub.MAX_BODY_BYTES)
        compressed = gzip.compress(raw, mtime=0)
        handler = self.make_reader(compressed, Content_Encoding="gzip")

        result = handler._read_json_object(
            max_body_bytes=hub.MAX_SYNC_BODY_BYTES,
            max_compressed_bytes=hub.MAX_SYNC_COMPRESSED_BYTES,
            allow_gzip=True,
        )

        self.assertEqual(1_600, len(result["nodes"]))
        self.assertEqual([], handler.responses)

    def test_json_reader_rejects_unsupported_broken_and_expanding_bodies(self):
        unsupported = self.make_reader(b"{}", Content_Encoding="br")
        self.assertIsNone(unsupported._read_json_object())
        self.assertEqual(415, unsupported.responses[0][0])

        gzip_on_regular_route = self.make_reader(gzip.compress(b"{}"), Content_Encoding="gzip")
        self.assertIsNone(gzip_on_regular_route._read_json_object())
        self.assertEqual(415, gzip_on_regular_route.responses[0][0])

        broken = self.make_reader(b"not-gzip", Content_Encoding="gzip")
        self.assertIsNone(broken._read_json_object(allow_gzip=True))
        self.assertEqual(400, broken.responses[0][0])

        expanding = self.make_reader(gzip.compress(b"x" * 33), Content_Encoding="gzip")
        self.assertIsNone(
            expanding._read_json_object(
                max_body_bytes=32, max_compressed_bytes=128, allow_gzip=True
            )
        )
        self.assertEqual(413, expanding.responses[0][0])

        wire_too_large = self.make_reader(gzip.compress(b"{}"), Content_Encoding="gzip")
        self.assertIsNone(
            wire_too_large._read_json_object(
                max_body_bytes=64, max_compressed_bytes=1, allow_gzip=True
            )
        )
        self.assertEqual(413, wire_too_large.responses[0][0])

    def test_json_reader_rejects_bad_lengths_and_json_shapes(self):
        invalid_length = self.make_reader()
        invalid_length.headers.replace_header("Content-Length", "NaN")
        self.assertIsNone(invalid_length._read_json_object())
        self.assertEqual(400, invalid_length.responses[0][0])

        negative = self.make_reader()
        negative.headers.replace_header("Content-Length", "-1")
        self.assertIsNone(negative._read_json_object())
        self.assertEqual(400, negative.responses[0][0])

        incomplete = self.make_reader(b"{}")
        incomplete.headers.replace_header("Content-Length", "3")
        self.assertIsNone(incomplete._read_json_object())
        self.assertEqual(400, incomplete.responses[0][0])

        for body in (b"{broken", b"\xff", b"[]"):
            handler = self.make_reader(body)
            self.assertIsNone(handler._read_json_object())
            self.assertEqual(400, handler.responses[0][0])

    def test_rate_limiting_and_pruning(self):
        hub._rate_limit_buckets.clear()
        hub._last_prune_time = time.monotonic() - 400.0
        # Check prune path with stale entry
        hub._rate_limit_buckets["198.51.100.1"] = (10.0, time.monotonic() - 400.0)
        self.assertTrue(hub._rate_limit_check("198.51.100.2"))
        self.assertNotIn("198.51.100.1", hub._rate_limit_buckets)

        # Deplete bucket for a test IP
        test_ip = "198.51.100.3"
        hub._rate_limit_buckets[test_ip] = (0.5, time.monotonic())
        self.assertFalse(hub._rate_limit_check(test_ip))

        # Check _client_ip helper fallback
        class DummyHandler:
            client_address = None
        self.assertEqual("unknown", hub._client_ip(DummyHandler()))
        class DummyEmptyHandler:
            client_address = ()
        self.assertEqual("unknown", hub._client_ip(DummyEmptyHandler()))


class HubHTTPTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        root = Path(self.tempdir.name)
        self.original_paths = (hub.HUB_DIR, hub.CFG_FILE, hub.NODES_FILE)
        hub.HUB_DIR = root
        hub.CFG_FILE = root / "config.json"
        hub.NODES_FILE = root / "nodes.json"
        hub._nodes_cache_key = None
        hub._nodes_cache = None
        hub._sub_cache_key = None
        hub._sub_cache_body = None
        hub._rate_limit_buckets.clear()
        hub._last_prune_time = 0.0
        self.cfg = hub.ensure_config()
        self.server = hub.LimitedThreadingHTTPServer(("127.0.0.1", 0), hub.Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        hub.HUB_DIR, hub.CFG_FILE, hub.NODES_FILE = self.original_paths
        hub._nodes_cache_key = None
        hub._nodes_cache = None
        hub._sub_cache_key = None
        hub._sub_cache_body = None
        self.tempdir.cleanup()

    def request(self, method, path, body=None, headers=None, authenticated=False):
        request_headers = dict(headers or {})
        if authenticated:
            request_headers["X-Hub-Token"] = self.cfg["register_token"]
        if isinstance(body, (dict, list)):
            body = json.dumps(body, separators=(",", ":")).encode()
            request_headers.setdefault("Content-Type", "application/json")
        connection = http.client.HTTPConnection(
            "127.0.0.1", self.server.server_address[1], timeout=3
        )
        try:
            connection.request(method, path, body=body, headers=request_headers)
            response = connection.getresponse()
            raw = response.read()
            response_headers = {k.lower(): v for k, v in response.getheaders()}
            if method == "HEAD":
                decoded = raw
            elif response_headers.get("content-type", "").startswith("application/json"):
                decoded = json.loads(raw or b"{}")
            else:
                decoded = raw
            return response.status, decoded, response_headers
        finally:
            connection.close()

    def test_http_read_routes_and_headers(self):
        status, health, headers = self.request("GET", "/health")
        self.assertEqual(200, status)
        self.assertEqual(0, health["nodes"])
        self.assertIn("no-store", headers["cache-control"])

        status, body, headers = self.request("HEAD", "/")
        self.assertEqual(200, status)
        self.assertEqual(b"", body)
        self.assertGreater(int(headers["content-length"]), 0)

        status, _, _ = self.request("GET", "/sub/wrong-token")
        self.assertEqual(401, status)

        registration = {
            "domain": "example.com",
            "password": "long-secret-password",
            "name": "main node",
        }
        status, created, _ = self.request(
            "POST",
            "/api/register",
            registration,
            headers={"Authorization": f"Bearer {self.cfg['register_token']}"},
        )
        self.assertEqual(200, status)
        self.assertEqual("example.com", created["node"]["domain"])
        self.request(
            "POST",
            "/api/register",
            {"domain": "short.example.com", "password": "short"},
            authenticated=True,
        )

        status, listing, _ = self.request("GET", "/api/nodes", authenticated=True)
        self.assertEqual(2, listing["count"])
        self.assertEqual({"lo***rd", "****"}, {n["password"] for n in listing["nodes"]})

        status, config, _ = self.request("GET", "/api/config", authenticated=True)
        self.assertEqual(200, status)
        self.assertEqual(self.cfg["sub_token"], config["sub_token"])

        status, encoded, headers = self.request(
            "GET", f"/sub/{self.cfg['sub_token']}?ip=1.2.3.4&port=2053"
        )
        self.assertEqual(200, status)
        decoded = base64.b64decode(encoded).decode()
        self.assertIn("@1.2.3.4:2053", decoded)
        self.assertEqual("1", headers["profile-update-interval"])

        self.assertEqual(
            400,
            self.request("GET", f"/sub/{self.cfg['sub_token']}?port=bad")[0],
        )
        self.assertEqual(
            400,
            self.request("GET", f"/sub/{self.cfg['sub_token']}?server=bad_host")[0],
        )
        self.assertEqual(401, self.request("GET", "/api/nodes")[0])
        self.assertEqual(401, self.request("GET", "/api/config")[0])
        self.assertEqual(404, self.request("GET", "/missing")[0])

    def test_http_mutation_routes(self):
        status, created, _ = self.request(
            "POST",
            "/api/register",
            {"domain": "example.com", "password": "secret", "name": "old"},
            authenticated=True,
        )
        self.assertEqual(200, status)
        node_id = created["node"]["id"]

        self.assertEqual(
            400,
            self.request(
                "POST",
                "/api/register",
                {"domain": "bad", "password": "secret"},
                authenticated=True,
            )[0],
        )
        status, renamed, _ = self.request(
            "POST", "/api/rename", {"id": node_id, "name": "new"}, authenticated=True
        )
        self.assertEqual(200, status)
        self.assertEqual("new", renamed["node"]["name"])
        self.assertEqual(
            400,
            self.request(
                "POST", "/api/rename", {"id": node_id, "name": ""}, authenticated=True
            )[0],
        )
        self.assertEqual(
            404,
            self.request(
                "POST", "/api/rename", {"id": "missing", "name": "name"}, authenticated=True
            )[0],
        )

        self.assertEqual(
            400,
            self.request("POST", "/api/delete", {}, authenticated=True)[0],
        )
        self.assertEqual(
            404,
            self.request(
                "POST", "/api/delete", {"id": "missing"}, authenticated=True
            )[0],
        )
        self.assertEqual(
            200,
            self.request("POST", "/api/delete", {"id": node_id}, authenticated=True)[0],
        )

        for route in ("/api/unregister", "/api/delete_by_password"):
            self.assertEqual(
                400,
                self.request("POST", route, {"domain": "example.com"}, authenticated=True)[0],
            )
        self.request(
            "POST",
            "/api/register",
            {"domain": "example.com", "password": "secret", "name": "to-remove"},
            authenticated=True,
        )
        status, removed, _ = self.request(
            "POST",
            "/api/delete_by_password",
            {"domain": "example.com", "password": "secret", "name": "to-remove"},
            authenticated=True,
        )
        self.assertEqual(200, status)
        self.assertEqual(1, removed["removed"])
        self.assertEqual(404, self.request("POST", "/not-an-api", {}, authenticated=True)[0])

    def test_http_sync_gzip_is_atomic_and_bounded(self):
        nodes = [{"name": f"n-{i}", "password": f"pw-{i}"} for i in range(1_800)]
        payload = json.dumps(
            {"domain": "large.example.com", "server": "large.example.com", "nodes": nodes},
            separators=(",", ":"),
        ).encode()
        self.assertGreater(len(payload), hub.MAX_BODY_BYTES)
        body = gzip.compress(payload, mtime=0)
        status, synced, _ = self.request(
            "POST",
            "/api/sync",
            body,
            headers={"Content-Type": "application/json", "Content-Encoding": "gzip"},
            authenticated=True,
        )
        self.assertEqual(200, status)
        self.assertEqual(1_800, synced["count"])

        before = hub.load_nodes()
        bad = gzip.compress(
            json.dumps(
                {
                    "domain": "large.example.com",
                    "server": "large.example.com",
                    "nodes": [{"name": "bad", "password": ""}],
                }
            ).encode()
        )
        self.assertEqual(
            400,
            self.request(
                "POST",
                "/api/sync",
                bad,
                headers={"Content-Type": "application/json", "Content-Encoding": "gzip"},
                authenticated=True,
            )[0],
        )
        self.assertEqual(before, hub.load_nodes())

        busy = mock.Mock()
        busy.acquire.return_value = False
        with mock.patch.object(hub, "SYNC_REQUEST_SLOTS", busy):
            self.assertEqual(
                429,
                self.request("POST", "/api/sync", {}, authenticated=True)[0],
            )
        busy.release.assert_not_called()

    def test_http_delete_verb(self):
        _, created, _ = self.request(
            "POST",
            "/api/register",
            {"domain": "example.com", "password": "secret"},
            authenticated=True,
        )
        node_id = created["node"]["id"]
        self.assertEqual(401, self.request("DELETE", f"/api/nodes/{node_id}")[0])
        self.assertEqual(
            200,
            self.request("DELETE", f"/api/nodes/{node_id}", authenticated=True)[0],
        )
        self.assertEqual(
            404,
            self.request("DELETE", f"/api/nodes/{node_id}", authenticated=True)[0],
        )
        self.assertEqual(404, self.request("DELETE", "/missing", authenticated=True)[0])

    def test_http_faults_map_to_safe_errors(self):
        # Auth/config failures happen before a request body is consumed.
        with mock.patch.object(hub, "ensure_config", side_effect=hub.DataStoreError("cfg")):
            self.assertEqual(
                503,
                self.request("GET", "/health")[0],
            )
            self.assertEqual(
                503,
                self.request("POST", "/api/register", {}, authenticated=True)[0],
            )

        malformed = self.request(
            "POST", "/api/register", b"{broken", authenticated=True,
            headers={"Content-Type": "application/json"},
        )
        self.assertEqual(400, malformed[0])
        malformed_sync = self.request(
            "POST", "/api/sync", b"{broken", authenticated=True,
            headers={"Content-Type": "application/json"},
        )
        self.assertEqual(400, malformed_sync[0])

        with mock.patch.object(hub, "load_nodes", side_effect=hub.DataStoreError("nodes")):
            self.assertEqual(503, self.request("GET", "/health")[0])
            self.assertEqual(503, self.request("GET", "/api/nodes", authenticated=True)[0])
        with mock.patch.object(hub, "subscription_body", side_effect=hub.DataStoreError("nodes")):
            self.assertEqual(503, self.request("GET", f"/sub/{self.cfg['sub_token']}")[0])

        with mock.patch.object(hub, "upsert_node", side_effect=hub.DataStoreError("save")):
            self.assertEqual(
                503,
                self.request(
                    "POST", "/api/register", {"domain": "example.com", "password": "pw"}, authenticated=True
                )[0],
            )
        with mock.patch.object(hub, "sync_domain_nodes", side_effect=hub.DataStoreError("save")):
            self.assertEqual(
                503,
                self.request(
                    "POST", "/api/sync", {"domain": "example.com", "server": "example.com", "nodes": []}, authenticated=True
                )[0],
            )
        with mock.patch.object(hub, "delete_node", side_effect=hub.DataStoreError("delete")):
            self.assertEqual(
                503,
                self.request("POST", "/api/delete", {"id": "id"}, authenticated=True)[0],
            )
            self.assertEqual(
                503,
                self.request("DELETE", "/api/nodes/id", authenticated=True)[0],
            )
        with mock.patch.object(hub, "rename_node", side_effect=hub.DataStoreError("rename")):
            self.assertEqual(
                503,
                self.request("POST", "/api/rename", {"id": "id", "name": "name"}, authenticated=True)[0],
            )
        with mock.patch.object(hub, "delete_by_credentials", side_effect=hub.DataStoreError("remove")):
            self.assertEqual(
                503,
                self.request(
                    "POST", "/api/unregister", {"domain": "example.com", "password": "pw"}, authenticated=True
                )[0],
            )

        # A plain subscription takes the cacheable no-override branch.
        self.assertEqual(200, self.request("GET", f"/sub/{self.cfg['sub_token']}")[0])

    def test_rate_limiting_http_rejection(self):
        with mock.patch.object(hub, "_rate_limit_check", return_value=False):
            status, data, _ = self.request("GET", "/health")
            self.assertEqual(429, status)
            self.assertEqual("rate limited", data.get("error"))

            status, data, _ = self.request(
                "POST", "/api/register", {"domain": "example.com", "password": "pw"}, authenticated=True
            )
            self.assertEqual(429, status)
            self.assertEqual("rate limited", data.get("error"))

            status, data, _ = self.request("DELETE", "/api/nodes/some-id", authenticated=True)
            self.assertEqual(429, status)
            self.assertEqual("rate limited", data.get("error"))


class HubInfrastructureTests(unittest.TestCase):
    def test_server_rejects_when_all_worker_slots_are_busy(self):
        server = hub.LimitedThreadingHTTPServer(("127.0.0.1", 0), hub.Handler)
        left, right = socket.socketpair()
        acquired = 0
        try:
            while server._slots.acquire(blocking=False):
                acquired += 1
            server.process_request(left, ("local", 0))
            self.assertEqual(64, acquired)
        finally:
            left.close()
            right.close()
            for _ in range(acquired):
                server._slots.release()
            server.server_close()

    def test_server_worker_reports_finish_errors_and_releases_slot(self):
        server = hub.LimitedThreadingHTTPServer(("127.0.0.1", 0), hub.Handler)
        left, right = socket.socketpair()
        finished = threading.Event()
        server.finish_request = mock.Mock(side_effect=RuntimeError("boom"))

        def report_error(*_args):
            finished.set()

        server.handle_error = mock.Mock(side_effect=report_error)
        server.shutdown_request = mock.Mock()
        try:
            server.process_request(left, ("local", 0))
            self.assertTrue(finished.wait(2))
            server.handle_error.assert_called_once()
            server.shutdown_request.assert_called_once()
            self.assertTrue(server._slots.acquire(blocking=False))
            server._slots.release()
        finally:
            left.close()
            right.close()
            server.server_close()

    def test_main_init_and_server_modes(self):
        with tempfile.TemporaryDirectory() as root:
            original_paths = (hub.HUB_DIR, hub.CFG_FILE, hub.NODES_FILE)
            try:
                hub.HUB_DIR = Path(root)
                hub.CFG_FILE = Path(root) / "config.json"
                hub.NODES_FILE = Path(root) / "nodes.json"
                with mock.patch.dict(
                    os.environ,
                    {"EASYTROJAN_HUB_DIR": root, "EASYTROJAN_HUB_LISTEN": "127.0.0.1:2099"},
                    clear=False,
                ), mock.patch.object(hub.sys, "argv", ["hub_server.py", "--init"]):
                    hub.main()
                self.assertTrue((Path(root) / "config.json").is_file())
            finally:
                hub.HUB_DIR, hub.CFG_FILE, hub.NODES_FILE = original_paths

        class FakeHTTP:
            def __init__(self, address, handler):
                self.address = address
                self.handler = handler

            def serve_forever(self):
                raise StopIteration

        with mock.patch.object(hub, "ensure_config", return_value={"bind": "127.0.0.1:2099"}), \
             mock.patch.object(hub, "LimitedThreadingHTTPServer", FakeHTTP), \
             mock.patch.dict(os.environ, {"EASYTROJAN_HUB_LISTEN": "127.0.0.1:2099"}, clear=False), \
             mock.patch.object(hub.sys, "argv", ["hub_server.py"]):
            with self.assertRaises(StopIteration):
                hub.main()

    def test_running_as_main_executes_init_path(self):
        with tempfile.TemporaryDirectory() as root, mock.patch.dict(
            os.environ,
            {"EASYTROJAN_HUB_DIR": root, "EASYTROJAN_HUB_LISTEN": "127.0.0.1:2099"},
            clear=False,
        ), mock.patch.object(hub.sys, "argv", ["hub_server.py", "--init"]):
            # runpy exercises the module guard as well as the --init entrypoint.
            runpy.run_path(str(Path(hub.__file__)), run_name="__main__")
            self.assertTrue((Path(root) / "nodes.json").is_file())


if __name__ == "__main__":
    unittest.main()
