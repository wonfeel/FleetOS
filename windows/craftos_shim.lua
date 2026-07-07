-- Minimal CraftOS-compatible layer to run fleetos.lua as a real,
-- persistent process on Windows (no Minecraft). Unlike test/cc_mocks.lua
-- (which sandboxes everything in memory for one-shot tests), this shim
-- reads/writes REAL files on disk - deploys and data really persist
-- between runs.
--
-- No modem/monitor/sublevel exist on a bare Windows machine, so
-- peripheral.find always returns nil - any app that requires hardware
-- (fleetnet, raytower_master/slave, fleet_dashboard) will correctly
-- print "No modem/monitor found" and exit, exactly like a real CC
-- computer with nothing plugged in. Only hardware-free apps (e.g. clock,
-- or anything you write that's pure logic/scheduling) actually run here.

-- Lets an app tell "real CraftOS" apart from "this Windows emulation"
-- (real CraftOS never defines this) - used by apps/common/shell.lua to warn
-- about read()'s blocking-io.read limitation below, only where it applies.
_G.CRAFTOS_EMULATION = true

-- ---- fs: real disk, rooted at the current working directory ----

-- pulled out to a local helper (used by both fs.exists and fs.isDir
-- below) so fs.exists can check it too - real CraftOS's fs.exists returns
-- true for a directory just as much as a file, but io.open (this shim's
-- only other tool) can never open one, so a naive fs.exists alone always
-- misreported every real directory as "not found". Every internal call site
-- in this project already learned to check fs.isDir() FIRST as a workaround -
-- fixing the root cause here means a NEW caller that (reasonably) assumes
-- fs.exists alone is enough no longer needs to know that gotcha at all.
local function isDirOnDisk(path)
    local winpath = path:gsub("/", "\\")
    local pipe = io.popen('if exist "' .. winpath .. '\\" (echo YES) else (echo NO)')
    if not pipe then return false end
    local out = pipe:read("l")
    pipe:close()
    return out == "YES"
end

fs = {
    exists = function(path)
        if isDirOnDisk(path) then return true end
        local f = io.open(path, "r")
        if f then f:close(); return true end
        return false
    end,
    open = function(path, mode)
        if mode == "r" then
            local f = io.open(path, "r")
            if not f then return nil end
            return {
                readAll = function() local c = f:read("a"); return c end,
                close = function() f:close() end,
            }
        else
            local f = io.open(path, "w")
            if not f then return nil end
            return {
                write = function(data) f:write(data) end,
                close = function() f:close() end,
            }
        end
    end,
    delete = function(path)
        -- an empty or root-ish path here would run `rd /s /q` against
        -- the current directory (or the whole drive root) - fleetbridge.lua's
        -- own "delete" command already rejects an empty path before ever
        -- calling this, but this shim is also reachable directly (a
        -- shell.lua "delete" typed at the emulated prompt, or any future
        -- caller), and a real CraftOS fs.delete("") just fails cleanly
        -- rather than being destructive, so match that here too.
        local trimmed = (path or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if trimmed == "" or trimmed:match("^[%.\\/]+$") then
            error("fs.delete: refusing to delete an empty/root-ish path: '" .. tostring(path) .. "'", 0)
        end
        -- os.remove alone only handles files (and empty dirs) - real
        -- CraftOS's fs.delete removes a non-empty directory recursively too,
        -- so match that here (rd /s /q) rather than silently failing.
        local winpath = path:gsub("/", "\\")
        local pipe = io.popen('if exist "' .. winpath .. '\\" (echo DIR) else (echo FILE)')
        local kind = pipe and pipe:read("l") or "FILE"
        if pipe then pipe:close() end
        if kind == "DIR" then
            os.execute('rd /s /q "' .. winpath .. '" 2>NUL')
        else
            os.remove(path)
        end
    end,
    copy = function(src, dst)
        local i = io.open(src, "r")
        if not i then return end
        local data = i:read("a")
        i:close()
        local o = io.open(dst, "w")
        o:write(data)
        o:close()
    end,
    -- os.rename (Lua's stdlib wrapper around C's rename()) handles both
    -- files and directories on Windows as long as source/dest are on the
    -- same drive - real CraftOS's fs.move works the same way (rename, not
    -- copy+delete) for both.
    move = function(from, to) os.rename(from, to) end,
    combine = function(a, b) return a .. "/" .. b end,
    makeDir = function(path)
        os.execute(('mkdir "%s" 2>NUL'):format(path:gsub("/", "\\")))
    end,
    isDir = isDirOnDisk,
    list = function(path)
        local winpath = path:gsub("/", "\\")
        local entries = {}
        local pipe = io.popen('dir /b "' .. winpath .. '" 2>NUL')
        if pipe then
            for line in pipe:lines() do entries[#entries + 1] = line end
            pipe:close()
        end
        return entries
    end,
    getSize = function(path)
        local f = io.open(path, "rb")
        if not f then return 0 end
        local size = f:seek("end")
        f:close()
        return size or 0
    end,
}

-- ---- textutils ----
textutils = {
    serialize = function(t)
        local function ser(v)
            local ty = type(v)
            if ty == "table" then
                local parts = {}
                for k, val in pairs(v) do
                    local key = (type(k) == "number") and ("[" .. k .. "]") or ("[" .. string.format("%q", k) .. "]")
                    parts[#parts + 1] = key .. "=" .. ser(val)
                end
                return "{" .. table.concat(parts, ",") .. "}"
            elseif ty == "string" then
                return string.format("%q", v)
            else
                return tostring(v)
            end
        end
        return ser(t)
    end,
    unserialize = function(s)
        local fn = load("return " .. s)
        if not fn then return nil end
        return fn()
    end,
    formatTime = function(time, twentyFour)
        local h = math.floor(time) % 24
        local m = math.floor((time - math.floor(time)) * 60)
        return string.format("%02d:%02d", h, m)
    end,
}

-- ---- os additions ----
os.epoch = function(_) return os.time() * 1000 end
os.getComputerID = function() return 0 end
os.computerID = os.getComputerID
-- a real computer reboots and re-runs startup.lua - there's no such
-- persistent process here, so the closest equivalent is just ending this
-- run (re-launch run_fleetos.lua by hand to simulate the "boot back up")
os.reboot = function()
    print("[shim] os.reboot() called - exiting (re-run run_fleetos.lua to simulate booting back up)")
    os.exit(0)
end

-- Timer scheduling using real wall-clock seconds (os.time(), 1s
-- resolution - stock Lua has no sub-second monotonic clock without
-- extra libraries). Exposed via _G.shim so runtime/run_fleetos.lua's
-- driver loop can find the next timer to wait for.
local timerCounter = 0
local pendingTimers = {} -- id -> fireAt (os.time() seconds)

function os.startTimer(delay)
    timerCounter = timerCounter + 1
    pendingTimers[timerCounter] = os.time() + math.ceil(delay or 0)
    return timerCounter
end

-- Real CraftOS lets you cancel a timer you no longer care about (e.g. you
-- got the event you were actually waiting for via some other means first).
-- Without this, an uncancelled timer sits in pendingTimers until it fires -
-- harmless on real CraftOS (just one more ignored event in an unthrottled
-- queue), but costly here: run_sim_node.lua's driver waits out each pending
-- timer in real wall-clock time via shim.nextTimer(), so leaked timers pile
-- up and directly slow down every later cycle.
function os.cancelTimer(id)
    pendingTimers[id] = nil
end

-- Synthetic events queued by http.request (see below) - this shim has no
-- real async I/O, so http.request just runs the request immediately
-- (blocking) and queues the outcome here; pullEventRaw drains it before
-- ever yielding, so callers using the real CraftOS "fire off a request,
-- then os.pullEvent for http_success/http_failure" pattern work unmodified.
local pendingEvents = {}

function os.pullEventRaw(filter)
    if #pendingEvents > 0 then
        local ev = table.remove(pendingEvents, 1)
        if not filter or ev[1] == filter then
            return table.unpack(ev)
        end
        pendingEvents[#pendingEvents + 1] = ev -- not what was asked for - put it back, try the real queue
    end
    return coroutine.yield(filter)
end


function os.pullEvent(filter)
    -- Must go through pullEventRaw (not coroutine.yield directly) so it
    -- also drains the synthetic http_success/http_failure events queued by
    -- http.request - otherwise those events sit in pendingEvents forever
    -- (nothing else ever consumes them) and every http.request-based wait
    -- falls through to its own timeout instead of ever seeing the real
    -- response, even though the underlying request already succeeded.
    local event = { os.pullEventRaw(filter) }
    if event[1] == "terminate" then error("Terminated", 0) end
    return table.unpack(event)
end

function os.sleep(time)
    local id = os.startTimer(time or 0)
    while true do
        local _, gotId = os.pullEvent("timer")
        if gotId == id then break end
    end
end

shim = {
    nextTimer = function()
        local bestId, bestAt = nil, nil
        for id, at in pairs(pendingTimers) do
            if not bestAt or at < bestAt then bestId, bestAt = id, at end
        end
        return bestId, bestAt
    end,
    consumeTimer = function(id) pendingTimers[id] = nil end,
}

-- ---- colors + ANSI mapping ----
-- Windows Terminal / PowerShell 7+ render ANSI escape codes natively.
-- Classic cmd.exe on older Windows 10 builds may not - if colors show up
-- as garbled "^[[33m" text, run this via Windows Terminal or PowerShell
-- instead, or just ignore it (it's cosmetic only).
--
-- Values are the REAL CC:Tweaked colors.* bitmask constants (not an
-- arbitrary 0-7 sequence like an earlier version of this shim used) - only
-- the 8 actually referenced anywhere in this codebase (see fleetos.lua's
-- STATE_COLOR/STATE_BUTTONS) are defined, but each one's numeric value now
-- matches real gameplay exactly. This matters because fleetos.lua's new
-- monitor capture (see its "Monitor capture" section) ships these numbers
-- straight to the dashboard, which maps them to real CC:Tweaked's palette
-- (see dashboard.html's CC_COLORS) - with the old 0-7 scheme, the LOCAL
-- Windows simulation's monitor emulation would render the wrong colors
-- even though a real in-game node (which always uses the real `colors`
-- global, never this shim) would already be correct.
colors = {
    black = 32768, white = 1, gray = 128, lightGray = 256,
    yellow = 16, lime = 32, red = 16384, cyan = 512,
}
local ANSI_FG = {
    [32768] = 30, [1] = 97, [128] = 90, [256] = 37,
    [16] = 33, [32] = 92, [16384] = 31, [512] = 36,
}

-- ---- term ----
term = {
    clear = function() os.execute("cls") end,
    setCursorPos = function(_, _) end,
    write = function(s) io.write(s) end,
    setTextColor = function(c)
        local code = ANSI_FG[c]
        if code then io.write("\27[" .. code .. "m") end
    end,
    setBackgroundColor = function(_) end,
}
function write(s) io.write(tostring(s)) end

-- KNOWN LIMITATION: this is a plain blocking io.read(), not a proper
-- coroutine yield like real CraftOS's read() (which waits on "char"/"key"
-- events via os.pullEvent, letting every other task keep running between
-- keystrokes). Stock Lua has no non-blocking/timed stdin read without an
-- external library, which this project deliberately avoids depending on.
-- Practical effect: while apps/common/shell.lua's prompt is sitting at
-- "shell> " waiting for you to type, the ENTIRE process is frozen at the
-- OS level - fleetbridge, _monitor_mirror, everything - since a blocking
-- io.read() never returns control to the Lua coroutine scheduler at all.
-- This is invisible in real Minecraft (real read() yields fine there) and
-- only bites in this Windows emulation.
-- Workaround: don't rely on the local interactive shell staying open
-- alongside fleetbridge - type 'exit' when done (frees the scheduler), or
-- skip running "shell" locally altogether and control the node entirely
-- through the dashboard's Terminal panel or `python fleetctl.py shell
-- <node-id>` (interactive) / `fleetctl.py type <node-id> <text>`
-- (one-shot) - all three go through fleetos.runShellLine() over HTTP,
-- as a separate OS process/request, and never touch this read() at all.
function read() return io.read("l") end

-- ---- shell (CraftOS global program runner, used by fleetos.runShellLine) ----
shell = {
    run = function(...)
        print("[shell.run] " .. table.concat({ ... }, " ") .. " (mocked - no real programs here)")
        return true
    end,
}

-- ---- textutils JSON (used by fleetbridge.lua to talk to bridge_server.py) ----

local function jsonEncode(v)
    local ty = type(v)
    if v == nil then return "null" end
    if ty == "boolean" or ty == "number" then return tostring(v) end
    if ty == "string" then
        local escaped = v:gsub('[\\"]', "\\%0"):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
        return '"' .. escaped .. '"'
    end
    if ty == "table" then
        local n = 0
        for _ in pairs(v) do n = n + 1 end
        local isArray = n > 0
        for i = 1, n do
            if v[i] == nil then isArray = false break end
        end
        if n == 0 then return "[]" end
        if isArray then
            local parts = {}
            for i = 1, n do parts[i] = jsonEncode(v[i]) end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local parts = {}
        for k, val in pairs(v) do
            parts[#parts + 1] = jsonEncode(tostring(k)) .. ":" .. jsonEncode(val)
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return "null"
end

local function jsonDecode(s)
    local pos = 1
    local parseValue

    local function skipWs()
        while pos <= #s and s:sub(pos, pos):match("%s") do pos = pos + 1 end
    end

    local function parseString()
        pos = pos + 1
        local buf = {}
        while true do
            local c = s:sub(pos, pos)
            if c == '"' then pos = pos + 1; break end
            if c == "\\" then
                local nc = s:sub(pos + 1, pos + 1)
                local map = { n = "\n", t = "\t", r = "\r", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
                buf[#buf + 1] = map[nc] or nc
                pos = pos + 2
            else
                buf[#buf + 1] = c
                pos = pos + 1
            end
        end
        return table.concat(buf)
    end

    local function parseNumber()
        local start = pos
        while pos <= #s and s:sub(pos, pos):match("[%d%.%-%+eE]") do pos = pos + 1 end
        return tonumber(s:sub(start, pos - 1))
    end

    parseValue = function()
        skipWs()
        local c = s:sub(pos, pos)
        if c == '"' then return parseString() end
        if c == "{" then
            pos = pos + 1
            local obj = {}
            skipWs()
            if s:sub(pos, pos) == "}" then pos = pos + 1; return obj end
            while true do
                skipWs()
                local key = parseString()
                skipWs()
                pos = pos + 1 -- ':'
                obj[key] = parseValue()
                skipWs()
                local ch = s:sub(pos, pos)
                pos = pos + 1
                if ch == "}" then break end
            end
            return obj
        end
        if c == "[" then
            pos = pos + 1
            local arr = {}
            skipWs()
            if s:sub(pos, pos) == "]" then pos = pos + 1; return arr end
            local i = 1
            while true do
                arr[i] = parseValue()
                i = i + 1
                skipWs()
                local ch = s:sub(pos, pos)
                pos = pos + 1
                if ch == "]" then break end
            end
            return arr
        end
        if s:sub(pos, pos + 3) == "true" then pos = pos + 4; return true end
        if s:sub(pos, pos + 4) == "false" then pos = pos + 5; return false end
        if s:sub(pos, pos + 3) == "null" then pos = pos + 4; return nil end
        return parseNumber()
    end

    local ok, result = pcall(parseValue)
    if ok then return result end
    return nil
end

textutils.serializeJSON = jsonEncode
textutils.unserializeJSON = jsonDecode

-- ---- http (via the system curl.exe - Windows 10+ ships one at
-- C:\Windows\System32\curl.exe). Implements http.get/http.post (used by
-- older call sites/tests) plus http.request (the async form apps/common/
-- fleetbridge.lua and install.lua now use for a real per-request timeout).
-- Each returns a CC:Tweaked-style response handle or (nil, error). ----

local function shellQuote(s)
    return '"' .. s .. '"'
end

local function httpRequest(method, url, body, headers, timeout)
    local bodyOutFile = os.tmpname()
    local dataFile

    local args = { "-X", method }
    if timeout then
        table.insert(args, "-m")
        table.insert(args, tostring(timeout))
    end
    if headers then
        for k, v in pairs(headers) do
            table.insert(args, "-H")
            table.insert(args, shellQuote(k .. ": " .. v))
        end
    end
    if body then
        dataFile = os.tmpname()
        local f = io.open(dataFile, "wb")
        f:write(body)
        f:close()
        table.insert(args, "--data-binary")
        table.insert(args, "@" .. dataFile)
    end
    table.insert(args, shellQuote(url))

    local cmd = "curl -s -o " .. shellQuote(bodyOutFile) .. ' -w "%{http_code}" ' .. table.concat(args, " ")
    local pipe = io.popen(cmd, "r")
    local code = nil
    if pipe then
        local out = pipe:read("a") or ""
        pipe:close()
        code = tonumber(out:match("%d+"))
    end

    local respBody = ""
    local rf = io.open(bodyOutFile, "r")
    if rf then respBody = rf:read("a") or ""; rf:close() end
    os.remove(bodyOutFile)
    if dataFile then os.remove(dataFile) end

    if not code or code < 200 or code >= 300 then
        return nil, "HTTP " .. tostring(code or "connection failed")
    end

    return {
        readAll = function() return respBody end,
        close = function() end,
        getResponseCode = function() return code end,
    }
end

http = {
    get = function(url, headers) return httpRequest("GET", url, nil, headers) end,
    post = function(url, body, headers) return httpRequest("POST", url, body, headers) end,

    -- Async form: real CraftOS fires this off and returns immediately, then
    -- delivers an http_success/http_failure event later. This shim has no
    -- true async I/O, so it just runs the (blocking, curl-based) request
    -- right now and queues the outcome as a synthetic event for the next
    -- os.pullEventRaw/os.pullEvent call to pick up (see pendingEvents
    -- above) - callers that fire-then-pullEvent (the real CraftOS idiom)
    -- work unmodified, they just don't get true concurrency here.
    request = function(urlOrOpts, body, headers, method)
        local url, timeout
        if type(urlOrOpts) == "table" then
            url = urlOrOpts.url
            body = urlOrOpts.body
            headers = urlOrOpts.headers
            method = urlOrOpts.method
            timeout = urlOrOpts.timeout
        else
            url = urlOrOpts
        end
        method = method or (body and "POST" or "GET")
        local resp, err = httpRequest(method, url, body, headers, timeout)
        if resp then
            pendingEvents[#pendingEvents + 1] = { "http_success", url, resp }
        else
            pendingEvents[#pendingEvents + 1] = { "http_failure", url, err }
        end
    end,
}

-- ---- peripheral / rednet / sublevel: no real game hardware on Windows ----
-- peripheral.find("modem") returns a dummy modem so apps that require one
-- (fleetnet, fleetbridge, raytower_master/slave) get past that check and
-- reach their HTTP/logic - there's just nobody else to talk to over
-- rednet (broadcast/send are no-ops, receive always "times out" as nil).
local FAKE_MODEM = { name = "fake_modem" }

-- peripheral.find("monitor") returns a real (if inert) monitor object - a
-- manual, emulation-only way to exercise fleetos.lua's monitor capture (see
-- its "Monitor capture" section) and the dashboard's monitor emulation
-- without a real Minecraft world, same spirit as gps's fake_pos.txt below.
-- Every method is a genuine no-op (nothing to actually draw to) - the point
-- is just to BE PRESENT so fleetos.lua's peripheral.find wrapper captures
-- whatever gets written to it into MONITOR_GRID.
--
-- Simulated monitor size - a real monitor is an assembled rectangle of
-- physical blocks (up to 8 wide x 6 tall, TileMonitor.java's MAX_WIDTH/
-- MAX_HEIGHT), and its actual character grid is derived from that via the
-- SAME formula real CC:Tweaked uses (TileMonitor.rebuildTerminal()) - not
-- an arbitrary character count. Change the two BLOCKS_* constants (or
-- TEXT_SCALE) to simulate a different monitor size/zoom; everything
-- downstream (grid, report, dashboard rendering) adapts automatically
-- since it only ever reads getSize(), never these constants directly.
local FAKE_MONITOR_BLOCKS_WIDE = 3
local FAKE_MONITOR_BLOCKS_TALL = 2
local FAKE_MONITOR_TEXT_SCALE = 1.0 -- 0.5-5.0 in 0.5 steps, matches monitor.setTextScale()

-- Opt-in per-node override for "fake terminals" - nodes that only ever
-- exist in this Windows simulation (no real in-game computer behind them
-- at all), which may want a different physical monitor shape than the
-- 3x2 default every other simulated node uses (e.g. a portrait 2x3 fake
-- terminal instead of the usual landscape 3x2). Drop a
-- "fake_monitor_size.txt" file with "widthBlocks,heightBlocks" (e.g. "2,3")
-- next to this node's startup.lua/config.lua - same discovery pattern as
-- bridge_override.txt - to size just that node's fake monitor differently
-- without touching this shared shim file.
do
    local f = fs.open("fake_monitor_size.txt", "r")
    if f then
        local line = f.readLine()
        f.close()
        local w, h = (line or ""):match("^%s*(%d+)%s*,%s*(%d+)%s*$")
        if w and h then
            FAKE_MONITOR_BLOCKS_WIDE = tonumber(w)
            FAKE_MONITOR_BLOCKS_TALL = tonumber(h)
        end
    end
end

local function computeMonitorCharGrid(blocksWide, blocksTall, textScale)
    -- TileMonitor.java: RENDER_BORDER = 2/16, RENDER_MARGIN = 0.5/16,
    -- RENDER_PIXEL_SCALE = 1/64 (all in block-units); a character is 6x9
    -- of those pixel-scale units (FixedWidthFontRenderer.FONT_WIDTH/HEIGHT).
    local borderAndMargin = 2 / 16 + 0.5 / 16
    local pixelScale = 1 / 64
    local w = math.floor((blocksWide - 2 * borderAndMargin) / (textScale * 6 * pixelScale) + 0.5)
    local h = math.floor((blocksTall - 2 * borderAndMargin) / (textScale * 9 * pixelScale) + 0.5)
    return math.max(1, w), math.max(1, h)
end

local FAKE_MONITOR_W, FAKE_MONITOR_H = computeMonitorCharGrid(
    FAKE_MONITOR_BLOCKS_WIDE, FAKE_MONITOR_BLOCKS_TALL, FAKE_MONITOR_TEXT_SCALE)

local FAKE_MONITOR = {
    name = "fake_monitor",
    getSize = function() return FAKE_MONITOR_W, FAKE_MONITOR_H end,
    getTextScale = function() return FAKE_MONITOR_TEXT_SCALE end,
    getCursorPos = function() return 1, 1 end,
    setCursorPos = function(_, _) end,
    setTextColor = function(_) end,
    setTextColour = function(_) end,
    setBackgroundColor = function(_) end,
    setBackgroundColour = function(_) end,
    write = function(_) end,
    clear = function() end,
    clearLine = function() end,
    setTextScale = function(_) end,
    isColor = function() return true end,
    isColour = function() return true end,
    scroll = function(_) end,
}

-- this emulation previously only ever recognized "modem"/"monitor" -
-- peripheral.find("drive")/("printer") always returned nil, unlike a real
-- computer which could have either attached, so an app using either could
-- only ever be developed/tested in-game, never locally. Both are real,
-- if minimal, in-memory stand-ins (not just erroring stubs) - a disk drive
-- with no disk inserted (a legitimate, common real state - every method
-- behaves exactly as real CC:Tweaked's drive peripheral does with nothing
-- in it) and a printer that actually accumulates pages/text in memory so
-- printer-consuming code has something real to assert against locally.
local FAKE_DRIVE = {
    name = "fake_drive",
    isDiskPresent = function() return false end,
    getDiskLabel = function() return nil end,
    setDiskLabel = function(_) end,
    hasData = function() return false end,
    getMountPath = function() return nil end,
    hasAudio = function() return false end,
    getAudioTitle = function() return nil end,
    playAudio = function() end,
    stopAudio = function() end,
    ejectDisk = function() end,
    getDiskID = function() return nil end,
}

local FAKE_PRINTER_PAGE_WIDTH = 25
local FAKE_PRINTER_PAGE_HEIGHT = 21
-- Mutable state lives in upvalues (not table fields read via `self`) since
-- every OTHER fake peripheral in this file is called dot-style with no
-- implicit self (`monitor.getSize()`, matching real CC:Tweaked's peripheral
-- proxies, which are plain closures over the real peripheral - never `:`
-- method calls) - keeping this one consistent so `printer.write(...)`
-- behaves the same way callers already expect from every other peripheral.
local printerPages = {}      -- finished pages, each a list of lines - inspectable from a test if needed
local printerCurrentPage = nil -- {lines={...}, title=..., cx=1, cy=1} while a page is open, else nil

local FAKE_PRINTER = {
    name = "fake_printer",
    getInkLevel = function() return 100 end,
    getPaperLevel = function() return 64 end,
    newPage = function()
        if printerCurrentPage then return false end
        printerCurrentPage = { lines = {}, title = nil, cx = 1, cy = 1 }
        return true
    end,
    endPage = function()
        if not printerCurrentPage then return false end
        printerPages[#printerPages + 1] = printerCurrentPage
        printerCurrentPage = nil
        return true
    end,
    write = function(text)
        if not printerCurrentPage then error("no page started") end
        local p = printerCurrentPage
        p.lines[p.cy] = (p.lines[p.cy] or "") .. tostring(text)
        p.cx = p.cx + #tostring(text)
    end,
    setCursorPos = function(x, y)
        if not printerCurrentPage then error("no page started") end
        printerCurrentPage.cx, printerCurrentPage.cy = x, y
    end,
    getCursorPos = function()
        if not printerCurrentPage then error("no page started") end
        return printerCurrentPage.cx, printerCurrentPage.cy
    end,
    getPageSize = function() return FAKE_PRINTER_PAGE_WIDTH, FAKE_PRINTER_PAGE_HEIGHT end,
    setPageTitle = function(title)
        if not printerCurrentPage then error("no page started") end
        printerCurrentPage.title = title
    end,
}

local PERIPHERAL_KINDS = {
    modem = FAKE_MODEM,
    monitor = FAKE_MONITOR,
    drive = FAKE_DRIVE,
    printer = FAKE_PRINTER,
}
local PERIPHERALS_BY_NAME = {
    [FAKE_MODEM.name] = FAKE_MODEM,
    [FAKE_MONITOR.name] = FAKE_MONITOR,
    [FAKE_DRIVE.name] = FAKE_DRIVE,
    [FAKE_PRINTER.name] = FAKE_PRINTER,
}

peripheral = {
    find = function(kind)
        return PERIPHERAL_KINDS[kind]
    end,
    -- Real peripheral.getName() works via kernel-side bookkeeping of which
    -- wrapped table corresponds to which name - this shim fakes that with a
    -- plain `.name` field instead. Checking `.name` (not just `p == FAKE_MONITOR`)
    -- matters because fleetos.lua's peripheral.find wrapper (see its
    -- "Monitor capture" section) returns its OWN proxy table for a monitor,
    -- never the raw FAKE_MONITOR - an identity check alone would silently
    -- fall through to "fake_modem" for that proxy, which broke
    -- monitor_touch simulation (the proxy's `monName` would never match
    -- what fleetos.lua itself queues events under).
    getName = function(p)
        if type(p) == "table" and p.name then return p.name end
        return FAKE_MODEM.name
    end,
    isPresent = function(name) return PERIPHERALS_BY_NAME[name] ~= nil end,
    getNames = function()
        local names = {}
        for name in pairs(PERIPHERALS_BY_NAME) do names[#names + 1] = name end
        table.sort(names)
        return names
    end,
    -- Dispatches to the real fake peripheral's own method by name, instead
    -- of always erroring - lets world_call "peripheral_call" (see
    -- apps/common/fleetbridge.lua) actually exercise drive/printer/monitor
    -- methods locally, not just modem/monitor's total absence of them.
    call = function(name, method, ...)
        local p = PERIPHERALS_BY_NAME[name]
        if not p then error("no peripheral named " .. tostring(name)) end
        local fn = p[method]
        if type(fn) ~= "function" then
            error("peripheral '" .. tostring(name) .. "' has no method '" .. tostring(method) .. "'")
        end
        -- Every fake peripheral's methods are plain closures (dot-call
        -- semantics, matching `printer.write(...)`/`monitor.getSize()`
        -- usage elsewhere) - NOT `self`-style, so nothing extra is prepended.
        return fn(...)
    end,
}
rednet = {
    isOpen = function(_) return false end,
    open = function(_) end,
    broadcast = function(_, _) end,
    send = function(_, _, _) end,
    receive = function(_, timeout) if timeout then os.sleep(timeout) end return nil end,
}

-- ---- gps ----
-- Real gps.locate() needs a real GPS host constellation, which this
-- Windows emulation has no equivalent of - returns nil (same as "no GPS
-- network configured", the common real-world default) UNLESS a
-- fake_pos.txt file exists next to this computer's other files, in which
-- case it's read as "x,y,z" - a manual, emulation-only way to test the
-- dashboard's Position column/map without a real Minecraft world at all.
gps = {
    locate = function(_)
        local f = io.open("fake_pos.txt", "r")
        if not f then return nil end
        local line = f:read("l")
        f:close()
        if not line then return nil end
        local x, y, z = line:match("^%s*(-?%d+%.?%d*)%s*,%s*(-?%d+%.?%d*)%s*,%s*(-?%d+%.?%d*)")
        if not x then return nil end
        return tonumber(x), tonumber(y), tonumber(z)
    end,
}
