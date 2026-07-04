# FleetOS - project reference

A mini-OS for CC:Tweaked (Minecraft) computers, plus a Windows-side bridge/dashboard to control them remotely. **Every computer is equal, there is no master/slave.** Each one runs its own agent and talks to the bridge directly.

## Folder structure

- `game/` - everything that runs *inside Minecraft*. This is what gets copied onto a real computer (or bootstrapped via `install.lua`).
  - `fleetos.lua` - the kernel. Cooperative multitasking (coroutines), program manager, output capture (with color, cursor-aware so in-place line edits like backspace redraw correctly, see gotchas), monitor mirror + touch UI (per-app run/minimize/restore/close buttons, Windows-titlebar style; minimize is a pure display flag, doesn't pause the app).
  - `install.lua` - one-time bootstrap loader for a fresh computer. Only file you `wget` by hand; it fetches everything else from the bridge and writes a starter `config.lua`.
  - `config.lua` - per-node config (`id`, `role`, `startup` apps, `bridgeUrl`). Unique per computer.
  - `triangulation.lua` - shared math module (NOT an app) used by `apps/raytower/raytower_master.lua`. Not deployable via the normal per-app deploy path, the dashboard pushes it separately (`writefile`) alongside a `raytower_master` deploy.
  - `apps/common/` - `clock`, `shell` (interactive console), `fleetbridge` (talks to the bridge; put on every node you want reachable).
  - `apps/raytower/` - `raytower_master`/`raytower_slave`, an independent rednet-based tower-triangulation feature, unrelated to fleet control.
  - `raytower.lua` - standalone single-file version of the triangulation tool (not run under the kernel).
- `windows/` - PC-side tooling (never copied into the game).
  - `bridge_server.py` - stdlib-only HTTP server. Auth is opt-in and off by default (meant for `127.0.0.1` or a trusted VPN like Radmin only); set `FLEET_BRIDGE_KEY` before starting it to require a matching `X-API-Key` header on every request except `/`, `/dashboard`, `/install.lua` (can't carry headers, see below). Tracks nodes by id; serves the dashboard, `fleetos.lua`/`install.lua`/`triangulation.lua`/apps for fetching, and a command queue per node.
  - `dashboard.html` - static single-page web UI (works hosted anywhere, e.g. GitHub Pages, but always talks to a bridge on `127.0.0.1` or wherever "Bridge address" points; cross-origin HTTPS to non-localhost HTTP is blocked by browsers).
  - `craftos_shim.lua` - CraftOS emulation for running `fleetos.lua` as a real persistent Windows process (`run_fleetos.lua`/`run.bat`) without Minecraft.
  - `fleetctl.py` - CLI alternative to the dashboard.
- `test/` - `cc_mocks.lua` (lightweight in-memory CraftOS stubs for fast unit tests) + test scripts. Run from `game/`: `lua ../test/<name>.lua`.
- Root-level standalone human-facing guides (static HTML, not served by `bridge_server.py`, open directly in a browser): `guide.html` (Raytower/triangulation setup+calibration only), `fleetos_guide.html` (the whole project, in depth: bridge setup, install.lua, dashboard, the opt-in API key, fleetctl.py, troubleshooting), and `quickstart.html` (condensed 4-step version of just the bridge+install+API-key flow, links out to `fleetos_guide.html` for detail). Keep all three in sync with reality when their subject matter changes; don't merge them, they're intentionally scoped differently.

## How control works (no master/slave)

Every node's `apps/common/fleetbridge.lua`:
1. Reads its own `id`/`bridgeUrl` from `config.lua`.
2. Polls `GET {bridgeUrl}/poll?node={id}` for queued commands, executes them **locally on itself** (no rednet needed for this), reports back via `POST /report?node={id}`.
3. Command types: `run`, `kill`, `deploy` (writes app code + `.bak` backup, restarts if it was running), `rollback`, `type` (remote terminal via `fleetos.runShellLine`), `readfile`/`writefile`, `update` (re-fetches `fleetos.lua` itself and `os.reboot()`s, since the kernel isn't an "app" so `deploy` can't touch it), `rename` (writes a `node_id.txt` override, takes priority over `config.lua`'s `id`, and reboots so the new id takes effect everywhere).

The dashboard/`fleetctl.py` queue commands via `POST /command` with a `node` field (a specific id, or `"*"` for every known node).

## Known gotchas (already fixed, don't reintroduce)

- **Real CraftOS's `print`/`write` call the *global* `write`/`term.write` internally.** Once fleetos.lua overrides those globals for output capture, calling through to "the real function" recurses back into the hooks and double-captures. Fixed with a `capturing` reentrancy guard in fleetos.lua, don't remove it, and don't add new global-function hooks without the same guard. `test/cc_mocks.lua`/`craftos_shim.lua` don't wire print/write/term.write together, so this class of bug **won't show up in local tests**, only in the real game.
- `fs.exists()` in both local shims only works for files (uses `io.open`), not directories, use `fs.isDir()` for directory checks.
- Apps are grouped into folders (`common/`, `raytower/`) purely for browsing/deploy UI; `fleetos.lua`'s `spawn()`/`appPath()` resolve a bare name across all groups, so `config.lua`'s `startup` list never needs a group prefix.
- **Output capture is cursor-aware, not just append-only.** Real CraftOS's `read()` edits the input line in place (`term.setCursorPos` back to the start of input, then rewrites it, e.g. backspace = rewrite one char shorter + a trailing blank to erase the old last char) instead of ever printing a fresh line. `fleetos.lua` tracks a virtual `cursorCol`/`lineOriginX/Y` and splices writes into `currentLine`/`currentColors` at that column (see `spliceCurrentLine`) instead of blindly appending. Naive appending was the exact bug where backspacing looked fine on the real screen but left garbage in the monitor mirror / dashboard Terminal panel, since neither of those actually looks at the real screen, only at the capture buffer. Don't revert this to plain concatenation.
- **`FLEET_BRIDGE_KEY`'s `X-API-Key` must never be sent to a `deploy` command's arbitrary `url`**, only to the bridge's own `BASE_URL`. `apps/common/fleetbridge.lua`'s `authHeaders(url, ...)` checks `url:sub(1,#BASE_URL)==BASE_URL` before attaching it; don't simplify this to "always attach" or a deploy pointed at some other host would leak the key to it.
- **A task can die two ways**: explicitly via `kill()`, or on its own (crash/normal return), caught by `tick()`'s dead-task sweep. Both MUST go through the shared `removeTask()` so `minimizedApps` never keeps a stale entry for a name that gets respawned later. Don't re-inline either path.
- **Output capture's cursor tracking has a known gap for input lines LONGER than the terminal's width.** Real CraftOS's `read()` never wraps to a new row for long input, confirmed against upstream `bios.lua`: it always keeps the cursor on the same row and scrolls the *visible window* of characters horizontally (`nScroll`) instead. So the `y == lineOriginY` row check in `fleetos.lua`'s `term.setCursorPos` hook is safe (real `read()` never presents a different row for the same input line). But the capture doesn't model `nScroll` itself, once a line is long enough to scroll, what gets `term.write`-ed is a *substring* of the real input starting mid-way through it, at the same screen column every time, so `spliceCurrentLine` overwrites our captured copy with that substring instead of the full logical line, silently losing the scrolled-off prefix. Rare in practice (default terminal is 51 cols; a "shell> " prompt leaves ~44 for typed text), and no worse than the pre-fix behavior for this same edge case (which was wrong too, just differently), not fixed, just documented so nobody "fixes" the row-check thinking that's the gap.

## Testing without Minecraft

- Unit tests: `cd game && lua ../test/<script>.lua` (uses `cc_mocks.lua`).
- Full persistent simulation: `windows/run.bat` (uses `craftos_shim.lua`, real timers, real files).
- Bridge + dashboard: `windows/start_bridge.bat` (localhost) or `start_bridge_mc.bat` (binds to a Radmin IP for real remote play), then open `http://127.0.0.1:8787/`.
- You can drive a live bridge directly with `curl` (e.g. `curl -X POST http://<host>:8787/command -d '{"type":"update","node":"<id>"}'`). This is the same API the dashboard uses, useful for pushing kernel/app updates to already-deployed real computers without asking the user to click through the UI. Add `-H "X-API-Key: <key>"` if that bridge was started with `FLEET_BRIDGE_KEY` set.
