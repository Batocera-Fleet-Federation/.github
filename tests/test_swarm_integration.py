import base64
import json
import os
import ssl
import time
import unittest
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen


OVERMIND_URL = os.environ.get("OVERMIND_URL", "http://127.0.0.1:8000").rstrip("/")
DRONE_A_URL = os.environ.get("DRONE_A_URL", "https://127.0.0.1:8443").rstrip("/")
DRONE_B_URL = os.environ.get("DRONE_B_URL", "https://127.0.0.1:8444").rstrip("/")
DRONE_USER = os.environ.get("DRONE_APP_USERNAME", "admin")
DRONE_PASSWORD = os.environ.get("DRONE_APP_PASSWORD", "changeme")
OVERMIND_EMAIL = os.environ.get("OVERMIND_EMAIL", "demo@example.com")
OVERMIND_PASSWORD = os.environ.get("OVERMIND_PASSWORD", "DemoPass123")
WAIT_SECONDS = int(os.environ.get("SWARM_TEST_WAIT_SECONDS", "90"))


TLS_CONTEXT = ssl._create_unverified_context()


def request_json(url, method="GET", payload=None, token=None, basic_auth=None, expected=200):
    headers = {"Accept": "application/json"}
    data = None
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if basic_auth:
        raw = f"{basic_auth[0]}:{basic_auth[1]}".encode("utf-8")
        headers["Authorization"] = "Basic " + base64.b64encode(raw).decode("ascii")
    req = Request(url, data=data, method=method, headers=headers)
    try:
        with urlopen(req, timeout=10, context=TLS_CONTEXT if url.startswith("https://") else None) as response:
            body = response.read().decode("utf-8", errors="replace")
            if response.status != expected:
                raise AssertionError(f"{url} returned {response.status}: {body}")
            return json.loads(body) if body else {}
    except HTTPError as error:
        body = error.read().decode("utf-8", errors="replace")
        if error.code == expected:
            try:
                return json.loads(body) if body else {}
            except json.JSONDecodeError:
                return {"body": body}
        raise AssertionError(f"{url} returned {error.code}: {body}") from error


def request_bytes(url, basic_auth=None, expected=200):
    headers = {}
    if basic_auth:
        raw = f"{basic_auth[0]}:{basic_auth[1]}".encode("utf-8")
        headers["Authorization"] = "Basic " + base64.b64encode(raw).decode("ascii")
    req = Request(url, headers=headers)
    try:
        with urlopen(req, timeout=10, context=TLS_CONTEXT if url.startswith("https://") else None) as response:
            data = response.read()
            if response.status != expected:
                raise AssertionError(f"{url} returned {response.status}: {data[:200]!r}")
            return data, dict(response.headers)
    except HTTPError as error:
        body = error.read()
        if error.code == expected:
            return body, dict(error.headers)
        raise AssertionError(f"{url} returned {error.code}: {body[:200]!r}") from error


class SwarmIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        deadline = time.time() + WAIT_SECONDS
        last_error = None
        while time.time() < deadline:
            try:
                request_json(f"{OVERMIND_URL}/health")
                request_json(f"{DRONE_A_URL}/v1/api/systems", basic_auth=(DRONE_USER, DRONE_PASSWORD))
                request_json(f"{DRONE_B_URL}/v1/api/systems", basic_auth=(DRONE_USER, DRONE_PASSWORD))
                break
            except (AssertionError, URLError, TimeoutError) as error:
                last_error = error
                time.sleep(3)
        else:
            raise AssertionError(f"Swarm did not become healthy: {last_error}")
        login = request_json(
            f"{OVERMIND_URL}/api/auth/login",
            method="POST",
            payload={"email": OVERMIND_EMAIL, "password": OVERMIND_PASSWORD},
        )
        cls.overmind_token = login["access_token"]

        cls.devices = []
        deadline = time.time() + WAIT_SECONDS
        while time.time() < deadline:
            payload = request_json(f"{OVERMIND_URL}/api/devices", token=cls.overmind_token)
            cls.devices = payload.get("devices", [])
            if len(cls.devices) >= 2 and all((item.get("system_info") or {}) for item in cls.devices):
                break
            time.sleep(5)

    def test_overmind_and_drones_are_healthy(self):
        self.assertEqual(request_json(f"{OVERMIND_URL}/health")["status"], "ok")
        self.assertTrue(request_json(f"{DRONE_A_URL}/v1/api/systems", basic_auth=(DRONE_USER, DRONE_PASSWORD)))
        self.assertTrue(request_json(f"{DRONE_B_URL}/v1/api/systems", basic_auth=(DRONE_USER, DRONE_PASSWORD)))

    def test_multiple_drones_report_system_info(self):
        self.assertGreaterEqual(len(self.devices), 2)
        for device in self.devices:
            info = device.get("system_info") or {}
            self.assertTrue(info.get("hostname") or info.get("device_name"))
            self.assertIn("architecture", info)
            self.assertIn("container", info)

    def test_speed_samples_arrive(self):
        for device in self.devices[:2]:
            samples = request_json(f"{OVERMIND_URL}/api/devices/{quote(device['device_id'], safe='')}/speed", token=self.overmind_token)
            self.assertTrue(samples.get("samples"), f"missing speed sample for {device['device_id']}")

    def test_peer_summary_uses_latest_labels(self):
        for device in self.devices[:2]:
            detail = request_json(f"{OVERMIND_URL}/api/devices/{quote(device['device_id'], safe='')}", token=self.overmind_token)
            peers = detail.get("peer_checks") or []
            targets = {peer.get("target_drone_id") for peer in peers}
            self.assertEqual(len(targets), len(peers))
            for peer in peers:
                self.assertNotIn(peer.get("status"), ("RED", "GREEN"))
                self.assertIn(peer.get("status"), ("pass", "fail"))
                self.assertTrue(peer.get("target_name") or peer.get("target_drone_id"))

    def test_drone_rom_download_existing_and_missing(self):
        systems = request_json(f"{DRONE_A_URL}/v1/api/systems", basic_auth=(DRONE_USER, DRONE_PASSWORD))
        system_names = [item.get("name") for item in systems if item.get("name")]
        self.assertTrue(system_names)
        selected_system = system_names[0]
        roms = request_json(f"{DRONE_A_URL}/v1/api/systems/{quote(selected_system, safe='')}", basic_auth=(DRONE_USER, DRONE_PASSWORD))
        downloadable = [item for item in roms.get("roms", []) if item.get("unique_id") and item.get("is_downloadable", True)]
        self.assertTrue(downloadable)
        data, headers = request_bytes(
            f"{DRONE_A_URL}/v1/api/systems/{quote(selected_system, safe='')}/roms/{quote(downloadable[0]['unique_id'], safe='')}",
            basic_auth=(DRONE_USER, DRONE_PASSWORD),
        )
        self.assertGreater(len(data), 0)
        self.assertIn("attachment", headers.get("Content-Disposition", ""))
        body, _ = request_bytes(
            f"{DRONE_A_URL}/v1/api/systems/{quote(selected_system, safe='')}/roms/does-not-exist.zip",
            basic_auth=(DRONE_USER, DRONE_PASSWORD),
            expected=404,
        )
        self.assertIn(b"not found", body.lower())

    def test_api_admin_and_openapi_mtls_guidance(self):
        status = request_json(f"{DRONE_A_URL}/v1/api/admin/api/status", basic_auth=(DRONE_USER, DRONE_PASSWORD))
        self.assertIn("swagger_url", status)
        self.assertIn("certificate", status)
        self.assertNotIn("private_key", json.dumps(status).lower())
        spec = request_json(f"{DRONE_A_URL}/v1/api/openapi.json", basic_auth=(DRONE_USER, DRONE_PASSWORD))
        self.assertIn("mtls", json.dumps(spec).lower())
        cert, _ = request_bytes(f"{DRONE_A_URL}/v1/api/admin/api/certificate", basic_auth=(DRONE_USER, DRONE_PASSWORD))
        self.assertIn(b"BEGIN CERTIFICATE", cert)


if __name__ == "__main__":
    unittest.main()
