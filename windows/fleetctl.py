"""
fleetctl.py - control the Minecraft fleet from your real Windows PC,
through bridge_server.py (must already be running).

    python fleetctl.py ping
    python fleetctl.py status
    python fleetctl.py run <target|*> <app>
    python fleetctl.py kill <target|*> <app>
    python fleetctl.py deploy <target|*> <app> <raw-lua-url>
    python fleetctl.py rollback <target|*> <app>

Set FLEET_BRIDGE_URL/FLEET_BRIDGE_KEY env vars if the bridge isn't on
127.0.0.1:8787 or was started with FLEET_BRIDGE_KEY set.
"""

import json
import os
import sys
import urllib.error
import urllib.request

BASE_URL = os.environ.get("FLEET_BRIDGE_URL", "http://127.0.0.1:8787")
# only needed if bridge_server.py was started with FLEET_BRIDGE_KEY set
API_KEY = os.environ.get("FLEET_BRIDGE_KEY", "")


def _headers(extra=None):
    headers = dict(extra or {})
    if API_KEY:
        headers["X-API-Key"] = API_KEY
    return headers


def _get(path):
    req = urllib.request.Request(BASE_URL + path, headers=_headers())
    with urllib.request.urlopen(req, timeout=5) as r:
        return json.loads(r.read().decode("utf-8"))


def _post(path, obj):
    data = json.dumps(obj).encode("utf-8")
    req = urllib.request.Request(
        BASE_URL + path, data=data, headers=_headers({"Content-Type": "application/json"}),
    )
    with urllib.request.urlopen(req, timeout=5) as r:
        return json.loads(r.read().decode("utf-8"))


def cmd_ping():
    status = _get("/status")
    nodes = status.get("nodes", {})
    if not nodes:
        print("No computer has reported yet - is fleetbridge.lua running and polling this bridge?")
        return
    for node_id, n in nodes.items():
        age = n.get("seconds_since_report")
        state = f"{age:.1f}s ago" if age is not None else "never"
        stale = " (stale)" if age is not None and age > 10 else ""
        print(f"{node_id:<16} last report {state}{stale}")


def cmd_status():
    status = _get("/status")
    nodes = status.get("nodes", {})
    if not nodes:
        print("No computer has reported yet.")
        return

    for node_id, n in nodes.items():
        report = n.get("latest_report") or {}
        age = n.get("seconds_since_report")
        age_str = f"{age:.1f}s ago" if age is not None else "never"
        print(f"{node_id} (role={report.get('role', '?')}, last report {age_str}):")
        for entry in report.get("apps", []):
            print("  " + entry)

        results = report.get("results", [])
        if results:
            print("  last command results:")
            for r in results:
                cmd = r.get("command", {})
                print(f"    {cmd.get('type')} {cmd.get('app')} -> {r.get('result')}")
        print()


def cmd_run(target, app):
    print(_post("/command", {"type": "run", "target": target, "app": app}))


def cmd_kill(target, app):
    print(_post("/command", {"type": "kill", "target": target, "app": app}))


def cmd_deploy(target, app, url):
    print(_post("/command", {"type": "deploy", "target": target, "app": app, "url": url}))


def cmd_rollback(target, app):
    print(_post("/command", {"type": "rollback", "target": target, "app": app}))


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return

    action = args[0]
    try:
        if action == "ping":
            cmd_ping()
        elif action == "status":
            cmd_status()
        elif action == "run":
            cmd_run(args[1], args[2])
        elif action == "kill":
            cmd_kill(args[1], args[2])
        elif action == "deploy":
            cmd_deploy(args[1], args[2], args[3])
        elif action == "rollback":
            cmd_rollback(args[1], args[2])
        else:
            print(__doc__)
    except IndexError:
        print(__doc__)
    except urllib.error.URLError as e:
        print(f"Can't reach bridge_server.py at {BASE_URL}: {e}")
        print("Is it running? python bridge_server.py")


if __name__ == "__main__":
    main()
