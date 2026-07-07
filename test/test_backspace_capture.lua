-- Reproduces the reported bug: "when I erase text, the text on the
-- console doesn't get erased" - i.e. the monitor mirror / dashboard
-- Terminal panel (both driven by fleetos.getOutput()/getColoredOutput())
-- kept showing leftover garbage after backspacing, even though the real
-- in-game screen was fine.
--
-- Root cause: real CraftOS's read() edits the input line IN PLACE -
-- backspacing does term.setCursorPos(back to start of input) then
-- term.write(a shorter string + a trailing blank to erase the old last
-- character), it never prints a fresh line. The old capture code only
-- ever appended text to currentLine, so a backspace redraw just piled
-- more text onto the end of the buffer instead of overwriting.
--
-- test/cc_mocks.lua's term table has no getCursorPos, so fleetos.lua
-- falls back to a constant (1, 1) - fine for this test, since we just
-- keep every setCursorPos call on "row 1" to match, exactly like a real
-- single-line shell prompt would.
--
-- Run with (cwd must be game/):
--   cd game
--   lua ../test/test_backspace_capture.lua

dofile("../test/cc_mocks.lua")

local mainCo = coroutine.create(function()
    dofile("fleetos.lua")
end)
coroutine.resume(mainCo) -- boot up to the kernel's own event-wait

-- start a fresh line, like a shell prompt
term.clear()

-- "shell> " prompt, then the user types "h", "e"
term.write("shell> ")
term.write("h")
term.write("e")

-- NOTE: uses io.write (not print/write) for its own status lines - print()
-- is hooked by fleetos.lua and, being newline-terminated, would flush the
-- very "in progress" shell line this test is trying to inspect, corrupting
-- the exact state under test.
local function status(msg) io.write(msg .. "\n") end

local beforeBackspace = fleetos.getOutput()
assert(beforeBackspace[#beforeBackspace] == "shell> he", "expected 'shell> he' before backspacing, got: " .. tostring(beforeBackspace[#beforeBackspace]))
status("Test 1: typed line captured correctly - PASS")

-- real read()'s backspace redraw: move back to the start of input, write
-- the shorter line PLUS a trailing blank (to erase the old last char),
-- then move the cursor back to just after the remaining text
term.setCursorPos(8, 1) -- column 8 = right after "shell> "
term.write("h ")        -- "h" remains, trailing space erases the old "e"
term.setCursorPos(9, 1)

local afterBackspace = fleetos.getOutput()
local lastLine = afterBackspace[#afterBackspace]
assert(lastLine == "shell> h ", "expected the erased 'e' to be gone (got: " .. string.format("%q", lastLine) .. ") - backspacing must OVERWRITE at the cursor column, not append")
assert(not lastLine:find("shell> he"), "leftover 'he' found - the old character wasn't actually erased")
status("Test 2: backspace overwrites in place instead of appending - PASS")

-- backspace again down to just "shell> "
term.setCursorPos(8, 1)
term.write(" ") -- erase the "h", nothing left to keep
term.setCursorPos(8, 1)

-- exactly 1 trailing blank would require read() to shrink the row, which
-- real terminals never do either - it just stops mattering because
-- nothing renders past where the cursor sits (column 8). What matters is
-- the prompt is intact and no leftover "h"/"e" characters survived.
local afterSecondBackspace = fleetos.getOutput()
local finalLine = afterSecondBackspace[#afterSecondBackspace]
assert(finalLine:sub(1, 7) == "shell> ", "expected the prompt intact, got: " .. string.format("%q", finalLine))
assert(finalLine:sub(8):match("^%s*$"), "expected only blanks after the prompt, got: " .. string.format("%q", finalLine))
status("Test 3: repeated backspacing keeps overwriting correctly - PASS")

-- colored segments should reconstruct the same plain text (regression
-- check for the currentColors/buildSegments refactor)
local coloredOut = fleetos.getColoredOutput()
local segments = coloredOut[#coloredOut]
local rebuilt = ""
for _, seg in ipairs(segments) do rebuilt = rebuilt .. seg.text end
assert(rebuilt == finalLine, "getColoredOutput's segments should rebuild to the same text as getOutput, got: " .. string.format("%q", rebuilt))
status("Test 4: colored segments match plain output - PASS")

print("\nAll backspace-capture tests passed.")
