"""
world_demo.py - minimal example of a "world access" compute script (see
_fleetos_world.py).
Only does anything interesting if the calling Lua app passed ?node=<id> to
POST /compute/world_demo - without that, world.* calls raise WorldError,
which this catches and reports back as {"ok": false, "error": ...} so it's
still safe to test-run from the dashboard's "Compute scripts" section (no
node context there either).

Prints a greeting on the node's own terminal/monitor, then reports its GPS
position and attached peripherals - reads one JSON object from stdin
(ignored - this demo takes no input), prints one JSON object to stdout.
"""

import json
import sys

from _fleetos_world import world, WorldError


def main():
    json.load(sys.stdin)  # ignored - keeps the stdin-in/stdout-out contract
    try:
        world.print("hello from world_demo.py (running on your PC)")
        pos = None
        try:
            pos = world.gps_locate()
        except WorldError as e:
            pos = {"error": str(e)}
        peripherals = world.list_peripherals()
        print(json.dumps({"ok": True, "pos": pos, "peripherals": peripherals}))
    except WorldError as e:
        print(json.dumps({"ok": False, "error": str(e)}))


if __name__ == "__main__":
    main()
