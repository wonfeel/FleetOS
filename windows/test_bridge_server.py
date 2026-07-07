"""
test_bridge_server.py - unit tests for the reliability fixes in
bridge_server.py (this project had zero automated tests before this).
Exercises the module's internal state functions directly (no real HTTP
socket needed) since the interesting logic - broadcast seeding, inflight
requeue, result TTL/fetched, state persistence round-trip - all lives in
plain functions operating on module-level dicts guarded by `lock`.

Run with:
    py -m unittest test_bridge_server -v
"""
import os
import tempfile
import time
import unittest

import bridge_server as bs


class BridgeServerTests(unittest.TestCase):
    def setUp(self):
        # Fresh in-memory state for every test, regardless of what a
        # previous test (or a real running bridge sharing this module) left
        # behind. STATE_PATH is redirected to a scratch file so no test ever
        # touches the real bridge_state.json next to this file.
        bs.nodes.clear()
        bs.results_by_id.clear()
        bs.broadcast_log.clear()
        bs.next_id = 1
        self._tmp_state = tempfile.NamedTemporaryFile(delete=False, suffix=".json")
        self._tmp_state.close()
        os.unlink(self._tmp_state.name)  # _load_state must tolerate a missing file
        self._orig_state_path = bs.STATE_PATH
        bs.STATE_PATH = self._tmp_state.name

    def tearDown(self):
        bs.STATE_PATH = self._orig_state_path
        if os.path.exists(self._tmp_state.name):
            os.unlink(self._tmp_state.name)
        if os.path.exists(self._tmp_state.name + ".tmp"):
            os.unlink(self._tmp_state.name + ".tmp")

    # a "*" broadcast sent before a node ever registered must still
    # reach that node once it does register (get_node's seeding).
    def test_broadcast_reaches_future_node(self):
        cmd = {"id": 1, "type": "list"}
        bs.broadcast_log.append({"id": 1, "ts": time.time(), "cmd": cmd})
        node = bs.get_node("brand_new_node")
        self.assertIn(cmd, node["pending"])

    def test_stale_broadcast_not_seeded(self):
        cmd = {"id": 1, "type": "list"}
        old_ts = time.time() - bs.BROADCAST_LOG_TTL_SECONDS - 10
        bs.broadcast_log.append({"id": 1, "ts": old_ts, "cmd": cmd})
        node = bs.get_node("brand_new_node")
        self.assertEqual(node["pending"], [])

    # a command hand out via /poll (moved to "inflight") that never gets
    # acked by a matching /report result must be requeued into "pending"
    # after INFLIGHT_REQUEUE_SECONDS, not lost forever.
    def test_inflight_requeues_after_timeout(self):
        node = bs.get_node("node_a")
        cmd = {"id": 5, "type": "list"}
        old_ts = time.time() - bs.INFLIGHT_REQUEUE_SECONDS - 5
        node["inflight"]["5"] = {"cmd": cmd, "ts": old_ts}
        bs._sweep_inflight()
        self.assertNotIn("5", node["inflight"])
        self.assertIn(cmd, node["pending"])

    def test_inflight_not_requeued_before_timeout(self):
        node = bs.get_node("node_a")
        cmd = {"id": 6, "type": "list"}
        node["inflight"]["6"] = {"cmd": cmd, "ts": time.time()}
        bs._sweep_inflight()
        self.assertIn("6", node["inflight"])
        self.assertEqual(node["pending"], [])

    # an unfetched result gets a much longer grace period than a
    # fetched one before _prune_results drops it.
    def test_unfetched_result_survives_short_ttl(self):
        now = time.time()
        past_short_ttl = now - bs.RESULT_TTL_SECONDS - 5
        bs.results_by_id["1"] = {"result": {"ok": True}, "ts": past_short_ttl, "fetched": False}
        bs._prune_results()
        self.assertIn("1", bs.results_by_id)

    def test_fetched_result_dropped_after_short_ttl(self):
        now = time.time()
        past_short_ttl = now - bs.RESULT_TTL_SECONDS - 5
        bs.results_by_id["1"] = {"result": {"ok": True}, "ts": past_short_ttl, "fetched": True}
        bs._prune_results()
        self.assertNotIn("1", bs.results_by_id)

    def test_unfetched_result_dropped_after_long_ttl(self):
        now = time.time()
        past_long_ttl = now - bs.UNFETCHED_RESULT_TTL_SECONDS - 5
        bs.results_by_id["1"] = {"result": {"ok": True}, "ts": past_long_ttl, "fetched": False}
        bs._prune_results()
        self.assertNotIn("1", bs.results_by_id)

    # pending/inflight/results/broadcast_log/next_id must round-trip
    # through a save+load cycle exactly (a bridge restart shouldn't lose
    # queued work) - latest_report/latest_report_time are intentionally NOT
    # persisted (runtime-only, refreshed by the node itself).
    def test_state_round_trips_through_save_and_load(self):
        node = bs.get_node("node_a")
        node["pending"].append({"id": 9, "type": "list"})
        node["inflight"]["10"] = {"cmd": {"id": 10, "type": "list"}, "ts": time.time()}
        bs.results_by_id["9"] = {"result": {"ok": True}, "ts": time.time(), "fetched": False}
        bs.broadcast_log.append({"id": 11, "ts": time.time(), "cmd": {"id": 11, "type": "list"}})
        bs.next_id = 42

        bs._save_state()

        bs.nodes.clear()
        bs.results_by_id.clear()
        bs.broadcast_log.clear()
        bs.next_id = 1

        bs._load_state()

        self.assertEqual(bs.next_id, 42)
        self.assertIn("node_a", bs.nodes)
        self.assertEqual(bs.nodes["node_a"]["pending"], [{"id": 9, "type": "list"}])
        self.assertIn("10", bs.nodes["node_a"]["inflight"])
        self.assertIn("9", bs.results_by_id)
        self.assertEqual(len(bs.broadcast_log), 1)
        # runtime-only fields reset, not persisted
        self.assertIsNone(bs.nodes["node_a"]["latest_report"])

    def test_load_state_tolerates_missing_file(self):
        # setUp already ensured the scratch path doesn't exist - this should
        # not raise, just leave module state as-is.
        bs._load_state()


if __name__ == "__main__":
    unittest.main()
