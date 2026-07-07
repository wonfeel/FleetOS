-- Unit tests for (fleetos.setShared/getShared/publish - minimal IPC
-- between apps). Run with (cwd must be game/):
--   cd game
--   lua ../test/test_ipc.lua

dofile("../test/cc_mocks.lua")

-- hide the real config.lua so boot() doesn't auto-spawn shell/fleetbridge -
-- same trick test_monitor_buttons.lua uses, noise this test doesn't need.
local realFsExists = fs.exists
fs.exists = function(path)
    if path == "config.lua" then return false end
    return realFsExists(path)
end

local mainCo = coroutine.create(function()
    dofile("fleetos.lua")
end)

local function resume(...)
    local ok, err = coroutine.resume(mainCo, ...)
    assert(ok, "fleetos crashed: " .. tostring(err))
end

resume() -- boot(): config.lua hidden, so only _monitor_mirror/_supervisor get spawned

local function assertEq(actual, expected, msg)
    if actual ~= expected then
        error(("FAIL: %s (expected %s, got %s)"):format(msg, tostring(expected), tostring(actual)), 2)
    end
end

-- Test 1: setShared/getShared round-trip, visible across separate spawned apps.
do
    fleetos.spawn("writer", function()
        fleetos.setShared("position", { x = 1, y = 2, z = 3 })
    end)
    resume("fleetos_tick")

    local readValue = nil
    fleetos.spawn("reader", function()
        readValue = fleetos.getShared("position")
    end)
    resume("fleetos_tick")

    assertEq(readValue.x, 1, "shared value x")
    assertEq(readValue.y, 2, "shared value y")
    print("Test 1: setShared/getShared visible across apps - PASS")
end

-- Test 2: getShared for a never-set key returns nil, not an error.
do
    local ok, result = pcall(function() return fleetos.getShared("never_set_key") end)
    assertEq(ok, true, "getShared on missing key should not error")
    assertEq(result, nil, "getShared on missing key")
    print("Test 2: getShared on unset key returns nil - PASS")
end

-- Test 3: publish() never errors even though this project's test mocks/
-- Windows shim have no real os.queueEvent (neither cc_mocks.lua nor
-- craftos_shim.lua implement one) - it's pcall'd internally specifically so
-- calling it is always safe, degrading to a silent no-op outside real
-- CC:Tweaked (where os.queueEvent is a native primitive and this actually
-- broadcasts). Actual event delivery can only be verified in-game.
do
    local publishOk = nil
    fleetos.spawn("publisher", function()
        publishOk = pcall(fleetos.publish, "position_updated", { x = 9 })
    end)
    resume("fleetos_tick")

    assertEq(publishOk, true, "publish() should never error, even with no real event queue")
    print("Test 3: publish() is always safe to call - PASS")
end

print("\nAll IPC tests passed.")
