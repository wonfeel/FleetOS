-- Verifies fleetos.lua's output capture (print/write mirrored into a
-- buffer) and runShellLine (remote command execution) actually work -
-- the foundation of the remote terminal feature.
-- Run with (cwd must be game/):
--   cd game
--   lua ..\test\test_output_capture.lua

dofile("../test/cc_mocks.lua")

local mainCo = coroutine.create(function()
    dofile("fleetos.lua")
end)

-- boot the kernel (spawns clock+shell from config.lua, prints the banner)
coroutine.resume(mainCo)

local output = fleetos.getOutput()
assert(#output > 0, "expected some captured output after boot")

local foundBanner = false
for _, line in ipairs(output) do
    if line:find("FleetOS kernel") then foundBanner = true end
end
assert(foundBanner, "expected the boot banner to be in the captured output")
print("Test 1: boot output captured - PASS")

-- runShellLine("list") is a built-in kernel command (handled directly,
-- never reaches shell.run) - it should echo the line and print each task
local ok = fleetos.runShellLine("list")
assert(ok, "runShellLine should report success for the built-in 'list' command")

local output2 = fleetos.getOutput()
local foundEcho, foundTask = false, false
for _, line in ipairs(output2) do
    if line == "> list" then foundEcho = true end
    if line:find("shell") and line:find("suspended") then foundTask = true end
end
assert(foundEcho, "expected '> list' echo line in output")
assert(foundTask, "expected 'list' to print the running shell task")
print("Test 2: runShellLine executes + captures output - PASS")

-- a real CraftOS program (not a kernel built-in) still falls through to
-- the mocked shell.run
local ok3 = fleetos.runShellLine("reboot")
assert(ok3, "runShellLine should report success for the mocked shell.run")
local output3 = fleetos.getOutput()
local foundMockRun = false
for _, line in ipairs(output3) do
    if line:find("%[shell%.run%] reboot") then foundMockRun = true end
end
assert(foundMockRun, "expected a non-kernel command to fall through to shell.run")
print("Test 2b: non-kernel commands fall through to shell.run - PASS")

-- getOutput(n) returns only the last n lines
local last2 = fleetos.getOutput(2)
assert(#last2 == 2, "expected exactly 2 lines, got " .. #last2)
assert(last2[2] == output3[#output3], "getOutput(n) should return the MOST RECENT n lines")
print("Test 3: getOutput(n) truncation - PASS")

print("\nAll output-capture tests passed.")
