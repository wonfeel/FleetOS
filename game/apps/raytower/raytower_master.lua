-- FleetOS app: continuous tower polling + position solve + monitor display.
-- Runs as a background task under fleetos.lua (add "raytower_master" to
-- config.lua's startup list on the master node).
--
-- forward/qsign come from config.lua (fields raytowerForward, raytowerQSign).
-- To FIND the right values, use the standalone raytower.lua's
-- "master calibrate" command first (it's a one-off diagnostic tool, not
-- meant to run under the kernel).

local Triangulator = dofile("triangulation.lua")
local RaytowerAuth = dofile("apps/raytower/_raytower_auth.lua")

local PROTOCOL = "raytower"
local DATA_FILE = "rays.dat"
local RESPONSE_WINDOW = 0.4

local cfg = {}
if fs.exists("config.lua") then
    local ok, c = pcall(dofile, "config.lua")
    if ok and type(c) == "table" then cfg = c end
end

-- this loop broadcasts on rednet + waits for every tower's response
-- once per interval - real server load (rednet packets + the receiving
-- computers waking to answer), not just this one computer's CPU, which is
-- a real TPS risk with many towers/masters. Two mitigations:
-- 1) cfg.raytowerPollInterval lets an operator explicitly trade off
--    responsiveness vs. server load for their own setup (default unchanged
--    at 1s, same as before this existed).
-- 2) Adaptive backoff (POLL_INTERVAL_IDLE_MULTIPLIER below): once the
--    solved position AND the exact set of responding towers have been
--    stable for STABLE_CYCLES_BEFORE_BACKOFF consecutive cycles, the
--    interval gradually backs off up to that multiplier - a parked/idle
--    rig (the common case - most of the time nothing is actually moving)
--    generates proportionally less rednet traffic, while any real change
--    (a tower answering/dropping out, the position actually moving)
--    immediately resets back to the fast interval.
local POLL_INTERVAL_BASE = cfg.raytowerPollInterval or 1.0
local POLL_INTERVAL_IDLE_MULTIPLIER = 3
local STABLE_CYCLES_BEFORE_BACKOFF = 10
local POSITION_STABLE_EPSILON = 0.05 -- blocks; smaller movement than this still counts as "stable"

local forward = cfg.raytowerForward or { x = 1, y = 0, z = 0 }
local qsignCfg = cfg.raytowerQSign or { 1, 1, 1 }
local tri = Triangulator.new(forward, qsignCfg)

-- shared secret for signing/verifying rednet traffic - see
-- raytower_auth.lua's header for exactly what this does and doesn't
-- protect against. "" (unset) means unsigned, matching previous behavior -
-- set the SAME raytowerSecret in both the master's and every slave's
-- config.lua to turn this on for a fleet.
local RAYTOWER_SECRET = cfg.raytowerSecret or ""
if RAYTOWER_SECRET == "" then
    print("[raytower_master] WARNING: raytowerSecret not set in config.lua - rednet traffic is unsigned")
end

-- This is a ~1s realtime control loop (see POLL_INTERVAL/RESPONSE_WINDOW
-- below), not a one-shot bootstrap - a slow/dead bridge must fail fast and
-- fall back to the local Triangulator rather than visibly freezing the
-- monitor, unlike apps/common/fleetbridge.lua's 8s bootstrap-style budget.
local BRIDGE_TIMEOUT = 0.3

-- Offloads the same math tri:solve() does to windows/compute/triangulation.py
-- (or .cpp once compiled) via the bridge's generic POST /compute/<name>
-- route. Only ever attempted if
-- `http` exists and cfg.bridgeUrl is set; the caller falls back to the
-- local Triangulator on ANY failure (missing http, no bridgeUrl, timeout,
-- bad response), so a node with no PC/bridge configured behaves exactly as
-- it did before this existed.
local function solveViaBridge(rays)
    if not http or not cfg.bridgeUrl then
        return nil, "bridge not configured"
    end

    local body = textutils.serializeJSON({ forward = forward, qsign = qsignCfg, rays = rays })
    local url = cfg.bridgeUrl .. "/compute/triangulation"

    http.request({ url = url, body = body, headers = { ["Content-Type"] = "application/json" }, timeout = BRIDGE_TIMEOUT })
    local timerId = os.startTimer(BRIDGE_TIMEOUT)
    local resp, err
    while true do
        local event, a, b = os.pullEvent()
        if event == "http_success" and a == url then
            os.cancelTimer(timerId)
            resp = b
            break
        elseif event == "http_failure" and a == url then
            os.cancelTimer(timerId)
            err = b
            break
        elseif event == "timer" and a == timerId then
            err = "bridge request timed out"
            break
        end
    end
    if not resp then
        return nil, err or "bridge request failed"
    end

    local respBody = resp.readAll()
    resp.close()
    local ok, decoded = pcall(textutils.unserializeJSON, respBody)
    if not ok or type(decoded) ~= "table" then
        return nil, "bad response from bridge"
    end
    if not decoded.ok then
        return nil, decoded.error or "bridge solve failed"
    end
    return { x = decoded.x, y = decoded.y, z = decoded.z }
end

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
local lastViaBridge = nil

local lastAuthWarn = nil

-- adaptive backoff bookkeeping - see POLL_INTERVAL_BASE's comment above.
local function respondingTowerSetKey(respondedNow)
    local ids = {}
    for id in pairs(respondedNow) do ids[#ids + 1] = id end
    table.sort(ids)
    return table.concat(ids, ",")
end

local lastTowerSetKey = nil
local lastStablePos = nil
local stableCycles = 0

while true do
    rednet.broadcast(RaytowerAuth.sign({ type = "poll" }, RAYTOWER_SECRET), PROTOCOL)

    local respondedNow = {}
    local deadline = os.epoch("utc") + RESPONSE_WINDOW * 1000

    while true do
        local remaining = (deadline - os.epoch("utc")) / 1000
        if remaining <= 0 then break end

        local senderId, message, protocol = rednet.receive(PROTOCOL, remaining)
        if senderId and protocol == PROTOCOL and type(message) == "table" and message.type == "report"
           and message.id and message.origin and message.quat then
            local okAuth, authErr = RaytowerAuth.verify(message, RAYTOWER_SECRET)
            if okAuth then
                rawRays[message.id] = { origin = message.origin, quat = message.quat }
                respondedNow[message.id] = true
            elseif authErr ~= lastAuthWarn then
                print("[raytower_master] rejected report from '" .. tostring(message.id) .. "': " .. tostring(authErr))
                lastAuthWarn = authErr
            end
        end
    end

    for id in pairs(rawRays) do
        if not respondedNow[id] then
            rawRays[id] = nil
        end
    end

    rebuildTriangulator(rawRays)

    -- Try the bridge first (if configured, and only worth attempting once
    -- there are enough rays to solve at all) - fall back to the local
    -- Triangulator on any failure. See solveViaBridge's own comment for why
    -- this can never make a standalone (no PC/bridge) node worse off.
    local pos, err, viaBridge
    if tri:count() >= 2 then
        local rays = {}
        for _, r in pairs(rawRays) do
            rays[#rays + 1] = { origin = r.origin, quat = r.quat }
        end
        pos, err = solveViaBridge(rays)
        viaBridge = pos ~= nil
    end
    if not pos then
        pos, err = tri:solve()
        viaBridge = false
    end

    if viaBridge ~= lastViaBridge then
        print("[raytower_master] solving via " .. (viaBridge and "bridge (windows/compute)" or "local Lua"))
        lastViaBridge = viaBridge
    end

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

    -- back off the poll interval once BOTH the responding-tower set
    -- and the solved position have been stable for a while - any change
    -- (a tower joins/drops, the rig actually moves, solving starts/stops
    -- failing) immediately resets to the fast interval, so this never adds
    -- perceptible lag to a genuinely live/moving rig.
    local towerSetKey = respondingTowerSetKey(respondedNow)
    local positionMoved = true
    if pos and lastStablePos then
        local dx, dy, dz = pos.x - lastStablePos.x, pos.y - lastStablePos.y, pos.z - lastStablePos.z
        positionMoved = math.sqrt(dx * dx + dy * dy + dz * dz) > POSITION_STABLE_EPSILON
    end
    if not pos or towerSetKey ~= lastTowerSetKey or positionMoved then
        stableCycles = 0
    else
        stableCycles = stableCycles + 1
    end
    lastTowerSetKey = towerSetKey
    if pos then lastStablePos = pos end

    local intervalFactor = (stableCycles >= STABLE_CYCLES_BEFORE_BACKOFF) and POLL_INTERVAL_IDLE_MULTIPLIER or 1
    os.sleep(POLL_INTERVAL_BASE * intervalFactor)
end
