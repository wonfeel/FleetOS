"""
test_integration.py - end-to-end integration test: a real bridge_server.py
HTTP server talking to a REAL sim-node subprocess (craftos_shim.lua ->
fleetos.lua -> apps/common/fleetbridge.lua, the exact same path
windows/dashboard.html's "Create emulation" button uses) over real HTTP on
localhost. Every other test file in this project either calls
bridge_server.py's internals directly (test_bridge_server.py) or fakes a
node with raw HTTP requests (test_bridge_server_load.py) - neither can catch
a real protocol mismatch between the Python and Lua sides, a real
subprocess-spawn failure, or real end-to-end timing. This is the one test
that actually runs the Lua side as a separate process and watches the whole
poll/report/command/result cycle happen for real.

Requires a real `lua` interpreter on PATH AND Windows - skipped (not failed)
otherwise. windows/craftos_shim.lua (what the spawned sim node actually
runs) shells out to cmd.exe/ping.exe/powershell.exe by design (see its own
header comment) - it was never meant to run on Linux/Mac, so this would
hang or fail there for reasons that have nothing to do with what this test
is actually checking. See .github/workflows/ci.yml, which runs this
specific test only on a windows-latest runner.

Run with (cwd must be windows/):
    py -m unittest test_integration -v
"""
import json
import os
import shutil
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request

import bridge_server as bs


def _request(url, method="GET", body=None, headers=None):
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read().decode("utf-8"))
        except (json.JSONDecodeError, ValueError):
            return e.code, None


@unittest.skipUnless(sys.platform == "win32", "craftos_shim.lua is Windows-only (cmd.exe/ping.exe/powershell.exe)")
@unittest.skipUnless(shutil.which("lua"), "no 'lua' interpreter on PATH - install Lua 5.x to run this")
class RealSimNodeIntegrationTest(unittest.TestCase):
    NODE_ID = "integration_test_node"

    @classmethod
    def setUpClass(cls):
        cls._tmp_state = tempfile.NamedTemporaryFile(delete=False, suffix=".json")
        cls._tmp_state.close()
        os.unlink(cls._tmp_state.name)
        cls._orig_state_path = bs.state_repo.state_path
        bs.state_repo.state_path = cls._tmp_state.name

        # A scratch sim dir, NOT windows/sim/ - this test's spawned node
        # (and its whole simulated computer filesystem) must never touch a
        # real dev sim node someone might have running/inspecting locally.
        cls._tmp_sim_dir = tempfile.mkdtemp(prefix="fleetos_sim_test_")
        cls._orig_sim_dir = bs.SIM_DIR
        bs.SIM_DIR = cls._tmp_sim_dir

        cls._orig_sim_spawn_enabled = bs.SIM_SPAWN_ENABLED
        bs.SIM_SPAWN_ENABLED = True

        cls.server = bs.Server(("127.0.0.1", 0), bs.Handler)
        cls.port = cls.server.server_address[1]
        cls.base_url = f"http://127.0.0.1:{cls.port}"
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        with bs.state.lock:
            proc = bs.state.sim_processes.pop(cls.NODE_ID, None)
        if proc is not None and proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except Exception:
                proc.kill()

        cls.server.shutdown()
        cls.server.server_close()

        bs.state_repo.state_path = cls._orig_state_path
        bs.SIM_DIR = cls._orig_sim_dir
        bs.SIM_SPAWN_ENABLED = cls._orig_sim_spawn_enabled

        if os.path.exists(cls._tmp_state.name):
            os.unlink(cls._tmp_state.name)
        if os.path.exists(cls._tmp_state.name + ".tmp"):
            os.unlink(cls._tmp_state.name + ".tmp")
        shutil.rmtree(cls._tmp_sim_dir, ignore_errors=True)

    def _wait_for(self, predicate, timeout, description):
        deadline = time.time() + timeout
        last = None
        while time.time() < deadline:
            last = predicate()
            if last:
                return last
            time.sleep(0.2)
        self.fail(f"timed out waiting for: {description} (last seen: {last!r})")

    def test_full_cycle_spawn_report_command_result(self):
        # 1. Spawn a REAL sim node (same path as the dashboard's "Create
        # emulation" button) - a real lua.exe subprocess running
        # craftos_shim.lua -> fleetos.lua -> apps/common/fleetbridge.lua.
        status, data = _request(
            f"{self.base_url}/admin/spawn_sim_node", method="POST",
            body={"id": self.NODE_ID, "role": "integration-test"},
            headers={"X-Fleet-Dashboard": "1"})
        self.assertEqual(status, 200, f"spawn failed: {data}")
        self.assertTrue(data.get("ok"))
        self.assertIsInstance(data.get("pid"), int)

        # 2. Wait for it to actually poll/report for real - proves the
        # whole chain (lua process boot, fleetos.lua's kernel, fleetbridge's
        # HTTP client, this bridge's /poll+/report handlers) genuinely
        # works end to end, not just that a process was spawned.
        def has_reported():
            _, data = _request(f"{self.base_url}/status")
            node = (data or {}).get("nodes", {}).get(self.NODE_ID)
            return node if node and node.get("latest_report") else None

        node_status = self._wait_for(has_reported, timeout=30, description=f"{self.NODE_ID} to report")
        self.assertEqual(node_status["latest_report"]["role"], "integration-test")

        # 3. Queue a real command and wait for its result - the full
        # /command -> node's /poll -> node executes -> node's /report ->
        # /result/<id> round trip, driven by the real fleetbridge.lua poll
        # loop on its own schedule, not anything this test controls
        # directly. "help" (a real craftos_shim.lua builtin, not Lua code -
        # `type`'s text goes through shell.run's program dispatch, so it
        # has to be an actual program name) always succeeds and always
        # prints the same recognizable text, making it a reliable probe.
        status, data = _request(
            f"{self.base_url}/command", method="POST",
            body={"node": self.NODE_ID, "type": "type", "text": "help"},
            headers={"X-Fleet-Dashboard": "1"})
        self.assertEqual(status, 200, f"queue command failed: {data}")
        cmd_id = data["id"]

        def result_ready():
            _, data = _request(f"{self.base_url}/result/{cmd_id}")
            return data if data and data.get("found") else None

        result = self._wait_for(result_ready, timeout=15, description=f"result for command {cmd_id}")
        self.assertTrue(result["result"]["ok"], f"command reported failure: {result['result']}")

        # 4. The output "help" prints should show up in the node's captured
        # terminal output on its NEXT report - confirms output capture
        # (not just "the command didn't error").
        def marker_in_output():
            _, data = _request(f"{self.base_url}/status")
            node = (data or {}).get("nodes", {}).get(self.NODE_ID)
            output = (node or {}).get("latest_report", {}).get("output") or []
            return any("Built-in programs" in line for line in output) or None

        self._wait_for(marker_in_output, timeout=15, description="'help' output to appear in node output")


if __name__ == "__main__":
    unittest.main()
