"""
_fleetos_world.py - lets a windows/compute/<name>.py script act like a real
Lua program running on a FleetOS computer, instead of a pure stdin-in/
stdout-out function: `world.print(...)` shows up in that computer's real
terminal AND any attached monitor (fleetos.lua mirrors both from the same
output buffer - see its "Output capture" section), and `world.gps_locate()`/
`world.peripheral_call()` read real in-game state, the same APIs
apps/common/fleetbridge.lua and apps/raytower/*.lua already use.

Only works if the calling Lua app invoked this script with ?node=<id> on
POST /compute/<name> (see bridge_server.py's docstring) - that's what sets
the FLEETOS_NODE/FLEETOS_BRIDGE_URL env vars read below. Without it, every
call here raises WorldError immediately instead of hanging.

Each call is one HTTP round trip to the bridge's POST /world_call, which
queues a "world_call" command for that node exactly like any dashboard
command and blocks until the node's OWN fleetbridge.lua poll loop (running
independently, ~1s cadence) picks it up, executes the real Lua, and reports
back - so this can take up to a few seconds per call. See
apps/common/fleetbridge.lua's "world_call" command handler for the actual
Lua execution.

Usage from a compute script:
    from _fleetos_world import world
    world.print("hello from Python")
    pos = world.gps_locate()
    names = world.list_peripherals()

The leading underscore keeps this out of GET /compute_scripts' listing (see
bridge_server.py's list_compute_script_names()) - it's a shared helper to
import, not a script you'd "Run" on its own.
"""

import json
import os
import urllib.error
import urllib.request


class WorldError(Exception):
    pass


class World:
    def __init__(self):
        self.node = os.environ.get("FLEETOS_NODE")
        self.bridge_url = os.environ.get("FLEETOS_BRIDGE_URL", "http://127.0.0.1:8787")

    def _call(self, action, args=None):
        if not self.node:
            raise WorldError(
                "no node context for this compute script - the calling Lua app must "
                "POST /compute/<name>?node=<id> to use world.* (see fleetos_world.py)")
        body = json.dumps({"node": self.node, "action": action, "args": args or {}}).encode("utf-8")
        req = urllib.request.Request(
            self.bridge_url + "/world_call", data=body,
            headers={"Content-Type": "application/json"}, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                result = json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            try:
                result = json.loads(e.read().decode("utf-8"))
            except (ValueError, UnicodeDecodeError):
                raise WorldError("world_call '" + action + "' failed: HTTP " + str(e.code))
        except (urllib.error.URLError, OSError) as e:
            raise WorldError("world_call '" + action + "' failed: " + str(e))
        if result.get("error"):
            raise WorldError(result["error"])
        return result.get("value")

    def print(self, text):
        """Prints on the node's real terminal/monitor, same as an in-game print()."""
        return self._call("print", {"text": str(text)})

    def gps_locate(self, timeout=2):
        """Returns {"x":, "y":, "z":} via the node's gps.locate(), or raises if no GPS host answers."""
        return self._call("gps_locate", {"timeout": timeout})

    def peripheral_call(self, name, method, *params):
        """Calls peripheral.call(name, method, ...params) on the node and returns its result."""
        return self._call("peripheral_call", {"name": name, "method": method, "params": list(params)})

    def list_peripherals(self):
        """Returns the node's peripheral.getNames() - what hardware is actually attached."""
        return self._call("list_peripherals", {})


world = World()
