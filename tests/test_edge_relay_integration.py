"""In-process, cross-repo integration tests for the outbound-only networking redesign.

These wire the **real** Overmind Edge ``MuxServer`` (asyncio) and the **real**
Drone mux client + relay code (``app.transport``) over a self-signed TLS loopback
connection and move an actual asset's bytes through the Edge **relay** -- exactly
the production path, minus router/port-forward and minus TLS verification.

Unlike ``test_swarm_integration.py`` (black-box HTTP against the live Docker
swarm), this runs in-process and needs no Docker, so it gives CI a fast, real
end-to-end proof that:

* a Drone connects to the Edge with an outbound-only connection (HELLO/ACK),
* the control-plane TRANSFER_REQUEST -> Edge -> TRANSFER_OFFER handshake pairs
  two Drones,
* asset bytes flow Drone -> Edge relay -> Drone (never via the control plane),
* the Edge records the transfer-session lifecycle (active -> completed),
* an offline sender is reported rather than hanging.

Run just this file (the swarm HTTP tests in this dir need a running swarm)::

    python3 -m pytest .github/tests/test_edge_relay_integration.py -v
"""

import asyncio
import hashlib
import os
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

_ROOT = Path(__file__).resolve().parents[2]
_OVERMIND_SRC = _ROOT / "batocera.overmind" / "src"
_DRONE_ROOT = _ROOT / "batocera.drone"
for _p in (str(_OVERMIND_SRC), str(_DRONE_ROOT)):
    if _p not in sys.path:
        sys.path.insert(0, _p)

_IMPORT_ERROR = None
try:
    from overmind.edge.auth import AllowAllAuthenticator
    from overmind.edge.registry import PresenceRegistry
    from overmind.edge.relay import RelayHub
    from overmind.edge.server import MuxServer

    from app.transport import assetfetch, relay_transfer
    from app.transport.mux_client import MuxClient, MuxSession, connect_tls
except Exception as exc:  # noqa: BLE001 -- record why and skip, don't crash discovery
    _IMPORT_ERROR = exc


def _have_openssl() -> bool:
    return shutil.which("openssl") is not None


def _make_self_signed(dir_path: Path):
    cert = dir_path / "edge-cert.pem"
    key = dir_path / "edge-key.pem"
    subprocess.run(
        [
            "openssl", "req", "-x509", "-newkey", "rsa:2048",
            "-keyout", str(key), "-out", str(cert),
            "-days", "1", "-nodes", "-subj", "/CN=localhost",
        ],
        check=True,
        capture_output=True,
    )
    return cert, key


@unittest.skipIf(_IMPORT_ERROR is not None, f"transport imports unavailable: {_IMPORT_ERROR}")
@unittest.skipUnless(_have_openssl(), "openssl is required to generate a loopback TLS cert")
class EdgeRelayIntegrationTests(unittest.TestCase):
    """Real Drone client <-> real Edge server, over loopback TLS."""

    def setUp(self):
        self._tmp = Path(tempfile.mkdtemp(prefix="edge-relay-it-"))
        self.addCleanup(lambda: shutil.rmtree(self._tmp, ignore_errors=True))
        cert, key = _make_self_signed(self._tmp)
        self._server_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self._server_ctx.load_cert_chain(certfile=str(cert), keyfile=str(key))

        # Asset bigger than one chunk (256 KiB) so multiple CHUNK frames relay.
        self._roms = self._tmp / "roms"
        (self._roms / "nes").mkdir(parents=True)
        self._asset_bytes = os.urandom(300 * 1024)
        (self._roms / "nes" / "game.nes").write_bytes(self._asset_bytes)
        self._asset = {
            "kind": "rom",
            "system": "nes",
            "relative_path": "nes/game.nes",
            "expected_size": len(self._asset_bytes),
            "expected_hash": None,
        }

        self._clients = []
        self._client_threads = []
        self._loop = None
        self._loop_thread = None
        self._aio_server = None

    def tearDown(self):
        # Signal clients first so they don't reconnect when the server drops.
        for client in self._clients:
            try:
                client.stop()
            except Exception:
                pass
        # Tear the server/loop down before joining: closing the server drops the
        # connections, which unblocks the clients' blocking socket reads so their
        # threads exit promptly; cancelling lingering tasks avoids "task was
        # destroyed but it is pending" noise.
        if self._loop is not None:

            async def _shutdown():
                if self._aio_server is not None:
                    self._aio_server.close()
                    try:
                        await self._aio_server.wait_closed()
                    except Exception:
                        pass
                pending = [t for t in asyncio.all_tasks() if t is not asyncio.current_task()]
                for task in pending:
                    task.cancel()
                await asyncio.gather(*pending, return_exceptions=True)

            try:
                asyncio.run_coroutine_threadsafe(_shutdown(), self._loop).result(timeout=5)
            except Exception:
                pass
            self._loop.call_soon_threadsafe(self._loop.stop)
        for th in self._client_threads:
            th.join(timeout=5)
        if self._loop_thread is not None:
            self._loop_thread.join(timeout=5)
        if self._loop is not None:
            try:
                self._loop.close()
            except Exception:
                pass

    # --- harness ---------------------------------------------------------
    def _start_edge(self, transfer_status=None) -> int:
        """Start a real MuxServer on a loopback port; return the port."""
        server = MuxServer(
            authenticator=AllowAllAuthenticator(),
            registry=PresenceRegistry(),
            relay=RelayHub(),
            transfer_secret=None,  # tokens not enforced in this harness
            transfer_status=transfer_status,
            ping_interval=5.0,
        )
        self._loop = asyncio.new_event_loop()
        port_box = {}
        started = threading.Event()

        async def _boot():
            srv = await asyncio.start_server(
                server.handle_connection, "127.0.0.1", 0, ssl=self._server_ctx
            )
            self._aio_server = srv
            port_box["port"] = srv.sockets[0].getsockname()[1]
            started.set()

        def _run():
            asyncio.set_event_loop(self._loop)
            self._loop.run_until_complete(_boot())
            self._loop.run_forever()

        self._loop_thread = threading.Thread(target=_run, daemon=True)
        self._loop_thread.start()
        self.assertTrue(started.wait(timeout=10), "edge server did not start")
        return port_box["port"]

    def _start_client(self, port: int, device_id: str, on_offer=None) -> MuxClient:
        url = f"tls://127.0.0.1:{port}"
        client = MuxClient(
            connect=lambda: connect_tls(url, verify=False),
            session_factory=lambda: MuxSession(
                device_id=device_id, token="test-token", capabilities=["relay"]
            ),
            ping_interval=5.0,
            backoff_initial=0.2,
            on_transfer_offer=on_offer,
        )
        th = threading.Thread(target=client.run_forever, daemon=True)
        th.start()
        self._clients.append(client)
        self._client_threads.append(th)
        deadline = time.time() + 10
        while time.time() < deadline and not client.connected:
            time.sleep(0.05)
        self.assertTrue(client.connected, f"{device_id} never connected to the edge")
        return client

    def _make_sender(self, port: int, device_id: str, errors: list) -> MuxClient:
        """A sender drone that serves the local asset whenever offered."""
        holder = {}

        def on_offer(message):
            sid = message.get("session_id")

            def worker():
                def resolve(asset, offset):
                    return relay_transfer.open_local_file_source(
                        self._roms, asset.get("relative_path"), offset
                    )

                try:
                    relay_transfer.serve_asset(holder["client"], sid, resolve, ready_timeout=15)
                except Exception as exc:  # noqa: BLE001
                    errors.append(repr(exc))

            threading.Thread(target=worker, daemon=True).start()

        client = self._start_client(port, device_id, on_offer=on_offer)
        holder["client"] = client
        return client

    def _receive(self, receiver: MuxClient, session_id: str, from_device: str) -> bytes:
        channel = relay_transfer.open_receiver_channel(
            receiver, session_id, "test-token", from_device, self._asset, ready_timeout=15
        )
        sink = bytearray()
        try:
            assetfetch.download(channel, self._asset, sink.extend, offset=0)
        finally:
            channel.close()
        return bytes(sink)

    # --- tests -----------------------------------------------------------
    def test_relay_moves_asset_end_to_end(self):
        port = self._start_edge()
        errors = []
        self._make_sender(port, "drone-sender", errors)
        receiver = self._start_client(port, "drone-receiver")

        got = self._receive(receiver, "s" * 32, "drone-sender")

        self.assertEqual(len(got), len(self._asset_bytes))
        self.assertEqual(
            hashlib.sha256(got).hexdigest(),
            hashlib.sha256(self._asset_bytes).hexdigest(),
            "relayed bytes do not match the source asset",
        )
        self.assertEqual(errors, [], f"sender errors: {errors}")

    def test_transfer_lifecycle_is_recorded(self):
        events = []
        port = self._start_edge(transfer_status=lambda sid, status: events.append((sid, status)))
        errors = []
        self._make_sender(port, "drone-sender", errors)
        receiver = self._start_client(port, "drone-receiver")

        self._receive(receiver, "a" * 32, "drone-sender")

        # Give the graceful-close frames a moment to reach the edge.
        deadline = time.time() + 5
        while time.time() < deadline and ("a" * 32, "completed") not in events:
            time.sleep(0.05)
        statuses = [status for sid, status in events if sid == "a" * 32]
        self.assertIn("active", statuses, f"missing active in {events}")
        self.assertIn("completed", statuses, f"missing completed in {events}")

    def test_request_for_offline_sender_errors(self):
        port = self._start_edge()
        receiver = self._start_client(port, "drone-receiver")
        with self.assertRaises((ConnectionError, TimeoutError)):
            self._receive(receiver, "b" * 32, "drone-not-here")


if __name__ == "__main__":
    unittest.main()
