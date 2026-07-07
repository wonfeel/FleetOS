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
-- from H:\MinecraftCode while still sandboxing anything it writes
-- (rays.dat, fleet_nodes.dat, etc).
-- extracted so fs.exists can check it too - see craftos_shim.lua's
-- identical fix/comment for why (real CraftOS's fs.exists returns true for
-- directories too, but io.open alone never can).
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
        if virtualFiles[path] then return #virtualFiles[path] end
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
rednet = {
    isOpen = function(_) return true end,
    open = function(_) end,
    broadcast = function(_, _) end,
    send = function(_, _, _) end,
    receive = function(_, _) return nil end,
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
