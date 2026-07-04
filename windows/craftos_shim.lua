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

-- ---- fs: real disk, rooted at the current working directory ----
fs = {
    exists = function(path)
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
    delete = function(path) os.remove(path) end,
    copy = function(src, dst)
        local i = io.open(src, "r")
        if not i then return end
        local data = i:read("a")
        i:close()
        local o = io.open(dst, "w")
        o:write(data)
        o:close()
    end,
    combine = function(a, b) return a .. "/" .. b end,
    makeDir = function(path)
        os.execute(('mkdir "%s" 2>NUL'):format(path:gsub("/", "\\")))
    end,
    isDir = function(path)
        local winpath = path:gsub("/", "\\")
        local pipe = io.popen('if exist "' .. winpath .. '\\" (echo YES) else (echo NO)')
        if not pipe then return false end
        local out = pipe:read("l")
        pipe:close()
        return out == "YES"
    end,
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

function os.pullEventRaw(filter)
    return coroutine.yield(filter)
end

function os.pullEvent(filter)
    local event = { coroutine.yield(filter) }
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
colors = {
    black = 0, white = 1, gray = 2, lightGray = 3,
    yellow = 4, lime = 5, red = 6, cyan = 7,
}
local ANSI_FG = {
    [0] = 30, [1] = 97, [2] = 90, [3] = 37,
    [4] = 33, [5] = 92, [6] = 31, [7] = 36,
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
-- C:\Windows\System32\curl.exe). Only implements what fleetbridge.lua
-- needs: http.get(url, headers) / http.post(url, body, headers), each
-- returning a CC:Tweaked-style response handle or (nil, error). ----

local function shellQuote(s)
    return '"' .. s .. '"'
end

local function httpRequest(method, url, body, headers)
    local bodyOutFile = os.tmpname()
    local dataFile

    local args = { "-X", method }
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
}

-- ---- peripheral / rednet / sublevel: no real game hardware on Windows ----
-- peripheral.find("modem") returns a dummy modem so apps that require one
-- (fleetnet, fleetbridge, raytower_master/slave) get past that check and
-- reach their HTTP/logic - there's just nobody else to talk to over
-- rednet (broadcast/send are no-ops, receive always "times out" as nil).
-- peripheral.find("monitor") stays nil - no fake monitor to draw to.
local FAKE_MODEM = { name = "fake_modem" }

peripheral = {
    find = function(kind)
        if kind == "modem" then return FAKE_MODEM end
        return nil
    end,
    getName = function(_) return "fake_modem" end,
}
rednet = {
    isOpen = function(_) return false end,
    open = function(_) end,
    broadcast = function(_, _) end,
    send = function(_, _, _) end,
    receive = function(_, timeout) if timeout then os.sleep(timeout) end return nil end,
}
