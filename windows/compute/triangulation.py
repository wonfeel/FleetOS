"""
triangulation.py - stdlib-only Python port of game/triangulation.lua's
Triangulator:solve() - same formulas (quaternion rotation, per-ray
projection matrix, 3x3 Cramer's-rule solve), so a node can offload this
math to the PC via bridge_server.py's POST /compute/triangulation instead
of doing it in Lua.

Contract: reads one JSON object from stdin -
    {"forward": {x,y,z}, "qsign": [sx,sy,sz],
     "rays": [{"origin": {x,y,z}, "quat": {x,y,z,w}}, ...]}
writes one JSON object to stdout -
    {"ok": true, "x":, "y":, "z":} or {"ok": false, "error": "..."}
"""

import json
import math
import sys


def rotate_by_quaternion(q, v):
    qx, qy, qz, qw = q["x"], q["y"], q["z"], q["w"]
    tx = 2 * (qy * v["z"] - qz * v["y"])
    ty = 2 * (qz * v["x"] - qx * v["z"])
    tz = 2 * (qx * v["y"] - qy * v["x"])
    cx = qy * tz - qz * ty
    cy = qz * tx - qx * tz
    cz = qx * ty - qy * tx
    return {
        "x": v["x"] + qw * tx + cx,
        "y": v["y"] + qw * ty + cy,
        "z": v["z"] + qw * tz + cz,
    }


def normalize(v):
    length = math.sqrt(v["x"] ** 2 + v["y"] ** 2 + v["z"] ** 2)
    if length < 1e-9:
        return {"x": 0.0, "y": 0.0, "z": 0.0}
    return {"x": v["x"] / length, "y": v["y"] / length, "z": v["z"] / length}


def det3(m):
    return (m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
            - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
            + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0]))


def solve3x3(a, b):
    d = det3(a)
    if abs(d) < 1e-9:
        return None

    def replace_col(col, vec):
        r = [row[:] for row in a]
        r[0][col] = vec[0]
        r[1][col] = vec[1]
        r[2][col] = vec[2]
        return r

    dx = det3(replace_col(0, b))
    dy = det3(replace_col(1, b))
    dz = det3(replace_col(2, b))
    return [dx / d, dy / d, dz / d]


def solve(forward, qsign, rays):
    if len(rays) < 2:
        return None, "need at least 2 rays"

    a = [[0.0, 0.0, 0.0], [0.0, 0.0, 0.0], [0.0, 0.0, 0.0]]
    b = [0.0, 0.0, 0.0]

    for ray in rays:
        quat = ray["quat"]
        sq = {"x": quat["x"] * qsign[0], "y": quat["y"] * qsign[1],
              "z": quat["z"] * qsign[2], "w": quat["w"]}
        d = normalize(rotate_by_quaternion(sq, forward))
        p = ray["origin"]

        m = [
            [1 - d["x"] * d["x"], -d["x"] * d["y"], -d["x"] * d["z"]],
            [-d["y"] * d["x"], 1 - d["y"] * d["y"], -d["y"] * d["z"]],
            [-d["z"] * d["x"], -d["z"] * d["y"], 1 - d["z"] * d["z"]],
        ]

        for i in range(3):
            for j in range(3):
                a[i][j] += m[i][j]

        px, py, pz = p["x"], p["y"], p["z"]
        b[0] += m[0][0] * px + m[0][1] * py + m[0][2] * pz
        b[1] += m[1][0] * px + m[1][1] * py + m[1][2] * pz
        b[2] += m[2][0] * px + m[2][1] * py + m[2][2] * pz

    result = solve3x3(a, b)
    if result is None:
        return None, "rays are parallel or the system is degenerate"

    return {"x": result[0], "y": result[1], "z": result[2]}, None


def main():
    body = json.load(sys.stdin)
    forward = body.get("forward") or {"x": 1, "y": 0, "z": 0}
    qsign = body.get("qsign") or [1, 1, 1]
    rays = body.get("rays") or []
    pos, err = solve(forward, qsign, rays)
    if pos is None:
        print(json.dumps({"ok": False, "error": err}))
    else:
        print(json.dumps({"ok": True, "x": pos["x"], "y": pos["y"], "z": pos["z"]}))


if __name__ == "__main__":
    main()
