-- Same persistent driver as run_fleetos.lua, but resolves craftos_shim.lua
-- via this script's own location instead of a path relative to cwd - lets
-- it be launched with cwd set to any simulated node folder (e.g.
-- windows/sim/nodeN/), which is what a multi-computer local simulation
-- needs (each node is its own "computer root" with its own fleetos.lua/
-- apps/config.lua copy, see windows/sim/).
--
-- Usage (cwd = the node folder):
--   lua <path-to>/run_sim_node.lua [bridge-url] [key]
--
-- The optional args write bridge_override.txt before first boot, same as
-- run_fleetos.lua - see its header comment for the full explanation.

local scriptDir = arg[0]:match("(.*)[/\\]") or "."
dofile(scriptDir .. "/craftos_shim.lua")

local argBridgeUrl, argBridgeKey = ...
if argBridgeUrl then
    local f = fs.open("bridge_override.txt", "w")
    f.write(textutils.serialize({ url = argBridgeUrl, key = argBridgeKey or "" }))
    f.close()
    print("[run_sim_node] bridge override set to " .. argBridgeUrl)
end

local mainCo = coroutine.create(function()
    dofile("fleetos.lua")
end)

local function resume(...)
    local ok, err = coroutine.resume(mainCo, ...)
    if not ok then
        print("!! fleetos crashed: " .. tostring(err))
        os.exit(1)
    end
end

-- Waits out `seconds` of real wall-clock time. Stock Lua has no sub-second
-- sleep without extra libraries (no C compiler is available in this dev
-- environment to build LuaSocket - checked), and Windows' usual batch-script
-- sleep trick (`ping -n N`) only has ~1-second-per-packet granularity - much
-- too coarse for fleetbridge's 0.1-0.2s poll intervals, and it was silently
-- flooring every sub-second sleep to ~1s (see craftos_shim.lua's
-- os.startTimer comment for the full story). Below 1s, busy-wait on
-- os.clock() instead - pins one core for the wait, but that's the accepted
-- tradeoff for real sub-second precision here, and it's only during the
-- short waits between poll cycles, not continuously. 1s and up, keep the
-- ping-based sleep - imprecise but doesn't matter at that scale, and avoids
-- pinning a core for seconds at a time on the (rare) longer waits like
-- fleetbridge's HTTP_TIMEOUT.
local function sleepSeconds(seconds)
    if not seconds or seconds <= 0 then return end
    if seconds < 1 then
        local target = os.clock() + seconds
        while os.clock() < target do end
    else
        os.execute(("ping -n %d 127.0.0.1 >NUL 2>&1"):format(math.floor(seconds) + 1))
    end
end

resume()

while coroutine.status(mainCo) ~= "dead" do
    local id, fireAt = shim.nextTimer()

    if id then
        sleepSeconds(fireAt - os.clock())
        shim.consumeTimer(id)
        resume("timer", id)
    else
        resume("fleetos_tick")
        sleepSeconds(0.05)
    end
end

print("fleetos stopped.")
