-- Shared library: trilateration from rays (origin + quaternion direction).
-- Used by apps/raytower_master.lua. Loaded with dofile("triangulation.lua").

local Triangulator = {}
Triangulator.__index = Triangulator

function Triangulator.new(forward, qsign)
    local self = setmetatable({}, Triangulator)
    self.rays = {}
    self.forward = forward or { x = 1, y = 0, z = 0 }
    -- qsign flips the sign of the quaternion's x/y/z components before
    -- rotating - find the right combo with 'calibrate' in raytower_master.
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
Triangulator.rotateByQuaternion = rotateByQuaternion

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

return Triangulator
