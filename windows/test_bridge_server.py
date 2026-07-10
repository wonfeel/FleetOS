"""
test_bridge_server.py - unit tests for the reliability fixes in
bridge_server.py (this project had zero automated tests before this).
Exercises FleetState/StateRepository directly (no real HTTP socket needed)
since the interesting logic - broadcast seeding, inflight requeue, result
TTL/fetched, state persistence round-trip - all lives in methods on those
two classes, guarded by FleetState.lock.

Run with:
    py -m unittest test_bridge_server -v
"""
import os
import tempfile
import time
import unittest
from unittest.mock import patch

import bridge_server as bs


class BridgeServerTests(unittest.TestCase):
    def setUp(self):
        # Fresh in-memory state for every test, regardless of what a
        # previous test (or a real running bridge sharing this module) left
        # behind. STATE_PATH is redirected to a scratch file so no test ever
        # touches the real bridge_state.json next to this file.
        bs.state.nodes.clear()
        bs.state.results_by_id.clear()
        bs.state.broadcast_log.clear()
        bs.state.next_id = 1
        self._tmp_state = tempfile.NamedTemporaryFile(delete=False, suffix=".json")
        self._tmp_state.close()
        os.unlink(self._tmp_state.name)  # _load_state must tolerate a missing file
        self._orig_state_path = bs.state_repo.state_path
        bs.state_repo.state_path = self._tmp_state.name

    def tearDown(self):
        bs.state_repo.state_path = self._orig_state_path
        if os.path.exists(self._tmp_state.name):
            os.unlink(self._tmp_state.name)
        if os.path.exists(self._tmp_state.name + ".tmp"):
            os.unlink(self._tmp_state.name + ".tmp")

    # a "*" broadcast sent before a node ever registered must still
    # reach that node once it does register (get_node's seeding).
    def test_broadcast_reaches_future_node(self):
        cmd = {"id": 1, "type": "list"}
        bs.state.broadcast_log.append({"id": 1, "ts": time.time(), "cmd": cmd})
        node = bs.state.get_node("brand_new_node")
        self.assertIn(cmd, node["pending"])

    def test_stale_broadcast_not_seeded(self):
        cmd = {"id": 1, "type": "list"}
        old_ts = time.time() - bs.BROADCAST_LOG_TTL_SECONDS - 10
        bs.state.broadcast_log.append({"id": 1, "ts": old_ts, "cmd": cmd})
        node = bs.state.get_node("brand_new_node")
        self.assertEqual(node["pending"], [])

    # a command hand out via /poll (moved to "inflight") that never gets
    # acked by a matching /report result must be requeued into "pending"
    # after INFLIGHT_REQUEUE_SECONDS, not lost forever.
    def test_inflight_requeues_after_timeout(self):
        node = bs.state.get_node("node_a")
        cmd = {"id": 5, "type": "list"}
        old_ts = time.time() - bs.INFLIGHT_REQUEUE_SECONDS - 5
        node["inflight"]["5"] = {"cmd": cmd, "ts": old_ts}
        bs.state.sweep_inflight()
        self.assertNotIn("5", node["inflight"])
        self.assertIn(cmd, node["pending"])

    def test_inflight_not_requeued_before_timeout(self):
        node = bs.state.get_node("node_a")
        cmd = {"id": 6, "type": "list"}
        node["inflight"]["6"] = {"cmd": cmd, "ts": time.time()}
        bs.state.sweep_inflight()
        self.assertIn("6", node["inflight"])
        self.assertEqual(node["pending"], [])

    # an unfetched result gets a much longer grace period than a
    # fetched one before _prune_results drops it.
    def test_unfetched_result_survives_short_ttl(self):
        now = time.time()
        past_short_ttl = now - bs.RESULT_TTL_SECONDS - 5
        bs.state.results_by_id["1"] = {"result": {"ok": True}, "ts": past_short_ttl, "fetched": False}
        bs.state.prune_results()
        self.assertIn("1", bs.state.results_by_id)

    def test_fetched_result_dropped_after_short_ttl(self):
        now = time.time()
        past_short_ttl = now - bs.RESULT_TTL_SECONDS - 5
        bs.state.results_by_id["1"] = {"result": {"ok": True}, "ts": past_short_ttl, "fetched": True}
        bs.state.prune_results()
        self.assertNotIn("1", bs.state.results_by_id)

    def test_unfetched_result_dropped_after_long_ttl(self):
        now = time.time()
        past_long_ttl = now - bs.UNFETCHED_RESULT_TTL_SECONDS - 5
        bs.state.results_by_id["1"] = {"result": {"ok": True}, "ts": past_long_ttl, "fetched": False}
        bs.state.prune_results()
        self.assertNotIn("1", bs.state.results_by_id)

    # pending/inflight/results/broadcast_log/next_id must round-trip
    # through a save+load cycle exactly (a bridge restart shouldn't lose
    # queued work) - latest_report/latest_report_time are intentionally NOT
    # persisted (runtime-only, refreshed by the node itself).
    def test_state_round_trips_through_save_and_load(self):
        node = bs.state.get_node("node_a")
        node["pending"].append({"id": 9, "type": "list"})
        node["inflight"]["10"] = {"cmd": {"id": 10, "type": "list"}, "ts": time.time()}
        bs.state.results_by_id["9"] = {"result": {"ok": True}, "ts": time.time(), "fetched": False}
        bs.state.broadcast_log.append({"id": 11, "ts": time.time(), "cmd": {"id": 11, "type": "list"}})
        bs.state.next_id = 42

        bs.state_repo.save(bs.state)

        bs.state.nodes.clear()
        bs.state.results_by_id.clear()
        bs.state.broadcast_log.clear()
        bs.state.next_id = 1

        bs.state_repo.load(bs.state)

        self.assertEqual(bs.state.next_id, 42)
        self.assertIn("node_a", bs.state.nodes)
        self.assertEqual(bs.state.nodes["node_a"]["pending"], [{"id": 9, "type": "list"}])
        self.assertIn("10", bs.state.nodes["node_a"]["inflight"])
        self.assertIn("9", bs.state.results_by_id)
        self.assertEqual(len(bs.state.broadcast_log), 1)
        # runtime-only fields reset, not persisted
        self.assertIsNone(bs.state.nodes["node_a"]["latest_report"])

    # _save_state() writes a temp file then os.replace()s it over the real
    # path (a single atomic filesystem rename), specifically so a crash
    # mid-write can never leave bridge_state.json holding a truncated/
    # corrupt mix of old and new data - the reader only ever sees the
    # fully-old or the fully-new content, never something in between.
    # Simulates the crash landing at the worst possible moment (after the
    # new content is fully written to the .tmp file, right as the rename
    # itself would happen) and confirms the ORIGINAL file survives intact.
    def test_state_file_survives_crash_during_atomic_replace(self):
        node = bs.state.get_node("node_a")
        node["pending"].append({"id": 1, "type": "list"})
        bs.state.next_id = 2
        bs.state_repo.save(bs.state)

        with open(bs.state_repo.state_path, "r", encoding="utf-8") as f:
            good_content = f.read()
        self.assertIn('"next_id": 2', good_content)

        node["pending"].append({"id": 2, "type": "list"})
        bs.state.next_id = 3
        with patch("os.replace", side_effect=OSError("simulated crash during rename")):
            bs.state_repo.save(bs.state)  # must not raise - StateRepository.save catches OSError and logs

        with open(bs.state_repo.state_path, "r", encoding="utf-8") as f:
            survived_content = f.read()
        self.assertEqual(
            survived_content, good_content,
            "state file was modified even though the atomic replace was interrupted - "
            "a reader could have observed a half-written/corrupt file")

        # Un-patched, a normal save now succeeds and the update finally lands.
        bs.state_repo.save(bs.state)
        with open(bs.state_repo.state_path, "r", encoding="utf-8") as f:
            final_content = f.read()
        self.assertIn('"next_id": 3', final_content)

    def test_load_state_tolerates_missing_file(self):
        # setUp already ensured the scratch path doesn't exist - this should
        # not raise, just leave module state as-is.
        bs.state_repo.load(bs.state)

    # node_shell_pins (the "shell PIN" feature) is persisted to node_meta.json
    # alongside node_folders (NODE_META_VERSION 2) - same round-trip contract
    # as bridge_state.json above, plus the version-1-file migration path.
    def _with_scratch_node_meta(self, initial_content=None):
        tmp = tempfile.NamedTemporaryFile(delete=False, suffix=".json")
        if initial_content is not None:
            tmp.write(initial_content.encode("utf-8"))
        tmp.close()
        if initial_content is None:
            os.unlink(tmp.name)
        orig_path = bs.NODE_META_PATH
        bs.NODE_META_PATH = tmp.name
        self.addCleanup(setattr, bs, "NODE_META_PATH", orig_path)
        self.addCleanup(lambda: os.path.exists(tmp.name) and os.unlink(tmp.name))
        # Restore whatever the real node_meta.json had loaded at import time
        # (these tests mutate the module-level dicts directly) rather than
        # leaving scratch data behind for whichever test runs next.
        orig_folders = dict(bs.state.node_folders)
        orig_pins = dict(bs.state.node_shell_pins)

        def _restore():
            bs.state.node_folders.clear()
            bs.state.node_folders.update(orig_folders)
            bs.state.node_shell_pins.clear()
            bs.state.node_shell_pins.update(orig_pins)

        self.addCleanup(_restore)
        return tmp.name

    def test_shell_pin_round_trips_through_save_and_load(self):
        self._with_scratch_node_meta()
        bs.state.node_folders.clear()
        bs.state.node_shell_pins.clear()
        bs.state.node_shell_pins["node_a"] = bs._hash_shell_pin("1234")

        bs.state.save_node_folders()
        bs.state.node_shell_pins.clear()
        bs.state._load_node_folders()

        self.assertEqual(bs.state.node_shell_pins.get("node_a"), bs._hash_shell_pin("1234"))

    def test_shell_pin_missing_for_version_1_file(self):
        # A node_meta.json written before this feature existed (version 1,
        # no "shell_pins" key at all) must load with no PINs set, not crash.
        self._with_scratch_node_meta('{"version": 1, "data": {"node_a": "farm"}}')
        bs.state.node_folders.clear()
        bs.state.node_shell_pins.clear()

        bs.state._load_node_folders()

        self.assertEqual(bs.state.node_folders.get("node_a"), "farm")
        self.assertEqual(bs.state.node_shell_pins, {})

    # _merge_report (protocolVersion >= 2's payload-diet contract - see
    # fleetbridge.lua's report()/PROTOCOL_VERSION comments and this
    # function's own docstring in bridge_server.py).
    def _with_scratch_node_logs(self):
        tmp_dir = tempfile.mkdtemp()
        orig_dir = bs.NODE_LOGS_DIR
        bs.NODE_LOGS_DIR = tmp_dir
        bs._node_loggers.clear()
        self.addCleanup(setattr, bs, "NODE_LOGS_DIR", orig_dir)
        self.addCleanup(bs._node_loggers.clear)

    def test_merge_report_keeps_omitted_fields_from_previous_report(self):
        self._with_scratch_node_logs()
        node = bs.state.get_node("node_a")

        bs._merge_report(node, "node_a", {"id": "node_a", "role": "farm", "pos": {"x": 1, "y": 2, "z": 3}})
        # second report omits role/pos entirely (protocolVersion >= 2:
        # "unchanged since last successful report")
        bs._merge_report(node, "node_a", {"id": "node_a"})

        self.assertEqual(node["latest_report"]["role"], "farm")
        self.assertEqual(node["latest_report"]["pos"], {"x": 1, "y": 2, "z": 3})

    def test_merge_report_output_is_appended_not_replaced(self):
        self._with_scratch_node_logs()
        node = bs.state.get_node("node_b")

        bs._merge_report(node, "node_b", {"id": "node_b", "output": ["line1", "line2"], "outputCursor": 2})
        bs._merge_report(node, "node_b", {"id": "node_b", "output": ["line3"], "outputCursor": 3})

        self.assertEqual(node["latest_report"]["output"], ["line1", "line2", "line3"])

    def test_merge_report_ignores_duplicate_output_cursor(self):
        # An at-least-once HTTP retry resending the exact same delta must
        # not double-append it.
        self._with_scratch_node_logs()
        node = bs.state.get_node("node_c")

        bs._merge_report(node, "node_c", {"id": "node_c", "output": ["line1"], "outputCursor": 1})
        bs._merge_report(node, "node_c", {"id": "node_c", "output": ["line1"], "outputCursor": 1})

        self.assertEqual(node["latest_report"]["output"], ["line1"])

    def test_merge_report_output_tail_replaces_not_appends(self):
        self._with_scratch_node_logs()
        node = bs.state.get_node("node_d")

        bs._merge_report(node, "node_d", {"id": "node_d", "outputTail": "shell> "})
        bs._merge_report(node, "node_d", {"id": "node_d", "outputTail": "shell> l"})

        self.assertEqual(node["latest_report"]["output"], ["shell> l"])

    def test_merge_report_output_capped_at_max_stored(self):
        self._with_scratch_node_logs()
        node = bs.state.get_node("node_e")

        bs._merge_report(node, "node_e", {
            "id": "node_e",
            "output": [f"line{i}" for i in range(bs.MAX_OUTPUT_LINES_STORED + 50)],
            "outputCursor": bs.MAX_OUTPUT_LINES_STORED + 50,
        })

        self.assertEqual(len(node["latest_report"]["output"]), bs.MAX_OUTPUT_LINES_STORED)
        self.assertEqual(node["latest_report"]["output"][-1], f"line{bs.MAX_OUTPUT_LINES_STORED + 49}")


if __name__ == "__main__":
    unittest.main()
