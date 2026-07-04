-- FleetOS app: continuous tower polling + position solve + monitor display.
-- Runs as a background task under fleetos.lua (add "raytower_master" to
-- config.lua's startup list on the master node).
--
-- forward/qsign come from config.lua (fields raytowerForward, raytowerQSign).
-- To FIND the right values, use the standalone raytower.lua's
-- "master calibrate" command first (it's a one-off diagnostic tool, not
-- meant to run under the kernel).

local Triangulator = dofile("triangulation.lua")

local PROTOCOL = "raytower"
local DATA_FILE = "rays.dat"
local POLL_INTERVAL = 1.0
local RESPONSE_WINDOW = 0.4

local cfg = {}
if fs.exists("config.lua") then
    local ok, c = pcall(dofile, "config.lua")
    if ok and type(c) == "table" then cfg = c end
end

local forward = cfg.raytowerForward or { x = 1, y = 0, z = 0 }
local qsignCfg = cfg.raytowerQSign or { 1, 1, 1 }
local tri = Triangulator.new(forward, qsignCfg)

local modem = peripheral.find("modem")
if not modem then
    print("[raytower_master] No modem found")
    return
end
if not rednet.isOpen(peripheral.getName(modem)) then
    rednet.open(peripheral.getName(modem))
end

local function loadRays()
    if not fs.exists(DATA_FILE) then return {} end
    local f = fs.open(DATA_FILE, "r")
    local data = f.readAll()
    f.close()
    local ok, result = pcall(textutils.unserialize, data)
    return (ok and type(result) == "table") and result or {}
end

local function saveRays(rawRays)
    local f = fs.open(DATA_FILE, "w")
    f.write(textutils.serialize(rawRays))
    f.close()
end

local function rebuildTriangulator(rawRays)
    tri:clear()
    for id, r in pairs(rawRays) do
        tri:addRay(id, r.origin, r.quat)
    end
end

-- optional monitor peripheral - claimed so the kernel's terminal mirror
-- (fleetos.lua) doesn't fight this app for the same screen
local monitor = peripheral.find("monitor")
if monitor then
    monitor.setTextScale(1)
    fleetos.claimMonitor()
end

local function drawMonitor(pos, err, rawRays)
    if not monitor then return end
    local w, h = monitor.getSize()

    local function line(y, text, color)
        monitor.setCursorPos(1, y)
        monitor.clearLine()
        if color then monitor.setTextColor(color) end
        monitor.write(text)
        monitor.setTextColor(colors.white)
    end

    local function centered(y, text, color)
        local x = math.max(1, math.floor((w - #text) / 2) + 1)
        monitor.setCursorPos(x, y)
        monitor.clearLine()
        if color then monitor.setTextColor(color) end
        monitor.write(text)
        monitor.setTextColor(colors.white)
    end

    monitor.setBackgroundColor(colors.black)
    monitor.clear()

    line(1, string.rep("=", w), colors.gray)
    centered(2, "RAY TRIANGULATION", colors.yellow)
    line(3, string.rep("=", w), colors.gray)

    local row = 5
    local ids = {}
    for id in pairs(rawRays) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local r = rawRays[id]
        line(row, ("%-16s %8.1f,%7.1f,%8.1f"):format(id, r.origin.x, r.origin.y, r.origin.z), colors.lightGray)
        row = row + 1
    end

    line(row + 1, string.rep("-", w), colors.gray)

    if pos then
        centered(row + 3, ("X: %.2f"):format(pos.x), colors.lime)
        centered(row + 4, ("Y: %.2f"):format(pos.y), colors.lime)
        centered(row + 5, ("Z: %.2f"):format(pos.z), colors.lime)
    elseif err then
        centered(row + 3, err, colors.red)
    end

    line(h, string.rep("=", w), colors.gray)
end

print("[raytower_master] polling towers")

local rawRays = loadRays()
local lastPrintedErr = nil

while true do
    rednet.broadcast({ type = "poll" }, PROTOCOL)

    local respondedNow = {}
    local deadline = os.epoch("utc") + RESPONSE_WINDOW * 1000

    while true do
        local remaining = (deadline - os.epoch("utc")) / 1000
        if remaining <= 0 then break end

        local senderId, message, protocol = rednet.receive(PROTOCOL, remaining)
        if senderId and protocol == PROTOCOL and type(message) == "table" and message.type == "report"
           and message.id and message.origin and message.quat then
            rawRays[message.id] = { origin = message.origin, quat = message.quat }
            respondedNow[message.id] = true
        end
    end

    for id in pairs(rawRays) do
        if not respondedNow[id] then
            rawRays[id] = nil
        end
    end

    rebuildTriangulator(rawRays)
    local pos, err = tri:solve()
    if pos then
        print(("[raytower_master] %.2f, %.2f, %.2f (towers: %d)"):format(pos.x, pos.y, pos.z, tri:count()))
    elseif err ~= lastPrintedErr then
        -- only on change, not every second - a dead/undershot tower set
        -- would otherwise spam this line forever
        print("[raytower_master] " .. tostring(err))
    end
    lastPrintedErr = err
    drawMonitor(pos, err, rawRays)

    saveRays(rawRays)
    os.sleep(POLL_INTERVAL)
end
