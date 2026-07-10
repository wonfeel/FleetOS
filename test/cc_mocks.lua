-- Stub/mock implementations of the CC:Tweaked globals used by our code
-- (fs, textutils, os.epoch, sublevel, peripheral, rednet). Load this
-- BEFORE dofile-ing project files to run them under a plain desktop Lua
-- interpreter, outside Minecraft, for local testing.
--
-- Only implements what our scripts actually touch - not a full CraftOS
-- emulator.

local M = {}

-- ---- fs ----
local virtualFiles = {}

-- Reads/writes go to an in-memory table first (so tests never touch real
-- project files); if a path isn't in memory, fall back to the real disk
-- for READS ONLY - this lets fleetos.lua load the real config.lua/apps/*
-- from the project root while still sandboxing anything it writes
-- (rays.dat, fleet_nodes.dat, etc).
-- extracted so fs.exists can check it too - see craftos_shim.lua's
-- identical fix/comment for why (real CraftOS's fs.exists returns true for
-- directories too, but io.open alone never can).
--
-- Tests run on both Windows (local dev) and Linux (CI, see
-- .github/workflows/ci.yml's lua-tests job) - package.config's first
-- character is Lua's own portable way to tell them apart (it's the
-- directory separator package.path uses, no external dependency needed),
-- since io.popen needs a genuinely different command on each: cmd.exe's
-- "if exist" is invalid syntax under /bin/sh and vice versa. Getting this
-- wrong doesn't error, it just silently returns wrong answers on the
-- "other" OS - which is exactly what happened here before this existed
-- (every directory check quietly failed on Linux, since this used to be
-- Windows-only).
local IS_WINDOWS = package.config:sub(1, 1) == "\\"

local function isDirOnDisk(path)
    local pipe
    if IS_WINDOWS then
        local winpath = path:gsub("/", "\\")
        pipe = io.popen('if exist "' .. winpath .. '\\" (echo YES) else (echo NO)')
    else
        pipe = io.popen('[ -d "' .. path .. '" ] && echo YES || echo NO')
    end
    if not pipe then return false end
    local out = pipe:read("l")
    pipe:close()
    return out == "YES"
end

fs = {
    exists = function(path)
        if virtualFiles[path] ~= nil then return true end
        if isDirOnDisk(path) then return true end
        local f = io.open(path, "r")
        if f then f:close(); return true end
        return false
    end,
    open = function(path, mode)
        if mode == "r" then
            if virtualFiles[path] then
                local content = virtualFiles[path]
                return { readAll = function() return content end, close = function() end }
            end
            local f = io.open(path, "r")
            if not f then return nil end
            local content = f:read("a")
            f:close()
            return { readAll = function() return content end, close = function() end }
        else
            local buf = { data = "" }
            return {
                write = function(data) buf.data = buf.data .. data; virtualFiles[path] = buf.data end,
                close = function() end,
            }
        end
    end,
    delete = function(path) virtualFiles[path] = nil end,
    copy = function(src, dst) virtualFiles[dst] = virtualFiles[src] end,
    move = function(from, to)
        if virtualFiles[from] ~= nil then
            virtualFiles[to] = virtualFiles[from]
            virtualFiles[from] = nil
        else
            os.rename(from, to)
        end
    end,
    combine = function(a, b) return a .. "/" .. b end,
    makeDir = function(_) end,
    isDir = isDirOnDisk,
    list = function(path)
        local entries = {}
        local pipe
        if IS_WINDOWS then
            local winpath = path:gsub("/", "\\")
            pipe = io.popen('dir /b "' .. winpath .. '" 2>NUL')
        else
            pipe = io.popen('ls -1 "' .. path .. '" 2>/dev/null')
        end
        if pipe then
            for line in pipe:lines() do entries[#entries + 1] = line end
            pipe:close()
        end
        return entries
    end,
    getSize = function(path)
        if virtualFiles[path] then return #virtualFiles[path] end
        local f = io.open(path, "rb")
        if not f then return 0 end
        local size = f:seek("end")
        f:close()
        return size or 0
    end,
}

-- ---- textutils JSON (used by fleetbridge.lua/fleetgateway.lua to talk to
-- bridge_server.py, or each other over rednet) - identical implementation
-- to windows/craftos_shim.lua's (same source of truth), just also
-- available under the lightweight mock so a test doesn't need the full
-- Windows shim just to exercise JSON-speaking code. ----
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

-- ---- textutils ----
textutils = {
    serializeJSON = jsonEncode,
    unserializeJSON = jsonDecode,
    serialize = function(t)
        -- minimal deterministic serializer good enough for our flat tables
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

-- ---- os additions (real os.clock/os.time exist in stock Lua already) ----
os.epoch = os.epoch or function(_) return math.floor(os.clock() * 1000) end

-- ---- bit: matches CC:Tweaked's bios.lua global `bit` table - same shim
-- as windows/craftos_shim.lua (see that file's comment for the full
-- rationale). Needed so apps/common/_sha256.lua's real HMAC-SHA256 (used by
-- _signed_rednet.lua) works when tests dofile() it under plain desktop Lua.
if not bit then
    local BIT_MASK32 = 0xFFFFFFFF
    bit = {
        band = function(a, b) return (a & b) & BIT_MASK32 end,
        bor = function(a, b) return (a | b) & BIT_MASK32 end,
        bxor = function(a, b) return (a ~ b) & BIT_MASK32 end,
        bnot = function(a) return (~a) & BIT_MASK32 end,
        blshift = function(a, n) return (a << n) & BIT_MASK32 end,
        blogic_rshift = function(a, n) return (a & BIT_MASK32) >> n end,
        brshift = function(a, n)
            -- Same fix as windows/craftos_shim.lua's copy of this shim -
            -- see its comment for why n >= 32 needs special-casing.
            a = a & BIT_MASK32
            if n <= 0 then return a end
            if n >= 32 then
                return (a & 0x80000000) ~= 0 and BIT_MASK32 or 0
            end
            local shifted = (a >> n) & BIT_MASK32
            if (a & 0x80000000) ~= 0 then
                shifted = (shifted | ((BIT_MASK32 << (32 - n)) & BIT_MASK32)) & BIT_MASK32
            end
            return shifted
        end,
    }
end

-- os.pullEventRaw/os.pullEvent/os.startTimer/os.sleep, implemented with
-- real coroutine.yield exactly like CraftOS itself does. This only works
-- correctly when the caller is running inside a coroutine that something
-- else resumes (e.g. fleetos.lua's kernel loop, or the driver script that
-- runs fleetos.lua itself as a coroutine).
local timerCounter = 0
function os.startTimer(_)
    timerCounter = timerCounter + 1
    return timerCounter
end

-- No actual pending-timer bookkeeping here to cancel (unlike real
-- CraftOS/windows/craftos_shim.lua) - a plain no-op is enough for
-- anything that calls this just to avoid firing a stale timeout after
-- getting its real result first (e.g. fleetbridge.lua/fleetgateway.lua's
-- own httpRequest).
function os.cancelTimer(_) end

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

os.getComputerID = os.getComputerID or function() return 0 end
os.computerID = os.computerID or os.getComputerID
-- no-op here (not os.exit) - a real reboot would kill this test process
-- entirely, which would just look like the test hanging/crashing
os.reboot = os.reboot or function() end

-- ---- term (just enough for fleetos.lua's status screen) ----
term = {
    clear = function() end,
    setCursorPos = function(_, _) end,
    write = function(s) io.write(s) end,
    setTextColor = function(_) end,
    setBackgroundColor = function(_) end,
}

-- ---- colors (only names actually used by our monitor/UI code) ----
colors = {
    black = 0, white = 1, gray = 2, lightGray = 3,
    yellow = 4, lime = 5, red = 6, cyan = 7,
}

-- ---- fake sensor data: sublevel API (CC: Sable) ----
-- Lets you fake a tower's position/orientation without a real Sub-Level.
function M.makeFakeSublevel(position, quat)
    return {
        getUniqueId = function() return "mock-uid" end,
        getLogicalPose = function()
            return {
                position = position,
                orientation = { v = { x = quat.x, y = quat.y, z = quat.z }, a = quat.w },
            }
        end,
    }
end

-- ---- shell (CraftOS global program runner, used by fleetos.runShellLine) ----
shell = {
    run = function(...)
        print("[shell.run] " .. table.concat({ ... }, " ") .. " (mocked - no real programs here)")
        return true
    end,
}

-- ---- read/write (CraftOS globals used by shell.lua/fleetmaster.lua) ----
-- read() returns nil (as if stdin hit EOF immediately) so scripted demos
-- don't hang waiting for a human; write() just prints.
function write(s) io.write(tostring(s)) end
function read() return nil end

-- ---- peripheral / rednet stubs (no networking in local tests) ----
peripheral = {
    find = function(_) return nil end,
    getName = function(_) return "mock" end,
    isPresent = function(_) return false end,
    getNames = function() return {} end,
    call = function(name, method, ...) error("peripheral '" .. tostring(name) .. "' not mocked") end,
}
-- A shared in-memory "network": every simulated computer that's been
-- registered (M.rednetJoin) has its own inbox queue. rednetCurrentId is
-- whichever computer's coroutine is CURRENTLY resumed - a test driving
-- several coroutines (one per simulated computer, e.g.
-- test/test_fleetgateway.lua's leader-election scenarios) must call
-- M.rednetSetCurrentComputer(id) right before EVERY resume of that
-- computer's coroutine, since broadcast/send/receive all key off it.
-- receive() yields (rather than ever returning nil on "nothing yet, but
-- not timed out either") when nothing is queued - real CC:Tweaked's
-- rednet.receive is itself a blocking (i.e. coroutine-yielding) call under
-- the hood; a caller's own remaining-time loop (see fleetgateway.lua's
-- main loop) is what actually enforces the timeout by simply not calling
-- receive() again once its own deadline has passed, not this mock.
local rednetInboxes = {}
local rednetCurrentId = nil

function M.rednetJoin(id)
    rednetInboxes[id] = rednetInboxes[id] or {}
end

function M.rednetSetCurrentComputer(id)
    M.rednetJoin(id)
    rednetCurrentId = id
end

-- Non-yielding single check, for a test-side "observer" that isn't itself
-- running inside a coroutine (unlike a real gateway) - returns nil
-- immediately if nothing's queued instead of blocking, so plain test code
-- can drain an inbox in a tight loop without ever needing coroutine.yield.
function M.rednetTryReceive(id, protocolFilter)
    local inbox = rednetInboxes[id]
    if not inbox then return nil end
    for i, entry in ipairs(inbox) do
        if not protocolFilter or entry.protocol == protocolFilter then
            table.remove(inbox, i)
            return entry.senderId, entry.message, entry.protocol
        end
    end
    return nil
end

rednet = {
    isOpen = function(_) return true end,
    open = function(_) end,
    broadcast = function(message, protocol)
        for id, inbox in pairs(rednetInboxes) do
            if id ~= rednetCurrentId then
                inbox[#inbox + 1] = { senderId = rednetCurrentId, message = message, protocol = protocol }
            end
        end
    end,
    send = function(targetId, message, protocol)
        local inbox = rednetInboxes[targetId]
        if inbox then
            inbox[#inbox + 1] = { senderId = rednetCurrentId, message = message, protocol = protocol }
        end
    end,
    -- Respects its own `timeout` (seconds) via os.epoch("utc"), same as
    -- real CC:Tweaked - a caller like fleetgateway.lua that ALSO tracks
    -- its own outer deadline via os.epoch relies on this returning nil
    -- once time's actually up, not looping forever until a message shows.
    -- A test controlling a fake, manually-advanced os.epoch (see
    -- test/test_fleetgateway.lua) uses this to deterministically simulate
    -- "no message arrived before timeout" without any real wall-clock
    -- delay.
    receive = function(protocolFilter, timeout)
        local deadline = timeout and (os.epoch("utc") + timeout * 1000) or nil
        while true do
            local inbox = rednetInboxes[rednetCurrentId]
            if inbox then
                for i, entry in ipairs(inbox) do
                    if not protocolFilter or entry.protocol == protocolFilter then
                        table.remove(inbox, i)
                        return entry.senderId, entry.message, entry.protocol
                    end
                end
            end
            if deadline and os.epoch("utc") >= deadline then
                return nil
            end
            coroutine.yield("rednet_mock_wait")
        end
    end,
}

-- ---- gps ----
-- Real CraftOS's gps.locate() needs a GPS host constellation (4+ wireless
-- modems); returning nil (as if none exists) matches that "no GPS network
-- configured" case, which is the common/default case for a fresh fleet -
-- tests exercising a real fix should override this per-test.
gps = {
    locate = function(_, _) return nil end,
}

return M
