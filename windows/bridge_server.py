"""
bridge_server.py - local HTTP bridge between your Windows PC and every
FleetOS computer in Minecraft. Every node runs apps/fleetbridge.lua and
polls/reports independently and directly - there's no single "master"
relaying for everyone else. Nodes are identified by config.lua's `id`.

Authentication is OPT-IN and off by default - only meant to be reachable
on 127.0.0.1. If you ever expose this beyond localhost (Tailscale,
FLEET_BRIDGE_HOST=0.0.0.0, port forwarding, etc.), set FLEET_BRIDGE_KEY
before starting this server; every request then needs a matching
X-API-Key header (apps/common/fleetbridge.lua reads its key from
config.lua's `apiKey` field or the same env var; dashboard.html has an
"API key" field next to the bridge address; fleetctl.py/install.lua read
FLEET_BRIDGE_KEY too). Without FLEET_BRIDGE_KEY set, there's still no
auth at all - anyone who can reach this can run/deploy code and
read/write files on any of your in-game computers. Binding beyond
127.0.0.1 (FLEET_BRIDGE_HOST) with no key set refuses to start at all
(set FLEET_BRIDGE_HOST_ALLOW_INSECURE=1 to override, see main()).

Every state-changing dashboard route (/command, /apps, /compute_scripts/*,
/pcfiles/write, /pcfiles/mkdir, /pcfiles/delete) also requires an
X-Fleet-Dashboard header regardless of FLEET_BRIDGE_KEY -
this is what actually stops a random cross-origin web page from firing
commands via a blind fetch()/form POST (CORS's Access-Control-Allow-Origin: *
only controls whether cross-origin JS can read a response, not whether the
request is sent at all). /report and /compute/<name> are exempt since only
fleetbridge.lua/raytower_master.lua (not a browser) call them.
dashboard.html sends this header on every call.

Other hardening in here: per-IP rate limiting, a max request body size,
result/output pruning so long-running memory doesn't grow unbounded, and
rotating file logging (see LOG_PATH) alongside console output.

Stdlib only, no pip install needed. Run with:
    python bridge_server.py [port]

Endpoints:
    GET  /            - web dashboard (open this in a browser)
    GET  /install.lua  - one-time bootstrap loader for a FRESH CC:Tweaked
                         computer - the only file you `wget` by hand; it
                         fetches fleetos.lua + the base apps and writes a
                         starter config.lua itself (see install.lua's header)
    GET  /fleetos.lua  - raw source of the kernel itself (install.lua fetches
                         this - you normally don't need to touch it directly)
    GET  /triangulation.lua - raw source of the shared triangulation module
                         (apps/raytower/raytower_master.lua dofile()s this as
                         a top-level file - the dashboard pushes it alongside
                         a raytower_master deploy since it's not an app itself)
    GET  /apps         - {groups: [{name, apps: [...]}], names: [...]} of
                         every app available in game/apps/, grouped by folder
    POST /apps         - creates a brand NEW app: {name, group, content} ->
                         writes game/apps/<group>/<name>.lua (group must be
                         one of APP_GROUPS, or omitted/"other" for flat
                         apps/<name>.lua); fails if that name already exists
    GET  /apps/<name>.lua - raw source of one app (fleetbridge.lua's "deploy"
                            fetches this directly - no pastebin needed for
                            apps that already live in game/apps/)
    POST /apps/<name>.lua - saves edited source back to disk on THIS PC
                            (does not touch any real in-game computer - Deploy
                            afterwards to push it out)
    GET  /poll?node=<id>   - each node's fleetbridge.lua calls this with its
                             own id; returns & clears commands queued for it
                             (or for "*") and auto-registers the node. Also
                             sets an X-Shell-Pin-Set response header (see
                             /admin/shell_pin) so fleetbridge.lua can cache
                             locally whether Ctrl+T needs a PIN, without a
                             separate request
    POST /report?node=<id> - each node's fleetbridge.lua calls this after
                             every poll; stores that node's latest status
                             (running apps, recent terminal output) + indexes
                             command results by id. protocolVersion >= 2
                             sends most fields only when changed since the
                             last successful report (merged, not replaced -
                             see the handler) and `output` as an
                             outputCursor-gated delta instead of resending
                             the full window every cycle
    GET  /status       - dashboard/fleetctl.py call this; every known node's
                         latest status, keyed by node id
    GET  /result/<id>  - dashboard polls this for a specific command's result
                         (e.g. readfile content), so a slow poll cycle can't miss it
    POST /command      - dashboard/fleetctl.py call this; body needs a `node`
                         (a specific node id, or "*" to queue for every node
                         known so far)
    POST /node_folder  - {node, folder} assigns a node to a dashboard-side
                         folder ("" clears it) - persisted to node_meta.json,
                         exposed back via /status's per-node `folder` field
    POST /admin/shell_pin - {nodes: [...], pin} sets (or, pin="", clears) the
                         PIN apps/common/shell.lua requires locally before a
                         `bridge <url> [key]` override on those node ids -
                         persisted to node_meta.json alongside folders
    POST /shell_pin_check?node=<id> - called by apps/common/fleetbridge.lua
                         (not the dashboard) to verify a locally-typed PIN
                         against the hash set via /admin/shell_pin above;
                         {"required": false, "ok": true} if no PIN is set
                         for that node at all (the default)
    POST /admin/delete_node - {nodes: [...]} removes those node ids from
                         the fleet view (status, folder, shell PIN) -
                         bridge-side only, a still-polling node reappears
                         on its next report
    POST /admin/spawn_sim_node - {id, role} starts a local Windows-
                         simulated computer (windows/sim/<id>/, driven by
                         run_sim_node.lua) as a real subprocess of this
                         bridge process - dev/testing only, disabled unless
                         FLEET_ENABLE_SIM_SPAWN=1 is set (same reasoning as
                         COMPUTE_ENABLED: it's OS code execution, just of
                         our own known script rather than an arbitrary one)
    POST /compute/<name>[?node=<id>] - runs windows/compute/<name>.py (or
                         <name>.exe if no .py exists) as a subprocess, feeding
                         the JSON request body via stdin and returning
                         whatever JSON it prints to stdout - lets heavy/
                         non-realtime logic (e.g. apps/raytower/
                         raytower_master.lua's triangulation) run in
                         Python/C++ on the PC instead of Lua in-game. If
                         stdout ISN'T valid JSON, it's wrapped as
                         {"output": "<raw text>"} instead of failing outright
                         - convenient for a quick/dirty script that just
                         print()s plain text while you're still writing it.
                         The optional ?node=<id> opts the script into "world
                         access": FLEETOS_NODE/FLEETOS_BRIDGE_URL env vars are
                         set so it can `from fleetos_world import world` and
                         call world.print()/gps_locate()/peripheral_call() -
                         each is relayed to that node's real fleetbridge.lua
                         via POST /world_call below and actually executed as
                         Lua there, so the script's output shows up in that
                         node's terminal/monitor and it can read real sensors,
                         same as an in-game program. Without ?node=, those
                         calls fail fast instead - existing scripts (e.g.
                         triangulation.py) are unaffected either way. Called
                         by a CC:Tweaked computer, not a browser - see the
                         CSRF note below for why it's exempt from that.
    POST /world_call     {node, action, args} - queues a "world_call" command
                         for `node` exactly like POST /command does, and
                         blocks until that node's own poll loop executes it
                         (print/gps_locate/peripheral_call/list_peripherals)
                         and reports a result back, then returns it. Only
                         ever called by a running /compute/<name> subprocess
                         (via windows/compute/fleetos_world.py), never a
                         browser - see the CSRF note below.
    GET  /compute_scripts - {names: [...]} of every windows/compute/<name>.py
                         script (dashboard's "Compute scripts" editor)
    GET  /compute_scripts/<name> - raw source of one compute script's .py file
    POST /compute_scripts/<name> - creates/saves windows/compute/<name>.py
                         from {content}: dashboard-only editing, separate from
                         actually running it (POST /compute/<name> above)
    GET  /pcfiles?root=game|compute&path=<rel> - lists one directory under
                         game/ or windows/compute/ ON THIS PC (dashboard
                         Explorer's "This PC" source - browsing game/ mirrors
                         exactly what a real computer's fs looks like, since
                         it's the master copy everything is deployed from)
    GET  /pcfiles/read?root=...&path=<rel> - raw content of one PC-side file
    POST /pcfiles/write  {root, path, content} - create/overwrite a PC-side
                         file (creates parent dirs as needed - also how
                         drag-and-drop upload writes each dropped file)
    POST /pcfiles/mkdir  {root, path} - create a PC-side directory
    POST /pcfiles/delete {root, path} - delete a PC-side file or directory
                         (recursively)
    POST /pcfiles/move   {root, from, to} - rename/move a PC-side file or
                         directory
"""

import hashlib
import hmac
import json
import logging
import logging.handlers
import os
import re
import secrets
import shutil
import signal
import subprocess
import sys
import threading
import time
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, parse_qs

# Path resolution/containment/name-validation helpers (resolve_pc_path,
# resolve_compute_script, resolve_app_path, PC_ROOTS, GAME_DIR/APPS_DIR/
# COMPUTE_DIR/etc, and friends) live in bridge_paths.py - genuinely
# self-contained (explicit args in, value out, none of them touch this
# file's mutable fleet state), split out to shrink what you need to read to
# understand request handling here. Named import, not `import *` -
# bridge_paths.py's own SCRIPT_DIR isn't in this list on purpose, so it
# never shadows this file's own SCRIPT_DIR (defined separately below).
from bridge_paths import (  # noqa: F401
    GAME_DIR, APPS_DIR, FLEETOS_PATH, INSTALL_PATH, TRIANGULATION_PATH,
    DASHBOARD_PATH, DOCS_DIR, SIM_DIR, RUN_SIM_NODE_PATH, COMPUTE_DIR,
    PC_ROOTS, APP_GROUPS,
    resolve_compute_script, list_compute_script_names, is_valid_compute_name,
    is_valid_sim_node_id, is_valid_sim_role, lua_quote,
    resolve_pc_path, list_pc_entries,
    list_app_names, list_apps_grouped, resolve_app_path,
)

# Opt-in: unset/empty means no auth at all (the historical, still-default
# behavior for a plain 127.0.0.1 bridge). Set this before starting the
# server to require a matching X-API-Key header on every request.
API_KEY = os.environ.get("FLEET_BRIDGE_KEY", "")

# Optional second, weaker key: grants read-only access (/status,
# /result/<id>, /apps, /pcfiles listing+read, /compute_scripts listing+read)
# but is rejected by every state-changing route (/command, file writes,
# /compute/<name> execution, etc - see _check_auth's require_full). Handing
# this out instead of FLEET_BRIDGE_KEY to a viewer/second machine means a
# leaked read-only key can't run code or touch files - only FLEET_BRIDGE_KEY
# can. Meaningless unless FLEET_BRIDGE_KEY is also set.
READONLY_API_KEY = os.environ.get("FLEET_BRIDGE_READONLY_KEY", "")

# /compute/<name> runs an arbitrary local .py/.exe with the same OS
# privileges as this process - real code execution, not sandboxed in any way.
# Off by default; an operator has to deliberately opt in even if they've set
# an API key, since a leaked/guessed key would otherwise mean full RCE on the
# host PC (not just the Minecraft computers).
COMPUTE_ENABLED = os.environ.get("FLEET_ENABLE_COMPUTE") == "1"

# POST /admin/spawn_sim_node starts a real `lua` OS process (windows/
# run_sim_node.lua, see windows/sim/) - only meaningful for local dev/
# testing (a Windows-emulated stand-in for a real in-game computer), but
# it's still spawning a subprocess on the host PC, so it gets the same
# opt-in treatment as COMPUTE_ENABLED above rather than being always-on.
SIM_SPAWN_ENABLED = os.environ.get("FLEET_ENABLE_SIM_SPAWN") == "1"

# basic health/metrics - previously the only way to guess at bridge
# health was to poll /status and eyeball whether nodes look recent, and there
# were no counters at all to notice a degrading system (rising error rate,
# rate-limit hits) before it became a visible outage.
START_TIME = time.time()
HEALTH_RECENT_SECONDS = 30  # a node counts as "reporting recently" for /health if its last report is within this

# ---- GET /metrics/history - reconstructs the same counters as
# FleetState.metrics, bucketed over time, straight from bridge.log (+ its
# rotated bridge.log.1, .2, ... siblings) instead of a live in-process
# accumulator. FleetState.metrics itself only ever holds the CURRENT
# cumulative total since this process started - no way to ask "what was the
# poll rate 20 minutes ago", and a dashboard reload loses even the
# client-side history it had been building up. The log already has
# everything needed (timestamp, method, path, status on every request)
# since BaseHTTPRequestHandler's default log_request call - this just
# re-derives the same per-request classification state.metric_inc()'s call
# sites use, from that text instead of from a live counter. HONEST LIMIT:
# only covers whatever log retention is
# actually on disk (RotatingFileHandler's backupCount below) - a busy fleet
# rotates through that faster than a quiet one, so "week" can come back
# short; `coverage_seconds` in the response tells the caller exactly how
# far back real data actually goes, instead of silently zero-filling.
METRICS_HISTORY_RANGES = {
    # range key -> (total span in seconds, bucket width in seconds)
    "minute": (60, 5),
    "15m": (900, 30),
    "hour": (3600, 60),
    "24h": (86400, 900),
    "week": (604800, 7200),
}
METRICS_HISTORY_FIELDS = (
    "polls_served", "reports_received", "commands_queued",
    "results_fetched", "rate_limited", "http_errors",
)
# Matches log_message's own output format below (Handler.log_message just
# logs `fmt % args` unchanged, and BaseHTTPRequestHandler's default
# log_request builds that from self.requestline/code/size) - e.g.:
#   2026-07-09 02:26:48,122 [bridge] "POST /report?node=X HTTP/1.1" 200 -
# Path is captured only up to the first "?"/space/quote - enough to tell
# routes apart (/poll vs /report vs /command) without caring about query
# strings, matching how the live counters key off self.path (already
# stripped of its query string by do_GET before any _metric_inc call).
_LOG_LINE_RE = re.compile(
    r'^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}),\d+ \[bridge\] "(\S+) ([^\s"?]+)[^"]*" (\d+)')


def _categorize_log_line(method, path, status):
    # Deliberately mirrors the exact conditions at each state.metric_inc() call
    # site above (see /poll, /report, /command, /result/<id> handlers, and
    # _check_rate_limit/_send_json) - kept in sync BY HAND, not derived
    # automatically, so a change to what increments a live counter needs
    # the same change made here, or historical and live numbers drift
    # apart. Also note: a 429 increments BOTH rate_limited AND http_errors,
    # same as live (_send_json increments http_errors_total for ANY
    # status >= 400, including the 429 _check_rate_limit already sent).
    counts = {}
    if status == 200:
        if method == "GET" and path == "/poll":
            counts["polls_served"] = 1
        elif method == "POST" and path == "/report":
            counts["reports_received"] = 1
        elif method == "POST" and path == "/command":
            counts["commands_queued"] = 1
        elif method == "GET" and path.startswith("/result/"):
            counts["results_fetched"] = 1
    if status == 429:
        counts["rate_limited"] = 1
    if status >= 400:
        counts["http_errors"] = 1
    return counts


def _log_files_newest_first():
    # bridge.log is always current; RotatingFileHandler names older ones
    # bridge.log.1 (most recently rotated) through bridge.log.<backupCount>
    # (oldest) - so this order is already newest-to-oldest.
    paths = [LOG_PATH]
    i = 1
    while True:
        candidate = f"{LOG_PATH}.{i}"
        if not os.path.isfile(candidate):
            break
        paths.append(candidate)
        i += 1
    return paths


def _iter_log_lines_reverse(path, chunk_size=65536):
    # Yields raw lines newest-first without ever loading the whole file
    # into memory - lets _metrics_history_buckets stop as soon as it has
    # walked back past the requested window instead of always parsing an
    # entire (up to 1MB, or up to backupCount of them for "week") log file
    # start-to-finish on every request, which is what made short ranges
    # (minute/15m/hour - only needing the tail) pay the same cost as week.
    try:
        f = open(path, "rb")
    except OSError:
        return
    with f:
        f.seek(0, os.SEEK_END)
        pos = f.tell()
        trailing = b""
        while pos > 0:
            read_size = min(chunk_size, pos)
            pos -= read_size
            f.seek(pos)
            chunk = f.read(read_size)
            data = chunk + trailing
            parts = data.split(b"\n")
            trailing = parts[0]  # possibly a partial line - prepend to next (earlier) chunk
            for raw in reversed(parts[1:]):
                if raw:
                    yield raw.decode("utf-8", errors="replace")
        if trailing:
            yield trailing.decode("utf-8", errors="replace")


def _parse_log_ts(ts_str):
    # ts_str is always 'YYYY-MM-DD HH:MM:SS' (fixed width, from _LOG_LINE_RE) -
    # slicing out the ints directly and handing mktime an already-built
    # tuple skips strptime's generic format-string parsing (its regex and
    # locale/month-name lookups), which is most of its cost. mktime itself
    # still resolves DST correctly since it gets the real date+time, not an
    # offset added after the fact.
    return time.mktime((
        int(ts_str[0:4]), int(ts_str[5:7]), int(ts_str[8:10]),
        int(ts_str[11:13]), int(ts_str[14:16]), int(ts_str[17:19]),
        0, 0, -1))


def _metrics_history_buckets(range_key):
    cfg = METRICS_HISTORY_RANGES.get(range_key)
    if cfg is None:
        return None
    span_seconds, bucket_seconds = cfg
    now = time.time()
    num_buckets = span_seconds // bucket_seconds
    # Bucket grid is anchored to absolute epoch time (multiples of
    # bucket_seconds), not to `now` - this is what lets it line up exactly
    # with state.history's ring-buffer indexing (idx = int(ts // bucket_seconds)),
    # so live data can be dropped straight into the right slot with no
    # rescaling. base_idx is the idx of buckets[0].
    last_idx = int(now // bucket_seconds)
    base_idx = last_idx - num_buckets + 1
    start_ts = base_idx * bucket_seconds
    buckets = [
        {"ts": (base_idx + i) * bucket_seconds, **{f: 0 for f in METRICS_HISTORY_FIELDS}}
        for i in range(num_buckets)
    ]

    # 1. Live in-memory ring buffer first - O(num_buckets), zero file I/O.
    # Authoritative for anything since this process started: metric_inc()
    # keeps every range's buffer updated in O(1) per event as it happens.
    # Storage position for a given idx is idx % num_buckets (metric_inc's
    # write-side formula) - NOT the same as this loop's output position i
    # (i = idx - base_idx) unless base_idx happens to be a multiple of
    # num_buckets, so the lookup must use the same modulo, not live_slots[i].
    live_slots = state.history_snapshot(range_key)
    for i in range(num_buckets):
        expected_idx = base_idx + i
        slot = live_slots[expected_idx % num_buckets]
        if slot["idx"] == expected_idx:
            counts = slot["counts"]
            for f in METRICS_HISTORY_FIELDS:
                buckets[i][f] = counts.get(f, 0)

    # 2. Log fallback ONLY for the slice of the window older than
    # START_TIME - live tracking can't have seen anything before this
    # process existed. This shrinks toward nothing as uptime grows, and
    # once the whole requested range postdates START_TIME (start_ts >=
    # START_TIME) it's skipped entirely - no log I/O at all at that point,
    # for any range including "week". Capped at START_TIME so it can never
    # re-add events the live counters already counted.
    reached_start = True
    oldest_seen = now
    if start_ts < START_TIME:
        reached_start = False
        oldest_seen = START_TIME
        # Same log-line timestamp string repeats across many consecutive
        # lines during a request burst (second-resolution timestamps) -
        # memoizing avoids re-running _parse_log_ts for every repeat.
        ts_cache = {}
        for path in _log_files_newest_first():
            for line in _iter_log_lines_reverse(path):
                m = _LOG_LINE_RE.match(line)
                if not m:
                    continue
                ts_str = m.group(1)
                ts = ts_cache.get(ts_str)
                if ts is None:
                    try:
                        ts = _parse_log_ts(ts_str)
                    except ValueError:
                        continue
                    ts_cache[ts_str] = ts
                if ts >= START_TIME:
                    continue  # already counted live - keep walking backward for the pre-start gap
                oldest_seen = min(oldest_seen, ts)
                if ts < start_ts:
                    # Reading newest-first, so everything else left in this
                    # file (and any older rotated files) is even older -
                    # nothing further can land inside the window.
                    reached_start = True
                    break
                idx = int(ts // bucket_seconds) - base_idx
                if idx < 0 or idx >= len(buckets):
                    continue
                for field, n in _categorize_log_line(m.group(2), m.group(3), int(m.group(4))).items():
                    buckets[idx][field] += n
            if reached_start:
                break

    # Once we've walked back past the window start (or live tracking
    # already covers it in full), coverage is complete. Only when every
    # available log line has been exhausted without ever reaching
    # start_ts do we report the real (short) coverage.
    coverage_seconds = span_seconds if reached_start else max(0.0, now - oldest_seen)

    return {
        "range": range_key,
        "bucket_seconds": bucket_seconds,
        "buckets": buckets,
        "coverage_seconds": round(coverage_seconds, 1),
    }


# Multiple dashboard tabs/clients polling /metrics/history at once would
# otherwise each trigger their own full log walk for the same range at
# nearly the same moment. Also scales with bucket width: a "week" bucket
# covers 2h, so recomputing it every 15s (the client's poll interval) buys
# nothing but cost - no point re-walking the whole log more often than a
# bucket's worth of new data could even shift a bar. Floor of 3s still
# collapses near-simultaneous requests for the fine-grained ranges; cap of
# 60s keeps even "week" reasonably fresh.
def _metrics_history_cache_ttl(range_key):
    cfg = METRICS_HISTORY_RANGES.get(range_key)
    if cfg is None:
        return 3
    _, bucket_seconds = cfg
    return max(3, min(60, bucket_seconds // 10))


_metrics_history_cache_lock = threading.Lock()
_metrics_history_cache = {}  # range_key -> (monotonic_time, result)


def _metrics_history_buckets_cached(range_key):
    now_mono = time.monotonic()
    with _metrics_history_cache_lock:
        cached = _metrics_history_cache.get(range_key)
        if cached and now_mono - cached[0] < _metrics_history_cache_ttl(range_key):
            return cached[1]
    result = _metrics_history_buckets(range_key)
    if result is not None:
        with _metrics_history_cache_lock:
            _metrics_history_cache[range_key] = (now_mono, result)
    return result


# Every request needs this header, regardless of FLEET_BRIDGE_KEY - a plain
# cross-origin fetch()/form POST from some unrelated site a user has open in
# another tab can't set custom headers without a CORS preflight, and browsers
# only send the real request if the preflight succeeds; since our preflight
# response doesn't depend on the caller's origin, only a caller that already
# knows to send this exact header gets through. This is what actually closes
# the CSRF hole on state-changing requests when no API key is set - CORS's
# wildcard Access-Control-Allow-Origin only governs whether cross-origin JS
# may READ a response, not whether the request fires, so CORS alone doesn't
# stop a blind cross-site POST. dashboard.html sends this on every call.
CSRF_HEADER = "X-Fleet-Dashboard"

# Base set of state-changing POST routes that ONLY a browser (the
# dashboard) ever triggers as a side effect of a UI action - shared by
# both the full-key check and the CSRF check in do_POST so the two lists
# can't drift apart (a route added to only one of them would silently
# lose the other's protection). Routes that are state-changing but are
# NEVER called by a browser (e.g. /report, /compute/<name>, /world_call -
# only ever called by a CC:Tweaked computer or a compute-script subprocess)
# are deliberately NOT in this set; they're added explicitly where needed
# instead (see do_POST).
BROWSER_TRIGGERED_PATHS = (
    "/command", "/apps", "/pcfiles/write", "/pcfiles/mkdir",
    "/pcfiles/delete", "/pcfiles/move", "/node_folder", "/admin/reload", "/admin/import",
    "/admin/shell_pin", "/admin/delete_node", "/admin/spawn_sim_node",
)

MAX_BODY_BYTES = 2 * 1024 * 1024          # reject absurdly large request bodies outright
MAX_OUTPUT_LINES_STORED = 200             # cap per-node output kept in memory
RESULT_TTL_SECONDS = 5 * 60               # FETCHED command results older than this are dropped
UNFETCHED_RESULT_TTL_SECONDS = 30 * 60    # a result nobody has read yet (e.g. dashboard was
                                           # closed) gets a much longer grace period before
                                           # being dropped, so a slow admin doesn't miss it
MAX_RESULTS_STORED = 2000                 # hard cap regardless of age, in case of a burst
RATE_LIMIT_WINDOW_SECONDS = 10
# Per source IP, per window. 100 was sized for the old ~1.2s effective poll
# cadence (a craftos_shim.lua timer-rounding bug silently floored every
# sub-1s sleep to ~1s - see game/apps/common/fleetbridge.lua's
# POLL_INTERVAL_ACTIVE comment). Fixed, real cadence is now ~0.3-0.4s/cycle
# (poll+report = 2 requests), which is ~55-65 req/10s for a SINGLE node -
# already close to 100 alone, and multiple nodes sharing one source IP (any
# NAT'd fleet, or this project's own windows/sim/ multi-node local dev setup,
# where every sim node shares 127.0.0.1) add up fast. 600 comfortably covers
# a double-digit node count at the new cadence while still capping any one
# source at 60 req/s, which is still well above what real fleet polling
# needs. FLEET_RATE_LIMIT_MAX_REQUESTS overrides for deployments that want a
# different number instead of a code change.
try:
    # Guarded the same way _PORT_FOR_LOG above is - this runs at import
    # time, so a typo'd env var (stray whitespace from a batch script,
    # "600rps", etc.) would otherwise crash the whole process before it can
    # even log an error, instead of just falling back to the documented
    # default.
    RATE_LIMIT_MAX_REQUESTS = int(os.environ.get("FLEET_RATE_LIMIT_MAX_REQUESTS", "600"))
except ValueError:
    RATE_LIMIT_MAX_REQUESTS = 600

INFLIGHT_REQUEUE_SECONDS = 20             # a command handed out by /poll but never acked by a
                                           # matching /report result (node crashed/lost network
                                           # mid-command) is put back in "pending" after this long,
                                           # so it isn't silently lost - see _sweep_inflight()
BROADCAST_LOG_TTL_SECONDS = 5 * 60        # how long a "*" command stays eligible to be handed to
                                           # a node that hadn't registered yet when it was sent

# Bug fix: LOG_PATH used to be a fixed "bridge.log" regardless of port, so
# two bridge_server.py instances (e.g. one left running in the background
# via run_bridge_background.bat on one port, another started later on a
# different port for testing) both fought over the SAME log file - the
# second one's RotatingFileHandler couldn't rename bridge.log -> bridge.log.1
# once it hit its size cap because the first process still had it open
# (Windows won't let you rename a file that's open elsewhere, unlike POSIX),
# spamming "--- Logging error ---"/PermissionError on every rotation attempt
# forever after (harmless to the server itself - it keeps running either
# way - but very noisy). Naming the file after the port a process actually
# binds to means two DIFFERENT ports never contend for the same file; the
# default port (8787) keeps the original plain "bridge.log" name so existing
# setups/scripts pointing at it aren't affected.
#
# Note: this only fixes the LOG file. bridge_state.json/node_meta.json are
# still shared across every bridge_server.py instance in this same windows/
# directory regardless of port - fine for the normal case (one fleet, one
# port), but running two instances against the same directory for two
# unrelated fleets/ports would still have them silently share that state.
# Copy windows/ to a second directory if you need fully isolated instances.
try:
    # Guarded, not a bare int(sys.argv[1]): this line runs at IMPORT time (it
    # has to, to name the log file before the logger below is even set up),
    # so argv[1] isn't necessarily a port at all if something else imports
    # this module with its own argv - a test runner (`python -m unittest
    # test_bridge_server`) has argv[1] == "test_bridge_server", not a port,
    # which raised ValueError here and broke every test/other-tool import
    # until this guard was added. Falls back to the default port's log name
    # in that case, same as main()'s own now-shared `port` will.
    _PORT_FOR_LOG = int(sys.argv[1])
except (IndexError, ValueError):
    _PORT_FOR_LOG = 8787
_LOG_FILENAME = "bridge.log" if _PORT_FOR_LOG == 8787 else f"bridge-{_PORT_FOR_LOG}.log"
# All logs (this file's own, per-node report output, sim-node console
# capture) live under one windows/logs/ root, split into subdirectories by
# kind - previously scattered flat across windows/ itself (bridge.log,
# bridge_stdout.log), windows/logs/ (per-node .log, no further grouping),
# and windows/sim/<id>/ (mixed in with that node's actual simulated
# filesystem). LOGS_DIR is computed the same way LOG_PATH always was
# (can't use SCRIPT_DIR - that's defined further down, and this whole
# block has to run at import time, before SCRIPT_DIR exists yet).
LOGS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs")
LOG_PATH = os.path.join(LOGS_DIR, "bridge", _LOG_FILENAME)
os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
logger = logging.getLogger("bridge")
logger.setLevel(logging.INFO)
# size-based rotation alone (still needed - protects against a burst
# filling the disk) previously kept only backupCount=3 old files, which a
# single busy day could rotate through entirely, losing everything older
# than a few hours. Raised well past what one day of normal traffic should
# ever produce - genuine calendar-day rotation (TimedRotatingFileHandler)
# isn't used here since it wouldn't ALSO cap total size, and stdlib's
# logging.handlers has no single handler that does both at once.
_file_handler = logging.handlers.RotatingFileHandler(
    LOG_PATH, maxBytes=1 * 1024 * 1024, backupCount=20, encoding="utf-8")
_file_handler.setFormatter(logging.Formatter("%(asctime)s %(message)s"))
logger.addHandler(_file_handler)
_console_handler = logging.StreamHandler(sys.stdout)
_console_handler.setFormatter(logging.Formatter("%(message)s"))
logger.addHandler(_console_handler)

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# Auto-generated FLEET_BRIDGE_KEY (see _get_or_create_auto_key below) - a
# user who binds beyond 127.0.0.1 (Radmin VPN, LAN) previously had to invent
# and remember their own key just to satisfy the "refuses to bind without
# one" check in main(). Persisted to disk (not regenerated every restart) -
# a fresh key on every restart would silently lock out every already-
# installed node's config.lua apiKey / the dashboard's saved key.
BRIDGE_KEY_FILE = os.path.join(SCRIPT_DIR, "bridge_key.txt")


def _get_or_create_auto_key():
    try:
        with open(BRIDGE_KEY_FILE, "r", encoding="utf-8") as f:
            existing = f.read().strip()
        if existing:
            return existing
    except FileNotFoundError:
        pass
    new_key = secrets.token_urlsafe(24)
    try:
        with open(BRIDGE_KEY_FILE, "w", encoding="utf-8") as f:
            f.write(new_key)
    except OSError as e:
        logger.warning(f"[bridge] couldn't save {BRIDGE_KEY_FILE}: {e} - "
                       "this key won't survive a restart")
    return new_key


COMPUTE_TIMEOUT_SECONDS = 5   # protects the bridge from a hung/runaway script;
                              # independent of whatever timeout the CALLER
                              # (e.g. raytower_master.lua) gives up waiting at
COMPUTE_WORLD_TIMEOUT_SECONDS = 30   # generous timeout for a compute script that
                              # opted into world access (?node=<id>) - it may
                              # make several world_call round trips, each
                              # waiting on that node's ~1s poll cadence
WORLD_CALL_TIMEOUT_SECONDS = 8   # how long POST /world_call blocks waiting for
                              # the target node's normal poll loop to pick up
                              # and answer a queued world_call command

# ThreadingHTTPServer spawns one thread per request with no cap -
# /compute (blocks up to COMPUTE_WORLD_TIMEOUT_SECONDS on a subprocess) and
# /world_call (blocks up to WORLD_CALL_TIMEOUT_SECONDS polling in a loop) are
# the two routes that hold a thread for a long time rather than returning
# almost immediately, so a burst of either can exhaust threads/resources
# under load. A bounded semaphore caps how many of EITHER can run at once,
# failing fast with 503 instead of letting requests pile up unbounded.
MAX_CONCURRENT_LONG_REQUESTS = 4
_long_request_semaphore = threading.BoundedSemaphore(MAX_CONCURRENT_LONG_REQUESTS)


STATE_PATH = os.path.join(SCRIPT_DIR, "bridge_state.json")
NODE_META_PATH = os.path.join(SCRIPT_DIR, "node_meta.json")
# bump this + add a migration branch in FleetState._load_node_folders if this file's shape ever changes
NODE_META_VERSION = 2
STATE_VERSION = 1  # bump this + add a migration branch in StateRepository.load if this file's shape ever changes
# _save_state() used to run synchronously on every single /poll and /report
# (i.e. every mutation, INCLUDING the two highest-frequency request types -
# every node hits one or the other every poll cycle) - a full JSON re-dump
# of results_by_id/broadcast_log/every node's pending+inflight, written to
# disk, on every one of those. Harmless at the old ~1.2s effective poll
# cadence; a real bottleneck now that the timer-rounding bug that caused
# that cadence is fixed (see game/apps/common/fleetbridge.lua's
# POLL_INTERVAL_ACTIVE comment) and a real cycle is ~0.3-0.4s - a fleet of
# any size now means several full-state disk writes per second minimum.
# StateRepository.mark_dirty() replaces the write with a flag; its flush
# thread actually writes at most once per STATE_FLUSH_INTERVAL_SECONDS,
# batching however many mutations happened in between into one write. Two
# call sites deliberately still call StateRepository.save() directly
# instead of mark_dirty(): the final shutdown save (state must be on disk
# before the process actually exits) and /admin/reload (os.execv() replaces
# this process immediately after - a debounced write would never get a
# chance to run).
STATE_FLUSH_INTERVAL_SECONDS = 2


def _hash_shell_pin(pin):
    return hashlib.sha256(pin.encode("utf-8")).hexdigest()


class FleetState:
    """
    Owns every piece of mutable, in-memory fleet data - nodes, command
    results, the broadcast log, the next command id, sim-node subprocess
    handles, rate-limit buckets, dashboard folder assignments, shell PINs,
    and the operational counters - plus the single `lock` guarding all of
    it, instead of each being its own bare module-level global mutated
    directly by every Handler method. Previously "what state does this
    bridge actually hold" was only discoverable by reading every route by
    hand; it's now this class's __init__. Also fixes a real sharp edge:
    `global next_id; next_id += 1`-style reassignment only ever works on a
    MODULE-level name, which is exactly why persistence used to be awkward
    to factor out cleanly (see StateRepository below) - an attribute
    (`self.next_id += 1`) doesn't have that restriction.
    """

    def __init__(self):
        self.lock = threading.Lock()
        self.next_id = 1
        # command id (str) -> {"result": ..., "ts": float, "fetched": bool},
        # kept around so slow pollers (e.g. readfile) don't miss a result
        # that only appeared in a single fleetbridge.lua report cycle.
        # Pruned by prune_results() so a long-running bridge doesn't grow
        # this forever.
        self.results_by_id = {}
        # node id -> { "pending": [...], "inflight": {cmd_id_str: {"cmd":..., "ts":...}},
        #              "latest_report": {...}, "latest_report_time": float }
        # Nodes register themselves just by polling once - no separate
        # "join" step. "pending"/"inflight" are persisted (see
        # StateRepository) so a bridge restart doesn't silently drop
        # queued/in-flight commands; latest_report is runtime-only and gets
        # refreshed the moment the node polls/reports again.
        self.nodes = {}
        # Recent "*" (broadcast) commands, so a node that registers itself
        # AFTER the broadcast was sent still receives it - previously
        # target=="*" only queued to nodes already known at that instant.
        # Entries: {"id":, "ts":, "cmd":}. Pruned by age in prune_results().
        # Seeded into a node's "pending" once, at the moment that node is
        # first seen (see get_node()).
        self.broadcast_log = []
        # node id -> subprocess.Popen for a sim node started via
        # /admin/spawn_sim_node, kept only so a second spawn for the same id
        # while one's already running can be refused with a clear error
        # instead of two processes racing to write the same
        # bridge_override.txt/log file. Not persisted - a bridge restart
        # just loses track of already-running sim processes (they keep
        # running; re-spawning the same id after a bridge restart works
        # fine, it just won't detect the still-alive old one).
        self.sim_processes = {}
        # source IP -> list of request timestamps within the current
        # window, used by Handler._check_rate_limit(). Not meant to survive
        # a restart or scale past one process - this is a hobby-project
        # throttle against accidental/malicious request floods, not a
        # production rate limiter.
        self.request_times_by_ip = {}
        # node id -> folder name (dashboard's "system of folders" for
        # organizing a fleet). Purely a dashboard-side label -
        # fleetbridge.lua/the node itself never needs to know what folder
        # it's filed under, so this lives ONLY here, persisted to
        # node_meta.json (unlike `nodes` above, which is rebuilt from
        # scratch every time a node re-polls after a bridge restart).
        self.node_folders = {}
        # node id -> sha256 hex hash of a PIN apps/common/shell.lua
        # requires before accepting a local `bridge <url> [key]` command on
        # that node - see /shell_pin_check. Opt-in: a node with no entry
        # here has no PIN requirement at all (the default). Hashed rather
        # than stored as plaintext since node_meta.json is a plain file on
        # disk - cheap extra step, no reason not to.
        self.node_shell_pins = {}
        self.metrics = {
            "commands_queued_total": 0,
            "reports_received_total": 0,
            "polls_served_total": 0,
            "results_fetched_total": 0,
            "rate_limited_total": 0,
            "http_errors_total": 0,
        }
        # Per-range ring buffers, updated live by metric_inc() below so
        # GET /metrics/history can serve recent windows straight from
        # memory instead of re-parsing bridge.log on every request (see
        # _metrics_history_buckets, which only falls back to the log for
        # the portion of a requested window that predates START_TIME -
        # i.e. before this buffer existed). Not persisted: a restart just
        # empties it, and the log fallback covers the gap until it refills.
        # Each slot is {"idx": bucket_index or None, "counts": {...}};
        # "idx" lets a stale slot (last written on a previous wrap of the
        # ring, or never written) be told apart from a genuinely-zero
        # current bucket without needing to zero out the whole array on
        # every rollover.
        self.history = {
            range_key: [
                {"idx": None, "counts": dict.fromkeys(METRICS_HISTORY_FIELDS, 0)}
                for _ in range(span_seconds // bucket_seconds)
            ]
            for range_key, (span_seconds, bucket_seconds) in METRICS_HISTORY_RANGES.items()
        }
        self._load_node_folders()

    def metric_inc(self, name, n=1):
        with self.lock:
            self.metrics[name] = self.metrics.get(name, 0) + n
            if not name.endswith("_total"):
                return
            field = name[:-len("_total")]
            if field not in METRICS_HISTORY_FIELDS:
                return
            now = time.time()
            for range_key, (_, bucket_seconds) in METRICS_HISTORY_RANGES.items():
                slots = self.history[range_key]
                idx = int(now // bucket_seconds)
                slot = slots[idx % len(slots)]
                if slot["idx"] != idx:
                    slot["idx"] = idx
                    slot["counts"] = dict.fromkeys(METRICS_HISTORY_FIELDS, 0)
                slot["counts"][field] += n

    def history_snapshot(self, range_key):
        with self.lock:
            return [{"idx": s["idx"], "counts": dict(s["counts"])} for s in self.history[range_key]]

    def allocate_command_id(self):
        # Called with `lock` already held by the caller (every call site
        # already holds it for the rest of the mutation anyway) - a plain
        # attribute bump, not its own lock acquisition, so a caller never
        # has to release and re-acquire `lock` just to get an id.
        cmd_id = self.next_id
        self.next_id += 1
        return cmd_id

    def get_node(self, node_id):
        node = self.nodes.get(node_id)
        if node is None:
            node = {"pending": [], "inflight": {}, "latest_report": None, "latest_report_time": None}
            # Seed with any still-fresh "*" broadcasts sent before this node
            # ever registered - otherwise a command sent to "*" before a
            # node's first /poll would simply never reach it (the
            # historical bug).
            now = time.time()
            for entry in self.broadcast_log:
                if now - entry["ts"] <= BROADCAST_LOG_TTL_SECONDS:
                    node["pending"].append(entry["cmd"])
            self.nodes[node_id] = node
        return node

    def sweep_inflight(self):
        # Called with `lock` already held. A command /poll handed to a node
        # is moved to that node's "inflight" map, stamped with the time it
        # was handed out. If the matching /report result never arrives
        # (node crashed, lost network, or was killed mid-command) within
        # INFLIGHT_REQUEUE_SECONDS, put it back in "pending" so the next
        # poll gets another shot at it - previously a command vanished for
        # good the instant /poll returned it, regardless of whether it was
        # ever actually executed.
        now = time.time()
        for node in self.nodes.values():
            inflight = node.get("inflight")
            if not inflight:
                continue
            stale = [cid for cid, entry in inflight.items() if now - entry["ts"] > INFLIGHT_REQUEUE_SECONDS]
            for cid in stale:
                node["pending"].append(inflight.pop(cid)["cmd"])

    def prune_results(self):
        # Called with `lock` already held. Drops anything past its TTL,
        # then - if still over the hard cap (e.g. a burst of commands all
        # at once) - drops the oldest entries until back under it. A
        # result nobody has fetched yet (dashboard was closed, admin
        # stepped away) gets a much longer grace period than one that's
        # already been seen.
        now = time.time()
        expired = [
            cid for cid, entry in self.results_by_id.items()
            if now - entry["ts"] > (RESULT_TTL_SECONDS if entry.get("fetched") else UNFETCHED_RESULT_TTL_SECONDS)
        ]
        for cid in expired:
            del self.results_by_id[cid]
        if len(self.results_by_id) > MAX_RESULTS_STORED:
            oldest_first = sorted(self.results_by_id.items(), key=lambda kv: kv[1]["ts"])
            for cid, _ in oldest_first[: len(self.results_by_id) - MAX_RESULTS_STORED]:
                del self.results_by_id[cid]
        # Keeps only non-expired entries directly, rather than relying on
        # broadcast_log being sorted ascending by ts (true under normal
        # append-only operation, but NOT guaranteed after /admin/import
        # wholesale-replaces this list with an imported bundle's own
        # ordering) - a `del broadcast_log[:N]` form would delete N items
        # from the front regardless of whether those were actually the
        # stale ones.
        self.broadcast_log[:] = [e for e in self.broadcast_log if now - e["ts"] <= BROADCAST_LOG_TTL_SECONDS]
        self.sweep_inflight()

    def _load_node_folders(self):
        try:
            with open(NODE_META_PATH, "r", encoding="utf-8") as f:
                raw = json.load(f)
        except (FileNotFoundError, json.JSONDecodeError):
            self.node_folders = {}
            self.node_shell_pins = {}
            return
        # node_meta.json had no schema version at all before this - a
        # future shape change would have no way to tell "old unversioned
        # file" apart from "new file missing a field by mistake". A file
        # with no "version" key is the original shape (a flat
        # {node_id: folder_name} dict) - treated as version 1 with no
        # transformation needed. Version 2 added "shell_pins" alongside
        # "data" - a version-1 file simply has no such key, which .get()
        # below already treats as "no PINs set" with no explicit migration
        # branch needed.
        if isinstance(raw, dict) and "version" in raw:
            self.node_folders = raw.get("data", {})
            self.node_shell_pins = raw.get("shell_pins", {})
        else:
            self.node_folders = raw if isinstance(raw, dict) else {}
            self.node_shell_pins = {}
        if not isinstance(self.node_folders, dict):
            self.node_folders = {}
        if not isinstance(self.node_shell_pins, dict):
            self.node_shell_pins = {}

    def save_node_folders(self):
        # Called with `lock` already held. Best-effort - a failed write
        # here shouldn't take down the request that triggered it.
        try:
            with open(NODE_META_PATH, "w", encoding="utf-8") as f:
                json.dump(
                    {"version": NODE_META_VERSION, "data": self.node_folders, "shell_pins": self.node_shell_pins}, f)
        except OSError as e:
            logger.error(f"[bridge] failed to save {NODE_META_PATH}: {e}")


class StateRepository:
    """
    Persistence for FleetState's hot-path fields (pending/inflight per
    node, results_by_id, broadcast_log, next_id) to STATE_PATH - separate
    from FleetState itself so "what the in-memory state IS" and "how/when
    it gets written to disk" are independent concerns. node_folders/
    node_shell_pins are NOT handled here - see FleetState.save_node_folders/
    _load_node_folders - they're a separate file (node_meta.json) with much
    lower write frequency (admin actions only), saved synchronously and
    directly rather than through this debounced flow.
    """

    def __init__(self, state_path, flush_interval_seconds):
        self.state_path = state_path
        self.flush_interval_seconds = flush_interval_seconds
        self.dirty = False

    def save(self, state):
        # Called with state.lock already held.
        try:
            snapshot = {
                "version": STATE_VERSION,
                "next_id": state.next_id,
                "results_by_id": state.results_by_id,
                "broadcast_log": state.broadcast_log,
                "nodes": {
                    node_id: {"pending": node["pending"], "inflight": node["inflight"]}
                    for node_id, node in state.nodes.items()
                },
            }
            tmp_path = self.state_path + ".tmp"
            with open(tmp_path, "w", encoding="utf-8") as f:
                json.dump(snapshot, f)
            os.replace(tmp_path, self.state_path)
        except OSError as e:
            logger.error(f"[bridge] failed to save {self.state_path}: {e}")

    def load(self, state):
        try:
            with open(self.state_path, "r", encoding="utf-8") as f:
                snapshot = json.load(f)
        except (FileNotFoundError, json.JSONDecodeError):
            return
        # version 1 is the only shape that has ever existed - a file with
        # no "version" key (or an unrecognized one) is loaded best-effort
        # via the same .get()-with-defaults below rather than refused
        # outright, but logs a warning so a real future incompatibility
        # doesn't fail silently.
        version = snapshot.get("version")
        if version not in (None, STATE_VERSION):
            logger.warning(f"[bridge] {self.state_path} has unrecognized version {version!r} - loading best-effort")
        state.next_id = snapshot.get("next_id", state.next_id)
        state.results_by_id = snapshot.get("results_by_id", {})
        state.broadcast_log = snapshot.get("broadcast_log", [])
        for node_id, saved in snapshot.get("nodes", {}).items():
            state.nodes[node_id] = {
                "pending": saved.get("pending", []),
                "inflight": saved.get("inflight", {}),
                "latest_report": None,
                "latest_report_time": None,
            }
        logger.info(f"[bridge] restored state from {self.state_path}: "
                    f"{len(state.nodes)} node(s), {len(state.results_by_id)} result(s)")

    def mark_dirty(self):
        self.dirty = True

    def start_flush_thread(self, state):
        def _flush_loop():
            while True:
                time.sleep(self.flush_interval_seconds)
                with state.lock:
                    if not self.dirty:
                        continue
                    self.dirty = False
                    self.save(state)
        # daemon=True: this thread never blocks process exit - the
        # shutdown path in main()'s `finally` block does its own
        # synchronous final save(), this loop just doesn't need to be
        # joined/stopped first.
        threading.Thread(target=_flush_loop, daemon=True).start()


state = FleetState()
state_repo = StateRepository(STATE_PATH, STATE_FLUSH_INTERVAL_SECONDS)
state_repo.load(state)
state_repo.start_flush_thread(state)

# centralized log collection. Previously every node's output only ever
# lived in its own in-memory buffer (fleetos.getOutput(), capped and only
# viewable one node at a time through the dashboard's Terminal panel) - once
# a node rebooted or the bridge restarted, it was gone, and diagnosing
# something across several nodes meant switching the dashboard's Terminal
# between them one at a time. Every /report's new `output` lines (see the
# /report handler's outputCursor-gated merge, protocolVersion >= 2 - a node
# only ever reports lines it hasn't successfully delivered before, already
# deduplicated at the source) are appended here to windows/logs/nodes/<node>.log -
# a real terminal log an admin can grep/tail across the whole fleet, that
# survives node reboots and bridge restarts.
NODE_LOGS_DIR = os.path.join(LOGS_DIR, "nodes")
_node_loggers = {}
# Separate from the main `lock` (which guards fleet state like `nodes`) so
# this doesn't hold up unrelated request handling during file I/O. Needed
# because ThreadingHTTPServer runs every request on its own thread, and two
# concurrent /report calls for the SAME node (e.g. a retried CC:Tweaked
# http.post) could otherwise both see no logger yet and each construct their
# own RotatingFileHandler pointed at the same file.
# RLock (not Lock) since _log_node_output holds it while calling
# _get_node_logger, which also acquires it - same thread re-entering is
# fine with RLock, would deadlock with a plain Lock.
_node_log_lock = threading.RLock()


def _safe_log_filename(node_id):
    return re.sub(r"[^A-Za-z0-9_.-]", "_", node_id) or "unknown"


def _get_node_logger(node_id):
    with _node_log_lock:
        node_logger = _node_loggers.get(node_id)
        if node_logger is not None:
            return node_logger
        os.makedirs(NODE_LOGS_DIR, exist_ok=True)
        node_logger = logging.getLogger("bridge.node." + node_id)
        node_logger.setLevel(logging.INFO)
        node_logger.propagate = False
        handler = logging.handlers.RotatingFileHandler(
            os.path.join(NODE_LOGS_DIR, _safe_log_filename(node_id) + ".log"),
            maxBytes=1 * 1024 * 1024, backupCount=3, encoding="utf-8")
        handler.setFormatter(logging.Formatter("%(asctime)s %(message)s"))
        node_logger.addHandler(handler)
        _node_loggers[node_id] = node_logger
        return node_logger


def _log_node_output(node_id, new_lines):
    # Called only with lines the /report handler's outputCursor check has
    # already confirmed are genuinely new (not a retry-duplicated resend) -
    # no dedup needed here, just write them.
    if not new_lines:
        return
    with _node_log_lock:
        node_logger = _get_node_logger(node_id)
        for line in new_lines:
            node_logger.info(line)


def _merge_report(node, node_id, body):
    # Called with `lock` already held, mutates `node` in place. Extracted
    # out of the /report handler so it's directly unit-testable (see
    # test_bridge_server.py) without spinning up a real HTTP server, same
    # reasoning as _prune_results/_sweep_inflight above.
    #
    # protocolVersion >= 2 (see fleetbridge.lua's own comment on that
    # constant) omits apps/appVersions/pos/effectiveConfig/monitor entirely
    # when unchanged since the node's last successfully-delivered report,
    # instead of resending them in full every cycle - merge over the
    # previous report rather than replacing it outright, so an omitted key
    # keeps whatever value it already had. `output`/`outputTail`/
    # `outputCursor` are handled separately below, not through this generic
    # merge - see their own comments.
    merged = dict(node["latest_report"] or {})
    for key, value in body.items():
        if key not in ("output", "outputTail", "outputCursor"):
            merged[key] = value

    # `output` (if present at all) is a DELTA of newly-completed lines, not
    # the resent last-150-lines window protocolVersion 1 sent - append
    # rather than replace. Gated on `outputCursor` strictly advancing past
    # what's already been recorded so an at-least-once HTTP retry (the node
    # got no response, resent the exact same delta) can't double-append/
    # double-log it - this is what apps/common/fleetbridge.lua's
    # getOutputSince cursor exists for.
    new_lines = body.get("output")
    cursor = body.get("outputCursor")
    stored_lines = node.get("_output_lines", [])
    if isinstance(new_lines, list) and isinstance(cursor, (int, float)) \
            and cursor > node.get("_output_seq", 0):
        stored_lines = (stored_lines + new_lines)[-MAX_OUTPUT_LINES_STORED:]
        node["_output_lines"] = stored_lines
        node["_output_seq"] = cursor
        _log_node_output(node_id, new_lines)
    # The in-progress (not yet newline-terminated) line, e.g. a live
    # "shell> " prompt - always just the latest value, no cursor needed
    # (overwriting the same value twice is harmless, unlike double-
    # appending a list would be).
    tail = body.get("outputTail")
    if tail is not None:
        node["_output_tail"] = tail
    # Reconstructed flat array, same shape/contract every existing consumer
    # (dashboard.html's renderTerminal, etc.) already expects from
    # `latest_report.output` - runtime-only like latest_report itself, not
    # persisted by _save_state().
    merged["output"] = stored_lines + ([node["_output_tail"]] if node.get("_output_tail") else [])

    node["latest_report"] = merged
    node["latest_report_time"] = time.time()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        logger.info("[bridge] " + (fmt % args))

    def _cors_headers(self):
        # Lets the dashboard be hosted elsewhere (e.g. GitHub Pages) while
        # still talking to this bridge on your own PC. A wildcard origin
        # here means CORS itself provides no protection against a random
        # cross-origin page firing state-changing requests - see
        # _check_csrf's own comment for why CSRF_HEADER doesn't fully cover
        # that gap either. What actually stops it: FLEET_BRIDGE_KEY. Any
        # bind beyond 127.0.0.1 requires one (see main()), and a
        # cross-origin page has no way to read it out of the legitimate
        # dashboard's localStorage. If you're relying on the localhost-only,
        # no-key default instead, that default's safety comes from nothing
        # else being able to REACH this server at all (bound to 127.0.0.1),
        # not from anything in this CORS/CSRF layer.
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, X-API-Key, " + CSRF_HEADER)

    def do_OPTIONS(self):
        # never gated on auth - a CORS preflight carries no sensitive data,
        # and browsers send it without custom headers of its own
        self.send_response(204)
        self._cors_headers()
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _check_auth(self, require_full=False):
        # no FLEET_BRIDGE_KEY (and no READONLY key) set -> auth is off, same
        # as before this existed. compare_digest instead of == so a
        # mistyped/guessed key can't be narrowed down via response-time
        # differences. require_full=True rejects a valid READONLY_API_KEY
        # on state-changing routes - see that constant's comment.
        if not API_KEY and not READONLY_API_KEY:
            self._auth_role = "full"
            return True
        provided = self.headers.get("X-API-Key", "")
        if API_KEY and provided and hmac.compare_digest(provided, API_KEY):
            self._auth_role = "full"
            return True
        if not require_full and READONLY_API_KEY and provided and hmac.compare_digest(provided, READONLY_API_KEY):
            self._auth_role = "readonly"
            return True
        self._send_json({"error": "unauthorized - missing/invalid X-API-Key"}, status=401)
        return False

    def _check_csrf(self):
        # Required on every state-changing route regardless of FLEET_BRIDGE_KEY
        # (see CSRF_HEADER above).
        #
        # HONEST SCOPE NOTE: this header is NOT a secret and does NOT stop a
        # determined attacker's own JavaScript. _cors_headers() explicitly
        # allows CSRF_HEADER in Access-Control-Allow-Headers with a wildcard
        # Origin, so a malicious page's own fetch() CAN pass the CORS
        # preflight and set this header - "our preflight doesn't check
        # Origin" makes this MORE permissive, not less. All this actually
        # stops is a "dumb" CSRF vector that can't set custom headers at all
        # (a plain <form> POST, an <img>/<script> GET) - it does nothing
        # against a page that specifically knows to add this one header,
        # which is trivial to find by reading this file (public source).
        #
        # When FLEET_BRIDGE_KEY is set (mandatory for any non-127.0.0.1
        # bind - see main()), _check_auth's X-API-Key check already ran
        # before this and is the REAL defense: a cross-origin page cannot
        # read the key out of the legitimate dashboard's localStorage
        # (Same-Origin Policy), so it cannot forge a valid request
        # regardless of what this check does. This header only matters on
        # its own when no key is configured at all (127.0.0.1-only,
        # no-auth-needed default) - in that mode it's real but weak
        # protection against a malicious website the browser also happens
        # to have open, not a meaningful barrier against one that's
        # specifically targeting this bridge.
        #
        # Doesn't protect against a non-browser client (curl, fleetctl.py)
        # either way - those were never the threat model here, they
        # already require you to have chosen to run them.
        if self.headers.get(CSRF_HEADER):
            return True
        self._send_json({"error": "missing " + CSRF_HEADER + " header"}, status=403)
        return False

    def _check_rate_limit(self):
        ip = self.client_address[0]
        now = time.time()
        with state.lock:
            times = [t for t in state.request_times_by_ip.get(ip, []) if now - t < RATE_LIMIT_WINDOW_SECONDS]
            times.append(now)
            state.request_times_by_ip[ip] = times
            count = len(times)
        if count > RATE_LIMIT_MAX_REQUESTS:
            state.metric_inc("rate_limited_total")
            self._send_json({"error": "rate limit exceeded, slow down"}, status=429)
            return False
        return True

    def _send_json(self, obj, status=200, extra_headers=None):
        if status >= 400:
            state.metric_inc("http_errors_total")
        body = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        for name, value in (extra_headers or {}).items():
            self.send_header(name, value)
        self._cors_headers()
        self.end_headers()
        self.wfile.write(body)

    def _read_json_body(self):
        # Reads and JSON-decodes the request body, or sends the
        # appropriate error response itself and returns None - every call
        # site just does `if body is None: return` (consolidates what used
        # to be 13 duplicated copies of "read body / handle oversized /
        # 413", and fixes three bugs found in the same review pass: a
        # malformed Content-Length crashing with an uncaught ValueError,
        # this function still fully buffering an oversized body before
        # rejecting it (defeating the point of MAX_BODY_BYTES), and non-
        # dict JSON - a bare list/string/number/null is valid JSON but
        # crashes every route's `.get(...)` call with AttributeError).
        try:
            length = int(self.headers.get("Content-Length", 0))
        except ValueError:
            self._send_json({"error": "invalid Content-Length header"}, status=400)
            return None
        if length < 0:
            self._send_json({"error": "invalid Content-Length header"}, status=400)
            return None
        if length > MAX_BODY_BYTES:
            # Don't read the full attacker-declared length into memory just
            # to discard it - that defeats the point of this guard. Close
            # the connection instead of trying to keep it alive/in sync.
            self.close_connection = True
            self._send_json({"error": "request body too large"}, status=413)
            return None
        raw = self.rfile.read(length) if length else b"{}"
        try:
            parsed = json.loads(raw.decode("utf-8"))
        except Exception:
            parsed = {}
        if not isinstance(parsed, dict):
            self._send_json({"error": "request body must be a JSON object"}, status=400)
            return None
        return parsed

    def _send_text(self, text, content_type="text/plain; charset=utf-8", status=200):
        body = text.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self._cors_headers()
        self.end_headers()
        self.wfile.write(body)

    def _send_text_cacheable(self, text, content_type="text/plain; charset=utf-8"):
        # fleetos.lua/install.lua/triangulation.lua/apps/<name>.lua were
        # re-sent in full on every single GET, even when unchanged (a node
        # re-fetching the same fleetos.lua for every "update" command, the
        # dashboard's app editor reopening the same file repeatedly). An
        # ETag (content hash, not a Last-Modified timestamp - simpler, and
        # correct even if a file's mtime doesn't change but content does, or
        # vice versa on some filesystems) lets a conditional GET short-
        # circuit to a bodyless 304 when nothing actually changed - the
        # client still round-trips every time (this is revalidation, not
        # blind caching), so a stale copy is never served, just a redundant
        # re-download avoided. Concretely benefits the DASHBOARD's own
        # fetch() calls (browsers automatically attach If-None-Match once a
        # response has carried an ETag) - CC:Tweaked's http.get has no such
        # automatic behavior, so a node's own "update"/"deploy" fetch still
        # always pulls the full body; still correct either way, just not
        # bandwidth-optimized on that specific path.
        etag = '"' + hashlib.sha1(text.encode("utf-8")).hexdigest() + '"'
        if self.headers.get("If-None-Match") == etag:
            self.send_response(304)
            self.send_header("ETag", etag)
            self._cors_headers()
            self.end_headers()
            return
        body = text.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("ETag", etag)
        self._cors_headers()
        self.end_headers()
        self.wfile.write(body)

    def _serve_cacheable_file(self, path, not_found_label, content_type="text/plain; charset=utf-8"):
        # Shared by every plain "read this file off disk and send it,
        # ETag-cacheable" GET route (fleetos.lua, install.lua,
        # triangulation.lua, docs/*.html) - previously each was its own
        # copy-pasted try/except FileNotFoundError block.
        try:
            with open(path, "r", encoding="utf-8") as f:
                self._send_text_cacheable(f.read(), content_type=content_type)
        except FileNotFoundError:
            self._send_text(not_found_label + " not found", status=404)

    def do_GET(self):
        if not self._check_rate_limit():
            return

        parsed = urlsplit(self.path)
        self.path = parsed.path
        query = parse_qs(parsed.query)

        # exempt from auth: the dashboard shell itself (so a browser can
        # load the page and enter its API key in the first place), install.lua
        # (fetched via CraftOS's built-in `wget`, which can't send custom
        # headers at all - everything install.lua fetches AFTER that via its
        # own http.get DOES carry the key, once you pass one to
        # `install <bridge-url> <api-key>`), /health (a healthcheck
        # probe that had to know an API key first wouldn't be usable by most
        # monitoring/orchestration tooling, and it reveals nothing sensitive -
        # just a node count and an uptime number), and /docs/* (static help
        # pages checked into the repo - same trust level as the dashboard
        # shell itself, no fleet data in them).
        if self.path not in ("/", "/dashboard", "/install.lua", "/health") \
                and not self.path.startswith("/docs/") \
                and not self._check_auth(require_full=(self.path == "/admin/export")):
            return

        if self.path == "/" or self.path == "/dashboard":
            try:
                with open(DASHBOARD_PATH, "r", encoding="utf-8") as f:
                    self._send_text(f.read(), content_type="text/html; charset=utf-8")
            except FileNotFoundError:
                self._send_text("dashboard.html not found next to bridge_server.py", status=500)

        elif self.path == "/fleetos.lua":
            self._serve_cacheable_file(FLEETOS_PATH, "fleetos.lua")

        elif self.path == "/install.lua":
            self._serve_cacheable_file(INSTALL_PATH, "install.lua")

        elif self.path == "/triangulation.lua":
            # apps/raytower/raytower_master.lua dofile()s this as a
            # top-level file (not one of apps/*) - served separately so
            # the dashboard can push it alongside a raytower_master deploy.
            self._serve_cacheable_file(TRIANGULATION_PATH, "triangulation.lua")

        elif self.path.startswith("/docs/") and self.path.endswith(".html"):
            # lets the dashboard link straight to docs/*.html (e.g. the
            # hardening guide) instead of telling users to go dig through
            # the repo on disk.
            #
            # Bug fix: a plain "/", "\\", ".." substring blacklist on `name`
            # looked like it blocked traversal, but doesn't catch a bare
            # Windows drive-letter prefix like "C:evil.html" - on Windows,
            # os.path.join(DOCS_DIR, "C:evil.html") DISCARDS DOCS_DIR
            # entirely (a differently-drive-lettered component wins
            # outright in ntpath join semantics), resolving to "C:evil.html"
            # relative to that drive's own current directory - completely
            # outside docs/. Confirmed exploitable: os.path.abspath() of
            # that join lands on a totally different drive than DOCS_DIR.
            # Fixed the same way resolve_pc_path() already does it
            # (abspath + prefix check) instead of trying to extend the
            # blacklist with yet another special case.
            name = self.path[len("/docs/"):]
            docs_abs = os.path.abspath(DOCS_DIR)
            candidate = os.path.abspath(os.path.join(docs_abs, name))
            if not candidate.startswith(docs_abs + os.sep):
                self._send_text("invalid doc name", status=400)
                return
            self._serve_cacheable_file(
                candidate, name, content_type="text/html; charset=utf-8")

        elif self.path == "/apps":
            self._send_json({"groups": list_apps_grouped(), "names": list_app_names()})

        elif self.path.startswith("/apps/") and self.path.endswith(".lua"):
            # serves a single app's raw source so fleetbridge.lua's http.get
            # can fetch it directly as a "deploy" url - no pastebin needed
            # for apps that already live in game/apps/ (in a group folder
            # or flat, resolve_app_path checks both).
            name = self.path[len("/apps/"):]
            if "/" in name or ".." in name:
                self._send_text("invalid app name", status=400)
                return
            path = resolve_app_path(name)
            if not path:
                self._send_text("not found", status=404)
                return
            with open(path, "r", encoding="utf-8") as f:
                self._send_text_cacheable(f.read())

        elif self.path == "/compute_scripts":
            self._send_json({"names": list_compute_script_names()})

        elif self.path.startswith("/compute_scripts/"):
            name = self.path[len("/compute_scripts/"):]
            if not is_valid_compute_name(name):
                self._send_text("invalid compute script name", status=400)
                return
            path = os.path.join(COMPUTE_DIR, name + ".py")
            if not os.path.isfile(path):
                self._send_text("not found", status=404)
                return
            with open(path, "r", encoding="utf-8") as f:
                self._send_text(f.read())

        elif self.path == "/pcfiles":
            # Lists one directory under a PC_ROOTS root - dashboard Explorer's
            # "This PC" source. ?root=game|compute&path=<relative, may be "">
            root = (query.get("root") or [None])[0]
            rel = (query.get("path") or [""])[0]
            abs_path = resolve_pc_path(root, rel)
            if abs_path is None:
                self._send_json({"error": "invalid root/path"}, status=400)
                return
            if not os.path.isdir(abs_path):
                self._send_json({"error": "not found: " + rel}, status=404)
                return
            self._send_json({"entries": list_pc_entries(abs_path)})

        elif self.path == "/pcfiles/read":
            root = (query.get("root") or [None])[0]
            rel = (query.get("path") or [None])[0]
            abs_path = resolve_pc_path(root, rel or "")
            if abs_path is None or not rel:
                self._send_json({"error": "invalid root/path"}, status=400)
                return
            if not os.path.isfile(abs_path):
                self._send_json({"error": "not found: " + rel}, status=404)
                return
            with open(abs_path, "r", encoding="utf-8", errors="replace") as f:
                self._send_text(f.read())

        elif self.path == "/poll":
            node_id = (query.get("node") or [None])[0]
            if not node_id:
                self._send_json({"error": "poll needs ?node=<id>"}, status=400)
                return
            with state.lock:
                node = state.get_node(node_id)
                commands, node["pending"][:] = node["pending"][:], []
                now = time.time()
                for cmd in commands:
                    node["inflight"][str(cmd["id"])] = {"cmd": cmd, "ts": now}
                state_repo.mark_dirty()
                pin_set = node_id in state.node_shell_pins
            state.metric_inc("polls_served_total")
            # Piggybacks on the poll every node already does every cycle
            # (rather than a separate endpoint) so apps/common/fleetbridge.lua
            # can cache "does THIS node have a shell PIN" locally, at zero
            # extra network cost - see fleetos.lua's terminate handler for
            # why that local cache matters (gating Ctrl+T on a live network
            # round trip every time would be worse than the problem it
            # solves). A header, not a body field, so /poll's existing
            # "just a plain array of commands" response shape - which
            # apps/common/fleetbridge.lua's poll() already parses - doesn't
            # need to change at all.
            self._send_json(commands, extra_headers={"X-Shell-Pin-Set": "1" if pin_set else "0"})

        elif self.path == "/health":
            # previously the only way to guess at bridge health was to
            # poll /status and eyeball whether nodes look recent - a proper
            # healthcheck endpoint is what orchestration/monitoring tooling
            # (or just a cron job) actually needs. No auth required, same as
            # "/"/"/dashboard" - a healthcheck probe that had to know an API
            # key first wouldn't be usable by most external tooling.
            with state.lock:
                now = time.time()
                recent = sum(
                    1 for node in state.nodes.values()
                    if node["latest_report_time"] and (now - node["latest_report_time"]) < HEALTH_RECENT_SECONDS
                )
                nodes_known = len(state.nodes)
            self._send_json({
                "ok": True,
                "uptime_seconds": round(now - START_TIME, 1),
                "nodes_known": nodes_known,
                "nodes_reporting_recently": recent,
            })

        elif self.path == "/metrics":
            # basic operational counters - command volume, report
            # volume, error rate, rate-limit hits - so a degrading system
            # (rising errors, hitting the rate limiter) is visible before it
            # becomes a full outage, not just guessable after the fact from
            # bridge.log. Deliberately plain JSON (not Prometheus exposition
            # format) - consistent with every other route here, and this
            # project has no other Prometheus-format consumer to justify it.
            with state.lock:
                now = time.time()
                snapshot = dict(state.metrics)
            self._send_json({
                "uptime_seconds": round(now - START_TIME, 1),
                "nodes_known": len(state.nodes),
                "results_stored": len(state.results_by_id),
                **snapshot,
            })

        elif self.path == "/metrics/history":
            # Same auth tier as /metrics itself (read-only key is enough -
            # see the exempt-path check above do_GET's dispatch, which
            # only requires the FULL key for "/admin/export").
            range_key = (query.get("range") or ["hour"])[0]
            result = _metrics_history_buckets_cached(range_key)
            if result is None:
                self._send_json(
                    {"error": "invalid range - use one of: " + ", ".join(METRICS_HISTORY_RANGES)},
                    status=400)
                return
            self._send_json(result)

        elif self.path == "/status":
            with state.lock:
                now = time.time()
                result = {}
                for node_id, node in state.nodes.items():
                    ts = node["latest_report_time"]
                    result[node_id] = {
                        "latest_report": node["latest_report"],
                        "seconds_since_report": (now - ts) if ts else None,
                        "folder": state.node_folders.get(node_id, ""),
                        # surfaced for the dashboard's per-node status tab -
                        # never the PIN itself (only ever stored as a hash,
                        # see /admin/shell_pin), just whether one is set
                        "shellPinSet": node_id in state.node_shell_pins,
                    }
                self._send_json({"nodes": result})

        elif self.path.startswith("/result/"):
            cmd_id = self.path[len("/result/"):]
            with state.lock:
                entry = state.results_by_id.get(cmd_id)
                if entry is not None:
                    entry["fetched"] = True
            state.metric_inc("results_fetched_total")
            self._send_json({"found": entry is not None, "result": entry["result"] if entry else None})

        elif self.path == "/admin/export":
            # full-fleet backup/restore - previously the only persisted
            # state was bridge_state.json/node_meta.json as opaque files an
            # admin would have to know to copy by hand. This bundles both
            # into one downloadable JSON blob; POST /admin/import (below)
            # restores it. Full key required (not read-only) - this includes
            # every node's folder assignment and pending/inflight commands.
            with state.lock:
                bundle = {
                    "version": STATE_VERSION,  # - same versioning as bridge_state.json/node_meta.json
                    "exported_at": time.time(),
                    "node_folders": state.node_folders,
                    "next_id": state.next_id,
                    "broadcast_log": state.broadcast_log,
                    "nodes": {
                        node_id: {"pending": node["pending"], "inflight": node["inflight"]}
                        for node_id, node in state.nodes.items()
                    },
                }
            self._send_json(bundle)

        else:
            self._send_json({"error": "not found"}, status=404)

    def do_POST(self):
        if not self._check_rate_limit():
            return

        parsed = urlsplit(self.path)
        self.path = parsed.path
        query = parse_qs(parsed.query)

        is_apps_lua_path = self.path.startswith("/apps/") and self.path.endswith(".lua")

        # State-changing routes: a valid READONLY_API_KEY is rejected
        # here even though it'd otherwise pass _check_auth - see that
        # constant's comment. /compute/<name> and /world_call are both
        # included on top of BROWSER_TRIGGERED_PATHS since either can run
        # arbitrary code / call arbitrary peripheral methods on a node
        # - /world_call's "peripheral_call" action is just as capable as
        # /command, it's simply CSRF-exempt below (never called by a
        # browser), which is NOT the same thing as not needing a full key.
        needs_full_key = self.path in BROWSER_TRIGGERED_PATHS \
            or self.path == "/world_call" \
            or is_apps_lua_path \
            or self.path.startswith("/compute_scripts/") \
            or self.path.startswith("/compute/")
        if not self._check_auth(require_full=needs_full_key):
            return

        # CSRF guard: required on every route a browser triggers as a
        # side-effecting action. /report, /compute/<name> and /world_call are
        # excluded - all three are only ever called by a CC:Tweaked computer
        # or a compute-script subprocess it spawned (fleetbridge.lua /
        # raytower_master.lua / fleetos_world.py), never a browser, so
        # there's no browser-only header for any of them to send. Don't add
        # them here on the assumption that "it's POST so it must need CSRF"
        # - they don't.
        if self.path in BROWSER_TRIGGERED_PATHS \
                or is_apps_lua_path \
                or self.path.startswith("/compute_scripts/"):
            if not self._check_csrf():
                return

        # audit trail for every state-changing action - who (source IP,
        # key role) did what (method/path), so an incident can at least be
        # reconstructed after the fact. Body isn't logged (may contain file
        # contents/secrets); command bodies for /command specifically are
        # small and useful enough to include.
        if needs_full_key:
            logger.info(f"[audit] {self.client_address[0]} role={getattr(self, '_auth_role', '?')} POST {self.path}")

        if self.path == "/command":
            cmd = self._read_json_body()
            if cmd is None:
                return
            target = cmd.get("node") or cmd.get("target")  # "target" kept as an alias
            if not target:
                self._send_json({"error": "command needs a 'node' (or \"*\" for every known node)"}, status=400)
                return
            with state.lock:
                cmd["id"] = state.allocate_command_id()
                if target == "*":
                    for node in state.nodes.values():
                        node["pending"].append(cmd)
                    queued_to = list(state.nodes.keys())
                    # Remembered so a node that registers itself LATER (hadn't
                    # polled yet when this broadcast went out) still gets it -
                    # see get_node()'s seeding logic.
                    state.broadcast_log.append({"id": cmd["id"], "ts": time.time(), "cmd": cmd})
                else:
                    state.get_node(target)["pending"].append(cmd)
                    queued_to = [target]
                state_repo.mark_dirty()
            state.metric_inc("commands_queued_total")
            self._send_json({"queued": True, "id": cmd["id"], "nodes": queued_to})

        elif self.path == "/node_folder":
            # Assigns (or clears, if folder is "") a node to a dashboard-side
            # folder - purely organizational, the node itself never knows or
            # cares. Persisted immediately so it survives a bridge restart.
            body = self._read_json_body()
            if body is None:
                return
            node_id = (body.get("node") or "").strip()
            if not node_id:
                self._send_json({"error": "node_folder needs 'node'"}, status=400)
                return
            folder = (body.get("folder") or "").strip()
            with state.lock:
                if folder:
                    state.node_folders[node_id] = folder
                else:
                    state.node_folders.pop(node_id, None)
                state.save_node_folders()
            self._send_json({"ok": True})

        elif self.path == "/admin/shell_pin":
            # Sets (or, with pin="") clears the PIN apps/common/shell.lua
            # requires locally before it'll run `bridge <url> [key]` on the
            # given nodes - dashboard-only, full key + CSRF required like
            # any other fleet-wide config push. "nodes" is always an
            # explicit list (never a stored wildcard) - the dashboard
            # resolves "all" to every currently-known node id client-side
            # (see bulkSetShellPin), so this stays consistent with how
            # every other bulk action here already works.
            body = self._read_json_body()
            if body is None:
                return
            node_ids = body.get("nodes")
            if not isinstance(node_ids, list) or not node_ids:
                self._send_json({"error": "shell_pin needs a non-empty 'nodes' list"}, status=400)
                return
            pin = body.get("pin") or ""
            with state.lock:
                for node_id in node_ids:
                    if not isinstance(node_id, str) or not node_id:
                        continue
                    if pin:
                        state.node_shell_pins[node_id] = _hash_shell_pin(pin)
                    else:
                        state.node_shell_pins.pop(node_id, None)
                state.save_node_folders()
            self._send_json({"ok": True})

        elif self.path == "/admin/delete_node":
            # Removes a node from the fleet view entirely (status,
            # pending/inflight commands, folder assignment, shell PIN) -
            # dashboard-only, full key + CSRF, same "nodes" list-of-ids
            # convention as /admin/shell_pin above. Purely a bridge-side
            # cleanup: this does NOT reach out to the node itself, so a
            # still-alive node that keeps polling will simply reappear
            # (via get_node()) on its next poll/report cycle - intended for
            # clearing out stale/decommissioned/test entries, not for
            # actually taking a live computer offline.
            body = self._read_json_body()
            if body is None:
                return
            node_ids = body.get("nodes")
            if not isinstance(node_ids, list) or not node_ids:
                self._send_json({"error": "delete_node needs a non-empty 'nodes' list"}, status=400)
                return
            with state.lock:
                for node_id in node_ids:
                    if not isinstance(node_id, str) or not node_id:
                        continue
                    state.nodes.pop(node_id, None)
                    state.node_folders.pop(node_id, None)
                    state.node_shell_pins.pop(node_id, None)
                state.save_node_folders()
                state_repo.mark_dirty()
            self._send_json({"ok": True})

        elif self.path == "/admin/spawn_sim_node":
            # Starts a new Windows-simulated computer (windows/sim/<id>/,
            # driven by run_sim_node.lua - see that file's header) as a
            # real OS subprocess, so the dashboard's "Create emulation"
            # button doesn't need a terminal open. Only useful for local
            # dev/testing against this same bridge - never touches a real
            # in-game computer. Gated by SIM_SPAWN_ENABLED (see its
            # comment) on top of the usual full-key + CSRF requirement.
            if not SIM_SPAWN_ENABLED:
                self._send_json(
                    {"error": "sim node spawning is disabled - set FLEET_ENABLE_SIM_SPAWN=1 "
                              "on the bridge to allow starting local Lua sim processes from the dashboard"},
                    status=403)
                return
            body = self._read_json_body()
            if body is None:
                return
            node_id = (body.get("id") or "").strip()
            if not is_valid_sim_node_id(node_id):
                self._send_json({"error": "id must be 1-64 letters/digits/underscore/hyphen only"}, status=400)
                return
            role = (body.get("role") or "generic").strip() or "generic"
            if not is_valid_sim_role(role):
                self._send_json({"error": "role must be 1-32 letters/digits/space/underscore/hyphen"}, status=400)
                return
            lua_exe = shutil.which("lua")
            if not lua_exe:
                self._send_json(
                    {"error": "no 'lua' interpreter found on PATH - install Lua 5.x to use sim nodes"},
                    status=500)
                return
            with state.lock:
                existing = state.sim_processes.get(node_id)
                already_running = existing is not None and existing.poll() is None
            if already_running:
                self._send_json(
                    {"error": f"a sim node named '{node_id}' is already running (pid {existing.pid})"}, status=409)
                return

            node_dir = os.path.join(SIM_DIR, node_id)
            bridge_url = "http://127.0.0.1:" + str(self.server.server_address[1])
            created = not os.path.isdir(node_dir)
            if created:
                try:
                    os.makedirs(node_dir, exist_ok=True)
                    shutil.copy2(FLEETOS_PATH, os.path.join(node_dir, "fleetos.lua"))
                    shutil.copytree(APPS_DIR, os.path.join(node_dir, "apps"))
                    startup_src = os.path.join(GAME_DIR, "startup.lua")
                    if os.path.isfile(startup_src):
                        shutil.copy2(startup_src, os.path.join(node_dir, "startup.lua"))
                    # "clock" is deliberately NOT in here - it's a proof-of-
                    # concept app that prints every 5s forever, which floods
                    # the 200-line output buffer over any real session and
                    # evicts actual command output/results within moments -
                    # exactly the kind of thing that makes the Terminal feel
                    # broken right when you're trying to use it.
                    config_lua = (
                        '-- auto-created by dashboard\'s "Create emulation" button\n'
                        "return {id=%s, role=%s, startup={\"fleetbridge\"}}\n"
                    ) % (lua_quote(node_id), lua_quote(role))
                    with open(os.path.join(node_dir, "config.lua"), "w", encoding="utf-8") as f:
                        f.write(config_lua)
                except OSError as e:
                    self._send_json({"error": "failed to set up sim node folder: " + str(e)}, status=500)
                    return

            # Alongside the other two log kinds (bridge/, nodes/), not
            # inside node_dir itself - windows/sim/<id>/ is that node's
            # simulated computer filesystem (what a real in-game computer's
            # disk would look like), and a log file has no business mixed
            # into that any more than it would belong on a real node's disk.
            sim_logs_dir = os.path.join(LOGS_DIR, "sim")
            os.makedirs(sim_logs_dir, exist_ok=True)
            log_path = os.path.join(sim_logs_dir, node_id + "_console.log")
            try:
                log_file = open(log_path, "ab")
                try:
                    proc = subprocess.Popen(
                        [lua_exe, RUN_SIM_NODE_PATH, bridge_url],
                        cwd=node_dir, stdout=log_file, stderr=subprocess.STDOUT)
                finally:
                    log_file.close()  # child keeps its own OS-level handle once started
            except OSError as e:
                self._send_json({"error": "failed to start sim node: " + str(e)}, status=500)
                return
            with state.lock:
                state.sim_processes[node_id] = proc
            logger.info(f"[bridge] spawned sim node '{node_id}' (pid {proc.pid}, created={created})")
            self._send_json({"ok": True, "id": node_id, "pid": proc.pid, "created": created})

        elif self.path == "/shell_pin_check":
            # Called by apps/common/shell.lua (NOT the dashboard - no CSRF
            # header to send, so deliberately not in BROWSER_TRIGGERED_PATHS)
            # before it lets a player at the physical computer repoint this
            # node's bridge. Checked against whatever bridge is CURRENTLY
            # configured, before any override takes effect - see that file's
            # comment for why this has to be a server round trip rather than
            # a locally-stored PIN. Same auth level as /poll and /report
            # (whatever key, if any, this node already has), not full-key-only.
            node_id = (query.get("node") or [None])[0]
            if not node_id:
                self._send_json({"error": "shell_pin_check needs ?node=<id>"}, status=400)
                return
            body = self._read_json_body()
            if body is None:
                return
            pin = body.get("pin") or ""
            with state.lock:
                expected_hash = state.node_shell_pins.get(node_id)
            if expected_hash is None:
                self._send_json({"required": False, "ok": True})
                return
            ok = isinstance(pin, str) and hmac.compare_digest(_hash_shell_pin(pin), expected_hash)
            self._send_json({"required": True, "ok": ok})

        elif self.path == "/report":
            node_id = (query.get("node") or [None])[0]
            if not node_id:
                self._send_json({"error": "report needs ?node=<id>"}, status=400)
                return
            body = self._read_json_body()
            if body is None:
                return
            with state.lock:
                node = state.get_node(node_id)
                _merge_report(node, node_id, body)
                now = time.time()
                for item in body.get("results", []):
                    cmd = item.get("command", {})
                    cmd_id = cmd.get("id")
                    if cmd_id is not None:
                        state.results_by_id[str(cmd_id)] = {"result": item.get("result"), "ts": now, "fetched": False}
                        # The command finished executing - stop treating it as
                        # in-flight so _sweep_inflight() doesn't requeue it.
                        node["inflight"].pop(str(cmd_id), None)
                    # A successful "rename" acks under the OLD node_id (see
                    # fleetbridge.lua's rename handler) right before rebooting
                    # under the new one - without this, a folder assignment
                    # would silently orphan itself on the old, now-dead id.
                    result = item.get("result") or {}
                    if cmd.get("type") == "rename" and result.get("renamed") and cmd.get("newId"):
                        old_folder = state.node_folders.pop(node_id, None)
                        if old_folder:
                            state.node_folders[cmd["newId"]] = old_folder
                            state.save_node_folders()
                state.prune_results()
                state_repo.mark_dirty()
            state.metric_inc("reports_received_total")
            self._send_json({"ok": True})

        elif self.path == "/apps":
            # creates a brand new app on THIS PC. Deliberately separate from
            # the /apps/<name>.lua editor route below - refuses to clobber
            # an existing app so a typo'd "create" can't silently wipe one.
            body = self._read_json_body()
            if body is None:
                return
            name = (body.get("name") or "").strip()
            if not name or "/" in name or ".." in name or not name.replace("_", "").isalnum():
                self._send_json({"error": "invalid app name"}, status=400)
                return
            filename = name + ".lua"
            if resolve_app_path(filename):
                self._send_json({"error": "an app named '" + name + "' already exists"}, status=409)
                return
            group = body.get("group") or ""
            if group in APP_GROUPS:
                path = os.path.join(APPS_DIR, group, filename)
            else:
                path = os.path.join(APPS_DIR, filename)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            # The resolve_app_path() check above is a TOCTOU race (two
            # concurrent creates of the same name can both pass it before
            # either writes) - "x" mode makes the actual write atomic
            # against that exact race: the OS refuses to open a file that
            # already exists, so the second writer gets the same 409 the
            # first check was meant to guarantee instead of silently
            # clobbering the first writer's content.
            try:
                with open(path, "x", encoding="utf-8") as f:
                    f.write(body.get("content") or "")
            except FileExistsError:
                self._send_json({"error": "an app named '" + name + "' already exists"}, status=409)
                return
            self._send_json({"ok": True, "path": path})

        elif self.path.startswith("/apps/") and self.path.endswith(".lua"):
            # saves an edited app back to disk on THIS PC (game/apps/<name>.lua).
            # This does not touch the actual in-game computer - hit Deploy
            # afterwards to push the saved file out over the fleet.
            name = self.path[len("/apps/"):]
            if "/" in name or ".." in name:
                self._send_json({"error": "invalid app name"}, status=400)
                return
            body = self._read_json_body()
            if body is None:
                return
            content = body.get("content", "")
            # save back wherever it already lives (its group folder), so
            # editing doesn't move an app out of common/master/tower into
            # the flat apps/ folder. New apps (not found anywhere) default
            # to flat.
            path = resolve_app_path(name) or os.path.join(APPS_DIR, name)
            # Atomic write (same pattern /pcfiles/write already
            # uses) - this saves the exact app source a node's "deploy"/
            # "update" fetches and runs shortly after, so a crash/kill
            # mid-write here previously could leave a truncated/corrupt
            # .lua file that then gets deployed as-is.
            tmp_path = path + ".tmp_write"
            with open(tmp_path, "w", encoding="utf-8") as f:
                f.write(content)
            os.replace(tmp_path, path)
            self._send_json({"ok": True})

        elif self.path.startswith("/compute_scripts/"):
            # Saves a compute script's Python source to windows/compute/<name>.py
            # - dashboard-only editing (Create/Save), separate from actually
            # running it (POST /compute/<name> below, called by in-game Lua).
            # Always writes the .py form, even if an <name>.exe already exists
            # alongside it - compiled scripts aren't editable from here.
            name = self.path[len("/compute_scripts/"):]
            if not is_valid_compute_name(name):
                self._send_json({"error": "invalid compute script name"}, status=400)
                return
            body = self._read_json_body()
            if body is None:
                return
            os.makedirs(COMPUTE_DIR, exist_ok=True)
            path = os.path.join(COMPUTE_DIR, name + ".py")
            # Same atomic-write reasoning as /apps/<name>.lua above - this
            # script gets executed as a subprocess by POST /compute/<name>
            # shortly after being saved, so a truncated write here would
            # get run as-is.
            tmp_path = path + ".tmp_write"
            with open(tmp_path, "w", encoding="utf-8") as f:
                f.write(body.get("content", ""))
            os.replace(tmp_path, path)
            self._send_json({"ok": True})

        elif self.path == "/pcfiles/write":
            # Creates/overwrites a file under a PC_ROOTS root - used by the
            # dashboard's "This PC" Explorer AND its drag-and-drop upload
            # (each dropped file becomes one of these calls). Creates parent
            # directories as needed so dropping a whole folder tree works in
            # one pass without a separate mkdir per intermediate directory.
            body = self._read_json_body()
            if body is None:
                return
            abs_path = resolve_pc_path(body.get("root"), body.get("path") or "")
            if abs_path is None or not (body.get("path") or "").strip():
                self._send_json({"error": "invalid root/path"}, status=400)
                return
            os.makedirs(os.path.dirname(abs_path), exist_ok=True)
            # write to a temp file then os.replace() into place (atomic
            # on the same filesystem, same pattern _save_state already uses)
            # instead of writing straight into abs_path - a crash/kill mid-
            # write previously could leave abs_path holding truncated/
            # corrupt content instead of either the old or new version.
            tmp_path = abs_path + ".tmp_write"
            with open(tmp_path, "w", encoding="utf-8") as f:
                f.write(body.get("content") or "")
            os.replace(tmp_path, abs_path)
            self._send_json({"ok": True})

        elif self.path == "/pcfiles/mkdir":
            body = self._read_json_body()
            if body is None:
                return
            abs_path = resolve_pc_path(body.get("root"), body.get("path") or "")
            if abs_path is None or not (body.get("path") or "").strip():
                self._send_json({"error": "invalid root/path"}, status=400)
                return
            # Mirrors fleetbridge.lua's "mkdir" - os.makedirs(exist_ok=True)
            # alone would silently say nothing about a name collision.
            if os.path.isdir(abs_path):
                self._send_json({"ok": True, "alreadyExisted": True})
                return
            if os.path.exists(abs_path):
                self._send_json({"error": "a file already exists there: " + body.get("path", "")}, status=409)
                return
            try:
                os.makedirs(abs_path)
            except OSError as e:
                self._send_json({"error": "mkdir failed: " + str(e)}, status=500)
                return
            self._send_json({"ok": True})

        elif self.path == "/pcfiles/delete":
            body = self._read_json_body()
            if body is None:
                return
            rel = (body.get("path") or "").strip()
            abs_path = resolve_pc_path(body.get("root"), rel)
            # rel == "" would resolve to the root itself (game/ or compute/) -
            # refuse outright, same reasoning as fleetbridge.lua's "delete"
            # guard against an empty path meaning "the whole root".
            if abs_path is None or not rel:
                self._send_json({"error": "invalid root/path"}, status=400)
                return
            if not os.path.exists(abs_path):
                self._send_json({"error": "not found: " + rel}, status=404)
                return
            try:
                if os.path.isdir(abs_path):
                    shutil.rmtree(abs_path)
                else:
                    os.remove(abs_path)
            except OSError as e:
                self._send_json({"error": "delete failed: " + str(e)}, status=500)
                return
            self._send_json({"ok": True})

        elif self.path == "/pcfiles/move":
            # Renames/moves a file or directory under a PC_ROOTS root -
            # dashboard Explorer's rename UI, PC-side counterpart to
            # fleetbridge.lua's "move" command.
            body = self._read_json_body()
            if body is None:
                return
            root = body.get("root")
            from_rel = (body.get("from") or "").strip()
            to_rel = (body.get("to") or "").strip()
            from_abs = resolve_pc_path(root, from_rel)
            to_abs = resolve_pc_path(root, to_rel)
            if from_abs is None or to_abs is None or not from_rel or not to_rel:
                self._send_json({"error": "invalid root/path"}, status=400)
                return
            if not os.path.exists(from_abs):
                self._send_json({"error": "not found: " + from_rel}, status=404)
                return
            if os.path.exists(to_abs):
                self._send_json({"error": "already exists: " + to_rel}, status=409)
                return
            try:
                shutil.move(from_abs, to_abs)
            except OSError as e:
                self._send_json({"error": "move failed: " + str(e)}, status=500)
                return
            self._send_json({"ok": True})

        elif self.path.startswith("/compute/"):
            # Runs windows/compute/<name>.py|.exe as a subprocess, JSON in via
            # stdin, JSON out via stdout - see resolve_compute_script() and
            # the module docstring. List-form args only, never shell=True:
            # the name check below is the only thing standing between this
            # and arbitrary command injection if that were ever relaxed.
            if not COMPUTE_ENABLED:
                self._send_json(
                    {"error": "compute scripts are disabled - set FLEET_ENABLE_COMPUTE=1 "
                              "on the bridge to allow running windows/compute/*.py|.exe "
                              "(this executes arbitrary code with this process's privileges)"},
                    status=403)
                return
            name = self.path[len("/compute/"):]
            if not is_valid_compute_name(name):
                self._send_json({"error": "invalid compute script name"}, status=400)
                return
            body = self._read_json_body()
            if body is None:
                return
            path, is_python = resolve_compute_script(name)
            if not path:
                self._send_json({"error": "no compute script named '" + name + "'"}, status=404)
                return
            if not _long_request_semaphore.acquire(blocking=False):
                self._send_json(
                    {"error": "bridge is busy (too many concurrent compute/world_call requests), try again shortly"},
                    status=503)
                return
            argv = [sys.executable, path] if is_python else [path]

            # Opt-in "world access": if the CALLING Lua app passed ?node=<id>,
            # the script can import fleetos_world and call world.print(),
            # world.gps_locate(), world.peripheral_call() etc - each does an
            # HTTP round trip to /world_call below, which queues a command
            # for that SAME node the normal way and blocks until that node's
            # own poll loop executes it and reports back (see /world_call's
            # comment for the full path). Without ?node=, world.* calls fail
            # fast with a clear error - existing scripts that never asked for
            # this (e.g. triangulation.py, called with no node) are unaffected.
            node_id = (query.get("node") or [None])[0]
            env = None
            timeout = COMPUTE_TIMEOUT_SECONDS
            if node_id:
                # a minimal whitelist, not the bridge's full environment -
                # a compute script has no legitimate reason to see this
                # process's other env vars (which could include FLEET_BRIDGE_KEY
                # itself, unrelated secrets, etc). Just enough for Python/the
                # OS loader to work plus the two FLEETOS_* vars it actually needs.
                env = {k: v for k, v in os.environ.items() if k in ("PATH", "PATHEXT", "SystemRoot", "TEMP", "TMP")}
                env["FLEETOS_NODE"] = node_id
                env["FLEETOS_BRIDGE_URL"] = "http://127.0.0.1:" + str(self.server.server_address[1])
                timeout = COMPUTE_WORLD_TIMEOUT_SECONDS
            try:
                try:
                    proc = subprocess.run(
                        argv, input=json.dumps(body).encode("utf-8"),
                        capture_output=True, timeout=timeout, env=env)
                except subprocess.TimeoutExpired:
                    self._send_json(
                        {"error": "compute script '" + name + "' timed out after "
                                  + str(timeout) + "s"}, status=500)
                    return
                except OSError as e:
                    self._send_json({"error": "failed to run compute script '" + name + "': " + str(e)}, status=500)
                    return
                if proc.returncode != 0:
                    stderr_tail = proc.stderr.decode("utf-8", errors="replace")[-500:]
                    self._send_json(
                        {"error": "compute script '" + name + "' exited " + str(proc.returncode) + ": " + stderr_tail},
                        status=500)
                    return
                try:
                    result = json.loads(proc.stdout.decode("utf-8"))
                except UnicodeDecodeError:
                    self._send_json({"error": "compute script '" + name + "' printed non-UTF-8 output"}, status=500)
                    return
                except json.JSONDecodeError:
                    # A quick/dirty script that just print()s plain text (not a
                    # JSON object) is common, especially while writing a new one
                    # - wrap it instead of failing outright, so the dashboard's
                    # "Run" always gets something back to show.
                    result = {"output": proc.stdout.decode("utf-8", errors="replace")}
                self._send_json(result)
            finally:
                _long_request_semaphore.release()

        elif self.path == "/world_call":
            # Called by fleetos_world.py (running inside a /compute/<name>
            # subprocess that was given ?node=<id>, not by a browser - same
            # CSRF exemption reasoning as /report and /compute above) to let
            # that Python script act like a real Lua program instead of a
            # pure stdin/stdout function: {node, action, args} is queued as
            # a "world_call" command for `node` THE EXACT SAME WAY any
            # dashboard /command is (see POST /command above) - no separate
            # transport. That node's own fleetbridge.lua poll loop picks it
            # up on its next ~1s cycle, actually executes the Lua (print/
            # gps.locate/peripheral.call), and reports the result back
            # through the normal report()->results_by_id path. This just
            # blocks (polling that same results_by_id map) until it shows up
            # or WORLD_CALL_TIMEOUT_SECONDS passes - the compute script's own
            # subprocess timeout (COMPUTE_WORLD_TIMEOUT_SECONDS, see above)
            # is set generously longer so it doesn't get killed mid-wait.
            body = self._read_json_body()
            if body is None:
                return
            node_id = body.get("node")
            action = body.get("action")
            if not node_id or not action:
                self._send_json({"error": "world_call needs 'node' and 'action'"}, status=400)
                return
            if not _long_request_semaphore.acquire(blocking=False):
                self._send_json(
                    {"error": "bridge is busy (too many concurrent compute/world_call requests), try again shortly"},
                    status=503)
                return
            try:
                with state.lock:
                    cmd_id = state.allocate_command_id()
                    cmd = {"id": cmd_id, "type": "world_call", "action": action, "args": body.get("args") or {}}
                    state.get_node(node_id)["pending"].append(cmd)
                    # Bug fix: this queues onto the same persisted `pending`/
                    # next_id state /command does (which DOES call this) -
                    # missing it here meant a world_call queued right before
                    # a crash/kill could vanish on restart with no trace,
                    # silently (not even the timeout error path below runs).
                    state_repo.mark_dirty()
                deadline = time.time() + WORLD_CALL_TIMEOUT_SECONDS
                while time.time() < deadline:
                    with state.lock:
                        entry = state.results_by_id.get(str(cmd_id))
                    if entry is not None:
                        self._send_json(entry["result"])
                        return
                    time.sleep(0.1)
                self._send_json(
                    {"error": "world_call '" + action + "' timed out waiting for node '" + node_id + "'"}, status=504)
            finally:
                _long_request_semaphore.release()

        elif self.path == "/admin/import":
            # restores a bundle from GET /admin/export. Replaces
            # node_folders/nodes/broadcast_log/next_id wholesale (not
            # merged) - meant for disaster recovery (bridge PC died, restore
            # onto a fresh one) or rolling back a bad bulk "configure", not
            # routine use. latest_report/latest_report_time are intentionally
            # preserved for any node that already existed and is KEPT by this
            # import - a node repopulates those itself on its next poll
            # anyway, so wiping them would just show "no report yet" for a
            # few seconds; but a node NOT present in the bundle is dropped
            # entirely (see the bug note below).
            #
            # Bug fix: this used to only ADD/UPDATE the nodes listed in the
            # bundle, via get_node() (which never removes anything) - despite
            # this comment already promising "wholesale, not merged", a node
            # that existed on the server but wasn't in the imported bundle
            # was silently kept around forever. Found live: a user asked to
            # remove two stale test nodes by importing a bundle containing
            # only the one real node they wanted to keep, and the two stale
            # ones were still there afterward. Fixed by building a fresh
            # `nodes` dict from scratch instead of mutating the existing one.
            body = self._read_json_body()
            if body is None:
                return
            if not isinstance(body, dict) or "nodes" not in body:
                self._send_json({"error": "not a valid export bundle"}, status=400)
                return
            with state.lock:
                state.node_folders.clear()
                state.node_folders.update(body.get("node_folders") or {})
                state.broadcast_log[:] = body.get("broadcast_log") or []
                state.next_id = body.get("next_id", state.next_id)
                new_nodes = {}
                for node_id, saved in (body.get("nodes") or {}).items():
                    old = state.nodes.get(node_id)
                    new_nodes[node_id] = {
                        "pending": saved.get("pending", []),
                        "inflight": saved.get("inflight", {}),
                        "latest_report": old["latest_report"] if old else None,
                        "latest_report_time": old["latest_report_time"] if old else None,
                    }
                state.nodes.clear()
                state.nodes.update(new_nodes)
                state.save_node_folders()
                state_repo.mark_dirty()
            self._send_json({"ok": True})

        elif self.path == "/admin/reload":
            # re-exec this same process (same argv, same port) so
            # picking up a code update to bridge_server.py doesn't require
            # the operator to manually stop/restart it, losing whatever's
            # queued in the meantime. State is saved first (_save_state)
            # and reloaded automatically by _load_state() at the top of the
            # new process, exactly like a normal restart.
            #
            # Windows caveat: os.execv() has no real exec() syscall to call
            # on Windows, so Python emulates it by spawning a brand new
            # process and exiting this one - the PID actually changes, even
            # though the same port/state make it look seamless to an HTTP
            # client. Anything tracking the OLD pid specifically (notably
            # run_bridge_background.bat's bridge.pid, or a Task Scheduler
            # entry configured to watch one exact process) will see this
            # process as "gone" even though a new one is already serving
            # requests - re-run run_bridge_background.bat afterward if you
            # need bridge.pid/stop_bridge.bat to point at the right PID again.
            with state.lock:
                state_repo.save(state)
            self._send_json({"ok": True, "reloading": True})

            def _do_reload():
                time.sleep(0.3)  # give the response above a moment to flush
                logger.info("[bridge] /admin/reload: re-executing process now")
                os.execv(sys.executable, [sys.executable] + sys.argv)

            threading.Thread(target=_do_reload, daemon=True).start()

        else:
            self._send_json({"error": "not found"}, status=404)


class Server(ThreadingHTTPServer):
    # socketserver's default backlog (5) is well below what
    # test_bridge_server_load.py's own concurrency (up to 32 worker
    # threads hitting this server at once) needs - fine on a fast local
    # machine where accept() keeps up, but a slower/more loaded CI runner
    # can let the OS's backlog fill up first, resetting the excess
    # connections (seen as ConnectionResetError in the load tests, not a
    # bug in the test itself). A real fleet's bursts (many nodes polling
    # at once, a broadcast command fan-out) aren't smaller than this.
    request_queue_size = 128

    def handle_error(self, request, client_address):
        # A client (dashboard.html's polling, a curl with -m, a rebooting
        # node) closing/aborting mid-response is normal and frequent - the
        # default handle_error dumps a full traceback to stderr for every
        # single one of these, which drowns out real errors. Only genuinely
        # unexpected exceptions still get a full traceback.
        exc = sys.exc_info()[1]
        if isinstance(exc, (ConnectionAbortedError, ConnectionResetError, BrokenPipeError)):
            logger.info(f"[bridge] {client_address} disconnected mid-response ({type(exc).__name__})")
        else:
            logger.error(f"[bridge] unhandled error handling request from {client_address}:")
            logger.error(traceback.format_exc())


def main():
    global API_KEY
    port = _PORT_FOR_LOG  # parsed once, near LOG_PATH above, so the log filename and the bound port can't drift apart
    host = os.environ.get("FLEET_BRIDGE_HOST", "127.0.0.1")

    if not API_KEY and host != "127.0.0.1":
        # Previously refused to start at all here unless you set your own
        # FLEET_BRIDGE_KEY by hand first - real friction (a Radmin/LAN user
        # just wants it to work, not to invent and remember a secret) for a
        # security property that doesn't actually need a HUMAN-chosen key.
        # Auto-generate + persist one instead (see _get_or_create_auto_key)
        # so binding beyond localhost is still never silently unauthenticated
        # by default, but the user only ever has to copy-paste a key this
        # code already made for them. FLEET_BRIDGE_HOST_ALLOW_INSECURE=1
        # still works exactly as before, for someone who deliberately wants
        # zero auth on a network they fully trust.
        if os.environ.get("FLEET_BRIDGE_HOST_ALLOW_INSECURE") == "1":
            logger.warning("[bridge] WARNING: bound beyond localhost with no authentication -")
            logger.warning("[bridge] anyone who can reach this can run code on your game computer.")
            logger.warning("[bridge] (continuing because FLEET_BRIDGE_HOST_ALLOW_INSECURE=1)")
        else:
            API_KEY = _get_or_create_auto_key()
            logger.info("[bridge] ==================================================================")
            logger.info("[bridge] no FLEET_BRIDGE_KEY set - generated one automatically (saved to")
            logger.info(f"[bridge] {BRIDGE_KEY_FILE},")
            logger.info("[bridge] reused on every future restart - delete that file to get a new one):")
            logger.info("[bridge]")
            logger.info(f"[bridge]     {API_KEY}")
            logger.info("[bridge]")
            logger.info("[bridge] paste it into: `install <url> <key>`, config.lua's apiKey field,")
            logger.info("[bridge] or the dashboard's \"API key\" field.")
            logger.info("[bridge] ==================================================================")

    server = Server((host, port), Handler)

    # Optional TLS: off by default (plain HTTP, fine for a trusted LAN/
    # localhost), on if both env vars point to a cert+key pair (e.g. a
    # self-signed one - `openssl req -x509 -newkey rsa:2048 -nodes -keyout
    # key.pem -out cert.pem -days 365`). Once enabled, every node's
    # config.lua bridgeUrl and dashboard.html's bridge address need to say
    # https:// instead of http://.
    #
    # Deliberately still OPT-IN, not required, even when host != 127.0.0.1 -
    # Radmin VPN (this project's own documented, first-class way to reach a
    # bridge beyond localhost - see start_bridge_mc.bat/docs/fleetos_guide.
    # html) already encrypts the whole tunnel itself, so forcing a second,
    # app-level TLS layer on top would just be cert-generation friction for
    # no real security gain in that specific, common case. This can't tell
    # "bound to a VPN's virtual interface" apart from "bound to a real
    # public/port-forwarded interface" from here (both are just some
    # non-127.0.0.1 IP) - so instead of guessing, warn loudly and let the
    # operator judge their own network. Trying to build no-dependency
    # (`Stdlib only, no pip install needed` - see this file's own header)
    # auto-cert-generation isn't realistic either: Python's stdlib ssl
    # module can only USE a cert, not create one, and shelling out to
    # openssl.exe (like other best-effort helpers in this file) can't be
    # assumed present on a stock Windows install the way curl.exe can.
    tls_cert = os.environ.get("FLEET_TLS_CERT")
    tls_key = os.environ.get("FLEET_TLS_KEY")
    scheme = "http"
    if tls_cert and tls_key:
        import ssl
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(certfile=tls_cert, keyfile=tls_key)
        server.socket = ctx.wrap_socket(server.socket, server_side=True)
        scheme = "https"
        logger.info("[bridge] TLS enabled (FLEET_TLS_CERT/FLEET_TLS_KEY set)")
    elif host != "127.0.0.1":
        logger.warning("[bridge] ==================================================================")
        logger.warning("[bridge] WARNING: bound to " + host + " (beyond localhost) over plain HTTP, no TLS.")
        logger.warning("[bridge] If this is only reachable over a VPN you already trust (Radmin,")
        logger.warning("[bridge] Tailscale, etc.) that tunnel is already encrypted end-to-end - this")
        logger.warning("[bridge] is fine as-is, nothing more to do.")
        logger.warning("[bridge] If this is reachable over the OPEN INTERNET instead (a forwarded")
        logger.warning("[bridge] router port, a cloud VM's public IP, etc.) - your API key and every")
        logger.warning("[bridge] command/file you send travel in CLEARTEXT and can be read or")
        logger.warning("[bridge] altered by anyone between you and this PC. Fix it:")
        logger.warning("[bridge]   openssl req -x509 -newkey rsa:2048 -nodes -days 365 \\")
        logger.warning("[bridge]     -keyout key.pem -out cert.pem -subj \"/CN=fleetos-bridge\"")
        logger.warning("[bridge]   set FLEET_TLS_CERT=cert.pem")
        logger.warning("[bridge]   set FLEET_TLS_KEY=key.pem")
        logger.warning("[bridge] then restart the bridge and switch every bridgeUrl/dashboard address")
        logger.warning("[bridge] from http:// to https://.")
        logger.warning("[bridge] ==================================================================")

    logger.info(f"[bridge] listening on {scheme}://{host}:{port}")
    if API_KEY:
        logger.info("[bridge] FLEET_BRIDGE_KEY is set - requests need a matching X-API-Key header")
    if READONLY_API_KEY:
        logger.info("[bridge] FLEET_BRIDGE_READONLY_KEY is set - grants read-only access")
    if COMPUTE_ENABLED:
        logger.info("[bridge] FLEET_ENABLE_COMPUTE=1 - /compute/<name> scripts CAN be executed")
    if SIM_SPAWN_ENABLED:
        logger.info("[bridge] FLEET_ENABLE_SIM_SPAWN=1 - /admin/spawn_sim_node CAN start local Lua sim processes")
    logger.info("[bridge] make sure apps/fleetbridge.lua's BASE_URL matches this address")
    logger.info("[bridge] and that computercraft-server.toml allows http to it (see windows/README.md)")
    logger.info(f"[bridge] logging to {LOG_PATH}")

    # Graceful shutdown: on Ctrl+C (KeyboardInterrupt/SIGINT, all
    # platforms) or SIGTERM/SIGBREAK (where supported - SIGTERM doesn't exist
    # as a deliverable signal on Windows, SIGBREAK is its Ctrl+Break console
    # equivalent), save pending/inflight commands and results to disk before
    # exiting so a restart doesn't lose them - previously nothing was saved on
    # shutdown at all, relying only on _save_node_folders' opportunistic writes.
    def _handle_term_signal(signum, frame):
        raise SystemExit(0)

    for _sig_name in ("SIGTERM", "SIGBREAK"):
        _sig = getattr(signal, _sig_name, None)
        if _sig is not None:
            try:
                signal.signal(_sig, _handle_term_signal)
            except (ValueError, OSError):
                pass

    try:
        server.serve_forever()
    except (KeyboardInterrupt, SystemExit):
        logger.info("\n[bridge] stopping - saving state")
    finally:
        with state.lock:
            state_repo.save(state)
        server.server_close()
        logger.info("[bridge] state saved, exiting")


if __name__ == "__main__":
    main()
