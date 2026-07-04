-- Persistent driver: boots fleetos.lua as a coroutine and keeps it alive
-- for real, waiting on real wall-clock timers, until the process is
-- killed (Ctrl+C / closing the window).
--
-- Must be run with the CURRENT DIRECTORY set to game/ (that folder plays
-- the role of a CC computer's root, both here and in Minecraft) - e.g.:
--   cd game
--   lua ..\windows\run_fleetos.lua
-- or just double-click windows\run.bat, which does the cd for you.

dofile("../windows/craftos_shim.lua")

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
