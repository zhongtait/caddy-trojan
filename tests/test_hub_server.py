import io
import json
import tempfile
import unittest
from email.message import Message
from pathlib import Path

import hub_server as hub


class HubStateTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        root = Path(self.tempdir.name)
        self.original_paths = (hub.HUB_DIR, hub.CFG_FILE, hub.NODES_FILE)
        hub.HUB_DIR = root
        hub.CFG_FILE = root / "config.json"
        hub.NODES_FILE = root / "nodes.json"

    def tearDown(self):
        hub.HUB_DIR, hub.CFG_FILE, hub.NODES_FILE = self.original_paths
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


class HubHandlerTests(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
