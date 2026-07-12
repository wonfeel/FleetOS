"""
world_demo.py - minimal example of a "world access" compute script (see
_fleetos_world.py). No ?node=<id> on the request -> world.* raises
WorldError, caught and reported as {"ok": false, ...} - still safe to
test-run from the dashboard with no real node behind it.
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
