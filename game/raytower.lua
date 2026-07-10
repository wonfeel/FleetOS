-- raytower.lua
-- Everything in one file: triangulation math, master logic, slave logic.
-- The same file is uploaded to ALL computers (master and every tower),
-- the role is chosen by the first argument at launch.
--
-- Usage:
--   raytower slave                       -- run on a tower (needs CC: Sable, computer on a Sub-Level)
--   raytower master listen               -- run on master, auto-polls towers
--   raytower master add <id> <x> <y> <z> <qx> <qy> <qz> <qw>  -- add a ray manually
--   raytower master remove <id>
--   raytower master list
--   raytower master solve
--   raytower master clear
--
-- note: this standalone tool's rednet traffic is UNSIGNED, unlike
-- apps/raytower/raytower_master.lua|raytower_slave.lua (which support a
-- shared raytowerSecret via apps/common/_signed_rednet.lua). Deliberate -
-- this file is intentionally a single, dependency-free file for one-off
-- calibration sessions (see the header above), and pulling in the auth
-- module would mean uploading two files instead of one. Only use this for
-- a supervised calibration session, not as a long-running unattended master/
-- slave - use the signed apps/raytower/*.lua versions under the kernel for
-- that instead.

local PROTOCOL = "raytower"

-- ============================================================
-- Triangulator - trilateration from rays (origin + quaternion)
-- ============================================================

local Triangulator = {}
Triangulator.__index = Triangulator

-- forward - base vector rotated by the quaternion to get the ray's
-- direction. Verify it empirically on your tower - adjust to
-- {0,0,-1}, {1,0,0} etc. if needed.
function Triangulator.new(forward, qsign)
    local self = setmetatable({}, Triangulator)
    self.rays = {}
    self.forward = forward or { x = 1, y = 0, z = 0 }
    -- qsign flips the sign of the quaternion's x/y/z components before
    -- rotating - find the right combo with 'raytower master calibrate'
    self.qsign = qsign or { 1, 1, 1 }
    return self
end

local function rotateByQuaternion(q, v)
    local qx, qy, qz, qw = q.x, q.y, q.z, q.w
    local tx = 2 * (qy * v.z - qz * v.y)
    local ty = 2 * (qz * v.x - qx * v.z)
    local tz = 2 * (qx * v.y - qy * v.x)
    local cx = qy * tz - qz * ty
    local cy = qz * tx - qx * tz
    local cz = qx * ty - qy * tx
    return {
        x = v.x + qw * tx + cx,
        y = v.y + qw * ty + cy,
        z = v.z + qw * tz + cz,
    }
end

local function normalize(v)
    local len = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
    if len < 1e-9 then return { x = 0, y = 0, z = 0 } end
    return { x = v.x / len, y = v.y / len, z = v.z / len }
end

function Triangulator:addRay(id, origin, quat)
    local s = self.qsign
    local sq = { x = quat.x * s[1], y = quat.y * s[2], z = quat.z * s[3], w = quat.w }
    local dir = normalize(rotateByQuaternion(sq, self.forward))
    self.rays[id] = { origin = origin, dir = dir }
end

function Triangulator:removeRay(id)
    self.rays[id] = nil
end

function Triangulator:clear()
    self.rays = {}
end

function Triangulator:count()
    local n = 0
    for _ in pairs(self.rays) do n = n + 1 end
    return n
end

local function solve3x3(A, b)
    local function det3(m)
        return m[1][1] * (m[2][2] * m[3][3] - m[2][3] * m[3][2])
             - m[1][2] * (m[2][1] * m[3][3] - m[2][3] * m[3][1])
             + m[1][3] * (m[2][1] * m[3][2] - m[2][2] * m[3][1])
    end

    local D = det3(A)
    if math.abs(D) < 1e-9 then
        return nil
    end

    local function replaceCol(col, vec)
        local r = {
            { A[1][1], A[1][2], A[1][3] },
            { A[2][1], A[2][2], A[2][3] },
            { A[3][1], A[3][2], A[3][3] },
        }
        r[1][col] = vec[1]
        r[2][col] = vec[2]
        r[3][col] = vec[3]
        return r
    end

    local Dx = det3(replaceCol(1, b))
    local Dy = det3(replaceCol(2, b))
    local Dz = det3(replaceCol(3, b))

    return { Dx / D, Dy / D, Dz / D }
end

function Triangulator:solve()
    local n = self:count()
    if n < 2 then
        return nil, "need at least 2 rays"
    end

    local A = { { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 } }
    local b = { 0, 0, 0 }

    for _, ray in pairs(self.rays) do
        local d, p = ray.dir, ray.origin

        local M = {
            { 1 - d.x * d.x,     - d.x * d.y,     - d.x * d.z },
            {     - d.y * d.x, 1 - d.y * d.y,     - d.y * d.z },
            {     - d.z * d.x,     - d.z * d.y, 1 - d.z * d.z },
        }

        for i = 1, 3 do
            for j = 1, 3 do
                A[i][j] = A[i][j] + M[i][j]
            end
        end

        local px, py, pz = p.x, p.y, p.z
        b[1] = b[1] + (M[1][1] * px + M[1][2] * py + M[1][3] * pz)
        b[2] = b[2] + (M[2][1] * px + M[2][2] * py + M[2][3] * pz)
        b[3] = b[3] + (M[3][1] * px + M[3][2] * py + M[3][3] * pz)
    end

    local result = solve3x3(A, b)
    if not result then
        return nil, "rays are parallel or the system is degenerate"
    end

    return { x = result[1], y = result[2], z = result[3] }
end

-- ============================================================
-- Slave - runs on a tower
-- ============================================================

local function runSlave()
    -- tower identity comes from the Sub-Level itself (CC: Sable)
    local ok, uid = pcall(function() return sublevel.getUniqueId() end)
    if not ok then
        print("Computer is not on a Sub-Level (CC: Sable)")
        return
    end
    local TOWER_ID = "tower_" .. uid

    local modem = peripheral.find("modem")
    if not modem then
        print("No modem found")
        return
    end
    rednet.open(peripheral.getName(modem))

    if not fs.exists("startup.lua") then
        local f = fs.open("startup.lua", "w")
        f.write('shell.run("raytower", "slave")')
        f.close()
    end

    print("Slave '" .. TOWER_ID .. "' ready, waiting for master poll...")

    while true do
        local senderId, message = rednet.receive(PROTOCOL)

        if type(message) == "table" and message.type == "poll" then
            -- position and orientation come straight from CC: Sable's
            -- sublevel.getLogicalPose(). NOTE: the docs describe this table's
            -- contents in plain English ("position, orientation, scale,
            -- rotation point") without listing exact Lua key names. If this
            -- errors or returns nil, run:
            --   print(textutils.serialize(sublevel.getLogicalPose()))
            -- once in-game and fix the two field names below to match.
            local ok2, pos, quat = pcall(function()
                local pose = sublevel.getLogicalPose()
                local p = pose.position    -- vector {x,y,z} - verify key name
                local q = pose.orientation -- quaternion {v={x,y,z}, a=w} - verify key name
                return { x = p.x, y = p.y, z = p.z },
                       { x = q.v.x, y = q.v.y, z = q.v.z, w = q.a }
            end)

            if not ok2 then
                print("Computer is not on a Sub-Level (CC: Sable), ray not sent")
            else
                rednet.send(senderId, {
                    type = "report",
                    id = TOWER_ID,
                    origin = pos,
                    quat = quat,
                }, PROTOCOL)
            end
        end
    end
end

-- ============================================================
-- Master - coordinator, polls towers and computes the position
-- ============================================================

local function runMaster(subArgs)
    local DATA_FILE = "rays.dat"
    local POLL_INTERVAL = 0.2
    local RESPONSE_WINDOW = 0.3

    -- forward vector + quaternion sign flips can be overridden without
    -- editing the file, using the numbers 'raytower master calibrate' finds:
    --   raytower master listen 1 0 0 -1 1 1
    -- (defaults to forward={0,0,1}, qsign={1,1,1} if not given)
    local fx = tonumber(subArgs[2]) or 1
    local fy = tonumber(subArgs[3]) or 0
    local fz = tonumber(subArgs[4]) or 0
    local sx = tonumber(subArgs[5]) or 1
    local sy = tonumber(subArgs[6]) or 1
    local sz = tonumber(subArgs[7]) or 1
    if subArgs[2] then
        print(("Using forward = (%.0f, %.0f, %.0f), qsign = (%.0f, %.0f, %.0f)")
            :format(fx, fy, fz, sx, sy, sz))
    end
    local tri = Triangulator.new({ x = fx, y = fy, z = fz }, { sx, sy, sz })

    local function loadRays()
        if not fs.exists(DATA_FILE) then return {} end
        local f = fs.open(DATA_FILE, "r")
        local data = f.readAll()
        f.close()
        local ok, result = pcall(textutils.unserialize, data)
        if ok and type(result) == "table" then return result end
        return {}
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

    -- optional monitor peripheral - shows the position in-game without
    -- needing to look at the computer terminal
    local monitor = peripheral.find("monitor")
    if monitor then
        monitor.setTextScale(1)
        monitor.setBackgroundColor(colors.black)
        monitor.setTextColor(colors.white)
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

    local function printSolved(rawRays)
        rebuildTriangulator(rawRays)
        local pos, err = tri:solve()
        if pos then
            print(("Position: %.2f, %.2f, %.2f"):format(pos.x, pos.y, pos.z))
        elseif err then
            print(err)
        end
        drawMonitor(pos, err, rawRays)
    end

    local cmd = (subArgs[1] or ""):gsub("^%-%-", "")
    local rawRays = loadRays()
    local DEBUG -- set below (subArgs[2]/[5] == "debug"); nil is falsy just like false, so no initializer needed

    if cmd == "add" then
        local id = subArgs[2]
        local x, y, z = tonumber(subArgs[3]), tonumber(subArgs[4]), tonumber(subArgs[5])
        local qx, qy, qz, qw = tonumber(subArgs[6]), tonumber(subArgs[7]), tonumber(subArgs[8]), tonumber(subArgs[9])
        if not (id and x and y and z and qx and qy and qz and qw) then
            print("Usage: raytower master add <id> <x> <y> <z> <qx> <qy> <qz> <qw>")
            return
        end
        rawRays[id] = { origin = { x = x, y = y, z = z }, quat = { x = qx, y = qy, z = qz, w = qw } }
        saveRays(rawRays)
        print("Ray '" .. id .. "' added/updated")
        printSolved(rawRays)

    elseif cmd == "remove" then
        local id = subArgs[2]
        if not id then print("Usage: raytower master remove <id>"); return end
        rawRays[id] = nil
        saveRays(rawRays)
        print("Ray '" .. id .. "' removed")
        printSolved(rawRays)

    elseif cmd == "list" then
        local n = 0
        for id, r in pairs(rawRays) do
            n = n + 1
            print(("%s: %.2f, %.2f, %.2f"):format(id, r.origin.x, r.origin.y, r.origin.z))
        end
        if n == 0 then print("No rays") end

    elseif cmd == "clear" then
        rawRays = {}
        saveRays(rawRays)
        print("All rays removed")

    elseif cmd == "solve" then
        printSolved(rawRays)

    elseif cmd == "calibrate" then
        -- raytower master calibrate <targetX> <targetY> <targetZ>
        -- Stand exactly where the towers are aimed, read your own
        -- coordinates (F3), run this. It brute-forces every forward-axis
        -- and quaternion sign combination against the towers' last known
        -- origin/quat (from rays.dat) and ranks them by angular error to
        -- the real target, so you don't have to guess forward/invert by hand.
        local tx, ty, tz = tonumber(subArgs[2]), tonumber(subArgs[3]), tonumber(subArgs[4])
        if not (tx and ty and tz) then
            print("Usage: raytower master calibrate <targetX> <targetY> <targetZ>")
            return
        end

        local n = 0
        for _ in pairs(rawRays) do n = n + 1 end
        if n == 0 then
            print("No rays known yet - run 'listen' for a moment first so rays.dat has data")
            return
        end

        local function normv(v)
            local len = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
            if len < 1e-9 then return v end
            return { x = v.x / len, y = v.y / len, z = v.z / len }
        end

        local function angleDeg(a, b)
            local dot = a.x * b.x + a.y * b.y + a.z * b.z
            if dot > 1 then dot = 1 elseif dot < -1 then dot = -1 end
            return math.deg(math.acos(dot))
        end

        local axes = {
            { x = 1, y = 0, z = 0 }, { x = -1, y = 0, z = 0 },
            { x = 0, y = 1, z = 0 }, { x = 0, y = -1, z = 0 },
            { x = 0, y = 0, z = 1 }, { x = 0, y = 0, z = -1 },
        }
        local signs = {
            { 1, 1, 1 }, { -1, 1, 1 }, { 1, -1, 1 }, { 1, 1, -1 },
            { -1, -1, 1 }, { -1, 1, -1 }, { 1, -1, -1 }, { -1, -1, -1 },
        }

        local results = {}
        for _, forward in ipairs(axes) do
            for _, s in ipairs(signs) do
                local totalErr, count = 0, 0
                for _, r in pairs(rawRays) do
                    local q = r.quat
                    local sq = { x = q.x * s[1], y = q.y * s[2], z = q.z * s[3], w = q.w }
                    local dir = normv(rotateByQuaternion(sq, forward))
                    local trueDir = normv({ x = tx - r.origin.x, y = ty - r.origin.y, z = tz - r.origin.z })
                    totalErr = totalErr + angleDeg(dir, trueDir)
                    count = count + 1
                end
                results[#results + 1] = {
                    forward = forward, sign = s, avgErr = totalErr / count,
                }
            end
        end

        table.sort(results, function(a, b) return a.avgErr < b.avgErr end)

        print("Best forward/sign combinations (lower = better):")
        for i = 1, math.min(5, #results) do
            local r = results[i]
            print(("%d) forward=(%.0f,%.0f,%.0f) qsign=(%.0f,%.0f,%.0f) err=%.2f deg")
                :format(i, r.forward.x, r.forward.y, r.forward.z, r.sign[1], r.sign[2], r.sign[3], r.avgErr))
        end
        print("Apply the #1 result: edit self.forward and the quat sign flip in addRay.")

    elseif cmd == "listen" then
        -- raytower master listen [fx fy fz] [debug]
        DEBUG = (subArgs[2] == "debug") or (subArgs[5] == "debug")
        local modem = peripheral.find("modem")
        if not modem then
            print("No modem found (wireless/ender)")
            return
        end
        rednet.open(peripheral.getName(modem))

        if not fs.exists("startup.lua") then
            local f = fs.open("startup.lua", "w")
            f.write('shell.run("raytower", "master", "listen")')
            f.close()
        end

        print("Master started, polling towers on '" .. PROTOCOL .. "'... (Ctrl+T to stop)")

        while true do
            rednet.broadcast({ type = "poll" }, PROTOCOL)

            local respondedNow = {}
            local deadline = os.epoch("utc") + RESPONSE_WINDOW * 1000

            while true do
                local remaining = (deadline - os.epoch("utc")) / 1000
                if remaining <= 0 then break end

                local senderId, message = rednet.receive(PROTOCOL, remaining)
                if senderId and type(message) == "table" and message.type == "report"
                   and message.id and message.origin and message.quat then
                    rawRays[message.id] = { origin = message.origin, quat = message.quat }
                    respondedNow[message.id] = true
                    if DEBUG then
                        local o, q = message.origin, message.quat
                        print(("%s origin=(%.2f,%.2f,%.2f) quat=(%.3f,%.3f,%.3f,%.3f)")
                            :format(message.id, o.x, o.y, o.z, q.x, q.y, q.z, q.w))
                    end
                end
            end

            for id in pairs(rawRays) do
                if not respondedNow[id] then
                    print("Tower '" .. id .. "' did not respond, removed")
                    rawRays[id] = nil
                end
            end

            rebuildTriangulator(rawRays)
            local pos, err = tri:solve()
            if pos then
                print(("Position: %.2f, %.2f, %.2f (towers: %d)"):format(pos.x, pos.y, pos.z, tri:count()))
            end
            drawMonitor(pos, err, rawRays)

            saveRays(rawRays)
            sleep(POLL_INTERVAL)
        end

    else
        print("Commands: add, remove, list, clear, solve, listen")
    end
end

-- ============================================================
-- Entry point - role selected by the first argument
-- ============================================================

local args = { ... }
local role = (args[1] or ""):gsub("^%-%-", "")

if role == "slave" then
    runSlave()

elseif role == "master" then
    local subArgs = {}
    for i = 2, #args do subArgs[#subArgs + 1] = args[i] end
    runMaster(subArgs)

else
    print("Usage:")
    print("  raytower slave")
    print("  raytower master listen")
    print("  raytower master add|remove|list|clear|solve ...")
end
