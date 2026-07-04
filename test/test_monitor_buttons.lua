-- End-to-end check of the monitor panel's per-app buttons using a fake
-- "advanced monitor" peripheral (a simple in-memory character grid) plus
-- synthetic monitor_touch events - verifies the actual rendered columns
-- and that tapping each button performs the right action:
--   stopped   -> [>] run
--   running   -> [_] minimize, [X] close
--   minimized -> [^] restore, [X] close
--
-- Run with (cwd must be game/):
--   cd game
--   lua ../test/test_monitor_buttons.lua

dofile("../test/cc_mocks.lua")

-- hide the real config.lua so boot() doesn't auto-spawn shell/fleetbridge
-- (both die almost instantly under mocks - noise this test doesn't need,
-- see PROJECT_NOTES.md/prior test comments on why `clock` is used instead)
local realFsExists = fs.exists
fs.exists = function(path)
    if path == "config.lua" then return false end
    return realFsExists(path)
end

-- fake advanced monitor: an in-memory W x H character grid that
-- drawMonitorPanel's getSize/clear/setCursorPos/write/setTextColor calls
-- operate on, so we can inspect exactly what it would show in-game.
local W, H = 26, 8
local screen = {}
local cursorX, cursorY = 1, 1
local monitor = {
    getSize = function() return W, H end,
    setBackgroundColor = function(_) end,
    setTextColor = function(_) end,
    clear = function()
        screen = {}
        for y = 1, H do
            screen[y] = {}
            for x = 1, W do screen[y][x] = " " end
        end
    end,
    setCursorPos = function(x, y) cursorX, cursorY = x, y end,
    write = function(text)
        for i = 1, #text do
            local x = cursorX + i - 1
            if screen[cursorY] and x >= 1 and x <= W then
                screen[cursorY][x] = text:sub(i, i)
            end
        end
        cursorX = cursorX + #text
    end,
}

peripheral.find = function(kind) if kind == "monitor" then return monitor end return nil end
peripheral.getName = function(_) return "fakemon" end

local function rowText(y)
    return table.concat(screen[y])
end

local mainCo = coroutine.create(function()
    dofile("fleetos.lua")
end)

local function resume(...)
    local ok, err = coroutine.resume(mainCo, ...)
    assert(ok, "fleetos crashed: " .. tostring(err))
end

resume() -- boot(): config.lua hidden, so only _monitor_mirror gets spawned
resume("fleetos_tick") -- starts _monitor_mirror: os.startTimer(1) -> id 1, then its first redraw

-- alphabetically: clock, fleetbridge, raytower_master, raytower_slave,
-- shell - "clock" sorts first, so its row is right after the header
local clockRow = rowText(2)
assert(clockRow:find("clock"), "expected 'clock' on row 2, got: " .. clockRow)
assert(clockRow:find("%[>%]"), "stopped app should show a [>] run button, got: " .. clockRow)
print("Test 1: stopped app shows a run button - PASS")

fleetos.spawn("clock")
resume("timer", 1) -- the timerId _monitor_mirror is currently waiting on (see above)

clockRow = rowText(2)
assert(clockRow:find(">"), "running app's icon should be '>'")
assert(clockRow:find("%[_%]"), "running app should show a [_] minimize button, got: " .. clockRow)
assert(clockRow:find("%[X%]"), "running app should show an [X] close button, got: " .. clockRow)
print("Test 2: running app shows minimize + close buttons - PASS")

local minStart = clockRow:find("%[_%]")
resume("monitor_touch", "fakemon", minStart + 1, 2) -- tap inside "[_]"

clockRow = rowText(2)
assert(clockRow:find("%[%^%]"), "minimized app should show a [^] restore button, got: " .. clockRow)
assert(clockRow:find("%[X%]"), "minimized app should still show [X] close, got: " .. clockRow)
assert(not clockRow:find("%[_%]"), "minimized app should no longer show [_] minimize, got: " .. clockRow)
local function isRunning(name)
    for _, t in ipairs(fleetos.list()) do
        if t.name == name then return true end
    end
    return false
end
assert(isRunning("clock"), "minimizing must not stop the app")
print("Test 3: tapping [_] minimizes (app keeps running) - PASS")

local restoreStart = clockRow:find("%[%^%]")
resume("monitor_touch", "fakemon", restoreStart + 1, 2) -- tap inside "[^]"

clockRow = rowText(2)
assert(clockRow:find("%[_%]"), "restored app should show [_] minimize again, got: " .. clockRow)
assert(isRunning("clock"), "restoring must not stop the app")
print("Test 4: tapping [^] restores - PASS")

local closeStart = clockRow:find("%[X%]")
resume("monitor_touch", "fakemon", closeStart + 1, 2) -- tap inside "[X]"

assert(not isRunning("clock"), "tapping [X] should stop the app")
clockRow = rowText(2)
assert(clockRow:find("%[>%]"), "stopped again should show a [>] run button, got: " .. clockRow)
print("Test 5: tapping [X] closes the app - PASS")

local runStart = clockRow:find("%[>%]")
resume("monitor_touch", "fakemon", runStart + 1, 2) -- tap inside "[>]"

assert(isRunning("clock"), "tapping [>] should start the app")
print("Test 6: tapping [>] runs the app - PASS")

-- header row toggles collapse (row 1, untouched by app-row logic above)
local headerBefore = rowText(1)
assert(headerBefore:find("running"), "expected the running count in the header, got: " .. headerBefore)
resume("monitor_touch", "fakemon", 1, 1)
local headerAfter = rowText(1)
assert(headerAfter:find("collapsed"), "expected the header to say collapsed, got: " .. headerAfter)
-- collapsed hides the app-list ROWS (replaced by a full-height log tail,
-- not literal blank space) - row 2 now shows log content (clock's own
-- "[clock] HH:MM" prints) instead of an app row with a run/minimize/close
-- button, so its absence is what proves the app list is gone
assert(not rowText(2):find("%[_%]") and not rowText(2):find("%[>%]"),
    "collapsed view should hide app rows/buttons, got: " .. rowText(2))
print("Test 7: tapping the header collapses the app list - PASS")

resume("monitor_touch", "fakemon", 1, 1) -- expand again for the next test
assert(rowText(1):find("running"), "expected the header to un-collapse")

-- regression check: a task can stop either by being explicitly killed OR
-- by its own coroutine finishing/crashing on its own (tick()'s dead-task
-- sweep) - both must forget a minimized flag the same way, or a later
-- respawn under the same name wrongly inherits it. "shell" dies on its
-- own almost immediately under cc_mocks.lua (read() returns nil right
-- away) - perfect for forcing the natural-death path on demand.
fleetos.spawn("shell")
local okMin = fleetos.minimize("shell")
assert(okMin, "expected shell to minimize")
resume("fleetos_tick") -- resumes shell for the first time - it dies naturally (not via kill) within this same tick
assert(not isRunning("shell"), "shell should have died naturally under cc_mocks (read() returns nil)")

fleetos.spawn("shell") -- respawn under the same name, still not yet resumed

-- Force exactly ONE redraw to inspect this moment - tapping clock's own
-- button (row 2, still running from Test 6) as a side channel, since
-- _monitor_mirror (always dispatched first, being ORDER[1]) redraws
-- synchronously as part of handling this touch, BEFORE shell gets its own
-- turn later in this same tick to run-and-die again. A SECOND event here
-- would let that happen first and hide the very moment being checked.
local clockRow = rowText(2)
local clockMinStart = clockRow:find("%[_%]")
resume("monitor_touch", "fakemon", clockMinStart + 1, 2) -- tap clock's [_] (harmless side effect, just to force this one redraw)

-- alphabetically: clock, fleetbridge, raytower_master, raytower_slave,
-- shell - shell is the last row (row 6 with these 5 apps + header)
local shellRow = rowText(6)
assert(shellRow:find("shell"), "expected 'shell' on row 6, got: " .. shellRow)
assert(shellRow:find("%[_%]"), "respawned shell should show as running ([_] minimize), not minimized - got: " .. shellRow)
assert(not shellRow:find("%[%^%]"), "respawned shell must NOT inherit the old minimized flag - got: " .. shellRow)
print("Test 8: a stale minimized flag doesn't survive a natural death + respawn - PASS")

print("\nAll monitor button tests passed.")
