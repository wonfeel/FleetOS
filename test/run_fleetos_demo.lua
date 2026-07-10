-- Actually boots game/fleetos.lua locally (as a coroutine, driven by
-- synthetic OS events) using the CraftOS mocks, so you can see the
-- kernel spawn the "clock" app from the real game/config.lua/apps/clock.lua
-- and keep it alive across several ticks - without Minecraft.
--
-- Run with (cwd must be game/, same as a real CC computer's root):
--   cd game
--   lua ..\test\run_fleetos_demo.lua

dofile("../test/cc_mocks.lua")

print("=== Booting fleetos.lua locally (mocked CraftOS) ===\n")

local mainCo = coroutine.create(function()
    dofile("fleetos.lua")
end)

local function step(...)
    local ok, a = coroutine.resume(mainCo, ...)
    if not ok then
        print("!! fleetos crashed: " .. tostring(a))
        return false
    end
    if coroutine.status(mainCo) == "dead" then
        print("-- fleetos exited cleanly")
        return false
    end
    return true
end

-- 1) first resume: runs boot() up to its first os.pullEventRaw() yield
--    (this is where "clock" gets spawned and the status screen prints)
if not step() then os.exit(1) end

-- 2) feed a few generic events so the kernel loop ticks a couple of times
for _ = 1, 3 do
    if not step("mouse_click", 1, 1, 1) then os.exit(1) end
end

-- 3) fire the exact timer id clock.lua's os.sleep(5) is waiting on, so it
--    actually resumes and prints again (proves multitasking really works,
--    not just that it booted)
if not step("timer", 1) then os.exit(1) end

-- 4) a couple more idle ticks
for _ = 1, 2 do
    if not step("mouse_click", 1, 1, 1) then os.exit(1) end
end

-- 5) clean shutdown, same as pressing Ctrl+T in-game
print("\n=== Sending terminate ===")
step("terminate")

print("\nDemo finished: kernel booted, spawned 'clock' from config.lua,")
print("survived multiple event ticks, resumed clock after its timer fired,")
print("and shut down cleanly on terminate.")
