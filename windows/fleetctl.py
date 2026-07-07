"""
fleetctl.py - control the Minecraft fleet from your real Windows PC,
through bridge_server.py (must already be running).

    python fleetctl.py ping
    python fleetctl.py status
    python fleetctl.py run <target|*> <app>
    python fleetctl.py kill <target|*> <app>
    python fleetctl.py deploy <target|*> <app> <raw-lua-url>
    python fleetctl.py rollback <target|*> <app>
    python fleetctl.py type <target|*> <text...>
    python fleetctl.py shell <target>

"type"/"shell" run a line as if typed at that node's own shell prompt
(fleetos.runShellLine, same as the dashboard's Terminal panel) - "shell"
is an interactive loop. Unlike apps/common/shell.lua's LOCAL prompt in the
Windows emulation (windows/craftos_shim.lua), this never blocks anything
running on the node itself (fleetbridge, monitor mirror, ...) - it's a
separate OS process talking over HTTP, not sharing that node's single
cooperative scheduler thread. Prefer this over the emulation's local
"shell" app whenever you also want fleetbridge to keep polling.

Set FLEET_BRIDGE_URL/FLEET_BRIDGE_KEY env vars if the bridge isn't on
127.0.0.1:8787 or was started with FLEET_BRIDGE_KEY set.
"""

import json
import os
import sys
import time
import urllib.error
import urllib.request

BASE_URL = os.environ.get("FLEET_BRIDGE_URL", "http://127.0.0.1:8787")
# only needed if bridge_server.py was started with FLEET_BRIDGE_KEY set
API_KEY = os.environ.get("FLEET_BRIDGE_KEY", "")

# bridge_server.py requires this on every state-changing route (/command,
# /apps) regardless of FLEET_BRIDGE_KEY - see its header comment. It's a
# CSRF guard against random web pages, not a secret; any non-browser
# client (like this script) just needs to send *something*.
CSRF_HEADER = "X-Fleet-Dashboard"


def _headers(extra=None):
    headers = dict(extra or {})
    headers[CSRF_HEADER] = "fleetctl.py"
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


def _output_tail(target):
    status = _get("/status")
    node = status.get("nodes", {}).get(target)
    if not node:
        return None
    report = node.get("latest_report") or {}
    return report.get("output") or []


def _send_type(target, text, last_len):
    # Fire-and-forget, same as dashboard.html's sendTerminalLine() - the
    # command only actually runs on the node's next poll cycle (~1s), so we
    # can't get a result back immediately. Instead poll /status a few times
    # and print whatever new lines show up in that node's output tail.
    _post("/command", {"type": "type", "target": target, "text": text})
    new_lines = []
    for _ in range(15):
        time.sleep(0.3)
        output = _output_tail(target)
        if output is not None and len(output) > last_len:
            new_lines = output[last_len:]
            last_len = len(output)
            break
    for line in new_lines:
        print(line)
    return last_len


def cmd_type(target, text):
    last_len = len(_output_tail(target) or [])
    _send_type(target, text, last_len)


def cmd_shell(target):
    print(f"fleetctl interactive shell -> '{target}' (Ctrl+C or 'exit' to quit)")
    print("Runs each line via that node's fleetos.runShellLine(), same as the dashboard's")
    print("Terminal panel - doesn't touch the node's own console, so nothing running there")
    print("(fleetbridge, monitor mirror, ...) is ever blocked while you type here.")
    last_len = len(_output_tail(target) or [])
    while True:
        try:
            line = input(f"{target}> ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            return
        if not line:
            continue
        if line in ("exit", "quit"):
            return
        try:
            last_len = _send_type(target, line, last_len)
        except urllib.error.HTTPError as e:
            print(f"Bridge rejected the request ({e.code}): {e.read().decode('utf-8', 'replace')}")
        except urllib.error.URLError as e:
            print(f"Can't reach bridge: {e}")


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
        elif action == "type":
            cmd_type(args[1], " ".join(args[2:]))
        elif action == "shell":
            cmd_shell(args[1])
        else:
            print(__doc__)
    except IndexError:
        print(__doc__)
    except urllib.error.HTTPError as e:
        print(f"Bridge rejected the request ({e.code}): {e.read().decode('utf-8', 'replace')}")
    except urllib.error.URLError as e:
        print(f"Can't reach bridge_server.py at {BASE_URL}: {e}")
        print("Is it running? python bridge_server.py")


if __name__ == "__main__":
    main()
