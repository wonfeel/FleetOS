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
read/write files on any of your in-game computers.

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
"""

import hmac
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, parse_qs

# Opt-in: unset/empty means no auth at all (the historical, still-default
# behavior for a plain 127.0.0.1 bridge). Set this before starting the
# server to require a matching X-API-Key header on every request.
API_KEY = os.environ.get("FLEET_BRIDGE_KEY", "")

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
GAME_DIR = os.path.join(SCRIPT_DIR, "..", "game")
APPS_DIR = os.path.join(GAME_DIR, "apps")
FLEETOS_PATH = os.path.join(GAME_DIR, "fleetos.lua")
INSTALL_PATH = os.path.join(GAME_DIR, "install.lua")
TRIANGULATION_PATH = os.path.join(GAME_DIR, "triangulation.lua")
DASHBOARD_PATH = os.path.join(SCRIPT_DIR, "dashboard.html")

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
results_by_id = {}   # command id -> its result, kept around so slow pollers
                      # (e.g. readfile) don't miss a result that only appeared
                      # in a single fleetbridge.lua report cycle

# node id -> { "pending": [...], "latest_report": {...}, "latest_report_time": float }
# Nodes register themselves just by polling once - no separate "join" step.
nodes = {}


def get_node(node_id):
    node = nodes.get(node_id)
    if node is None:
        node = {"pending": [], "latest_report": None, "latest_report_time": None}
        nodes[node_id] = node
    return node


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print("[bridge] " + (fmt % args))

    def _cors_headers(self):
        # Lets the dashboard be hosted elsewhere (e.g. GitHub Pages) while
        # still talking to this bridge on your own PC. No credentials are
        # used, so a wildcard origin doesn't widen who can reach this
        # server - that's still governed entirely by what host/port this
        # process binds to (see FLEET_BRIDGE_HOST in main()) and whether
        # FLEET_BRIDGE_KEY is set.
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, X-API-Key")

    def do_OPTIONS(self):
        # never gated on auth - a CORS preflight carries no sensitive data,
        # and browsers send it without custom headers of its own
        self.send_response(204)
        self._cors_headers()
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _check_auth(self):
        # no FLEET_BRIDGE_KEY set -> auth is off, same as before this
        # existed. compare_digest instead of == so a mistyped/guessed key
        # can't be narrowed down via response-time differences.
        if not API_KEY:
            return True
        provided = self.headers.get("X-API-Key", "")
        if provided and hmac.compare_digest(provided, API_KEY):
            return True
        self._send_json({"error": "unauthorized - missing/invalid X-API-Key"}, status=401)
        return False

    def _send_json(self, obj, status=200):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self._cors_headers()
        self.end_headers()
        self.wfile.write(body)

    def _read_json_body(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b"{}"
        try:
            return json.loads(raw.decode("utf-8"))
        except Exception:
            return {}

    def _send_text(self, text, content_type="text/plain; charset=utf-8", status=200):
        body = text.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self._cors_headers()
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urlsplit(self.path)
        self.path = parsed.path
        query = parse_qs(parsed.query)

        # exempt from auth: the dashboard shell itself (so a browser can
        # load the page and enter its API key in the first place) and
        # install.lua (fetched via CraftOS's built-in `wget`, which can't
        # send custom headers at all - everything install.lua fetches
        # AFTER that via its own http.get DOES carry the key, once you
        # pass one to `install <bridge-url> <api-key>`)
        if self.path not in ("/", "/dashboard", "/install.lua") and not self._check_auth():
            return

        if self.path == "/" or self.path == "/dashboard":
            try:
                with open(DASHBOARD_PATH, "r", encoding="utf-8") as f:
                    self._send_text(f.read(), content_type="text/html; charset=utf-8")
            except FileNotFoundError:
                self._send_text("dashboard.html not found next to bridge_server.py", status=500)

        elif self.path == "/fleetos.lua":
            try:
                with open(FLEETOS_PATH, "r", encoding="utf-8") as f:
                    self._send_text(f.read())
            except FileNotFoundError:
                self._send_text("fleetos.lua not found", status=404)

        elif self.path == "/install.lua":
            try:
                with open(INSTALL_PATH, "r", encoding="utf-8") as f:
                    self._send_text(f.read())
            except FileNotFoundError:
                self._send_text("install.lua not found", status=404)

        elif self.path == "/triangulation.lua":
            # apps/raytower/raytower_master.lua dofile()s this as a
            # top-level file (not one of apps/*) - served separately so
            # the dashboard can push it alongside a raytower_master deploy.
            try:
                with open(TRIANGULATION_PATH, "r", encoding="utf-8") as f:
                    self._send_text(f.read())
            except FileNotFoundError:
                self._send_text("triangulation.lua not found", status=404)

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
                self._send_text(f.read())

        elif self.path == "/poll":
            node_id = (query.get("node") or [None])[0]
            if not node_id:
                self._send_json({"error": "poll needs ?node=<id>"}, status=400)
                return
            with lock:
                node = get_node(node_id)
                commands, node["pending"][:] = node["pending"][:], []
            self._send_json(commands)

        elif self.path == "/status":
            with lock:
                now = time.time()
                result = {}
                for node_id, node in nodes.items():
                    ts = node["latest_report_time"]
                    result[node_id] = {
                        "latest_report": node["latest_report"],
                        "seconds_since_report": (now - ts) if ts else None,
                    }
                self._send_json({"nodes": result})

        elif self.path.startswith("/result/"):
            cmd_id = self.path[len("/result/"):]
            with lock:
                found = cmd_id in results_by_id
                result = results_by_id.get(cmd_id)
            self._send_json({"found": found, "result": result})

        else:
            self._send_json({"error": "not found"}, status=404)

    def do_POST(self):
        global next_id

        if not self._check_auth():
            return

        parsed = urlsplit(self.path)
        self.path = parsed.path
        query = parse_qs(parsed.query)

        if self.path == "/command":
            cmd = self._read_json_body()
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
                else:
                    get_node(target)["pending"].append(cmd)
                    queued_to = [target]
            self._send_json({"queued": True, "id": cmd["id"], "nodes": queued_to})

        elif self.path == "/report":
            node_id = (query.get("node") or [None])[0]
            if not node_id:
                self._send_json({"error": "report needs ?node=<id>"}, status=400)
                return
            body = self._read_json_body()
            with lock:
                node = get_node(node_id)
                node["latest_report"] = body
                node["latest_report_time"] = time.time()
                for item in body.get("results", []):
                    cmd_id = item.get("command", {}).get("id")
                    if cmd_id is not None:
                        results_by_id[str(cmd_id)] = item.get("result")
            self._send_json({"ok": True})

        elif self.path == "/apps":
            # creates a brand new app on THIS PC. Deliberately separate from
            # the /apps/<name>.lua editor route below - refuses to clobber
            # an existing app so a typo'd "create" can't silently wipe one.
            body = self._read_json_body()
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
            with open(path, "w", encoding="utf-8") as f:
                f.write(body.get("content") or "")
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
            content = body.get("content", "")
            # save back wherever it already lives (its group folder), so
            # editing doesn't move an app out of common/master/tower into
            # the flat apps/ folder. New apps (not found anywhere) default
            # to flat.
            path = resolve_app_path(name) or os.path.join(APPS_DIR, name)
            with open(path, "w", encoding="utf-8") as f:
                f.write(content)
            self._send_json({"ok": True})

        else:
            self._send_json({"error": "not found"}, status=404)


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8787
    host = os.environ.get("FLEET_BRIDGE_HOST", "127.0.0.1")
    server = ThreadingHTTPServer((host, port), Handler)
    print(f"[bridge] listening on http://{host}:{port}")
    if API_KEY:
        print("[bridge] FLEET_BRIDGE_KEY is set - requests need a matching X-API-Key header")
    elif host != "127.0.0.1":
        print("[bridge] WARNING: bound beyond localhost with no authentication -")
        print("[bridge] anyone who can reach this can run code on your game computer.")
        print("[bridge] set FLEET_BRIDGE_KEY before starting this server to require an API key")
    print("[bridge] make sure apps/fleetbridge.lua's BASE_URL matches this address")
    print("[bridge] and that computercraft-server.toml allows http to it (see windows/README.md)")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[bridge] stopping")


if __name__ == "__main__":
    main()
