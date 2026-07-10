-- Unit tests for fleetos.getOutputSince (the delta view apps/common/
-- fleetbridge.lua's report() uses instead of resending the last 150 lines
-- every cycle - see game/fleetos.lua's own comment on it). Run with (cwd
-- must be game/):
--   cd game
--   lua ../test/test_output_diet.lua

dofile("../test/cc_mocks.lua")

-- hide the real config.lua so boot() doesn't auto-spawn shell/fleetbridge -
-- same trick test_ipc.lua/test_monitor_buttons.lua use, noise this test
-- doesn't need.
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

-- Test 1: a cursor of 0 (never asked before) gets everything flushed so far.
do
    fleetos.spawn("printer1", function()
        print("hello")
        print("world")
    end)
    resume("fleetos_tick")

    local newLines, cursor = fleetos.getOutputSince(0)
    local found = 0
    for _, line in ipairs(newLines) do
        if line == "hello" or line == "world" then found = found + 1 end
    end
    assertEq(found, 2, "first getOutputSince(0) should include both new lines")
    assertEq(cursor > 0, true, "cursor should advance past 0")
    print("Test 1: getOutputSince(0) returns everything flushed so far - PASS")
end

-- Test 2: calling again with the cursor just returned yields no new lines
-- until something new is actually printed.
do
    local _, cursor1 = fleetos.getOutputSince(0)
    local newLines2, cursor2 = fleetos.getOutputSince(cursor1)
    assertEq(#newLines2, 0, "no new lines between two calls with nothing printed in between")
    assertEq(cursor2, cursor1, "cursor shouldn't move if nothing new was flushed")
    print("Test 2: repeat calls with an unchanged cursor return no new lines - PASS")
end

-- Test 3: a line printed AFTER a cursor was taken shows up on the next
-- call, and only that line (not everything again).
do
    local _, cursorBefore = fleetos.getOutputSince(0)

    fleetos.spawn("printer2", function()
        print("only this one is new")
    end)
    resume("fleetos_tick")

    local newLines, cursorAfter = fleetos.getOutputSince(cursorBefore)
    assertEq(#newLines, 1, "exactly one new line since cursorBefore")
    assertEq(newLines[1], "only this one is new", "the new line's content")
    assertEq(cursorAfter > cursorBefore, true, "cursor should advance again")
    print("Test 3: only genuinely new lines are returned, not a resend - PASS")
end

-- Test 4: an in-progress (not yet newline-terminated) line shows up as
-- `tail`, every call, without ever appearing in `newLines` - report()
-- relies on this to show a live "shell> "-style prompt without treating it
-- as a completed, appendable line.
do
    fleetos.spawn("writer", function()
        write("partial line, no newline yet")
    end)
    resume("fleetos_tick")

    local _, cursor = fleetos.getOutputSince(0)
    local newLines, _, tail = fleetos.getOutputSince(cursor)
    assertEq(#newLines, 0, "an in-progress line must not appear in newLines")
    assertEq(tail, "partial line, no newline yet", "tail should reflect the in-progress line")
    print("Test 4: in-progress line surfaces only via tail, never newLines - PASS")
end

print("\nAll output-diet tests passed.")
