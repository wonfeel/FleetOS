-- Runs the real game/triangulation.lua against synthetic ("fake sensor")
-- ray data with a known target, to verify the math actually converges.
-- Run with (cwd must be game/, same as a real CC computer's root):
--   cd game
--   lua ..\test\test_triangulation.lua

dofile("../test/cc_mocks.lua")

local Triangulator = dofile("triangulation.lua")

-- Builds the shortest-arc quaternion that rotates `from` onto `to`
-- (both must be unit vectors). Used here to fabricate a fake tower's
-- orientation quaternion that points exactly at a chosen target.
local function shortestArcQuat(from, to)
    local dot = from.x * to.x + from.y * to.y + from.z * to.z
    if dot < -0.999999 then
        -- 180 degree case: pick any perpendicular axis
        local axis = { x = 0, y = 1, z = 0 }
        return { x = axis.x, y = axis.y, z = axis.z, w = 0 }
    end
    local cx = from.y * to.z - from.z * to.y
    local cy = from.z * to.x - from.x * to.z
    local cz = from.x * to.y - from.y * to.x
    local w = 1 + dot
    local q = { x = cx, y = cy, z = cz, w = w }
    local len = math.sqrt(q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w)
    return { x = q.x / len, y = q.y / len, z = q.z / len, w = q.w / len }
end

local function normalize(v)
    local len = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
    return { x = v.x / len, y = v.y / len, z = v.z / len }
end

local function dist(a, b)
    local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- ============================================================
-- Test 1: 3 perfectly-aimed fake towers, no noise -> exact solve
-- ============================================================

local FORWARD = { x = 1, y = 0, z = 0 }
local target = { x = 1859.65, y = 17.98, z = 1591.59 }

local fakeTowers = {
    { id = "tower_A", origin = { x = 1856.64, y = 16.45, z = 1583.01 } },
    { id = "tower_B", origin = { x = 1871.02, y = 13.88, z = 1604.25 } },
    { id = "tower_C", origin = { x = 1840.10, y = 25.00, z = 1590.00 } },
}

local tri = Triangulator.new(FORWARD, { 1, 1, 1 })

for _, tower in ipairs(fakeTowers) do
    local dir = normalize({
        x = target.x - tower.origin.x,
        y = target.y - tower.origin.y,
        z = target.z - tower.origin.z,
    })
    local quat = shortestArcQuat(FORWARD, dir)
    tri:addRay(tower.id, tower.origin, quat)
end

local pos, err = tri:solve()
assert(pos, "solve() returned nil: " .. tostring(err))
local d = dist(pos, target)
print(("Test 1 (no noise): solved=(%.4f,%.4f,%.4f) target=(%.2f,%.2f,%.2f) error=%.6f blocks")
    :format(pos.x, pos.y, pos.z, target.x, target.y, target.z, d))
assert(d < 0.001, "expected near-zero error with perfect rays, got " .. d)
print("Test 1: PASS")

-- ============================================================
-- Test 2: same towers but with a wrong qsign -> should NOT converge
-- (proves the calibration step actually matters)
-- Note: with forward=(1,0,0), the shortest-arc quaternion's x-component
-- is always 0 (cross(forward, dir) has no x term when forward=(1,0,0)),
-- so flipping qsign.x is a no-op here - that's geometry, not a bug.
-- Flip qy instead, which the towers' aim actually depends on.
-- ============================================================

local triWrong = Triangulator.new(FORWARD, { 1, -1, 1 })
for _, tower in ipairs(fakeTowers) do
    local dir = normalize({
        x = target.x - tower.origin.x,
        y = target.y - tower.origin.y,
        z = target.z - tower.origin.z,
    })
    local quat = shortestArcQuat(FORWARD, dir)
    triWrong:addRay(tower.id, tower.origin, quat)
end
local posWrong = triWrong:solve()
local dWrong = dist(posWrong, target)
print(("Test 2 (wrong qsign): error=%.2f blocks"):format(dWrong))
assert(dWrong > 5, "expected wrong qsign to miss badly, got error " .. dWrong)
print("Test 2: PASS (wrong calibration correctly misses)")

-- ============================================================
-- Test 3: noisy quaternions (simulate sensor jitter) -> small but nonzero error
-- ============================================================

math.randomseed(42)
local function jitterQuat(q, amount)
    local jittered = {
        x = q.x + (math.random() - 0.5) * amount,
        y = q.y + (math.random() - 0.5) * amount,
        z = q.z + (math.random() - 0.5) * amount,
        w = q.w + (math.random() - 0.5) * amount,
    }
    local len = math.sqrt(jittered.x^2 + jittered.y^2 + jittered.z^2 + jittered.w^2)
    return { x = jittered.x/len, y = jittered.y/len, z = jittered.z/len, w = jittered.w/len }
end

local triNoisy = Triangulator.new(FORWARD, { 1, 1, 1 })
for _, tower in ipairs(fakeTowers) do
    local dir = normalize({
        x = target.x - tower.origin.x,
        y = target.y - tower.origin.y,
        z = target.z - tower.origin.z,
    })
    local quat = jitterQuat(shortestArcQuat(FORWARD, dir), 0.01)
    triNoisy:addRay(tower.id, tower.origin, quat)
end
local posNoisy = triNoisy:solve()
local dNoisy = dist(posNoisy, target)
print(("Test 3 (jittered quats): error=%.4f blocks"):format(dNoisy))
assert(dNoisy < 3, "noisy solve strayed too far: " .. dNoisy)
print("Test 3: PASS")

print("\nAll triangulation tests passed.")
