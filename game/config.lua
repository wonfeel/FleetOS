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
    bridgeUrl = "http://127.0.0.1:8787",

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

    -- Optional: shared secret for raytower's rednet traffic - set the
    -- SAME value here on the master and every slave tower to turn on
    -- packet signing + replay protection (see apps/raytower/raytower_auth.lua).
    -- Left unset, rednet traffic is unsigned (any player with a modem in
    -- range could forge/replay packets) - fine for a quick test, not
    -- recommended for a real multiplayer server.
    -- raytowerSecret = "some-shared-secret",

    -- Optional: base rednet-poll interval in seconds for apps/raytower/
    -- raytower_master.lua - trade off position-fix latency vs. rednet/
    -- server load for your own setup. Default 1.0 if unset. The app also
    -- backs off further on its own once the solved position is stable -
    -- see raytower_master.lua's own comment.
    -- raytowerPollInterval = 1.0,

    -- Optional override: physical size of this computer's attached
    -- monitor, in MONITOR BLOCKS (not characters), e.g. { w = 7, h = 4 }
    -- for a monitor built 7 blocks wide by 4 tall. Normally you don't need
    -- this - fleetos.lua auto-derives the real block size every tick from
    -- monitor.getSize()/getTextScale() using CC:Tweaked's own sizing
    -- formula (see computeMonitorBlocks in fleetos.lua), so the dashboard's
    -- monitor emulation already renders at the true in-game aspect ratio
    -- and updates itself if you physically resize the monitor. Only set
    -- this if that auto-detection is ever visibly wrong for your
    -- CC:Tweaked version.
    -- monitorBlocks = { w = 7, h = 4 },
}
