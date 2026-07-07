-- Persistent driver: boots fleetos.lua as a coroutine and keeps it alive
-- for real, waiting on real wall-clock timers, until the process is
-- killed (Ctrl+C / closing the window).
--
-- Must be run with the CURRENT DIRECTORY set to game/ (that folder plays
-- the role of a CC computer's root, both here and in Minecraft) - e.g.:
--   cd game
--   lua ..\windows\run_fleetos.lua [bridge-url] [key]
-- or just double-click windows\run.bat, which does the cd for you and
-- forwards the same optional arguments: run.bat http://127.0.0.1:8787 mykey
--
-- The optional args write bridge_override.txt before first boot - the same
-- file/format the in-game `bridge <url> [key]` shell command uses (see
-- apps/common/shell.lua and apps/common/fleetbridge.lua's header comment
-- for the full BASE_URL/API_KEY priority order) - so fleetbridge.lua picks
-- them up immediately instead of needing config.lua edited or the command
-- typed after boot. Omit them and existing config.lua/defaults apply as
-- before this existed.

-- resolve craftos_shim.lua via THIS script's own location, not a path
-- relative to cwd (run_sim_node.lua already does this - see its own
-- comment) - "../windows/craftos_shim.lua" only worked when cwd happened to
-- be exactly game/, and silently failed (or worse, resolved to some
-- unrelated file) from anywhere else.
local scriptDir = arg[0]:match("(.*)[/\\]") or "."
dofile(scriptDir .. "/craftos_shim.lua")

-- The kernel itself (dofile("fleetos.lua") below) still needs cwd to BE the
-- intended node root - that's the actual contract (cwd plays the role of a
-- CC computer's root, see the header above), not something a script can
-- override via its own location. Fail fast with a clear, actionable message
-- instead of dofile's much less obvious "cannot open fleetos.lua" a few
-- lines down, or - worse - silently creating config.lua/apps/etc in the
-- wrong directory if some other file happened to already exist there.
if not io.open("fleetos.lua", "r") then
    print("run_fleetos.lua: no fleetos.lua in the current directory.")
    print("cwd must be game/ (or a copy of it) - run this as:")
    print("  cd game")
    print("  lua ..\\windows\\run_fleetos.lua [bridge-url] [key]")
    print("or just double-click windows\\run.bat instead, which cd's for you.")
    os.exit(1)
end

local argBridgeUrl, argBridgeKey = ...
if argBridgeUrl then
    local f = fs.open("bridge_override.txt", "w")
    f.write(textutils.serialize({ url = argBridgeUrl, key = argBridgeKey or "" }))
    f.close()
    print("[run_fleetos] bridge override set to " .. argBridgeUrl)
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

-- boots the kernel up to its first event wait
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
        -- nothing scheduled yet (e.g. right after boot, before any app
        -- called os.sleep/os.startTimer) - nudge the kernel with a
        -- harmless event so newly-spawned tasks get their first chance
        -- to run up to their own first yield/timer. The short real wait
        -- bounds CPU usage if some task never starts a timer at all.
        resume("fleetos_tick")
        os.execute("ping -n 2 127.0.0.1 >NUL 2>&1")
    end
end

print("fleetos stopped.")
