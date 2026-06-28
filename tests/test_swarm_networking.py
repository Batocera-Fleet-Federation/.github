"""Swarm-level integration tests for the outbound-only networking redesign.

Black-box HTTP checks against the live Docker swarm (run after ``swarm-up.sh``),
complementing the in-process relay proof in ``test_edge_relay_integration.py``.

These verify the observable signals of the redesign in a real multi-container
deployment:

* Drones hold an outbound mux to the Edge, so Overmind sees them ``edge_online``
  (presence pushed over the mux + persisted to Postgres).
* The Super-Admin transfer-monitoring route is deployed and access-gated.
* Device records still expose the legacy reachability fields (backward compat).

Run after bringing the swarm up (these need the running containers)::

    .github/scripts/swarm-up.sh
    OVERMIND_URL=http://127.0.0.1:8000 python3 -m unittest \\
        .github.tests.test_swarm_networking -v
"""

import json
import os
import ssl
import time
import unittest
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen

OVERMIND_URL = os.environ.get("OVERMIND_URL", "http://127.0.0.1:8000").rstrip("/")
OVERMIND_EMAIL = os.environ.get("OVERMIND_EMAIL", "demo@example.com")
OVERMIND_PASSWORD = os.environ.get("OVERMIND_PASSWORD", "DemoPass123")
WAIT_SECONDS = int(os.environ.get("SWARM_TEST_WAIT_SECONDS", "120"))

_TLS = ssl._create_unverified_context()


def request_json(url, method="GET", payload=None, token=None, expected=200):
    headers = {"Accept": "application/json"}
    data = None
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = Request(url, data=data, method=method, headers=headers)
    try:
        ctx = _TLS if url.startswith("https://") else None
        with urlopen(req, timeout=10, context=ctx) as response:
            body = response.read().decode("utf-8", errors="replace")
            if response.status != expected:
                raise AssertionError(f"{url} returned {response.status}: {body[:200]}")
            return json.loads(body) if body else {}
    except HTTPError as error:
        body = error.read().decode("utf-8", errors="replace")
        if error.code == expected:
            try:
                return json.loads(body) if body else {}
            except json.JSONDecodeError:
                return {"body": body}
        raise AssertionError(f"{url} returned {error.code}: {body[:200]}") from error


class SwarmNetworkingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        deadline = time.time() + WAIT_SECONDS
        last_error = None
        while time.time() < deadline:
            try:
                request_json(f"{OVERMIND_URL}/health")
                break
            except (AssertionError, URLError, TimeoutError) as error:
                last_error = error
                time.sleep(3)
        else:
            raise AssertionError(f"Overmind did not become healthy: {last_error}")
        login = request_json(
            f"{OVERMIND_URL}/api/auth/login",
            method="POST",
            payload={"email": OVERMIND_EMAIL, "password": OVERMIND_PASSWORD},
        )
        cls.token = login["access_token"]

    def _devices(self):
        payload = request_json(f"{OVERMIND_URL}/api/devices", token=self.token)
        return payload.get("devices", [])

    def test_drones_report_edge_presence(self):
        """At least one Drone should connect outbound to the Edge and show
        edge_online -- proof the persistent mux works end-to-end in the swarm."""
        deadline = time.time() + WAIT_SECONDS
        online = []
        seen_field = False
        while time.time() < deadline:
            devices = self._devices()
            for device in devices:
                if "edge_online" in device:
                    seen_field = True
                if device.get("edge_online"):
                    online.append(device.get("device_id"))
            if online:
                break
            time.sleep(5)
        self.assertTrue(
            seen_field,
            "no device record exposed edge_online -- presence projection not wired",
        )
        self.assertTrue(
            online,
            "no Drone reported edge_online within the wait window "
            "(check the bff-edge container and DRONE_EDGE_ENABLED)",
        )

    def test_admin_transfers_route_is_deployed_and_gated(self):
        """The transfer-monitoring route exists and is Super-Admin gated; the demo
        (non-super-admin) user must be denied."""
        request_json(
            f"{OVERMIND_URL}/api/admin/transfers",
            token=self.token,
            expected=403,
        )

    def test_device_detail_keeps_reachability_fields(self):
        """Outbound-only must not drop the legacy reachability surface."""
        devices = self._devices()
        self.assertTrue(devices, "no devices registered")
        device_id = devices[0]["device_id"]
        detail = request_json(
            f"{OVERMIND_URL}/api/devices/{quote(device_id, safe='')}",
            token=self.token,
        )
        # The detail record should still carry the network/reachability surface
        # (now augmented with edge fields) rather than having been replaced.
        keys = set(detail.keys())
        self.assertTrue(
            keys & {"public_reachable_url", "public_resolvable", "reachable_url", "batocera_info"},
            f"device detail lost its reachability fields: {sorted(keys)[:20]}",
        )


if __name__ == "__main__":
    unittest.main()
