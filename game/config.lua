-- Per-node settings for fleetos.lua. Copy/edit this on EACH computer -
-- id must be unique across the fleet. Every computer is equal here -
-- there's no master/slave: each one runs its own fleetbridge and is
-- individually selectable from the dashboard by its id.

return {
    id = "node1",       -- unique name for this computer - pick this per node
                        -- (or rename it later from the dashboard - that writes
                        -- a node_id.txt override next to this file instead of
                        -- editing this line, see apps/common/fleetbridge.lua)
    role = "generic",   -- free-form label ("tower", "farm", "generic", ...), just for your own grouping

    -- Which apps (from /apps/) to auto-run on boot. "fleetbridge" is what
    -- makes this computer controllable from the dashboard - put it on
    -- every node you want to reach remotely. Add "raytower_master" (on
    -- exactly one computer) or "raytower_slave" (on tower computers) only
    -- if you're using the triangulation feature.
    startup = {
        "shell",
        "fleetbridge",
    },

    -- Where apps/fleetbridge.lua polls for commands from your real PC.
    -- If this computer and bridge_server.py are on the SAME machine as the
    -- Minecraft server, 127.0.0.1 is fine (but CC:Tweaked still needs it
    -- allowed in computercraft-server.toml's [http.rules] - see below).
    -- If you're playing over Radmin VPN (or any setup where the game
    -- server isn't the same machine running bridge_server.py), point this
    -- at your PC's Radmin-assigned IP instead (and start the bridge with
    -- windows/start_bridge_mc.bat, not start_bridge.bat), e.g.:
    --   bridgeUrl = "http://26.76.16.71:8787",
    bridgeUrl = "http://26.76.16.71:8787",

    -- Optional: only needed if you started bridge_server.py with
    -- FLEET_BRIDGE_KEY set - must match it exactly, or every request from
    -- this computer gets rejected with 401. Leave unset if you haven't
    -- set FLEET_BRIDGE_KEY (the default - no auth at all).
    -- apiKey = "some-secret-key",

    -- Optional: raytower calibration values (found via the standalone
    -- raytower.lua's "master calibrate" command). Only read by
    -- apps/raytower_master.lua.
    -- raytowerForward = { x = 1, y = 0, z = 0 },
    -- raytowerQSign = { 1, 1, 1 },
}
