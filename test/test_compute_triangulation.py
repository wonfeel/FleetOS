"""
test_compute_triangulation.py - cross-validates windows/compute/triangulation.py
against the exact same fake-tower/target vectors as test/test_triangulation.lua,
so the Python port is proven numerically faithful to the Lua original, not just
"runs without crashing". Also round-trips through the actual subprocess/stdin/
stdout contract bridge_server.py's /compute/<name> route uses, so a change to
one side (e.g. the JSON shape) can't silently break the other.

Run with:
    py test/test_compute_triangulation.py
(no pytest / pip install needed - stdlib only, matches triangulation.py itself)
"""

import json
import math
import os
import random
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "windows", "compute"))
import triangulation  # noqa: E402


TRIANGULATION_PY = os.path.join(os.path.dirname(__file__), "..", "windows", "compute", "triangulation.py")


def normalize(v):
    length = math.sqrt(v["x"] ** 2 + v["y"] ** 2 + v["z"] ** 2)
    return {"x": v["x"] / length, "y": v["y"] / length, "z": v["z"] / length}


def dist(a, b):
    return math.sqrt((a["x"] - b["x"]) ** 2 + (a["y"] - b["y"]) ** 2 + (a["z"] - b["z"]) ** 2)


def shortest_arc_quat(frm, to):
    # Same construction as test_triangulation.lua's shortestArcQuat: builds
    # the quaternion that rotates `frm` onto `to` (both unit vectors).
    dot = frm["x"] * to["x"] + frm["y"] * to["y"] + frm["z"] * to["z"]
    if dot < -0.999999:
        return {"x": 0.0, "y": 1.0, "z": 0.0, "w": 0.0}
    cx = frm["y"] * to["z"] - frm["z"] * to["y"]
    cy = frm["z"] * to["x"] - frm["x"] * to["z"]
    cz = frm["x"] * to["y"] - frm["y"] * to["x"]
    w = 1 + dot
    length = math.sqrt(cx * cx + cy * cy + cz * cz + w * w)
    return {"x": cx / length, "y": cy / length, "z": cz / length, "w": w / length}


FORWARD = {"x": 1, "y": 0, "z": 0}
TARGET = {"x": 1859.65, "y": 17.98, "z": 1591.59}
FAKE_TOWERS = [
    {"id": "tower_A", "origin": {"x": 1856.64, "y": 16.45, "z": 1583.01}},
    {"id": "tower_B", "origin": {"x": 1871.02, "y": 13.88, "z": 1604.25}},
    {"id": "tower_C", "origin": {"x": 1840.10, "y": 25.00, "z": 1590.00}},
]


def rays_aimed_at(target, qsign=(1, 1, 1)):
    rays = []
    for tower in FAKE_TOWERS:
        origin = tower["origin"]
        direction = normalize({
            "x": target["x"] - origin["x"],
            "y": target["y"] - origin["y"],
            "z": target["z"] - origin["z"],
        })
        quat = shortest_arc_quat(FORWARD, direction)
        rays.append({"origin": origin, "quat": quat})
    return rays


# ============================================================
# Test 1: 3 perfectly-aimed fake towers, no noise -> exact solve
# (same vectors as test_triangulation.lua's Test 1)
# ============================================================

pos, err = triangulation.solve(FORWARD, [1, 1, 1], rays_aimed_at(TARGET))
assert pos is not None, "solve() returned None: " + str(err)
d = dist(pos, TARGET)
print("Test 1 (no noise): solved=(%.4f,%.4f,%.4f) target=(%.2f,%.2f,%.2f) error=%.6f blocks"
      % (pos["x"], pos["y"], pos["z"], TARGET["x"], TARGET["y"], TARGET["z"], d))
assert d < 0.001, "expected near-zero error with perfect rays, got %s" % d
print("Test 1: PASS")

# ============================================================
# Test 2: same towers but with a wrong qsign -> should NOT converge
# (same as test_triangulation.lua's Test 2 - flips qy, matching the Lua
# comment explaining why qx is a geometric no-op for forward=(1,0,0))
# ============================================================

pos_wrong, _ = triangulation.solve(FORWARD, [1, -1, 1], rays_aimed_at(TARGET))
d_wrong = dist(pos_wrong, TARGET)
print("Test 2 (wrong qsign): error=%.2f blocks" % d_wrong)
assert d_wrong > 5, "expected wrong qsign to miss badly, got error %s" % d_wrong
print("Test 2: PASS (wrong calibration correctly misses)")

# ============================================================
# Test 3: noisy quaternions (simulate sensor jitter) -> small but nonzero error
# Uses Python's own RNG (not the same stream as Lua's math.random, but the
# same qualitative property: small jitter -> small, bounded error).
# ============================================================

random.seed(42)


def jitter_quat(q, amount):
    jittered = {k: q[k] + (random.random() - 0.5) * amount for k in ("x", "y", "z", "w")}
    length = math.sqrt(sum(v * v for v in jittered.values()))
    return {k: v / length for k, v in jittered.items()}


noisy_rays = []
for ray in rays_aimed_at(TARGET):
    noisy_rays.append({"origin": ray["origin"], "quat": jitter_quat(ray["quat"], 0.01)})

pos_noisy, _ = triangulation.solve(FORWARD, [1, 1, 1], noisy_rays)
d_noisy = dist(pos_noisy, TARGET)
print("Test 3 (jittered quats): error=%.4f blocks" % d_noisy)
assert d_noisy < 3, "noisy solve strayed too far: %s" % d_noisy
print("Test 3: PASS")

# ============================================================
# Test 4: same "no noise" vectors through the ACTUAL subprocess/stdin/stdout
# contract bridge_server.py's /compute/triangulation route uses - proves the
# CLI wrapper (main(), JSON in/out) matches solve() itself, not just that
# the math function alone is correct.
# ============================================================

request = {"forward": FORWARD, "qsign": [1, 1, 1], "rays": rays_aimed_at(TARGET)}
proc = subprocess.run([sys.executable, TRIANGULATION_PY],
                       input=json.dumps(request).encode("utf-8"),
                       capture_output=True, timeout=10)
assert proc.returncode == 0, "triangulation.py exited %d: %s" % (proc.returncode, proc.stderr.decode())
response = json.loads(proc.stdout.decode("utf-8"))
assert response["ok"], "expected ok=true, got %s" % response
d_subprocess = dist(response, TARGET)
print("Test 4 (subprocess round-trip): error=%.6f blocks" % d_subprocess)
assert d_subprocess < 0.001, "subprocess round-trip diverged from direct solve(): %s" % d_subprocess
print("Test 4: PASS")

# ============================================================
# Test 5: fewer than 2 rays -> a clean {"ok": false, "error": ...}, matching
# Lua's Triangulator:solve() returning (nil, "need at least 2 rays")
# ============================================================

pos_none, err_none = triangulation.solve(FORWARD, [1, 1, 1], rays_aimed_at(TARGET)[:1])
assert pos_none is None and err_none == "need at least 2 rays", "expected the 'need at least 2 rays' error"
print("Test 5: PASS (fewer than 2 rays reports the same error as the Lua original)")

print("\nAll compute-triangulation tests passed.")
