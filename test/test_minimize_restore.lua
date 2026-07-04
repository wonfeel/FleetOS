-- Verifies the Windows-style minimize/restore state machine
-- (fleetos.minimize/restore) that drives the monitor panel's per-app
-- buttons ([_] minimize, [^] restore, [X] close, [>] run). Minimize is
-- PURELY a display flag - the app itself keeps running completely
-- unaffected (same as minimizing a real window doesn't pause the process
-- behind it) - this is what's actually asserted below via fleetos.list().
--
-- Run with (cwd must be game/):
--   cd game
--   lua ../test/test_minimize_restore.lua

dofile("../test/cc_mocks.lua")

local mainCo = coroutine.create(function()
    dofile("fleetos.lua")
end)
coroutine.resume(mainCo)

-- clock is long-running under cc_mocks (pure os.sleep timer loop), unlike
-- shell/fleetbridge which die almost immediately under mocks (no real
-- stdin/http) - a stable subject for state checks across several calls.
local ok = fleetos.spawn("clock")
assert(ok, "expected clock to spawn")

local function isRunning(name)
    for _, t in ipairs(fleetos.list()) do
        if t.name == name then return true end
    end
    return false
end

assert(isRunning("clock"), "clock should be running after spawn")

local okBad1, errBad1 = fleetos.minimize("nonexistent_app")
assert(not okBad1 and errBad1, "minimizing a non-running app should fail")
local okBad2, errBad2 = fleetos.restore("nonexistent_app")
assert(not okBad2 and errBad2, "restoring a non-running app should fail")
print("Test 1: minimize/restore reject non-running apps - PASS")

local okMin = fleetos.minimize("clock")
assert(okMin, "expected clock to minimize")
assert(isRunning("clock"), "minimize must NOT stop the app - it's a display flag only")
print("Test 2: minimize keeps the app running - PASS")

local okRestore = fleetos.restore("clock")
assert(okRestore, "expected clock to restore")
assert(isRunning("clock"), "clock should still be running after restore")
print("Test 3: restore keeps the app running - PASS")

-- closing (kill) always wins, even while minimized
fleetos.minimize("clock")
local okKill = fleetos.kill("clock")
assert(okKill, "expected clock to be killable while minimized")
assert(not isRunning("clock"), "clock should be stopped after kill")
print("Test 4: closing a minimized app actually stops it - PASS")

-- respawning under the same name shouldn't inherit a stale minimized flag
-- from before (kill() clears it - see fleetos.lua)
local okRespawn = fleetos.spawn("clock")
assert(okRespawn, "expected clock to respawn")
local okRestore2 = fleetos.restore("clock")
assert(okRestore2 == true, "restoring a freshly respawned (non-minimized) app should be a harmless no-op")
fleetos.kill("clock")
print("Test 5: no stale minimized flag survives a kill+respawn - PASS")

print("\nAll minimize/restore tests passed.")
