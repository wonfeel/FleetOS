# Dockerfile - runs bridge_server.py + dashboard.html anywhere Docker runs
# (Windows/Mac/Linux), instead of relying on the Windows-only .bat launchers.
#
# bridge_server.py is already stdlib-only Python with no OS-specific calls
# in its core paths (every subprocess call uses list-form args, never
# shell=True, and every path is built with os.path.join) - this Dockerfile
# doesn't need to work around any Windows-specific behavior in the server
# itself. What it DOESN'T cover: windows/craftos_shim.lua and the
# "Create emulation" (/admin/spawn_sim_node) feature - those are a
# Windows-only local dev/test emulation of CraftOS, not part of "the site",
# and inherently can't run identically elsewhere (they shell out to
# cmd.exe/ping.exe/powershell.exe by design). Real CC:Tweaked nodes
# (actual Minecraft, any OS) were never affected either way - they only
# ever talk to this container over HTTP.
#
# Build:  docker build -t fleetos-bridge .
# Run:    docker run -p 8787:8787 -v fleetos-logs:/app/windows/logs -e FLEET_BRIDGE_KEY=... fleetos-bridge
#         (NOT a volume over the whole /app/windows - that would shadow the
#         bridge_server.py/dashboard.html/compute/ files this image just
#         copied in with an empty volume, breaking the container outright)
# Or:     docker compose up   (see docker-compose.yml - handles the port/volume/env wiring for you)

FROM python:3.12-slim

# Stdlib only (see bridge_server.py's own module docstring: "Stdlib only,
# no pip install needed") - no requirements.txt, nothing to pip install.
# Compute scripts (windows/compute/*.py) are the same. This is also the
# actual answer to "run Python/C++ compute scripts in an isolated
# environment" - see docker-compose.yml's own header comment for the full
# explanation: running THIS container at all means a compute script
# inherits the container's own constrained privileges (no host filesystem/
# process access beyond what's explicitly mounted) instead of running
# directly on the host with a normal user's full privileges, which is what
# happens outside Docker.

WORKDIR /app

# Only what bridge_server.py actually reads at runtime (see its own
# GAME_DIR/DOCS_DIR/COMPUTE_DIR/DASHBOARD_PATH constants) - not test/,
# reference/, or windows/sim/ (Windows-only, dev-time only, and windows/sim/
# is regenerated on demand anyway - see .dockerignore).
COPY game/ ./game/
COPY docs/ ./docs/
COPY windows/dashboard.html ./windows/
COPY windows/bridge_server.py ./windows/
COPY windows/bridge_paths.py ./windows/
COPY windows/openapi.yaml ./windows/
COPY windows/compute/ ./windows/compute/

WORKDIR /app/windows

# bridge_server.py writes bridge_state.json/node_meta.json/bridge_key.txt/
# logs/ right next to itself (SCRIPT_DIR-relative) - mount a volume over
# /app/windows in docker-compose.yml (or `docker run -v`) so those survive
# a container restart/rebuild instead of being lost with the container's
# writable layer.
EXPOSE 8787

# CRITICAL Docker-specific default: bridge_server.py's own default
# (FLEET_BRIDGE_HOST unset -> 127.0.0.1) would bind ONLY to the
# container's own loopback - completely unreachable through `docker run
# -p 8787:8787`, no matter what the port mapping says, since the process
# itself never accepts a connection arriving on the container's external
# interface. 0.0.0.0 (all interfaces INSIDE the container) is what
# actually needs to happen for port-mapping to work at all - this is NOT
# the same risk as binding 0.0.0.0 on a bare host, since Docker's own
# port mapping is the actual exposure boundary here, not this setting.
# Binding beyond 127.0.0.1 already triggers this project's existing
# auto-generate-an-API-key-if-none-set safeguard (see main() in
# bridge_server.py) - so a container run with no FLEET_BRIDGE_KEY still
# isn't silently unauthenticated, exactly like running on a LAN/VPN
# address without Docker at all.
ENV FLEET_BRIDGE_HOST=0.0.0.0

ENTRYPOINT ["python", "bridge_server.py"]
CMD ["8787"]
