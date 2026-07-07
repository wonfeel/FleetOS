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
                             (or for "*") and auto-registers the node
    POST /report?node=<id> - each node's fleetbridge.lua calls this after
                             every poll; stores that node's latest status
                             (running apps, recent terminal output) + indexes
                             command results by id
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

# basic health/metrics - previously the only way to guess at bridge
# health was to poll /status and eyeball whether nodes look recent, and there
# were no counters at all to notice a degrading system (rising error rate,
# rate-limit hits) before it became a visible outage.
START_TIME = time.time()
HEALTH_RECENT_SECONDS = 30  # a node counts as "reporting recently" for /health if its last report is within this

metrics = {
    "commands_queued_total": 0,
    "reports_received_total": 0,
    "polls_served_total": 0,
    "results_fetched_total": 0,
    "rate_limited_total": 0,
    "http_errors_total": 0,
}


def _metric_inc(name, n=1):
    with lock:
        metrics[name] = metrics.get(name, 0) + n


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
)

MAX_BODY_BYTES = 2 * 1024 * 1024          # reject absurdly large request bodies outright
MAX_OUTPUT_LINES_STORED = 200             # cap per-node output kept in memory
RESULT_TTL_SECONDS = 5 * 60               # FETCHED command results older than this are dropped
UNFETCHED_RESULT_TTL_SECONDS = 30 * 60    # a result nobody has read yet (e.g. dashboard was
                                           # closed) gets a much longer grace period before
                                           # being dropped, so a slow admin doesn't miss it
MAX_RESULTS_STORED = 2000                 # hard cap regardless of age, in case of a burst
RATE_LIMIT_WINDOW_SECONDS = 10
RATE_LIMIT_MAX_REQUESTS = 100             # per source IP, per window - generous for normal polling

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
LOG_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), _LOG_FILENAME)
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


GAME_DIR = os.path.join(SCRIPT_DIR, "..", "game")
APPS_DIR = os.path.join(GAME_DIR, "apps")
FLEETOS_PATH = os.path.join(GAME_DIR, "fleetos.lua")
INSTALL_PATH = os.path.join(GAME_DIR, "install.lua")
TRIANGULATION_PATH = os.path.join(GAME_DIR, "triangulation.lua")
DASHBOARD_PATH = os.path.join(SCRIPT_DIR, "dashboard.html")
COMPUTE_DIR = os.path.join(SCRIPT_DIR, "compute")
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


def resolve_compute_script(name):
    # .py takes priority (run via this same Python interpreter); .exe is the
    # fallback for a compiled script (e.g. a future C++ port) - either way
    # the caller gets the exact same /compute/<name> contract. Returns
    # (path, is_python) or (None, None) if neither exists.
    py_path = os.path.join(COMPUTE_DIR, name + ".py")
    if os.path.isfile(py_path):
        return py_path, True
    exe_path = os.path.join(COMPUTE_DIR, name + ".exe")
    if os.path.isfile(exe_path):
        return exe_path, False
    return None, None


def list_compute_script_names():
    # Leading underscore (e.g. _fleetos_world.py) marks a shared helper
    # module meant to be imported by other compute scripts, not a runnable
    # script itself - excluded from the dashboard's listing so it doesn't
    # show up as something you'd "Run".
    if not os.path.isdir(COMPUTE_DIR):
        return []
    return sorted(f[:-3] for f in os.listdir(COMPUTE_DIR) if f.endswith(".py") and not f.startswith("_"))


def is_valid_compute_name(name):
    return bool(name) and "/" not in name and name.replace("_", "").isalnum()


# ---- PC-side file browsing (dashboard's Explorer, "This PC" source) ----
# Two roots only - NOT the whole repo/disk - so this can't turn into a
# general-purpose remote file browser for the machine bridge_server.py
# happens to run on. "game" mirrors exactly what a real computer's
# fs would look like (it's the master copy everything gets deployed
# from/to); "compute" is where windows/compute/<name>.py|.exe live.
PC_ROOTS = {"game": GAME_DIR, "compute": COMPUTE_DIR}


def resolve_pc_path(root_key, rel_path):
    # Returns an absolute path guaranteed to stay inside PC_ROOTS[root_key],
    # or None if root_key is unknown or rel_path tries to escape it (via
    # "..", an absolute path, or a different drive letter) - os.path.abspath
    # + a prefix check catches all of those uniformly, which is more robust
    # on Windows than a plain ".." substring check (mixed "/"/"\", "C:\\..").
    root = PC_ROOTS.get(root_key)
    if root is None:
        return None
    root_abs = os.path.abspath(root)
    candidate = os.path.abspath(os.path.join(root_abs, rel_path or ""))
    if candidate != root_abs and not candidate.startswith(root_abs + os.sep):
        return None
    return candidate


def list_pc_entries(abs_dir):
    entries = []
    for name in os.listdir(abs_dir):
        full = os.path.join(abs_dir, name)
        is_dir = os.path.isdir(full)
        entries.append({"name": name, "isDir": is_dir, "size": 0 if is_dir else os.path.getsize(full)})
    entries.sort(key=lambda e: (not e["isDir"], e["name"].lower()))
    return entries


# Mirrors fleetos.lua's resolveAppPath: apps/<name>.lua flat first (for
# anything dropped in directly), then each group folder - keeps this in
# sync with game/apps/common|master|tower/ so the dashboard can find/edit
# apps regardless of which group they're filed under.
APP_GROUPS = ["common", "raytower"]


def list_app_names():
    names = set()
    if os.path.isdir(APPS_DIR):
        names.update(f[:-4] for f in os.listdir(APPS_DIR) if f.endswith(".lua"))
        for group in APP_GROUPS:
            group_dir = os.path.join(APPS_DIR, group)
            if os.path.isdir(group_dir):
                names.update(f[:-4] for f in os.listdir(group_dir) if f.endswith(".lua"))
    return sorted(names)


def list_apps_grouped():
    # Mirrors fleetos.lua's listAvailableApps() grouping so the dashboard
    # can show the same folder structure and offer it as a dropdown when
    # creating a new app.
    groups = []
    if not os.path.isdir(APPS_DIR):
        return groups
    flat = sorted(f[:-4] for f in os.listdir(APPS_DIR) if f.endswith(".lua"))
    for group in APP_GROUPS:
        group_dir = os.path.join(APPS_DIR, group)
        if os.path.isdir(group_dir):
            names = sorted(f[:-4] for f in os.listdir(group_dir) if f.endswith(".lua"))
            if names:
                groups.append({"name": group, "apps": names})
    if flat:
        groups.append({"name": "other", "apps": flat})
    return groups


def resolve_app_path(filename):
    flat = os.path.join(APPS_DIR, filename)
    if os.path.isfile(flat):
        return flat
    for group in APP_GROUPS:
        grouped = os.path.join(APPS_DIR, group, filename)
        if os.path.isfile(grouped):
            return grouped
    return None


lock = threading.Lock()
next_id = 1
results_by_id = {}   # command id (str) -> {"result": ..., "ts": float, "fetched": bool}, kept
                      # around so slow pollers (e.g. readfile) don't miss a
                      # result that only appeared in a single fleetbridge.lua
                      # report cycle. Pruned by _prune_results() so a long-
                      # running bridge doesn't grow this forever.

# node id -> { "pending": [...], "inflight": {cmd_id_str: {"cmd":..., "ts":...}},
#              "latest_report": {...}, "latest_report_time": float }
# Nodes register themselves just by polling once - no separate "join" step.
# "pending"/"inflight" are persisted (see _save_state) so a bridge restart
# doesn't silently drop queued/in-flight commands; latest_report is runtime-only
# and gets refreshed the moment the node polls/reports again.
nodes = {}

# Recent "*" (broadcast) commands, so a node that registers itself AFTER the
# broadcast was sent still receives it - previously target=="*" only queued to
# nodes already known at that instant. Entries: {"id":, "ts":, "cmd":}. Pruned
# by age in _prune_results(). Seeded into a node's "pending" once, at the
# moment that node is first seen (see get_node()).
broadcast_log = []

# source IP -> list of request timestamps within the current window, used by
# _check_rate_limit(). Not meant to survive a restart or scale past one
# process - this is a hobby-project throttle against accidental/malicious
# request floods, not a production rate limiter.
request_times_by_ip = {}

STATE_PATH = os.path.join(SCRIPT_DIR, "bridge_state.json")

# node id -> folder name (dashboard's "system of folders" for organizing a
# fleet). Purely a dashboard-side label - fleetbridge.lua/the node itself
# never needs to know what folder it's filed under, so this lives ONLY here,
# persisted to disk (unlike `nodes` above, which is rebuilt from scratch
# every time a node re-polls after a bridge restart).
NODE_META_PATH = os.path.join(SCRIPT_DIR, "node_meta.json")
node_folders = {}


# bump this + add a migration branch in _load_node_folders below if this file's shape ever changes
NODE_META_VERSION = 1


def _load_node_folders():
    global node_folders
    try:
        with open(NODE_META_PATH, "r", encoding="utf-8") as f:
            raw = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        node_folders = {}
        return
    # node_meta.json had no schema version at all before this - a future
    # shape change would have no way to tell "old unversioned file" apart
    # from "new file missing a field by mistake". A file with no "version"
    # key is the original shape (a flat {node_id: folder_name} dict) -
    # treated as version 1 with no transformation needed. When this shape
    # actually changes, add `if raw.get("version") == 1: raw = {migrate...}`
    # here rather than breaking older files outright.
    if isinstance(raw, dict) and "version" in raw:
        node_folders = raw.get("data", {})
    else:
        node_folders = raw if isinstance(raw, dict) else {}


def _save_node_folders():
    # Called with `lock` already held. Best-effort - a failed write here
    # shouldn't take down the request that triggered it.
    try:
        with open(NODE_META_PATH, "w", encoding="utf-8") as f:
            json.dump({"version": NODE_META_VERSION, "data": node_folders}, f)
    except OSError as e:
        logger.error(f"[bridge] failed to save {NODE_META_PATH}: {e}")


_load_node_folders()


def get_node(node_id):
    node = nodes.get(node_id)
    if node is None:
        node = {"pending": [], "inflight": {}, "latest_report": None, "latest_report_time": None}
        # Seed with any still-fresh "*" broadcasts sent before this node ever
        # registered - otherwise a command sent to "*" before a node's first
        # /poll would simply never reach it (the historical bug).
        now = time.time()
        for entry in broadcast_log:
            if now - entry["ts"] <= BROADCAST_LOG_TTL_SECONDS:
                node["pending"].append(entry["cmd"])
        nodes[node_id] = node
    return node


def _sweep_inflight():
    # Called with `lock` already held. A command /poll handed to a node is
    # moved to that node's "inflight" map, stamped with the time it was handed
    # out. If the matching /report result never arrives (node crashed, lost
    # network, or was killed mid-command) within INFLIGHT_REQUEUE_SECONDS,
    # put it back in "pending" so the next poll gets another shot at it -
    # previously a command vanished for good the instant /poll returned it,
    # regardless of whether it was ever actually executed.
    now = time.time()
    for node in nodes.values():
        inflight = node.get("inflight")
        if not inflight:
            continue
        stale = [cid for cid, entry in inflight.items() if now - entry["ts"] > INFLIGHT_REQUEUE_SECONDS]
        for cid in stale:
            node["pending"].append(inflight.pop(cid)["cmd"])


def _prune_results():
    # Called with `lock` already held. Drops anything past its TTL, then -
    # if still over the hard cap (e.g. a burst of commands all at once) -
    # drops the oldest entries until back under it. A result nobody has
    # fetched yet (dashboard was closed, admin stepped away) gets a much
    # longer grace period than one that's already been seen.
    now = time.time()
    expired = [
        cid for cid, entry in results_by_id.items()
        if now - entry["ts"] > (RESULT_TTL_SECONDS if entry.get("fetched") else UNFETCHED_RESULT_TTL_SECONDS)
    ]
    for cid in expired:
        del results_by_id[cid]
    if len(results_by_id) > MAX_RESULTS_STORED:
        oldest_first = sorted(results_by_id.items(), key=lambda kv: kv[1]["ts"])
        for cid, _ in oldest_first[: len(results_by_id) - MAX_RESULTS_STORED]:
            del results_by_id[cid]
    # Keeps only non-expired entries directly, rather than relying on
    # broadcast_log being sorted ascending by ts (true under normal
    # append-only operation, but NOT guaranteed after /admin/import
    # wholesale-replaces this list with an imported bundle's own ordering)
    # - the previous `del broadcast_log[:N]` form deleted N items from the
    # front regardless of whether those were actually the stale ones.
    broadcast_log[:] = [e for e in broadcast_log if now - e["ts"] <= BROADCAST_LOG_TTL_SECONDS]
    _sweep_inflight()


STATE_VERSION = 1  # bump this + add a migration branch in _load_state below if this file's shape ever changes


def _save_state():
    # Called with `lock` already held. Best-effort, like _save_node_folders -
    # persists exactly what a restart would otherwise lose: queued/in-flight
    # commands per node, command results, and the broadcast log. Runtime-
    # only fields (latest_report, latest_report_time) are NOT persisted - a
    # node refreshes those itself within one poll/report cycle after restart.
    try:
        snapshot = {
            "version": STATE_VERSION,
            "next_id": next_id,
            "results_by_id": results_by_id,
            "broadcast_log": broadcast_log,
            "nodes": {
                node_id: {"pending": node["pending"], "inflight": node["inflight"]}
                for node_id, node in nodes.items()
            },
        }
        tmp_path = STATE_PATH + ".tmp"
        with open(tmp_path, "w", encoding="utf-8") as f:
            json.dump(snapshot, f)
        os.replace(tmp_path, STATE_PATH)
    except OSError as e:
        logger.error(f"[bridge] failed to save {STATE_PATH}: {e}")


def _load_state():
    global next_id, results_by_id, broadcast_log
    try:
        with open(STATE_PATH, "r", encoding="utf-8") as f:
            snapshot = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return
    # version 1 is the only shape that has ever existed - a file with no
    # "version" key (or an unrecognized one) is loaded best-effort via the
    # same .get()-with-defaults below rather than refused outright, but logs
    # a warning so a real future incompatibility doesn't fail silently.
    version = snapshot.get("version")
    if version not in (None, STATE_VERSION):
        logger.warning(f"[bridge] {STATE_PATH} has unrecognized version {version!r} - loading best-effort")
    next_id = snapshot.get("next_id", next_id)
    results_by_id = snapshot.get("results_by_id", {})
    broadcast_log = snapshot.get("broadcast_log", [])
    for node_id, saved in snapshot.get("nodes", {}).items():
        nodes[node_id] = {
            "pending": saved.get("pending", []),
            "inflight": saved.get("inflight", {}),
            "latest_report": None,
            "latest_report_time": None,
        }
    logger.info(f"[bridge] restored state from {STATE_PATH}: "
                f"{len(nodes)} node(s), {len(results_by_id)} result(s)")


_load_state()

# centralized log collection. Previously every node's output only ever
# lived in its own in-memory buffer (fleetos.getOutput(), capped and only
# viewable one node at a time through the dashboard's Terminal panel) - once
# a node rebooted or the bridge restarted, it was gone, and diagnosing
# something across several nodes meant switching the dashboard's Terminal
# between them one at a time. Every /report's `output` (each node's last ~150
# lines) is appended here to windows/logs/<node>.log, deduplicated against
# the last line already written so re-sending the same rolling buffer every
# report doesn't multiply it - a real terminal log an admin can grep/tail
# across the whole fleet, that survives node reboots and bridge restarts.
NODE_LOGS_DIR = os.path.join(SCRIPT_DIR, "logs")
_node_loggers = {}
_node_last_logged_line = {}
# Separate from the main `lock` (which guards fleet state like `nodes`) so
# this doesn't hold up unrelated request handling during file I/O. Needed
# because ThreadingHTTPServer runs every request on its own thread, and two
# concurrent /report calls for the SAME node (e.g. a retried CC:Tweaked
# http.post) could otherwise both see no logger yet and each construct their
# own RotatingFileHandler pointed at the same file, or both compute
# overlapping "new" lines from a stale read of _node_last_logged_line and
# double-log/desync the dedup this function's docstring promises.
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


def _log_node_output(node_id, output_lines):
    if not output_lines:
        return
    with _node_log_lock:
        last_seen = _node_last_logged_line.get(node_id)
        start = 0
        if last_seen is not None:
            try:
                # search from the end - the line we're looking for is usually
                # near the tail, and an identical earlier duplicate line
                # shouldn't make us re-log everything after ITS first occurrence
                start = len(output_lines) - 1 - output_lines[::-1].index(last_seen) + 1
            except ValueError:
                start = 0  # our last position rolled off the buffer entirely - best effort, log what's left
        new_lines = output_lines[start:]
        if new_lines:
            node_logger = _get_node_logger(node_id)
            for line in new_lines:
                node_logger.info(line)
        _node_last_logged_line[node_id] = output_lines[-1]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        logger.info("[bridge] " + (fmt % args))

    def _cors_headers(self):
        # Lets the dashboard be hosted elsewhere (e.g. GitHub Pages) while
        # still talking to this bridge on your own PC. No credentials are
        # used, so a wildcard origin doesn't widen who can reach this
        # server - that's still governed entirely by what host/port this
        # process binds to (see FLEET_BRIDGE_HOST in main()) and whether
        # FLEET_BRIDGE_KEY is set. The CSRF_HEADER requirement on
        # state-changing routes (see _check_csrf) is what actually stops a
        # random cross-origin page from firing commands - CORS here only
        # controls whether cross-origin JS can READ the response.
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
        # (see CSRF_HEADER above). A browser can only have set this header if
        # dashboard.html's own JS built the request - a cross-site page can't
        # add it without a CORS preflight, and our preflight doesn't check
        # Origin, so it can't blindly probe its way past this. Doesn't
        # protect against a non-browser client (curl, fleetctl.py) - those
        # were never the threat model here, they already require you to
        # have chosen to run them.
        if self.headers.get(CSRF_HEADER):
            return True
        self._send_json({"error": "missing " + CSRF_HEADER + " header"}, status=403)
        return False

    def _check_rate_limit(self):
        ip = self.client_address[0]
        now = time.time()
        with lock:
            times = [t for t in request_times_by_ip.get(ip, []) if now - t < RATE_LIMIT_WINDOW_SECONDS]
            times.append(now)
            request_times_by_ip[ip] = times
            count = len(times)
        if count > RATE_LIMIT_MAX_REQUESTS:
            _metric_inc("rate_limited_total")
            self._send_json({"error": "rate limit exceeded, slow down"}, status=429)
            return False
        return True

    def _send_json(self, obj, status=200):
        if status >= 400:
            _metric_inc("http_errors_total")
        body = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
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

    def _serve_cacheable_file(self, path, not_found_label):
        # Shared by every plain "read this Lua source file off disk and
        # send it, ETag-cacheable" GET route (fleetos.lua, install.lua,
        # triangulation.lua) - previously each was its own copy-pasted
        # try/except FileNotFoundError block.
        try:
            with open(path, "r", encoding="utf-8") as f:
                self._send_text_cacheable(f.read())
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
        # `install <bridge-url> <api-key>`), and /health (a healthcheck
        # probe that had to know an API key first wouldn't be usable by most
        # monitoring/orchestration tooling, and it reveals nothing sensitive -
        # just a node count and an uptime number).
        if self.path not in ("/", "/dashboard", "/install.lua", "/health") \
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
            with lock:
                node = get_node(node_id)
                commands, node["pending"][:] = node["pending"][:], []
                now = time.time()
                for cmd in commands:
                    node["inflight"][str(cmd["id"])] = {"cmd": cmd, "ts": now}
                _save_state()
            _metric_inc("polls_served_total")
            self._send_json(commands)

        elif self.path == "/health":
            # previously the only way to guess at bridge health was to
            # poll /status and eyeball whether nodes look recent - a proper
            # healthcheck endpoint is what orchestration/monitoring tooling
            # (or just a cron job) actually needs. No auth required, same as
            # "/"/"/dashboard" - a healthcheck probe that had to know an API
            # key first wouldn't be usable by most external tooling.
            with lock:
                now = time.time()
                recent = sum(
                    1 for node in nodes.values()
                    if node["latest_report_time"] and (now - node["latest_report_time"]) < HEALTH_RECENT_SECONDS
                )
                nodes_known = len(nodes)
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
            with lock:
                now = time.time()
                snapshot = dict(metrics)
            self._send_json({
                "uptime_seconds": round(now - START_TIME, 1),
                "nodes_known": len(nodes),
                "results_stored": len(results_by_id),
                **snapshot,
            })

        elif self.path == "/status":
            with lock:
                now = time.time()
                result = {}
                for node_id, node in nodes.items():
                    ts = node["latest_report_time"]
                    result[node_id] = {
                        "latest_report": node["latest_report"],
                        "seconds_since_report": (now - ts) if ts else None,
                        "folder": node_folders.get(node_id, ""),
                    }
                self._send_json({"nodes": result})

        elif self.path.startswith("/result/"):
            cmd_id = self.path[len("/result/"):]
            with lock:
                entry = results_by_id.get(cmd_id)
                if entry is not None:
                    entry["fetched"] = True
            _metric_inc("results_fetched_total")
            self._send_json({"found": entry is not None, "result": entry["result"] if entry else None})

        elif self.path == "/admin/export":
            # full-fleet backup/restore - previously the only persisted
            # state was bridge_state.json/node_meta.json as opaque files an
            # admin would have to know to copy by hand. This bundles both
            # into one downloadable JSON blob; POST /admin/import (below)
            # restores it. Full key required (not read-only) - this includes
            # every node's folder assignment and pending/inflight commands.
            with lock:
                bundle = {
                    "version": STATE_VERSION,  # - same versioning as bridge_state.json/node_meta.json
                    "exported_at": time.time(),
                    "node_folders": node_folders,
                    "next_id": next_id,
                    "broadcast_log": broadcast_log,
                    "nodes": {
                        node_id: {"pending": node["pending"], "inflight": node["inflight"]}
                        for node_id, node in nodes.items()
                    },
                }
            self._send_json(bundle)

        else:
            self._send_json({"error": "not found"}, status=404)

    def do_POST(self):
        global next_id

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
            with lock:
                cmd["id"] = next_id
                next_id += 1
                if target == "*":
                    for node in nodes.values():
                        node["pending"].append(cmd)
                    queued_to = list(nodes.keys())
                    # Remembered so a node that registers itself LATER (hadn't
                    # polled yet when this broadcast went out) still gets it -
                    # see get_node()'s seeding logic.
                    broadcast_log.append({"id": cmd["id"], "ts": time.time(), "cmd": cmd})
                else:
                    get_node(target)["pending"].append(cmd)
                    queued_to = [target]
                _save_state()
            _metric_inc("commands_queued_total")
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
            with lock:
                if folder:
                    node_folders[node_id] = folder
                else:
                    node_folders.pop(node_id, None)
                _save_node_folders()
            self._send_json({"ok": True})

        elif self.path == "/report":
            node_id = (query.get("node") or [None])[0]
            if not node_id:
                self._send_json({"error": "report needs ?node=<id>"}, status=400)
                return
            body = self._read_json_body()
            if body is None:
                return
            output = body.get("output")
            if isinstance(output, list) and len(output) > MAX_OUTPUT_LINES_STORED:
                body["output"] = output[-MAX_OUTPUT_LINES_STORED:]
            with lock:
                node = get_node(node_id)
                node["latest_report"] = body
                node["latest_report_time"] = time.time()
                now = time.time()
                for item in body.get("results", []):
                    cmd = item.get("command", {})
                    cmd_id = cmd.get("id")
                    if cmd_id is not None:
                        results_by_id[str(cmd_id)] = {"result": item.get("result"), "ts": now, "fetched": False}
                        # The command finished executing - stop treating it as
                        # in-flight so _sweep_inflight() doesn't requeue it.
                        node["inflight"].pop(str(cmd_id), None)
                    # A successful "rename" acks under the OLD node_id (see
                    # fleetbridge.lua's rename handler) right before rebooting
                    # under the new one - without this, a folder assignment
                    # would silently orphan itself on the old, now-dead id.
                    result = item.get("result") or {}
                    if cmd.get("type") == "rename" and result.get("renamed") and cmd.get("newId"):
                        old_folder = node_folders.pop(node_id, None)
                        if old_folder:
                            node_folders[cmd["newId"]] = old_folder
                            _save_node_folders()
                _prune_results()
                _save_state()
            stored_output = body.get("output")
            if isinstance(stored_output, list):
                _log_node_output(node_id, stored_output)
            _metric_inc("reports_received_total")
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
                with lock:
                    cmd = {"id": next_id, "type": "world_call", "action": action, "args": body.get("args") or {}}
                    next_id += 1
                    get_node(node_id)["pending"].append(cmd)
                    cmd_id = cmd["id"]
                deadline = time.time() + WORLD_CALL_TIMEOUT_SECONDS
                while time.time() < deadline:
                    with lock:
                        entry = results_by_id.get(str(cmd_id))
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
            with lock:
                node_folders.clear()
                node_folders.update(body.get("node_folders") or {})
                broadcast_log[:] = body.get("broadcast_log") or []
                next_id = body.get("next_id", next_id)
                new_nodes = {}
                for node_id, saved in (body.get("nodes") or {}).items():
                    old = nodes.get(node_id)
                    new_nodes[node_id] = {
                        "pending": saved.get("pending", []),
                        "inflight": saved.get("inflight", {}),
                        "latest_report": old["latest_report"] if old else None,
                        "latest_report_time": old["latest_report_time"] if old else None,
                    }
                nodes.clear()
                nodes.update(new_nodes)
                _save_node_folders()
                _save_state()
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
            with lock:
                _save_state()
            self._send_json({"ok": True, "reloading": True})

            def _do_reload():
                time.sleep(0.3)  # give the response above a moment to flush
                logger.info("[bridge] /admin/reload: re-executing process now")
                os.execv(sys.executable, [sys.executable] + sys.argv)

            threading.Thread(target=_do_reload, daemon=True).start()

        else:
            self._send_json({"error": "not found"}, status=404)


class Server(ThreadingHTTPServer):
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

    logger.info(f"[bridge] listening on {scheme}://{host}:{port}")
    if API_KEY:
        logger.info("[bridge] FLEET_BRIDGE_KEY is set - requests need a matching X-API-Key header")
    if READONLY_API_KEY:
        logger.info("[bridge] FLEET_BRIDGE_READONLY_KEY is set - grants read-only access")
    if COMPUTE_ENABLED:
        logger.info("[bridge] FLEET_ENABLE_COMPUTE=1 - /compute/<name> scripts CAN be executed")
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
        with lock:
            _save_state()
        server.server_close()
        logger.info("[bridge] state saved, exiting")


if __name__ == "__main__":
    main()
