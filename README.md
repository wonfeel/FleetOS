# FleetOS

A mini-OS for CC:Tweaked (ComputerCraft, Minecraft) computers, plus a
Windows-side bridge/dashboard to control an entire fleet of them remotely.
Every computer is equal - there is no master/slave.

> **Note**: every other guide in this repo ([`docs/fleetos_guide.html`](docs/fleetos_guide.html),
> [`docs/quickstart.html`](docs/quickstart.html), [`docs/guide.html`](docs/guide.html)) is
> Russian-only - this file is a short English entry point so the project
> isn't completely opaque to a non-Russian-speaking reader. If you read
> Russian, start with [`docs/fleetos_guide.html`](docs/fleetos_guide.html)
> instead - it's the authoritative, in-depth guide.

## Layout

- [`game/`](game/) - everything that runs *inside Minecraft* (the kernel,
  `fleetos.lua`, and every app under `game/apps/`). See
  [`game/apps/README.md`](game/apps/README.md) if you want to write your own app.
- [`windows/`](windows/) - the PC-side bridge server (`bridge_server.py`,
  stdlib-only Python, no install needed) and the web dashboard
  (`dashboard.html`, open `http://127.0.0.1:8787/` once the bridge is
  running) used to control the fleet remotely, plus a Windows-only local
  simulation (`craftos_shim.lua`) for developing/testing without Minecraft
  at all - `windows/run_sim.bat` starts the bridge and two simulated nodes
  together, then opens the dashboard.
- [`test/`](test/) - unit tests, runnable without Minecraft (`cd game && lua ../test/<name>.lua`).
- [`docs/`](docs/) - every human-facing guide and the technical reference -
  see [`docs/README.html`](docs/README.html) for the index.
- [`reference/`](reference/) - third-party material kept locally for
  cross-checking real behavior (the CC:Tweaked mod source) - not part of
  this project, gitignored, safe to delete and re-fetch if you don't need it.

## Quick start

1. `cd windows && python bridge_server.py` (or `start_bridge.bat`) - starts
   the bridge on `http://127.0.0.1:8787`. Or, on any OS: `docker compose up`
   (see [`Dockerfile`](Dockerfile)/[`docker-compose.yml`](docker-compose.yml) -
   same bridge+dashboard, no local Python install needed, and it's also what
   actually contains `windows/compute/*.py` compute scripts to the
   container instead of running them with a normal user's full host
   privileges - see the compose file's own header comment).
2. Open that URL in a browser - that's the dashboard.
3. On a fresh CC:Tweaked computer in-game: `wget http://<your-pc-ip>:8787/install.lua install` then `install`.
4. The new computer shows up in the dashboard within a few seconds.

See [`docs/quickstart.html`](docs/quickstart.html) (Russian) for the same
steps with more detail, or [`docs/fleetos_guide.html`](docs/fleetos_guide.html)
for the full picture (bridge setup, the optional API key, troubleshooting,
everything). Admin/security features added in the reliability hardening
pass (backup/restore, health checks, read-only keys, etc.) are in
[`docs/hardening_guide.html`](docs/hardening_guide.html).

## License

MIT - see [`LICENSE`](LICENSE).
