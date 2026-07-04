-- Stage 1: kernel - cooperative multitasking on coroutines + program manager.
-- Programs live in /apps/<name>.lua and are started with spawn(name).
--
-- Usage from CraftOS shell:
--   fleetos              -- boots the kernel, runs configured startup apps, shows task list UI
--
-- Fresh computer with nothing installed yet? Use install.lua's bootstrap
-- loader (served at /install.lua) instead of fetching this file directly
-- - see that file's header.

local RUNNING = {}   -- name -> { co = coroutine, filter = eventFilter or nil }
local ORDER = {}      -- insertion order, for stable UI listing
local CURRENT = nil   -- name of the task presently being resumed (nil outside tick())

-- Display-only "minimized" flag per running app, used by the monitor
-- panel (and available to any app/remote command via fleetos.minimize/
-- restore). Purely cosmetic - a minimized app keeps running exactly as
-- before (same as minimizing a real window doesn't pause the process
-- behind it) - tick() below never even looks at this table.
local minimizedApps = {}

local APPS_DIR = "apps"
-- Apps are grouped by who typically needs them - purely a folder
-- convention for browsing/deploying, not a permission boundary. spawn()
-- resolves a bare name like "clock" by checking apps/<name>.lua first
-- (flat, for anything dropped in directly) then each group folder below,
-- so config.lua's startup list and shell's "run <app>" never need a
-- group prefix.
local APP_GROUPS = { "common", "raytower" }

-- ============================================================
-- Output capture - every print()/write() from ANY task (they all share
-- this computer's global environment) is mirrored into a rolling buffer,
-- so a remote terminal (apps/fleetbridge.lua) or the monitor mirror below
-- can show what's actually happening on this computer's screen without
-- being physically in front of it. Colors are captured too (whatever
-- term.setTextColor was last set to), kept in a PARALLEL structure so
-- getOutput()'s plain strings (used by fleetbridge.lua/the dashboard,
-- which don't care about color) stay unchanged.
-- ============================================================

local OUTPUT = {}         -- plain strings, one per completed line
local COLORED = {}        -- parallel: each entry is { {text=,color=}, ... } segments for that line
local MAX_OUTPUT_LINES = 500
local currentLine = ""       -- accumulates text between newlines, e.g. printStatus()
local currentColors = {}     -- currentColors[i] = color of currentLine's i-th character,
                              -- tracked PER CHARACTER (not per chunk) so a cursor-positioned
                              -- rewrite (see cursorCol below) can splice into the middle of
                              -- the line without losing older chunks' colors
local currentColor = colors.white
local cursorCol = 1                          -- 1-based column into currentLine where the
                                              -- next write lands
local lineOriginX, lineOriginY = nil, nil    -- real screen position where currentLine's
                                              -- column 1 is, so term.setCursorPos (below)
                                              -- can be translated into a currentLine column

local realPrint = print
local realWrite = write
local realTermWrite = term.write
local realSetTextColor = term.setTextColor
local realSetCursorPos = term.setCursorPos
local realGetCursorPos = term.getCursorPos or function() return 1, 1 end

-- Splices `text` into currentLine starting at column `col` (1-based),
-- OVERWRITING whatever was already there instead of just appending - a
-- real terminal does the same. This matters because CraftOS's own read()
-- (used for shell input) edits a line IN PLACE: backspacing repositions
-- the cursor to the start of input and rewrites it shorter (plus a
-- trailing blank to erase the old last character) via term.setCursorPos +
-- term.write, it does NOT print a fresh line. The old capture code only
-- ever appended, so every redraw piled onto the end of the buffer forever
-- - the real screen erased the character fine, but OUR capture (and
-- anything mirroring it: the monitor panel, the dashboard's Terminal
-- panel) never did, so backspacing looked broken there even though the
-- real in-game screen was correct.
local function spliceCurrentLine(col, text, color)
    col = math.max(1, math.min(col, #currentLine + 1))
    local before = currentLine:sub(1, col - 1)
    local afterStart = col + #text
    local after = currentLine:sub(afterStart)
    local newColors = {}
    for i = 1, #before do newColors[i] = currentColors[i] end
    for i = 1, #text do newColors[#before + i] = color end
    for i = 1, #after do newColors[#before + #text + i] = currentColors[afterStart + i - 1] end
    currentLine = before .. text .. after
    currentColors = newColors
end

-- Groups currentColors into {text=,color=} runs - COLORED/getColoredOutput/
-- the monitor panel all want this shape, not a per-character array.
local function buildSegments(line, colorsArr)
    local segments = {}
    local i = 1
    while i <= #line do
        local c = colorsArr[i] or colors.white
        local j = i
        while j + 1 <= #line and (colorsArr[j + 1] or colors.white) == c do j = j + 1 end
        segments[#segments + 1] = { text = line:sub(i, j), color = c }
        i = j + 1
    end
    return segments
end

local function flushLine()
    OUTPUT[#OUTPUT + 1] = currentLine
    COLORED[#COLORED + 1] = buildSegments(currentLine, currentColors)
    currentLine = ""
    currentColors = {}
    cursorCol = 1
    lineOriginX, lineOriginY = nil, nil
    while #OUTPUT > MAX_OUTPUT_LINES do
        table.remove(OUTPUT, 1)
        table.remove(COLORED, 1)
    end
end

-- Splices raw text (no assumed trailing newline) into the capture buffer
-- at the current cursor column, splitting into OUTPUT/COLORED lines
-- wherever a newline actually appears in `text`.
local function appendRaw(text, color)
    if text == "" then return end
    local pos = 1
    while true do
        local nlPos = text:find("\n", pos, true)
        local chunk = text:sub(pos, nlPos and (nlPos - 1) or nil)
        if chunk ~= "" then
            if currentLine == "" then
                -- fresh line: whatever the real cursor is at right now
                -- (before this write happens) is column 1 of this line
                lineOriginX, lineOriginY = realGetCursorPos()
                cursorCol = 1
            end
            spliceCurrentLine(cursorCol, chunk, color)
            cursorCol = cursorCol + #chunk
        end
        if not nlPos then break end
        flushLine()
        pos = nlPos + 1
    end
end

-- builds the "last n entries, including the in-progress one" view shared
-- by getOutput() and getColoredOutput() - `all`/`current` are whichever
-- pair (OUTPUT/currentLine or COLORED/buildSegments(...)) the caller wants
local function tailWithCurrent(all, current, isEmpty, n)
    local list = all
    if not isEmpty then
        list = {}
        for i = 1, #all do list[i] = all[i] end
        list[#list + 1] = current
    end
    if not n or n >= #list then return list end
    local out = {}
    for i = #list - n + 1, #list do out[#out + 1] = list[i] end
    return out
end

-- Real CraftOS's bios print()/write() are plain Lua functions that
-- internally call the GLOBAL write()/term.write() to do the actual
-- drawing - which by the time realPrint/realWrite below run, ARE these
-- very hooks (already reassigned). Without a guard, calling realPrint(...)
-- would recurse back into our own write()/term.write() hooks for the same
-- text, capturing every line twice (this doesn't show up under
-- test/cc_mocks.lua or windows/craftos_shim.lua, since those don't wire
-- print/write/term.write together - only real CraftOS does). `capturing`
-- stays true for the whole nested call, so only the outermost hook that
-- set it actually appends - inner ones still call through to the real
-- renderer, they just skip re-capturing what's already captured.
local capturing = false

_G.print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[#parts + 1] = tostring((select(i, ...)))
    end
    local wasCapturing = capturing
    if not wasCapturing then
        capturing = true
        appendRaw(table.concat(parts, "\t") .. "\n", currentColor)
    end
    local results = table.pack(realPrint(...))
    if not wasCapturing then capturing = false end
    return table.unpack(results, 1, results.n)
end

_G.write = function(text)
    local wasCapturing = capturing
    if not wasCapturing then
        capturing = true
        appendRaw(tostring(text), currentColor)
    end
    local results = table.pack(realWrite(text))
    if not wasCapturing then capturing = false end
    return table.unpack(results, 1, results.n)
end

term.write = function(text)
    local wasCapturing = capturing
    if not wasCapturing then
        capturing = true
        appendRaw(tostring(text), currentColor)
    end
    local results = table.pack(realTermWrite(text))
    if not wasCapturing then capturing = false end
    return table.unpack(results, 1, results.n)
end

term.setTextColor = function(color)
    currentColor = color
    return realSetTextColor(color)
end
if term.setTextColour then term.setTextColour = term.setTextColor end

-- Tracks where an in-place line redraw (see spliceCurrentLine above) is
-- about to write, by translating the real (x, y) into a column within
-- currentLine - but only when y matches the row currentLine started on
-- (lineOriginY); a setCursorPos to some unrelated row isn't part of
-- editing this line, so it's left alone (the next fresh line will
-- re-capture its own origin from scratch via appendRaw).
term.setCursorPos = function(x, y)
    if lineOriginY and y == lineOriginY and currentLine ~= "" then
        cursorCol = math.max(1, math.min(x - lineOriginX + 1, #currentLine + 1))
    end
    return realSetCursorPos(x, y)
end

-- Clearing the real screen didn't clear OUR captured scrollback, so a
-- monitor mirroring it (or a remote terminal) kept showing everything
-- from before the clear - wipe the capture buffer in step with the
-- actual screen.
local realTermClear = term.clear
term.clear = function()
    OUTPUT = {}
    COLORED = {}
    currentLine = ""
    currentColors = {}
    cursorCol = 1
    lineOriginX, lineOriginY = nil, nil
    return realTermClear()
end

-- ============================================================
-- Program manager
-- ============================================================

-- Finds the real file for a bare app name, checking the flat apps/
-- folder first, then each group folder in turn. Returns nil if none exist.
local function resolveAppPath(name)
    local flat = fs.combine(APPS_DIR, name .. ".lua")
    if fs.exists(flat) then return flat end
    for _, group in ipairs(APP_GROUPS) do
        local grouped = fs.combine(APPS_DIR, group .. "/" .. name .. ".lua")
        if fs.exists(grouped) then return grouped end
    end
    return nil
end

-- Lists every app available to run, grouped by folder (in APP_GROUPS
-- order, flat apps/ last since it's the exception, not the norm).
local function listAvailableApps()
    local groups = {}
    if fs.isDir(APPS_DIR) then
        local flatNames = {}
        for _, entry in ipairs(fs.list(APPS_DIR)) do
            if entry:match("%.lua$") and not fs.isDir(fs.combine(APPS_DIR, entry)) then
                flatNames[#flatNames + 1] = entry:gsub("%.lua$", "")
            end
        end
        for _, group in ipairs(APP_GROUPS) do
            local dir = fs.combine(APPS_DIR, group)
            local names = {}
            if fs.isDir(dir) then
                for _, entry in ipairs(fs.list(dir)) do
                    if entry:match("%.lua$") then
                        names[#names + 1] = entry:gsub("%.lua$", "")
                    end
                end
            end
            if #names > 0 then
                table.sort(names)
                groups[#groups + 1] = { name = group, apps = names }
            end
        end
        if #flatNames > 0 then
            table.sort(flatNames)
            groups[#groups + 1] = { name = "other", apps = flatNames }
        end
    end
    return groups
end

local function appExists(name)
    return resolveAppPath(name) ~= nil
end

-- Starts an app as a background task. fnOrName is either a function
-- (ad-hoc task) or a string naming a file in /apps/.
local function spawn(nameOrPath, fnOrNil)
    local name, fn = nameOrPath, fnOrNil

    if not fn then
        local path = resolveAppPath(name)
        if not path then
            return false, "app not found: " .. name
        end
        local ok, loaded = pcall(loadfile, path)
        if not ok or not loaded then
            return false, "failed to load: " .. tostring(loaded)
        end
        fn = loaded
    end

    if RUNNING[name] then
        return false, "already running: " .. name
    end

    local co = coroutine.create(function()
        local ok, err = pcall(fn)
        if not ok then
            print("[" .. name .. "] crashed: " .. tostring(err))
        end
    end)

    RUNNING[name] = { co = co, filter = nil }
    ORDER[#ORDER + 1] = name
    return true
end

-- Shared by kill() and tick()'s dead-task sweep - a task can stop either
-- by being explicitly killed OR by its coroutine finishing/crashing on its
-- own, and both must forget it the same way, so a later respawn under the
-- same name never inherits a stale minimizedApps flag from before.
local function removeTask(name)
    RUNNING[name] = nil
    minimizedApps[name] = nil
    for i, n in ipairs(ORDER) do
        if n == name then table.remove(ORDER, i) break end
    end
end

local function kill(name)
    if not RUNNING[name] then
        return false, "not running: " .. name
    end
    removeTask(name)
    return true
end

local function list()
    local out = {}
    for _, name in ipairs(ORDER) do
        if RUNNING[name] then
            out[#out + 1] = { name = name, status = coroutine.status(RUNNING[name].co) }
        end
    end
    return out
end

-- Windows-style minimize/restore: purely a display flag for the monitor
-- panel (and anything else that wants to show a compact "taskbar" state) -
-- the app keeps running completely unaffected, same as minimizing a real
-- window doesn't pause the process behind it.
local function minimizeApp(name)
    if not RUNNING[name] then return false, "not running: " .. name end
    minimizedApps[name] = true
    return true
end

local function restoreApp(name)
    if not RUNNING[name] then return false, "not running: " .. name end
    minimizedApps[name] = nil
    return true
end

local function taskState(name)
    if not RUNNING[name] then return "stopped" end
    return minimizedApps[name] and "minimized" or "running"
end

-- ============================================================
-- Scheduler - resumes every live task on each OS event
-- ============================================================

local function tick(event)
    local dead = {}
    for _, name in ipairs(ORDER) do
        local task = RUNNING[name]
        if task then
            local status = coroutine.status(task.co)
            if status == "dead" then
                dead[#dead + 1] = name
            elseif task.filter == nil or task.filter == event[1] then
                CURRENT = name
                local ok, filterOrErr = coroutine.resume(task.co, table.unpack(event))
                CURRENT = nil
                if coroutine.status(task.co) == "dead" then
                    if not ok then
                        print("[" .. name .. "] error: " .. tostring(filterOrErr))
                    end
                    dead[#dead + 1] = name
                else
                    -- if the task yielded a string, treat it as an event filter
                    task.filter = (type(filterOrErr) == "string") and filterOrErr or nil
                end
            end
        end
    end

    for _, name in ipairs(dead) do
        removeTask(name)
    end
end

-- ============================================================
-- Startup config: which apps to auto-run, read from config.lua
-- config.lua should return: { id = "...", role = "...", startup = {"app1","app2"} }
-- ============================================================

local function loadConfig()
    if not fs.exists("config.lua") then
        return { startup = {} }
    end
    local ok, cfg = pcall(dofile, "config.lua")
    if ok and type(cfg) == "table" then return cfg end
    return { startup = {} }
end

-- ============================================================
-- Kernel shell - press keys to list/kill tasks without stopping the loop
-- ============================================================

local STATUS_COLOR = {
    running = colors.lime,
    suspended = colors.yellow,
    dead = colors.red,
}

local function printStatus()
    term.clear()
    term.setCursorPos(1, 1)
    term.setTextColor(colors.yellow)
    print("FleetOS kernel - " .. #ORDER .. " task(s) running")
    term.setTextColor(colors.white)
    print(string.rep("-", 30))
    for _, t in ipairs(list()) do
        term.write(("  %-16s "):format(t.name))
        term.setTextColor(STATUS_COLOR[t.status] or colors.white)
        print(t.status)
        term.setTextColor(colors.white)
    end
    print(string.rep("-", 30))
    print("Run the 'shell' app (list/run/kill) to manage tasks interactively.")

    -- pcall'd: fs.list/isDir aren't implemented by every shim this runs
    -- under (see test/cc_mocks.lua, windows/craftos_shim.lua) - a gap
    -- there shouldn't be able to take down the whole boot sequence.
    local ok, groups = pcall(listAvailableApps)
    if ok and #groups > 0 then
        print("Apps you can 'run':")
        for _, g in ipairs(groups) do
            print("  [" .. g.name .. "] " .. table.concat(g.apps, ", "))
        end
    end
end

-- ============================================================
-- Monitor mirror - if a "monitor" peripheral is attached and no app has
-- claimed it for its own display (e.g. apps/raytower/raytower_master.lua
-- draws its own layout), shows a small task panel (tap a line to run/kill
-- it - Advanced Monitors only, monitor_touch never fires on a basic one)
-- plus a tail of the recent colored terminal output below it. Claims are
-- tracked by task name, not a raw flag, so a claiming app that crashes or
-- gets killed automatically releases the monitor next tick.
-- ============================================================

local monitorClaimedBy = nil

-- Per-state title-bar-style button clusters, right-aligned like a Windows
-- window's [_][X] - every app gets SOME control here regardless of state
-- (stopped just gets a run button instead of nothing), so there's always
-- a consistent right-hand control area, not just on running apps.
local STATE_ICON = { running = ">", minimized = "_", stopped = " " }
local STATE_COLOR = { running = colors.lime, minimized = colors.lightGray, stopped = colors.gray }
local STATE_BUTTONS = {
    stopped = { { text = "[>]", color = colors.lime, action = "run" } },
    running = {
        { text = "[_]", color = colors.yellow, action = "minimize" },
        { text = "[X]", color = colors.red, action = "close" },
    },
    minimized = {
        { text = "[^]", color = colors.cyan, action = "restore" },
        { text = "[X]", color = colors.red, action = "close" },
    },
}

-- draws the panel, returns rowApp: row -> { name, buttons = {{action,from,to},...} }
-- so a monitor_touch's (x, y) can be mapped to the right action - tapping
-- a button runs/minimizes/restores/closes that one app, tapping elsewhere
-- on a row does nothing (so a stray tap can't kill something). When
-- collapsed, the app list is hidden entirely (just the header + a
-- full-height terminal log) - tap the header row to toggle. Row 1 (the
-- header) is never in rowApp, monitorMirrorLoop's touch handler
-- special-cases it for that reason.
local function drawMonitorPanel(mon, collapsed)
    local w, h = mon.getSize()
    mon.setBackgroundColor(colors.black)
    mon.clear()

    local row = 1
    mon.setCursorPos(1, row)
    mon.setTextColor(colors.yellow)
    local header = collapsed and "FleetOS (collapsed)" or ("FleetOS - %d running"):format(#ORDER)
    mon.write(header:sub(1, w))
    row = row + 1

    local rowApp = {}

    if not collapsed then
        local ok, groups = pcall(listAvailableApps)
        local names, seen = {}, {}
        if ok then
            for _, g in ipairs(groups) do
                for _, n in ipairs(g.apps) do
                    if not seen[n] then
                        seen[n] = true
                        names[#names + 1] = n
                    end
                end
            end
            table.sort(names)
        end

        for _, name in ipairs(names) do
            if row > h - 1 then break end -- leave room for at least one log line below
            local state = taskState(name)
            local buttons = STATE_BUTTONS[state]
            local btnWidth = 0
            for _, b in ipairs(buttons) do btnWidth = btnWidth + #b.text end

            local nameWidth = math.max(0, w - btnWidth - 2)
            local nameText = name:sub(1, nameWidth)
            nameText = nameText .. string.rep(" ", nameWidth - #nameText)

            mon.setCursorPos(1, row)
            mon.setTextColor(STATE_COLOR[state])
            mon.write((STATE_ICON[state] .. " " .. nameText):sub(1, w))

            local btnRanges = {}
            if w >= btnWidth then
                local x = w - btnWidth + 1
                for _, b in ipairs(buttons) do
                    mon.setCursorPos(x, row)
                    mon.setTextColor(b.color)
                    mon.write(b.text)
                    btnRanges[#btnRanges + 1] = { action = b.action, from = x, to = x + #b.text - 1 }
                    x = x + #b.text
                end
            end

            rowApp[row] = { name = name, buttons = btnRanges }
            row = row + 1
        end

        mon.setTextColor(colors.gray)
        mon.setCursorPos(1, row)
        mon.write(string.rep("-", w))
        row = row + 1
    end

    if row <= h then
        local logLines = tailWithCurrent(COLORED, buildSegments(currentLine, currentColors), currentLine == "", h - row + 1)
        for _, segments in ipairs(logLines) do
            if row > h then break end
            mon.setCursorPos(1, row)
            local col = 1
            for _, seg in ipairs(segments) do
                if col > w then break end
                local text = seg.text:sub(1, w - col + 1)
                mon.setTextColor(seg.color or colors.white)
                mon.write(text)
                col = col + #text
            end
            row = row + 1
        end
    end

    mon.setTextColor(colors.white)
    return rowApp
end

local ROW_ACTION = {
    run = function(name) spawn(name) end,
    close = function(name) kill(name) end,
    minimize = function(name) minimizeApp(name) end,
    restore = function(name) restoreApp(name) end,
}

local function monitorMirrorLoop()
    local rowApp = {}
    local monName = nil
    local collapsed = false

    local function redraw()
        local claimed = monitorClaimedBy ~= nil and RUNNING[monitorClaimedBy] ~= nil
        local mon = peripheral.find("monitor")
        if mon and not claimed then
            monName = peripheral.getName(mon)
            local ok, result = pcall(drawMonitorPanel, mon, collapsed)
            rowApp = ok and result or {}
        else
            monName = nil
            rowApp = {}
        end
    end

    local timerId = os.startTimer(1)
    redraw()

    while true do
        local event = { os.pullEventRaw() }
        if event[1] == "timer" and event[2] == timerId then
            timerId = os.startTimer(1)
            redraw()
        elseif event[1] == "monitor_touch" and event[2] == monName and event[4] == 1 then
            collapsed = not collapsed
            redraw()
        elseif event[1] == "monitor_touch" and event[2] == monName then
            local x, y = event[3], event[4]
            local info = rowApp[y]
            if info then
                for _, b in ipairs(info.buttons) do
                    if x >= b.from and x <= b.to then
                        ROW_ACTION[b.action](info.name)
                        redraw()
                        break
                    end
                end
            end
        end
    end
end

-- ============================================================
-- Entry point
-- ============================================================

local function boot()
    if not fs.exists(APPS_DIR) then
        fs.makeDir(APPS_DIR)
    end

    local cfg = loadConfig()
    for _, appName in ipairs(cfg.startup or {}) do
        local ok, err = spawn(appName)
        if not ok then
            print("startup: " .. tostring(err))
        end
    end

    spawn("_monitor_mirror", monitorMirrorLoop)

    printStatus()

    while true do
        local event = { os.pullEventRaw() }
        if event[1] == "terminate" then
            print("FleetOS: terminate received, stopping all tasks.")
            break
        end
        tick(event)
    end
end

-- expose kernel API to spawned apps via a global table, since apps are
-- loaded with loadfile (fresh env) rather than required as modules
_G.fleetos = {
    spawn = spawn,
    kill = kill,
    list = list,
    -- Windows-style minimize/restore - display-only, doesn't touch
    -- scheduling (see minimizedApps above). Exposed here so any control
    -- surface (monitor taps, shell.lua, the dashboard's "type" command)
    -- can use it, not just the monitor panel.
    minimize = minimizeApp,
    restore = restoreApp,
    listAvailableApps = listAvailableApps,
    -- resolves where an app's file lives (its existing group folder if
    -- any), or where a brand new one should be created (flat apps/) -
    -- used by fleetbridge.lua's deploy/rollback so it writes to the same
    -- place spawn() will look for it.
    appPath = function(name)
        return resolveAppPath(name) or fs.combine(APPS_DIR, name .. ".lua")
    end,
    current = function() return CURRENT end,
    -- Call from within a running app to take over the "monitor"
    -- peripheral for its own display (e.g. raytower_master.lua) - the
    -- kernel's terminal mirror then leaves it alone until this app stops
    -- running (killed, crashed, or exits), no explicit release needed.
    claimMonitor = function() monitorClaimedBy = CURRENT end,
    releaseMonitor = function() if monitorClaimedBy == CURRENT then monitorClaimedBy = nil end end,
    -- returns the last `n` captured output lines (default: all buffered,
    -- up to MAX_OUTPUT_LINES). Includes the current in-progress line (e.g.
    -- a "shell> " prompt still waiting on its newline) so a remote viewer
    -- sees exactly what's really on screen right now.
    getOutput = function(n)
        return tailWithCurrent(OUTPUT, currentLine, currentLine == "", n)
    end,
    -- Same as getOutput(), but each line is a list of {text=, color=}
    -- segments instead of a plain string - lets a monitor (or anything
    -- else that can show color) reproduce this computer's screen
    -- faithfully instead of just white-on-black text.
    getColoredOutput = function(n)
        return tailWithCurrent(COLORED, buildSegments(currentLine, currentColors), currentLine == "", n)
    end,
    -- Runs a line of text from a remote terminal (the web dashboard's
    -- "type" command, or apps/common/shell.lua's own prompt). First tries
    -- it as a kernel command (list/run/kill/status/apps) - these aren't
    -- real CraftOS programs, so shell.run("kill clock") would otherwise
    -- fail with "No such program". Anything else falls through to
    -- shell.run so real programs (ls, reboot, fleetos, ...) still work.
    -- Output goes through the same capture as everything else.
    runShellLine = function(line)
        appendRaw("> " .. line .. "\n")

        local parts = {}
        for w in line:gmatch("%S+") do parts[#parts + 1] = w end
        local cmd = parts[1]

        if cmd == "list" or cmd == "status" then
            for _, t in ipairs(list()) do
                print(("  %-16s %s"):format(t.name, t.status))
            end
            return true

        elseif cmd == "run" then
            if not parts[2] then print("Usage: run <app>"); return false, "usage" end
            local ok, err = spawn(parts[2])
            print(ok and ("started " .. parts[2]) or ("error: " .. tostring(err)))
            return ok, err

        elseif cmd == "kill" then
            if not parts[2] then print("Usage: kill <app>"); return false, "usage" end
            local ok, err = kill(parts[2])
            print(ok and ("stopped " .. parts[2]) or ("error: " .. tostring(err)))
            return ok, err

        elseif cmd == "minimize" then
            if not parts[2] then print("Usage: minimize <app>"); return false, "usage" end
            local ok, err = minimizeApp(parts[2])
            print(ok and ("minimized " .. parts[2]) or ("error: " .. tostring(err)))
            return ok, err

        elseif cmd == "restore" then
            if not parts[2] then print("Usage: restore <app>"); return false, "usage" end
            local ok, err = restoreApp(parts[2])
            print(ok and ("restored " .. parts[2]) or ("error: " .. tostring(err)))
            return ok, err

        elseif cmd == "apps" then
            for _, g in ipairs(listAvailableApps()) do
                print("  [" .. g.name .. "] " .. table.concat(g.apps, ", "))
            end
            return true
        end

        local ok, err = pcall(function() shell.run(line) end)
        if not ok then appendRaw("error: " .. tostring(err) .. "\n") end
        return ok, err
    end,
}

boot()
