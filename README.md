# FleetOS

A mini-OS for CC:Tweaked (Minecraft) computers, plus a Windows-side bridge/dashboard to
control them remotely. **Every computer is equal, there is no master/slave.** Each one
runs its own agent and talks to the bridge directly.

See [`PROJECT_NOTES.md`](PROJECT_NOTES.md) for the full architecture reference, [`quickstart.html`](quickstart.html)
for a 4-step setup guide, and [`fleetos_guide.html`](fleetos_guide.html) for the in-depth guide
(Russian). [`guide.html`](guide.html) is a separate guide for the unrelated Raytower/triangulation
feature.

## Folder structure

- `game/` - everything that runs *inside Minecraft* (kernel `fleetos.lua`, bootstrap `install.lua`,
  per-node `config.lua`, apps under `apps/`).
- `windows/` - PC-side tooling: `bridge_server.py` (stdlib-only HTTP server), `dashboard.html`
  (the web UI, also published here as `index.html` for GitHub Pages), `fleetctl.py` (CLI
  alternative), `craftos_shim.lua`/`run_fleetos.lua` (run FleetOS as a persistent Windows
  process without Minecraft, for testing).
- `test/` - unit tests (`cc_mocks.lua` + test scripts), run from `game/`: `lua ../test/<name>.lua`.

## Dashboard-only hosted copy

`index.html` (repo root) is a static copy of `windows/dashboard.html`, published via GitHub
Pages purely for convenience, open it in a browser **on the same PC** running `bridge_server.py`
(it talks to `http://127.0.0.1:8787` by default; browsers block plain-HTTP requests to any other
address from an HTTPS page, so a Radmin/remote bridge address won't work from the hosted page
unless you allow insecure content for this site).

## No authentication by default

`bridge_server.py` has no login by default. Anyone who can reach it can run code and
read/write files on your in-game computers. Keep it bound to `127.0.0.1`/a trusted VPN, or
set `FLEET_BRIDGE_KEY` (see `fleetos_guide.html`, section 4) if it needs to be reachable by
others.
