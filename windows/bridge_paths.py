"""
bridge_paths.py - path resolution, containment, and name-validation helpers
for bridge_server.py, split out because they're genuinely self-contained:
every function here takes explicit arguments and returns a value, none of
them touch bridge_server.py's mutable fleet state (nodes/lock/next_id/etc),
so moving them costs nothing in behavior and meaningfully shrinks the part
of bridge_server.py that actually needs to be read to understand request
handling. Pulled out of bridge_server.py's original single file rather than
rewritten - see that file's own history for the original comments/context
if anything here looks unexplained.

Stdlib only (see bridge_server.py's own module docstring) - nothing to pip
install here either.
"""
import os
import re

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
GAME_DIR = os.path.join(SCRIPT_DIR, "..", "game")
APPS_DIR = os.path.join(GAME_DIR, "apps")
FLEETOS_PATH = os.path.join(GAME_DIR, "fleetos.lua")
INSTALL_PATH = os.path.join(GAME_DIR, "install.lua")
TRIANGULATION_PATH = os.path.join(GAME_DIR, "triangulation.lua")
DASHBOARD_PATH = os.path.join(SCRIPT_DIR, "dashboard.html")
DOCS_DIR = os.path.join(SCRIPT_DIR, "..", "docs")
SIM_DIR = os.path.join(SCRIPT_DIR, "sim")
RUN_SIM_NODE_PATH = os.path.join(SCRIPT_DIR, "run_sim_node.lua")
COMPUTE_DIR = os.path.join(SCRIPT_DIR, "compute")


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


# Sim node ids become a literal folder name under SIM_DIR (see
# /admin/spawn_sim_node) - restricted to a safe charset so a crafted id
# like "../../whatever" can't escape SIM_DIR, same threat model as
# resolve_pc_path's containment check but simpler to just forbid outright
# here since a sim node id has no legitimate reason to contain "/" or "..".
_SIM_NODE_ID_RE = re.compile(r"[A-Za-z0-9_-]{1,64}")
_SIM_ROLE_RE = re.compile(r"[A-Za-z0-9_ -]{1,32}")


def is_valid_sim_node_id(node_id):
    return bool(node_id) and _SIM_NODE_ID_RE.fullmatch(node_id) is not None


def is_valid_sim_role(role):
    return bool(role) and _SIM_ROLE_RE.fullmatch(role) is not None


def lua_quote(s):
    # Minimal Lua string-literal escaping for writing a generated
    # config.lua - defense in depth on top of the charset checks above
    # (which already forbid quotes/backslashes/newlines), not the only
    # thing standing between user input and a broken/injected config.lua.
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


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
