# FleetOS

![CI](https://github.com/wonfeel/FleetOS/actions/workflows/ci.yml/badge.svg)
![Python](https://img.shields.io/badge/Python-3.12-blue?style=flat)
![Lua](https://img.shields.io/badge/Lua-5.1%20%28CC%3ATweaked%29-2C2D72?style=flat)
![Docker](https://img.shields.io/badge/Docker-optional-2496ED?style=flat)
![Platform](https://img.shields.io/badge/platform-any%20(bridge)%20%2F%20Windows%20(sim)-0078d7?style=flat)
![License](https://img.shields.io/badge/license-MIT-green?style=flat)

[Русский](README.ru.md) | [Gateway cluster architecture](https://wonfeel.github.io/FleetOS/docs/ARCHITECTURE_GATEWAY_CLUSTER.html) | [Hardening guide](https://wonfeel.github.io/FleetOS/docs/hardening_guide.html)

A mini-OS for CC:Tweaked (ComputerCraft) computers, plus a Windows-side bridge and web dashboard
to control an entire fleet of them remotely, released under the [MIT license](LICENSE). Every
computer is equal - there is no master/slave - and every computer stays controllable, monitorable
and updatable from one browser tab without ever alt-tabbing into the game.

**The problem:** a CC:Tweaked computer only has its own screen and its own local disk - running
more than a couple of them means physically walking to each one to see what it's doing, type a
command, or push an update.
**The approach:** every computer runs the same small kernel (`fleetos.lua`) and polls a bridge
server on your PC over HTTP; the bridge queues commands and collects reports; a single-file web
dashboard turns that into a live terminal, a monitor-peripheral mirror, a file explorer, and
metrics - for any computer in the fleet, picked from a dropdown.

## Why this exists

ComputerCraft's own multitasking is nonexistent - one program owns the terminal until it exits -
and there's no built-in way to see what a computer is doing without standing in front of it.
`fleetos.lua` is a small cooperative-multitasking kernel (spawn/kill/list, an app's own crashes
don't take down the others) that runs the actual "programs" - a shell, a bridge-polling client, a
monitor mirror - as separate tasks. The bridge and dashboard exist so that kernel is actually
*useful* at fleet scale: nobody wants to `/tp` to 20 different farm computers to check on them.

## What it can do

No master/slave - every node runs the same kernel, and the dashboard just happens to be looking
at one of them at a time. A node registers itself just by polling once.

- **Live terminal** for any node - runs a command as if typed at the real shell prompt
  (`shell.run`), streams back print/write output.
- **Monitor mirror.** Whatever's actually drawn on a computer's attached monitor peripheral gets
  reconstructed pixel-for-pixel (real CC:Tweaked palette) in the browser, including tapping the
  emulated monitor to trigger a real `monitor_touch` event in-game.
- **File explorer** for a node's own filesystem, or the PC's `game/`/`compute/` folders. Browse,
  edit, create, delete, drag-and-drop deploy.
- Fleet-wide bulk operations: update/rollback with automatic kernel backup, config push (bridge
  URL, API key, startup app list), rename, folder organization, macros.

The **gateway cluster** (`apps/common/fleetgateway.lua`, see the
[architecture doc](https://wonfeel.github.io/FleetOS/docs/ARCHITECTURE_GATEWAY_CLUSTER.html))
lets a handful of trusted computers relay poll/report traffic for the rest of the fleet over
`rednet` instead of every node making its own HTTP call - signed heartbeat-based leader election,
automatic failover.

**Drone flight control** (`apps/drone/`) gives manual control (throttle/yaw/horizontal movement)
for a 4-motor tilt-rotor platform from the dashboard, with continuous attitude-hold so the body
stays level regardless of what the pilot commands, and a failsafe that ramps throttle to zero if
the connection drops. The control-mixing math is unit-tested on a desktop Lua interpreter
(`test/test_motor_mixer.lua`) - the redstone/peripheral wiring itself still needs real in-game
tuning, see [What's not done yet](#whats-not-done-yet).

- **Raytower triangulation** solves a computer's real-world position from directional rangefinder
  "rays" reported by tower computers, with an optional PC-side compute offload.
- HMAC-signed `rednet` traffic for gateway heartbeats/relay and raytower - opt-in shared secret,
  replay-protected.
- A **local simulation** (`windows/craftos_shim.lua`) runs the exact same `fleetos.lua`/app code
  as a Windows process, no Minecraft required. `windows/run_sim.bat` spins up the bridge plus two
  simulated nodes and opens the dashboard.

Docker/CI: the bridge + dashboard run in a container (`docker compose up`, no local Python
install needed - see the [Dockerfile](Dockerfile)'s header for why compute scripts run inside it
rather than with a host user's full privileges). GitHub Actions runs the Python, Lua and
Windows-integration suites on every push.

`game/fleetos.lua` is the kernel: cooperative scheduling via coroutines, a monitor-peripheral
mirror plus touch-forwarding, minimal pub/sub and shared-state IPC between apps
(`fleetos.publish`/`setShared`), an instruction-budget watchdog so one runaway app can't stall the
tick loop, self-update with automatic rollback on a bad deploy.

Everything that runs *as* a task under that kernel lives in `game/apps/`: `common/fleetbridge.lua`
(the HTTP polling client every controllable node runs), `common/shell.lua`,
`common/fleetgateway.lua` (relay cluster), `raytower/` (triangulation master/slave), `drone/`
(flight control plus the pure control-mixing math, kept in its own testable module).

- `windows/bridge_server.py` is stdlib-only Python (`ThreadingHTTPServer`, no dependencies),
  ~2400 lines split into `FleetState` (in-memory fleet data behind one lock) and `StateRepository`
  (atomic-write persistence, debounced flush thread) instead of module-level globals.
- `windows/dashboard.html` is a single self-contained file (HTML/CSS/JS, no build step, no
  framework). Terminal/monitor emulation, file explorer, fleet table, metrics, and drone controls
  all live here, with i18n (EN/RU) baked in.
- `windows/craftos_shim.lua` shims just enough of the CraftOS API (`fs`, `os.epoch`, redstone I/O,
  a `--headless` mode for CI) that the real `fleetos.lua`/apps run unmodified as a Windows
  process - local dev/testing without Minecraft at all.

## Metrics: from full log scan to O(1)

`GET /metrics/history` reconstructs per-bucket request-rate histograms (polls served, reports
received, rate-limited, HTTP errors, ...) for the dashboard's history panel. The first version
re-parsed the entire log file on *every* request, regardless of the requested window:

| Range (bucket width) | Before  | After (log parsed live) | After (fully in-memory) |
|---|---|---|---|
| minute (5s)  | ~600 ms | ~15 ms  | zero log I/O |
| hour (60s)   | ~600 ms | ~15 ms  | zero log I/O |
| 24h (900s)   | ~600 ms | ~500 ms | zero log I/O (after 24h uptime) |
| week (7200s) | ~600 ms | ~500 ms | zero log I/O (after 1 week uptime) |

"Log parsed live" reads the log tail backward and stops as soon as it's walked past the requested
window, instead of always scanning the whole file - that's the dominant cost for short ranges.
"Fully in-memory" is a per-range ring buffer updated in O(1) at the same call site that already
increments the live counters, so there's no log I/O at all once the process has been up longer
than the requested window; the log fallback only covers the gap before that.

The 24h/week rows still show ~500ms because log retention genuinely doesn't reach that far yet on
a freshly-restarted bridge - it's real data being read, not wasted work. A 3-60s cache (scaled to
the range's bucket width) keeps multiple open dashboard tabs from re-triggering it.

## Requirements

- **Bridge + dashboard**: Python 3.12+ (stdlib only - nothing to `pip install` for the bridge
  itself), any OS, or `docker compose up` with neither installed.
- **In-game**: CC:Tweaked (ComputerCraft) in Minecraft, with the bridge's host allowed in
  `computercraft-server.toml`'s `[http.rules]`.
- **Local simulation without Minecraft**: Windows + a `lua` 5.x interpreter on `PATH`.
- **Dev/test tooling** (optional): `flake8` (Python lint), `luacheck` (Lua lint) - see
  [`windows/setup.cfg`](windows/setup.cfg) / [`.luacheckrc`](.luacheckrc).

## Quick start

1. `cd windows && python bridge_server.py` (or `start_bridge.bat`) - starts the bridge on
   `http://127.0.0.1:8787`. Or, on any OS: `docker compose up` (same bridge + dashboard, no local
   Python install needed).
2. Open that URL in a browser - that's the dashboard.
3. On a fresh CC:Tweaked computer in-game:
   `wget http://<your-pc-ip>:8787/install.lua install` then `install`.
4. The new computer shows up in the dashboard within a few seconds.

See [`docs/quickstart.html`](https://wonfeel.github.io/FleetOS/docs/quickstart.html)
(Russian) for the same steps with more detail, or
[`docs/fleetos_guide.html`](https://wonfeel.github.io/FleetOS/docs/fleetos_guide.html)
for the full picture (bridge setup, the
optional API key, troubleshooting, everything).

## Layout

- [`game/`](game/) - everything that runs *inside Minecraft*. See
  [`game/apps/README.md`](game/apps/README.md) to write your own app.
- [`windows/`](windows/) - the bridge server, the dashboard, and the Windows-only local simulation.
- [`test/`](test/) - Lua unit tests, runnable without Minecraft (`cd game && lua ../test/<name>.lua`).
- [`docs/`](docs/) - every human-facing guide; see [`docs/README.html`](https://wonfeel.github.io/FleetOS/docs/README.html) for the index.
- [`.github/workflows/ci.yml`](.github/workflows/ci.yml) - Python (Linux + Windows), Lua, and the
  real end-to-end Windows-integration suite, on every push.

## Tests

```
test/test_*.lua (13 files)         Lua-side kernel/app tests, no Minecraft needed
  test_motor_mixer.lua               drone control-mixing math invariants
  test_fleetgateway.lua              leader election + failover
  test_signed_rednet.lua             HMAC signing/verification
  ...

windows/test_bridge_server.py (17)  bridge unit tests (state, persistence, TTLs)
windows/test_bridge_server_load.py (5)  concurrency: 32 threads, unique ids, no lost writes
windows/test_integration.py (1)     real lua subprocess, full poll/report/command/result cycle
```

Run everything CI runs, locally:
```bash
cd game && for f in ../test/test_*.lua; do lua "$f" || break; done
cd windows && python -m unittest test_bridge_server test_bridge_server_load test_integration -v
```

MIT - see [`LICENSE`](LICENSE).
