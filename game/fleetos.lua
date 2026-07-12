-- fleetos.lua
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

-- Which task (if any) currently owns the monitor for its own full-screen
-- drawing (claimMonitor()/releaseMonitor(), exposed on the API table) -
-- forward-declared here (not down in the "Monitor mirror" section where it
-- conceptually lives) because removeTask() above needs to clear it when a
-- claiming app is killed, so a dead app can't leave the monitor stuck
-- showing its last frame with no way back to the FleetOS panel.
local monitorClaimedBy = nil
-- name -> true while a claiming app is minimized (monitorClaimedBy forced
-- nil so the FleetOS panel takes over) - restoreApp() uses this to know to
-- hand the claim back rather than just clearing the minimized flag.
local claimBeforeMinimize = {}

local APPS_DIR = "apps"
-- Apps are grouped by who typically needs them - purely a folder
-- convention for browsing/deploying, not a permission boundary. spawn()
-- resolves a bare name like "clock" by checking apps/<name>.lua first
-- (flat, for anything dropped in directly) then each group folder below,
-- so config.lua's startup list and shell's "run <app>" never need a
-- group prefix.
local APP_GROUPS = { "common", "raytower" }

-- ============================================================
-- Output capture - every print()/write() from ANY task is mirrored into a
-- rolling buffer, so a remote terminal (fleetbridge.lua) or the monitor
-- mirror can show this screen without being physically in front of it.
-- Colors captured in a PARALLEL structure so getOutput()'s plain strings
-- (fleetbridge.lua/dashboard, which don't care about color) stay unchanged.
-- ============================================================

local OUTPUT = {}         -- plain strings, one per completed line
local COLORED = {}        -- parallel: each entry is { {text=,color=}, ... } segments for that line
local MAX_OUTPUT_LINES = 500
-- Total lines ever flushed, monotonic - never reset/decreased even as
-- OUTPUT gets trimmed from the front, so getOutputSince(cursor) has a
-- stable handle that doesn't drift as array indices shift.
local outputSeq = 0
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
    outputSeq = outputSeq + 1
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

-- Delta view for a low-bandwidth caller (fleetbridge.lua's report()) that
-- would otherwise resend the same ~150 lines every cycle. `cursor` is a
-- previously-returned outputSeq (0 first time). Returns newLines (complete
-- lines since cursor), newCursor, and tail (the in-progress line right
-- now, e.g. a "shell> " prompt still waiting on Enter - returned fresh
-- every call since it changes without ever flushing a completed line).
-- Cursor older than the oldest line still held -> falls back to returning
-- everything, same as getOutput().
local function getOutputSince(cursor)
    cursor = cursor or 0
    local oldestKeptSeq = outputSeq - #OUTPUT + 1
    local newLines
    if cursor >= outputSeq then
        newLines = {}
    elseif cursor < oldestKeptSeq - 1 then
        newLines = OUTPUT
    else
        local startIdx = cursor - oldestKeptSeq + 2
        newLines = {}
        for i = startIdx, #OUTPUT do newLines[#newLines + 1] = OUTPUT[i] end
    end
    return newLines, outputSeq, currentLine
end

-- Real CraftOS's print()/write() call the GLOBAL write()/term.write() to
-- draw - which by the time realPrint/realWrite run below, ARE these hooks
-- (already reassigned). Without a guard, realPrint(...) would recurse back
-- into our own hooks, capturing every line twice (doesn't show up under
-- the mocks/shim, only real CraftOS). `capturing` stays true for the whole
-- nested call so only the outermost hook actually appends.
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
-- Monitor capture - mirrors whatever gets drawn onto a REAL "monitor"
-- peripheral into a virtual grid, the same way print()/write() above
-- mirror the terminal into OUTPUT/COLORED - so a monitor's contents
-- (FleetOS's own monitor panel below, or an app's own monitor UI like
-- apps/raytower/raytower_master.lua) can be shown on the dashboard without
-- needing eyes on the physical block in-game. Hooked once, globally, at
-- peripheral.find - every method on the returned wrapper forwards to the
-- real monitor UNCHANGED (in-game visuals are completely unaffected) and
-- also updates MONITOR_GRID. Only foreground (text) color is tracked per
-- character - background is one solid color set by clear()/
-- setBackgroundColor(), since nothing in this codebase's monitor-drawing
-- code ever varies background per cell (confirmed by grepping every
-- monitor.* call site before writing this) - a deliberate scope call, not
-- an oversight.
-- ============================================================

local MONITOR_GRID = nil        -- { w, h, bg, cx, cy, curFg, cells = {[y]={[x]={ch,fg}}} }
local monitorBlocksCfg = nil    -- optional {w,h} from config.lua's monitorBlocks - see boot() and getMonitorSnapshot below
local monitorProxies = {}       -- real peripheral name -> memoized wrapper, so repeated
                                 -- peripheral.find("monitor") calls (monitorMirrorLoop below
                                 -- polls this every ~1s) don't rebuild the grid each time

local function blankMonitorRow(w)
    local row = {}
    for x = 1, w do row[x] = { ch = " ", fg = colors.white } end
    return row
end

local function ensureMonitorGrid(w, h)
    if not MONITOR_GRID or MONITOR_GRID.w ~= w or MONITOR_GRID.h ~= h then
        local cells = {}
        for y = 1, h do cells[y] = blankMonitorRow(w) end
        MONITOR_GRID = { w = w, h = h, bg = colors.black, cx = 1, cy = 1, curFg = colors.white, cells = cells }
    end
end

-- Converts one grid row into {text=,color=} runs - same shape buildSegments()
-- above already produces for terminal lines, so the dashboard's rendering
-- code (and anything else consuming COLORED-shaped data) can treat a
-- monitor snapshot's rows identically to a terminal's.
local function monitorRowSegments(row, w)
    local segments = {}
    local i = 1
    while i <= w do
        local c = row[i] and row[i].fg or colors.white
        local j = i
        while j + 1 <= w and (row[j + 1] and row[j + 1].fg or colors.white) == c do j = j + 1 end
        local chars = {}
        for k = i, j do chars[#chars + 1] = row[k] and row[k].ch or " " end
        segments[#segments + 1] = { text = table.concat(chars), color = c }
        i = j + 1
    end
    return segments
end

-- Real CC:Tweaked derives a monitor's character grid from its physical
-- block size (in-world) via TileMonitor.rebuildTerminal() (see
-- reference/ComputerCraft-1.79/.../TileMonitor.java, the actual Java
-- source this formula is transcribed from):
--   termWidth  = round((blocksWide - 2*(BORDER+MARGIN)) / (textScale*6*PIXEL_SCALE))
--   termHeight = round((blocksTall - 2*(BORDER+MARGIN)) / (textScale*9*PIXEL_SCALE))
-- with BORDER=2/16, MARGIN=0.5/16, PIXEL_SCALE=1/64 blocks. Inverting it
-- recovers the real physical block dimensions from getSize()+getTextScale()
-- alone - no manual config field needed, and it auto-updates if the
-- monitor is physically resized in-game (more/fewer blocks) since it's
-- recomputed from live values every time, not cached from boot.
-- Confirmed against a live node: w=50, h=26, textScale=1 -> blocks 5x4
-- (aspect 1.25) - notably NOT the 7x4 guessed by eye from an angled 3D
-- screenshot, which is exactly the kind of error this formula avoids.
local BORDER_PLUS_MARGIN = (2.0 / 16.0) + (0.5 / 16.0)
local PIXEL_SCALE = 1.0 / 64.0

local function computeMonitorBlocks(termW, termH, textScale)
    local ts = textScale or 1.0
    local blocksWide = termW * ts * 6.0 * PIXEL_SCALE + 2.0 * BORDER_PLUS_MARGIN
    local blocksTall = termH * ts * 9.0 * PIXEL_SCALE + 2.0 * BORDER_PLUS_MARGIN
    return math.floor(blocksWide + 0.5), math.floor(blocksTall + 0.5)
end

local function wrapMonitor(realMon)
    local name = peripheral.getName(realMon)

    -- Recomputed on every call (not just the first wrap) even for an
    -- already-memoized proxy below - a real monitor keeps the same
    -- peripheral name across an in-game resize (it's the same multiblock
    -- structure gaining/losing blocks), so this is the only way physical
    -- size changes get picked up without a reboot.
    do
        local w, h = realMon.getSize()
        ensureMonitorGrid(w, h)
        local ok, ts = pcall(realMon.getTextScale)
        local bw, bh = computeMonitorBlocks(w, h, ok and ts or 1.0)
        MONITOR_GRID.blockW, MONITOR_GRID.blockH = bw, bh
    end

    local existing = monitorProxies[name]
    if existing then return existing end

    local proxy = {}
    -- Real peripheral.getName() identifies a wrapped peripheral by kernel-
    -- side bookkeeping, not by an object field, and actively ERRORS
    -- ("table is not a peripheral") if handed a plain Lua table like this
    -- proxy instead of a genuine registered peripheral - confirmed live on a
    -- real CC:Tweaked server (this project's own shims are more lenient and
    -- fake peripheral.getName by checking for a `.name` field, which is why
    -- this bug never reproduced against them). Storing the real name here
    -- lets monitorMirrorLoop read `mon.name` directly instead of ever
    -- calling peripheral.getName() on this proxy at all - see its own
    -- comment where it does that.
    proxy.name = name
    proxy.getSize = function() return realMon.getSize() end
    proxy.getCursorPos = function() return realMon.getCursorPos() end
    proxy.isColor = function() return realMon.isColor() end
    proxy.isColour = proxy.isColor
    proxy.setTextScale = function(scale) return realMon.setTextScale(scale) end
    proxy.setCursorPos = function(x, y)
        MONITOR_GRID.cx, MONITOR_GRID.cy = x, y
        return realMon.setCursorPos(x, y)
    end
    proxy.setTextColor = function(c) MONITOR_GRID.curFg = c; return realMon.setTextColor(c) end
    proxy.setTextColour = proxy.setTextColor
    proxy.setBackgroundColor = function(c) MONITOR_GRID.bg = c; return realMon.setBackgroundColor(c) end
    proxy.setBackgroundColour = proxy.setBackgroundColor
    proxy.write = function(text)
        text = tostring(text)
        local g = MONITOR_GRID
        if g.cy >= 1 and g.cy <= g.h then
            local row = g.cells[g.cy]
            for i = 1, #text do
                local x = g.cx + i - 1
                if x >= 1 and x <= g.w then row[x] = { ch = text:sub(i, i), fg = g.curFg } end
            end
            g.cx = g.cx + #text
        end
        return realMon.write(text)
    end
    proxy.clear = function()
        local g = MONITOR_GRID
        for y = 1, g.h do g.cells[y] = blankMonitorRow(g.w) end
        return realMon.clear()
    end
    proxy.clearLine = function()
        local g = MONITOR_GRID
        if g.cy >= 1 and g.cy <= g.h then g.cells[g.cy] = blankMonitorRow(g.w) end
        return realMon.clearLine()
    end
    proxy.scroll = function(n) return realMon.scroll(n) end

    monitorProxies[name] = proxy
    return proxy
end

-- Reserves physical row 1 for the kernel's own title-bar chrome
-- (drawClaimedTitleBar, see the "Monitor mirror" section below) so a
-- claiming app's own row 1 (e.g. raytower_master's "====" border, drawn at
-- its own y=1) never collides with/gets overwritten by the [_][X] bar - the
-- app instead gets a virtual (w, h-1) screen starting one row down, and
-- every coordinate it uses is transparently offset by +1 before reaching
-- the real proxy. Only handed out to the actual claiming app (see
-- peripheral.find below) - the kernel's own _monitor_mirror task still
-- gets the raw, unshifted proxy so it can draw the chrome bar at the real
-- row 1.
local function shiftedMonitorView(proxy, ownerName)
    -- While ownerName is minimized, every write is silently dropped instead
    -- of reaching the real monitor/MONITOR_GRID - a minimized app keeps
    -- running its own loop unaffected (same as elsewhere), but its redraws
    -- no longer fight monitorMirrorLoop's panel for the screen. Before this,
    -- minimizing only cleared monitorClaimedBy (a kernel-side bookkeeping
    -- flag); the app itself kept calling monitor.write() on its own timer
    -- completely unaware of that, so its next redraw would silently pop the
    -- app's screen back up over the panel until the panel's own 1s tick
    -- redrew over it again - a visible flicker/"random" reappearance with
    -- no user action involved.
    local function suppressed() return minimizedApps[ownerName] end

    local shifted = { name = proxy.name }
    shifted.getSize = function()
        local w, h = proxy.getSize()
        return w, h - 1
    end
    shifted.getCursorPos = function()
        local x, y = proxy.getCursorPos()
        return x, y - 1
    end
    shifted.isColor = proxy.isColor
    shifted.isColour = proxy.isColour
    shifted.setTextScale = proxy.setTextScale
    shifted.setCursorPos = function(x, y) if suppressed() then return end return proxy.setCursorPos(x, y + 1) end
    shifted.setTextColor = proxy.setTextColor
    shifted.setTextColour = proxy.setTextColour
    shifted.setBackgroundColor = proxy.setBackgroundColor
    shifted.setBackgroundColour = proxy.setBackgroundColor
    shifted.write = function(text) if suppressed() then return end return proxy.write(text) end
    shifted.clear = function()
        if suppressed() then return end
        -- Can't call proxy.clear() (would wipe the chrome bar's row 1 too) -
        -- clear only the rows the app can actually see, one by one instead.
        local _, h = proxy.getSize()
        for y = 2, h do
            proxy.setCursorPos(1, y)
            proxy.clearLine()
        end
        proxy.setCursorPos(1, 2)
    end
    shifted.clearLine = function() if suppressed() then return end return proxy.clearLine() end
    shifted.scroll = function(n) if suppressed() then return end return proxy.scroll(n) end
    return shifted
end

-- Only "monitor" lookups are wrapped - modems/other peripherals pass
-- through completely untouched, so this can't affect rednet or anything
-- else that calls peripheral.find for a different kind.
local realPeripheralFind = peripheral.find
peripheral.find = function(kind, ...)
    if kind == "monitor" then
        local realMon = realPeripheralFind(kind, ...)
        if not realMon then return nil end
        local proxy = wrapMonitor(realMon)
        -- Every task except the kernel's own monitor-mirror loop gets the
        -- shifted (row-1-reserved) view - covers both the common case (an
        -- app about to claimMonitor() right after this call) and the rare
        -- one (an app peeking at the monitor without claiming it), since
        -- either way _monitor_mirror's unclaimed-panel redraw will already
        -- own row 1 in that second case too.
        if CURRENT ~= "_monitor_mirror" then
            return shiftedMonitorView(proxy, CURRENT)
        end
        return proxy
    end
    return realPeripheralFind(kind, ...)
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
-- A leading underscore marks a shared helper module (e.g.
-- apps/common/_signed_rednet.lua) meant to be dofile()'d directly by its
-- full path, not spawned as a standalone task - same convention
-- windows/compute/_fleetos_world.py already uses for the same reason.
-- Excluded here so it doesn't show up as something you'd "run".
local function isHelperModuleName(name)
    return name:sub(1, 1) == "_"
end

local function listAvailableApps()
    local groups = {}
    if fs.isDir(APPS_DIR) then
        local flatNames = {}
        for _, entry in ipairs(fs.list(APPS_DIR)) do
            if entry:match("%.lua$") and not fs.isDir(fs.combine(APPS_DIR, entry))
                    and not isHelperModuleName(entry) then
                flatNames[#flatNames + 1] = entry:gsub("%.lua$", "")
            end
        end
        for _, group in ipairs(APP_GROUPS) do
            local dir = fs.combine(APPS_DIR, group)
            local names = {}
            if fs.isDir(dir) then
                for _, entry in ipairs(fs.list(dir)) do
                    if entry:match("%.lua$") and not isHelperModuleName(entry) then
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

-- previously there was no way to tell WHICH version of an app's code is
-- actually running on a given node without diffing file contents by hand -
-- a fleet-wide deploy that only reached some nodes (a flaky one missed the
-- command, etc.) was invisible until behavior visibly diverged. Not a real
-- version number (apps have none) - a short content checksum, cheap enough
-- to compute on every report, good enough to tell "same code" from
-- "different code" across nodes at a glance. Not cryptographic - collisions
-- are theoretically possible, just extremely unlikely to matter for this.
local function simpleChecksum(content)
    local sum = 0
    for i = 1, #content do
        sum = (sum * 31 + content:byte(i)) % 0xFFFFFFFF
    end
    return ("%x"):format(sum)
end

local function appVersion(name)
    local path = resolveAppPath(name)
    if not path then return nil end
    local f = fs.open(path, "r")
    if not f then return nil end
    local content = f.readAll()
    f.close()
    return simpleChecksum(content)
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
        local ok, loaded, loadErr = pcall(loadfile, path)
        if not ok or not loaded then
            -- loadfile returns (nil, message) on a syntax error rather than
            -- raising - pcall then reports ok=true with loaded=nil, so the
            -- real reason is loadErr, not whatever pcall itself produced.
            return false, "failed to load: " .. tostring(loadErr or loaded)
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
    if monitorClaimedBy == name then monitorClaimedBy = nil end
    claimBeforeMinimize[name] = nil
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
    -- If this app currently owns the monitor for its own drawing, force the
    -- claim back to the kernel (so the FleetOS panel appears immediately,
    -- like minimizing a real window) and remember to hand it back on restore.
    if monitorClaimedBy == name then
        monitorClaimedBy = nil
        claimBeforeMinimize[name] = true
    end
    return true
end

local function restoreApp(name)
    if not RUNNING[name] then return false, "not running: " .. name end
    minimizedApps[name] = nil
    if claimBeforeMinimize[name] then
        claimBeforeMinimize[name] = nil
        monitorClaimedBy = name
    end
    return true
end

local function taskState(name)
    if not RUNNING[name] then return "stopped" end
    return minimizedApps[name] and "minimized" or "running"
end

-- ============================================================
-- Bridge override - lets the bridge address/key fleetbridge.lua talks to
-- be changed without editing config.lua, from either shell interpreter
-- (this kernel's own runShellLine, used by remote "type" commands via the
-- dashboard/fleetbridge, or the apps/common/shell.lua REPL) - both call
-- these instead of duplicating the file I/O. See apps/common/
-- fleetbridge.lua's header comment for the full BASE_URL/API_KEY priority
-- order this file participates in.
-- ============================================================

local BRIDGE_OVERRIDE_FILE = "bridge_override.txt"

local function restartBridgeIfRunning()
    if RUNNING["fleetbridge"] then
        kill("fleetbridge")
        spawn("fleetbridge")
        return true
    end
    return false
end

local function setBridgeOverride(url, key)
    local f = fs.open(BRIDGE_OVERRIDE_FILE, "w")
    f.write(textutils.serialize({ url = url, key = key or "" }))
    f.close()
    return true, restartBridgeIfRunning()
end

local function clearBridgeOverride()
    if fs.exists(BRIDGE_OVERRIDE_FILE) then fs.delete(BRIDGE_OVERRIDE_FILE) end
    return true, restartBridgeIfRunning()
end

local function getBridgeOverride()
    if not fs.exists(BRIDGE_OVERRIDE_FILE) then return nil end
    local f = fs.open(BRIDGE_OVERRIDE_FILE, "r")
    local content = f.readAll()
    f.close()
    local ok, decoded = pcall(textutils.unserialize, content)
    return (ok and type(decoded) == "table") and decoded or nil
end

-- same override-file pattern as the bridge address above, for the
-- `startup` app list - lets fleetbridge.lua's new "configure" command push a
-- new startup list (and/or bridge address, via setBridgeOverride above) to
-- many nodes at once from the dashboard, instead of hand-editing config.lua
-- on every single computer. Deliberately NOT rewriting config.lua's actual
-- Lua source (which may have comments/formatting worth preserving, and a
-- half-written rewrite could corrupt it) - loadConfig() below overlays this
-- on top of whatever config.lua itself says, same relationship
-- bridge_override.txt has with config.lua's bridgeUrl/apiKey fields.
local STARTUP_OVERRIDE_FILE = "startup_override.txt"

local function setStartupOverride(startupList)
    local f = fs.open(STARTUP_OVERRIDE_FILE, "w")
    f.write(textutils.serialize(startupList))
    f.close()
    return true
end

local function clearStartupOverride()
    if fs.exists(STARTUP_OVERRIDE_FILE) then fs.delete(STARTUP_OVERRIDE_FILE) end
    return true
end

local function getStartupOverride()
    if not fs.exists(STARTUP_OVERRIDE_FILE) then return nil end
    local f = fs.open(STARTUP_OVERRIDE_FILE, "r")
    local content = f.readAll()
    f.close()
    local ok, decoded = pcall(textutils.unserialize, content)
    return (ok and type(decoded) == "table") and decoded or nil
end

-- ============================================================
-- Scheduler - resumes every live task on each OS event
-- ============================================================

-- runaway-loop guard. A spawned app that never yields (no os.pullEvent/
-- os.sleep at all, e.g. an infinite "while true do end") previously hung the
-- ENTIRE kernel forever - tick()'s coroutine.resume() simply never returns,
-- so no other task, the monitor panel, or fleetbridge itself ever runs again.
-- debug.sethook's instruction-count hook forces an error inside the
-- misbehaving coroutine once it's run too long without yielding control back
-- - that surfaces through the normal "if not ok" crash path below, killing
-- only that one app via removeTask() (which also releases a stuck monitor
-- claim - see) instead of freezing the node. Feature-detected + pcall'd:
-- if the Lua environment doesn't support per-coroutine hooks (uncertain on
-- CC:Tweaked's Cobalt VM), this silently no-ops and behavior is unchanged
-- from before - a documented limitation there, not a crash.
local INSTR_BUDGET = 20000000
local hasDebugHook = type(debug) == "table" and type(debug.sethook) == "function"

-- Found live in a real game session: the watchdog was also arming on the
-- kernel's OWN internal tasks (_monitor_mirror, _supervisor - leading
-- underscore, same convention as "kernel-owned, not a spawned app"
-- elsewhere), and _monitor_mirror died silently on its very first tick on
-- a real server (blank monitor, gone from fleetos.list()) - debug.sethook's
-- count-hook semantics on Cobalt evidently don't match a redraw loop's
-- real instruction cost the way they did under desktop Lua, where this was
-- tested and never reproduced. The watchdog exists to catch a buggy THIRD-
-- PARTY app, not to police kernel code we already trust - kernel tasks are
-- exempt entirely now instead of guessing the right budget for them.
local function isKernelTaskName(name)
    return name:sub(1, 1) == "_"
end

local function instrBudgetHookFired()
    error("runaway loop: task ran " .. INSTR_BUDGET ..
          "+ instructions without yielding (killed by kernel watchdog)", 0)
end

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
                if hasDebugHook and not isKernelTaskName(name) then
                    pcall(debug.sethook, task.co, instrBudgetHookFired, "", INSTR_BUDGET)
                end
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
    local cfg
    if not fs.exists("config.lua") then
        cfg = { startup = {} }
    else
        local ok, loaded = pcall(dofile, "config.lua")
        cfg = (ok and type(loaded) == "table") and loaded or { startup = {} }
    end
    local startupOverride = getStartupOverride()
    if startupOverride then cfg.startup = startupOverride end
    return cfg
end

-- ============================================================
-- Shell PIN check - lives HERE in the kernel, not in
-- apps/common/fleetbridge.lua, on purpose: it has to be callable from the
-- very first tick, before any app has ever been resumed. If this were
-- registered by fleetbridge.lua's own top-level code instead (the way
-- setBridge/etc. above are used by apps/common/shell.lua), it would only
-- exist once fleetbridge's coroutine got its FIRST resume - and
-- game/config.lua's own default startup list is {"shell", "fleetbridge"},
-- shell first. A node booted with that exact default (or the Windows
-- emulation, where apps/common/shell.lua's read() blocks the whole
-- process - see its own comment - so fleetbridge can never get a resume
-- in until the shell prompt returns one) would have its very first
-- `bridge` command sail straight through with no PIN check at all,
-- silently defeating the whole feature. Small deliberate duplication of
-- fleetbridge.lua's BASE_URL/NODE_ID resolution instead of depending on
-- it having run.
-- ============================================================

local SHELL_PIN_ID_OVERRIDE_FILE = "node_id.txt"

local function shellPinUrlEncode(s)
    if textutils.urlEncode then return textutils.urlEncode(s) end
    return (s:gsub("[^%w%-%.~_]", function(c) return ("%%%02X"):format(c:byte()) end))
end

local function currentBridgeUrlAndKey()
    local override = getBridgeOverride()
    if override then return override.url, override.key or "" end
    local cfg = loadConfig()
    local envKey = os.getenv and os.getenv("FLEET_BRIDGE_KEY")
    return cfg.bridgeUrl or "http://127.0.0.1:8787", envKey or cfg.apiKey or ""
end

local function currentNodeId()
    if fs.exists(SHELL_PIN_ID_OVERRIDE_FILE) then
        local f = fs.open(SHELL_PIN_ID_OVERRIDE_FILE, "r")
        local id = f.readAll()
        f.close()
        if id and id ~= "" then return id end
    end
    return loadConfig().id or ("node_" .. os.getComputerID())
end

-- Returns (required, ok, err) - see apps/common/shell.lua's call site for
-- how this gates the `bridge` command. A network failure fails safe as
-- required=true, ok=false rather than letting the override through
-- silently when the bridge can't be reached to ask.
local function checkShellPin(pin)
    local url, key = currentBridgeUrlAndKey()
    local fullUrl = url .. "/shell_pin_check?node=" .. shellPinUrlEncode(currentNodeId())
    local headers = { ["Content-Type"] = "application/json" }
    if key ~= "" then headers["X-API-Key"] = key end
    http.request({ url = fullUrl, body = textutils.serializeJSON({ pin = pin or "" }), headers = headers, timeout = 8 })
    local timerId = os.startTimer(8)
    while true do
        local event, a, b = os.pullEvent()
        if event == "http_success" and a == fullUrl then
            os.cancelTimer(timerId)
            local body = b.readAll()
            b.close()
            local ok, decoded = pcall(textutils.unserializeJSON, body)
            if not ok or type(decoded) ~= "table" then return true, false, "bad response from bridge" end
            return decoded.required == true, decoded.ok == true
        elseif event == "http_failure" and a == fullUrl then
            os.cancelTimer(timerId)
            return true, false, "couldn't reach bridge: " .. tostring(b)
        elseif event == "timer" and a == timerId then
            return true, false, "timed out waiting for bridge"
        end
    end
end

-- Cached locally (see /poll's X-Shell-Pin-Set response header, refreshed
-- every poll cycle by apps/common/fleetbridge.lua) so the terminate
-- handler further below never has to make a network call just to find out
-- whether Ctrl+T needs gating AT ALL - a node that never had a PIN set
-- keeps today's instant, network-free Ctrl+T. Only once this is true does
-- pressing Ctrl+T actually pay for a live checkShellPin() round trip.
local cachedShellPinSet = false
local function markShellPinSet(isSet) cachedShellPinSet = isSet end

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

-- Overlaid on row 1 whenever an app has claimed the monitor for its own
-- full-screen drawing (see monitorClaimedBy) - every full-screen app gets a
-- Windows-style title bar (its name + [_][X]) for free, without that app
-- needing to draw one itself or know anything about being "closable" -
-- same reasoning as STATE_BUTTONS above (a consistent control area
-- regardless of what the app underneath is doing). Returns rowApp shaped
-- like drawMonitorPanel's, but with only row 1 populated.
local function drawClaimedTitleBar(mon, name)
    local w = select(1, mon.getSize())
    local buttons = {
        { text = "[_]", color = colors.yellow, action = "minimize" },
        { text = "[X]", color = colors.red, action = "close" },
    }
    local btnWidth = 0
    for _, b in ipairs(buttons) do btnWidth = btnWidth + #b.text end

    local nameWidth = math.max(0, w - btnWidth - 1)
    local nameText = (" " .. name):sub(1, nameWidth)
    nameText = nameText .. string.rep(" ", math.max(0, nameWidth - #nameText))

    mon.setBackgroundColor(colors.gray)
    mon.setCursorPos(1, 1)
    mon.setTextColor(colors.white)
    mon.write(nameText:sub(1, w))

    local btnRanges = {}
    if w >= btnWidth then
        local x = w - btnWidth + 1
        for _, b in ipairs(buttons) do
            mon.setCursorPos(x, 1)
            mon.setTextColor(b.color)
            mon.write(b.text)
            btnRanges[#btnRanges + 1] = { action = b.action, from = x, to = x + #b.text - 1 }
            x = x + #b.text
        end
    end
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.white)

    return { [1] = { name = name, buttons = btnRanges } }
end

-- Shared between monitorMirrorLoop's own real monitor_touch handling below
-- and touchMonitor() (exposed on the fleetos API table further down) - the
-- latter lets a REMOTE "monitor_touch" command (see fleetbridge.lua) fire
-- the exact same run/kill/minimize/restore/collapse-toggle a real finger
-- tap would, via the SAME hit-testing (handleMonitorTap), not a duplicated
-- copy of it. touchMonitor() deliberately does NOT go through a simulated
-- os.queueEvent("monitor_touch", ...) - tried that first, but this
-- project's Windows-simulation shim can't deliver it reliably (fleetbridge
-- itself calls an UNFILTERED os.pullEvent() for its own http wait right
-- after handling any command, which would silently swallow the very event
-- it just queued before monitorMirrorLoop ever saw it - a real CraftOS
-- event queue doesn't have this quirk, but no local shim reproduces one
-- perfectly either). Calling straight into the same functions a real tap
-- calls sidesteps that entirely and works identically in-game.
local monitorCollapsed = false
local monitorRowApp = {}

local function toggleMonitorCollapse()
    monitorCollapsed = not monitorCollapsed
end

local function handleMonitorTap(x, y)
    -- A claimed app's title bar (row 1) is checked first since it takes
    -- priority over the launcher panel's "tap header to collapse" - only
    -- fall back to that when nothing claimed the monitor (monitorRowApp[1]
    -- is only ever populated when claimed - see drawClaimedTitleBar).
    local info = monitorRowApp[y]
    if info then
        for _, b in ipairs(info.buttons) do
            if x >= b.from and x <= b.to then
                ROW_ACTION[b.action](info.name)
                return true
            end
        end
        return false, "no button there"
    end
    if y == 1 then
        toggleMonitorCollapse()
        return true
    end
    return false, "nothing clickable there"
end

local function monitorMirrorLoop()
    local monName = nil

    local function redraw()
        local claimed = monitorClaimedBy ~= nil and RUNNING[monitorClaimedBy] ~= nil
        local mon = peripheral.find("monitor")
        if not mon then
            monName = nil
            monitorRowApp = {}
            return
        end
        -- Bug fix: was `peripheral.getName(mon)` - real CC:Tweaked's native
        -- peripheral.getName() identifies a peripheral via its own internal
        -- registry, not by inspecting the table it's handed, and errors
        -- ("bad argument #1 (table is not a peripheral)") on our own
        -- hand-built Lua proxy table instead of a genuine registered
        -- peripheral object. Only this project's own shims (craftos_shim.lua/
        -- test/cc_mocks.lua) implement a fake peripheral.getName that's
        -- lenient enough to accept a plain table with a `.name` field - real
        -- CC:Tweaked isn't, which is exactly why wrapMonitor already stores
        -- that same name on the proxy as `.name` (see its own comment) -
        -- reading it directly here avoids the native call on a non-native
        -- object entirely, and works identically in both environments.
        -- Found live: this crashed _monitor_mirror on every single tick on
        -- a real CC:Tweaked server (never reproduced against the shim/mocks,
        -- which is exactly why it went unnoticed until now).
        monName = mon.name
        if claimed then
            -- Don't touch the app's own drawing below row 1 - just overlay
            -- a title bar on top of whatever it already wrote, every tick.
            local ok, result = pcall(drawClaimedTitleBar, mon, monitorClaimedBy)
            monitorRowApp = ok and result or {}
        else
            local ok, result = pcall(drawMonitorPanel, mon, monitorCollapsed)
            monitorRowApp = ok and result or {}
        end
    end

    local timerId = os.startTimer(1)
    redraw()

    while true do
        local event = { os.pullEventRaw() }
        if event[1] == "timer" and event[2] == timerId then
            timerId = os.startTimer(1)
            redraw()
        elseif event[1] == "monitor_touch" and event[2] == monName then
            handleMonitorTap(event[3], event[4])
            redraw()
        end
    end
end

-- ============================================================
-- Entry point
-- ============================================================

-- startup-app supervisor. Previously a crashed/killed startup app
-- (most critically fleetbridge - if it dies, this node goes silent to the
-- bridge and stays silent, since nothing polls/reports for it anymore)
-- just stayed dead forever: tick()'s dead-task sweep only ever removes a
-- finished coroutine, nothing ever restarts one. Runs as an ordinary task
-- through the same tick() scheduler (though - being a kernel task itself,
-- name "_supervisor" - it's now EXEMPT from the instruction-budget guard,
-- same as _monitor_mirror; see that guard's own comment for why).
--
-- Also restarts _monitor_mirror if it's ever not running - belt-and-
-- suspenders on top of exempting it from the guard (see that fix's own
-- comment): if it dies for any OTHER reason, a real monitor would otherwise
-- stay permanently blank/unresponsive with nothing to bring it back.
local SUPERVISOR_INTERVAL = 5
local function supervisorLoop(startupApps)
    while true do
        os.sleep(SUPERVISOR_INTERVAL)
        for _, appName in ipairs(startupApps) do
            if not RUNNING[appName] then
                local ok = spawn(appName)
                if ok then
                    print("[_supervisor] restarted '" .. appName .. "' (was not running)")
                end
            end
        end
        if not RUNNING["_monitor_mirror"] then
            spawn("_monitor_mirror", monitorMirrorLoop)
            print("[_supervisor] restarted '_monitor_mirror' (was not running)")
        end
    end
end

local function boot()
    if not fs.exists(APPS_DIR) then
        fs.makeDir(APPS_DIR)
    end

    local cfg = loadConfig()
    monitorBlocksCfg = cfg.monitorBlocks
    for _, appName in ipairs(cfg.startup or {}) do
        local ok, err = spawn(appName)
        if not ok then
            print("startup: " .. tostring(err))
        end
    end

    spawn("_monitor_mirror", monitorMirrorLoop)
    spawn("_supervisor", function() supervisorLoop(cfg.startup or {}) end)

    printStatus()

    while true do
        local event = { os.pullEventRaw() }
        if event[1] == "terminate" then
            if not cachedShellPinSet then
                print("FleetOS: terminate received, stopping all tasks.")
                break
            end
            -- A PIN is configured for this node - Ctrl+T alone isn't
            -- enough to stop the kernel (see the "Shell PIN check" section
            -- above). pcall wraps the whole prompt+verify sequence: read()
            -- and checkShellPin() both use the normal (throwing) form of
            -- pullEvent internally, so a second Ctrl+T pressed WHILE this
            -- is already waiting would otherwise escape as an uncaught
            -- "Terminated" error - which would still end up dropping to
            -- the native CraftOS shell, the exact outcome this exists to
            -- prevent. Any failure here (including that) resolves to
            -- "stay up", never "stop".
            local promptOk, pinCorrect = pcall(function()
                term.setTextColor(colors.yellow)
                print("FleetOS: terminate blocked - shell PIN required to stop.")
                term.setTextColor(colors.white)
                io.write("PIN: ")
                io.flush()
                local typed = read("*")
                local _, ok = checkShellPin(typed or "")
                return ok
            end)
            if promptOk and pinCorrect then
                print("FleetOS: PIN correct - stopping all tasks.")
                break
            else
                print("FleetOS: staying up (wrong/no PIN entered).")
            end
        else
            tick(event)
        end
    end
end

-- minimal IPC between apps. Previously the only way for two spawned
-- apps to share anything was a global variable (invisible/fragile - any app
-- could stomp on any other's globals with no namespacing at all) or a file
-- on disk (works, but heavyweight and slow for anything more frequent than
-- occasional config-style data). Two independent, deliberately simple
-- primitives, not a full message-passing framework:
--   - A shared key-value table (setShared/getShared) for "the current
--     state of X, whoever asks last wins" data (e.g. raytower's solved
--     position, so a hypothetical dashboard-summary app could read it
--     without parsing rays.dat itself).
--   - A publish/subscribe event (publish, using os.queueEvent under the
--     hood) for "something just happened" notifications - any app doing
--     os.pullEvent("fleetos_message") sees every publish() from every
--     other app, filtering on the topic field itself (same one-event-many-
--     listeners model tick() already uses for every other event, so this
--     doesn't introduce a new dispatch mechanism, just a new event name).
local sharedState = {}

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
    -- change/inspect/clear which bridge fleetbridge.lua talks to, without
    -- editing config.lua - see the "Bridge override" section above.
    setBridge = setBridgeOverride,
    clearBridge = clearBridgeOverride,
    getBridgeInfo = getBridgeOverride,
    -- see the "Shell PIN check" section above for why this lives here
    -- instead of apps/common/fleetbridge.lua.
    checkShellPin = checkShellPin,
    markShellPinSet = markShellPinSet,
    -- bulk-configurable startup app list, same override-file pattern
    -- as the bridge address above - see setStartupOverride's comment.
    setStartup = setStartupOverride,
    clearStartup = clearStartupOverride,
    getStartupOverride = getStartupOverride,
    listAvailableApps = listAvailableApps,
    -- short content-checksum "version" for a given app - see
    -- appVersion's own comment above. nil if the app doesn't exist.
    appVersion = appVersion,
    -- the same cheap, non-cryptographic checksum appVersion uses above,
    -- exposed generically - apps/common/fleetbridge.lua's report() reuses
    -- this to detect "did the monitor snapshot actually change since last
    -- report" instead of a bespoke hash of its own.
    checksum = simpleChecksum,
    -- resolves where an app's file lives (its existing group folder if
    -- any), or where a brand new one should be created (flat apps/) -
    -- used by fleetbridge.lua's deploy/rollback so it writes to the same
    -- place spawn() will look for it.
    appPath = function(name)
        return resolveAppPath(name) or fs.combine(APPS_DIR, name .. ".lua")
    end,
    current = function() return CURRENT end,
    -- see the "minimal IPC between apps" comment above.
    setShared = function(key, value) sharedState[key] = value end,
    getShared = function(key) return sharedState[key] end,
    -- pcall'd like touchMonitor's os.queueEvent use elsewhere in this file -
    -- this project's test mocks/Windows shim don't implement a real
    -- CraftOS-style event queue (os.queueEvent doesn't exist in either), so
    -- this safely no-ops there instead of erroring; works as a real
    -- broadcast in-game, where os.queueEvent is a native primitive.
    publish = function(topic, data) pcall(os.queueEvent, "fleetos_message", topic, data, CURRENT) end,
    -- Call from within a running app to take over the "monitor"
    -- peripheral for its own display (e.g. raytower_master.lua) - the
    -- kernel's terminal mirror then leaves it alone until this app stops
    -- running (killed, crashed, or exits), no explicit release needed.
    claimMonitor = function() monitorClaimedBy = CURRENT end,
    releaseMonitor = function() if monitorClaimedBy == CURRENT then monitorClaimedBy = nil end end,
    -- belt-and-suspenders: un-claims the monitor regardless of which app
    -- holds it, without killing that app - for a remote "the screen is stuck
    -- and I can't reach a terminal" situation. Normally unnecessary now that
    -- a hung claiming app gets killed by the instruction-budget watchdog
    -- (which already clears monitorClaimedBy via removeTask), but this covers
    -- a claiming app that's alive and yielding fine, just never redrawing/
    -- releasing on its own (e.g. waiting on something that'll never happen).
    forceReleaseMonitor = function() monitorClaimedBy = nil end,
    -- returns the last `n` captured output lines (default: all buffered,
    -- up to MAX_OUTPUT_LINES). Includes the current in-progress line (e.g.
    -- a "shell> " prompt still waiting on its newline) so a remote viewer
    -- sees exactly what's really on screen right now.
    getOutput = function(n)
        return tailWithCurrent(OUTPUT, currentLine, currentLine == "", n)
    end,
    -- see getOutputSince()'s own comment above for the (newLines, cursor,
    -- tail) contract - a low-bandwidth alternative to getOutput() for a
    -- caller that reports on a cycle and wants to avoid resending the same
    -- lines every time.
    getOutputSince = getOutputSince,
    -- Same as getOutput(), but each line is a list of {text=, color=}
    -- segments instead of a plain string - lets a monitor (or anything
    -- else that can show color) reproduce this computer's screen
    -- faithfully instead of just white-on-black text.
    getColoredOutput = function(n)
        return tailWithCurrent(COLORED, buildSegments(currentLine, currentColors), currentLine == "", n)
    end,
    -- Returns a snapshot of whatever's actually drawn on this computer's
    -- attached monitor peripheral (see "Monitor capture" above), or nil if
    -- no monitor has ever been found/drawn to this session. Same
    -- {text=,color=} row shape as getColoredOutput() - {w, h, bg,
    -- rows = { [y] = {segments...} } }.
    getMonitorSnapshot = function()
        local g = MONITOR_GRID
        if not g then return nil end
        local rows = {}
        for y = 1, g.h do rows[y] = monitorRowSegments(g.cells[y], g.w) end
        return {
            w = g.w, h = g.h, bg = g.bg, rows = rows,
            -- Physical block dimensions - auto-derived every tick from
            -- getSize()/getTextScale() via the real CC:Tweaked formula (see
            -- computeMonitorBlocks's comment), overridable by config.lua's
            -- monitorBlocks for the rare case the auto value is off (e.g. a
            -- CC:Tweaked version with different rendering constants). Lets
            -- the dashboard render the exact real aspect ratio instead of a
            -- rougher approximation from character counts alone.
            blockW = (monitorBlocksCfg and monitorBlocksCfg.w) or g.blockW,
            blockH = (monitorBlocksCfg and monitorBlocksCfg.h) or g.blockH,
        }
    end,
    -- Simulates a real finger tap at character column/row (x, y) on
    -- whatever monitor is currently attached - calls straight into
    -- handleMonitorTap (see the comment above monitorMirrorLoop), the exact
    -- same hit-testing/dispatch a real monitor_touch event goes through,
    -- rather than firing a fake event (see that comment for why). Lets the
    -- dashboard's monitor emulation be genuinely clickable, not just a
    -- picture. Returns false if no monitor has ever been found/drawn to
    -- this session.
    touchMonitor = function(x, y)
        if not MONITOR_GRID then return false, "no monitor attached" end
        local ok, err = handleMonitorTap(x, y)
        -- a remote monitor_touch (dashboard click) previously only ever
        -- reached the kernel's own chrome (handleMonitorTap above) - any
        -- ordinary app doing os.pullEvent("monitor_touch") to react to taps
        -- itself (not just the launcher panel/title bar) would never see a
        -- remote one, only a real physical tap. Also queueing the real event
        -- here fixes that for actual in-game nodes; pcall'd and best-effort
        -- since this project's Windows-simulation shim doesn't reproduce a
        -- real CraftOS event queue perfectly (see monitorMirrorLoop's own
        -- comment above) - the direct handleMonitorTap() call above is what
        -- keeps kernel chrome working regardless of whether this fires.
        pcall(function()
            local mon = peripheral.find("monitor")
            if mon then os.queueEvent("monitor_touch", mon.name, x, y) end
        end)
        return ok, err
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

        elseif cmd == "bridge" then
            if parts[2] == "clear" then
                local _, restarted = clearBridgeOverride()
                print("bridge override cleared - back to config.lua's bridgeUrl/apiKey")
                if restarted then print("fleetbridge restarted") end
            elseif not parts[2] then
                local info = getBridgeOverride()
                if info then
                    print("bridge override: " .. tostring(info.url)
                        .. ((info.key and info.key ~= "") and " (key set)" or " (no key)"))
                else
                    print("no bridge override set - using config.lua's bridgeUrl/apiKey (if any)")
                end
                print("Usage: bridge <url> [key]  |  bridge clear")
            else
                local _, restarted = setBridgeOverride(parts[2], parts[3])
                print("bridge set to " .. parts[2] .. ((parts[3] and parts[3] ~= "") and " (with key)" or ""))
                print(restarted and "fleetbridge restarted with new settings"
                    or "fleetbridge isn't running - start it with 'run fleetbridge'")
            end
            return true
        end

        local ok, err = pcall(function() shell.run(line) end)
        if not ok then appendRaw("error: " .. tostring(err) .. "\n") end
        return ok, err
    end,
}

boot()
