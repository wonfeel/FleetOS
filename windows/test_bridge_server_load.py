"""
test_bridge_server_load.py - load/concurrency tests for bridge_server.py,
separate from test_bridge_server.py's correctness-focused unit tests (which
exercise internal functions directly, no real socket). These spin up a REAL
bs.Server on an ephemeral localhost port and hammer it with real concurrent
HTTP requests from a thread pool - the things a single-threaded, function-
level test can't catch: races on shared state under ThreadingHTTPServer's
one-thread-per-request model, the rate limiter's actual behavior under
burst load, and the debounced state-save surviving concurrent writers
without corrupting bridge_state.json.

Run with (cwd must be windows/):
    py -m unittest test_bridge_server_load -v

Deliberately stdlib-only (urllib.request + concurrent.futures), matching
this project's "no pip install needed" rule - see bridge_server.py's own
module docstring.
"""
import json
import os
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

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


class LoadTestBase(unittest.TestCase):
    # A fresh real server per test class run (not per test method - actually
    # starting/stopping a ThreadingHTTPServer is cheap enough that per-method
    # would also be fine, but per-class keeps a load test's own run fast).
    @classmethod
    def setUpClass(cls):
        cls._tmp_state = tempfile.NamedTemporaryFile(delete=False, suffix=".json")
        cls._tmp_state.close()
        os.unlink(cls._tmp_state.name)
        cls._orig_state_path = bs.state_repo.state_path
        bs.state_repo.state_path = cls._tmp_state.name
        # Speeds up the state-consistency test below without waiting out the
        # real 2s default - see _state_flush_loop's own comment on why this
        # module-level constant is safe to reassign after the flush thread
        # (started once at import time) is already running: it re-reads the
        # global by name every loop iteration, not a value frozen at thread
        # start.
        cls._orig_flush_interval = bs.state_repo.flush_interval_seconds
        bs.state_repo.flush_interval_seconds = 0.2

        cls.server = bs.Server(("127.0.0.1", 0), bs.Handler)
        cls.port = cls.server.server_address[1]
        cls.base_url = f"http://127.0.0.1:{cls.port}"
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        bs.state_repo.state_path = cls._orig_state_path
        bs.state_repo.flush_interval_seconds = cls._orig_flush_interval
        if os.path.exists(cls._tmp_state.name):
            os.unlink(cls._tmp_state.name)
        if os.path.exists(cls._tmp_state.name + ".tmp"):
            os.unlink(cls._tmp_state.name + ".tmp")

    def setUp(self):
        # Fresh fleet state for every test method, same as
        # test_bridge_server.py's own setUp - a real server sitting on top
        # of the same module-level dicts still needs this per-test reset,
        # request-driven tests just can't reach into bs.state.nodes directly to
        # do it AS the test body the way the non-load tests do.
        with bs.state.lock:
            bs.state.nodes.clear()
            bs.state.results_by_id.clear()
            bs.state.broadcast_log.clear()
            bs.state.next_id = 1
            bs.state.request_times_by_ip.clear()
            for k in bs.state.metrics:
                bs.state.metrics[k] = 0


class ConcurrentNodeTrafficTests(LoadTestBase):
    # Simulates a fleet of N nodes each doing a poll+report cycle M times
    # concurrently - the actual traffic shape this server sees in
    # production, just compressed into a tight burst instead of spread
    # over real time.
    NODE_COUNT = 25
    CYCLES_PER_NODE = 8

    def _node_cycle(self, node_id):
        ok = 0
        for _ in range(self.CYCLES_PER_NODE):
            status, _ = _request(f"{self.base_url}/poll?node={node_id}")
            if status == 200:
                ok += 1
            status, _ = _request(
                f"{self.base_url}/report?node={node_id}", method="POST",
                body={"role": "test", "output": ["hi"], "outputCursor": 1})
            if status == 200:
                ok += 1
        return ok

    def test_many_nodes_concurrent_poll_report(self):
        node_ids = [f"loadtest_node_{i}" for i in range(self.NODE_COUNT)]
        start = time.time()
        with ThreadPoolExecutor(max_workers=self.NODE_COUNT) as pool:
            futures = [pool.submit(self._node_cycle, nid) for nid in node_ids]
            results = [f.result() for f in as_completed(futures)]
        elapsed = time.time() - start

        expected_per_node = self.CYCLES_PER_NODE * 2  # poll + report each cycle
        total_ok = sum(results)
        total_expected = expected_per_node * self.NODE_COUNT
        self.assertEqual(
            total_ok, total_expected,
            f"expected every poll/report to succeed (200), got {total_ok}/{total_expected} - "
            "a shortfall here means requests are failing under concurrency, not just running slow")

        rps = total_expected / elapsed if elapsed > 0 else float("inf")
        print(f"\n[load] {self.NODE_COUNT} nodes x {self.CYCLES_PER_NODE} poll+report cycles: "
              f"{total_expected} requests in {elapsed:.2f}s ({rps:.0f} req/s)")

        # All nodes must have actually registered - a race in get_node()
        # under concurrent first-poll-ever from many nodes at once would
        # show up here as a missing or duplicated entry.
        with bs.state.lock:
            self.assertEqual(set(bs.state.nodes.keys()), set(node_ids))


class ConcurrentCommandQueueTests(LoadTestBase):
    # The thing most likely to break under concurrency: next_id is a plain
    # module-level int incremented under `lock` - if any code path ever
    # touched it WITHOUT holding the lock, this test would catch it as a
    # duplicate or skipped id under real concurrent load (a single-threaded
    # test could never observe that race at all).
    COMMAND_COUNT = 200

    def test_concurrent_commands_get_unique_sequential_ids(self):
        def queue_one(i):
            status, data = _request(
                f"{self.base_url}/command", method="POST",
                body={"node": "loadtest_target", "type": "type", "text": f"echo {i}"},
                headers={"X-Fleet-Dashboard": "1"})
            return status, data

        with ThreadPoolExecutor(max_workers=32) as pool:
            results = list(pool.map(queue_one, range(self.COMMAND_COUNT)))

        statuses = [s for s, _ in results]
        self.assertTrue(
            all(s == 200 for s in statuses),
            f"expected every /command to succeed, got statuses: {set(statuses)}")

        ids = [d["id"] for _, d in results]
        self.assertEqual(len(ids), len(set(ids)), "duplicate command id under concurrent /command calls - a real race")

        with bs.state.lock:
            pending = bs.state.nodes["loadtest_target"]["pending"]
        self.assertEqual(
            len(pending), self.COMMAND_COUNT,
            "some queued commands went missing under concurrent load")
        pending_ids = [c["id"] for c in pending]
        self.assertEqual(len(pending_ids), len(set(pending_ids)), "duplicate id landed in pending queue")


class RateLimitBurstTests(LoadTestBase):
    def test_burst_over_limit_gets_429_then_recovers(self):
        orig_limit = bs.RATE_LIMIT_MAX_REQUESTS
        orig_window = bs.RATE_LIMIT_WINDOW_SECONDS
        bs.RATE_LIMIT_MAX_REQUESTS = 20
        bs.RATE_LIMIT_WINDOW_SECONDS = 1
        try:
            # All from this same process -> same source IP -> same rate
            # limit bucket. 3x the limit in one burst should reliably push
            # some requests over it.
            statuses = []
            for _ in range(60):
                status, _ = _request(f"{self.base_url}/status")
                statuses.append(status)

            self.assertIn(429, statuses, "expected at least one 429 once burst volume exceeded the limit")
            self.assertIn(200, statuses, "expected at least the first requests (under the limit) to still succeed")

            # Wait out the window, then confirm it recovers - not stuck
            # rejecting forever once tripped.
            time.sleep(bs.RATE_LIMIT_WINDOW_SECONDS + 0.5)
            status, _ = _request(f"{self.base_url}/status")
            self.assertEqual(status, 200, "rate limit should release once the window passes")
        finally:
            bs.RATE_LIMIT_MAX_REQUESTS = orig_limit
            bs.RATE_LIMIT_WINDOW_SECONDS = orig_window


class StateConsistencyUnderLoadTests(LoadTestBase):
    # Exercises the debounced-save mechanism (_mark_state_dirty/
    # _state_flush_loop, added to stop bridge_server.py writing a full
    # state snapshot to disk on every single request) under real concurrent
    # writers - confirms the eventual on-disk snapshot is valid JSON with
    # the right count, not just "the lock accounting looks right on paper".
    COMMAND_COUNT = 150

    def test_state_file_consistent_after_concurrent_writes(self):
        def queue_one(i):
            return _request(
                f"{self.base_url}/command", method="POST",
                body={"node": "loadtest_state_target", "type": "type", "text": f"x{i}"},
                headers={"X-Fleet-Dashboard": "1"})

        with ThreadPoolExecutor(max_workers=32) as pool:
            list(pool.map(queue_one, range(self.COMMAND_COUNT)))

        # Poll until the background flush thread has written a snapshot
        # that actually reflects ALL 150 writes - not just until a file
        # first appears. The flush loop can legitimately fire mid-burst and
        # persist a PARTIAL count (e.g. 135 of 150) if it happens to wake up
        # between two of the concurrent /command calls - that's correct,
        # expected debounce behavior (see _state_flush_loop's own comment:
        # it batches whatever landed since the last flush), and the very
        # next mutation re-marks state dirty, so the count keeps catching up
        # on subsequent flush cycles. Bailing out on the FIRST readable file
        # here (instead of the first one with the RIGHT count) would be
        # testing the debounce timing lottery, not correctness.
        deadline = time.time() + 5
        snapshot = None
        pending_count = None
        while time.time() < deadline:
            if os.path.exists(bs.state_repo.state_path):
                try:
                    with open(bs.state_repo.state_path, "r", encoding="utf-8") as f:
                        snapshot = json.load(f)
                    pending_count = len(snapshot.get("nodes", {}).get("loadtest_state_target", {}).get("pending", []))
                    if pending_count == self.COMMAND_COUNT:
                        break
                except json.JSONDecodeError:
                    pass  # caught mid-write (shouldn't happen - os.replace is atomic - but don't flake if it does)
            time.sleep(0.1)

        self.assertIsNotNone(snapshot, "bridge_state.json was never written within the deadline")
        self.assertEqual(
            pending_count, self.COMMAND_COUNT,
            f"on-disk state never converged to all {self.COMMAND_COUNT} writes within the deadline "
            f"(last seen: {pending_count}) - debounced save lost writes")


class SequentialThroughputSmokeTest(LoadTestBase):
    # Basic sanity, not a real benchmark: a few hundred quick sequential
    # requests shouldn't leak threads/connections or progressively slow
    # down (ThreadingHTTPServer spawns one thread per request with no cap -
    # see that class's own comment in bridge_server.py - this at least
    # catches a gross leak, not a subtle one).
    REQUEST_COUNT = 300

    def test_many_sequential_requests_stay_healthy(self):
        active_threads_before = threading.active_count()
        start = time.time()
        for _ in range(self.REQUEST_COUNT):
            status, _ = _request(f"{self.base_url}/health")
            self.assertEqual(status, 200)
        elapsed = time.time() - start
        print(f"\n[load] {self.REQUEST_COUNT} sequential /health requests in {elapsed:.2f}s "
              f"({self.REQUEST_COUNT / elapsed:.0f} req/s)")

        # Request-handling threads are short-lived (one per request, exits
        # when done) - a moment after the last response, the count should
        # have settled back down near where it started, not accumulated.
        time.sleep(0.5)
        active_threads_after = threading.active_count()
        self.assertLess(
            active_threads_after, active_threads_before + 10,
            f"thread count grew from {active_threads_before} to {active_threads_after} "
            "after sequential requests - possible thread leak")


if __name__ == "__main__":
    unittest.main()
