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

resume()

while coroutine.status(mainCo) ~= "dead" do
    local id, fireAt = shim.nextTimer()

    if id then
        local remaining = fireAt - os.time()
        if remaining > 0 then
            os.execute(("ping -n %d 127.0.0.1 >NUL 2>&1"):format(remaining + 1))
        end
        shim.consumeTimer(id)
        resume("timer", id)
    else
        resume("fleetos_tick")
        os.execute("ping -n 2 127.0.0.1 >NUL 2>&1")
    end
end

print("fleetos stopped.")
