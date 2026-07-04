-- Demonstrates cc_mocks.makeFakeSublevel(): substitutes real CC:Sable
-- sensor data with fake position/orientation, so the pose-extraction
-- logic from game/apps/raytower_slave.lua can be exercised without a
-- real Sub-Level or CC:Sable installed.
-- Run with (cwd must be game/):
--   cd game
--   lua ..\test\test_sensor_mock.lua

local mocks = dofile("../test/cc_mocks.lua")

-- Fake sensor reading: tower sits at (100, 64, 200), facing straight
-- along +X with no rotation (identity quaternion).
sublevel = mocks.makeFakeSublevel(
    { x = 100, y = 64, z = 200 },
    { x = 0, y = 0, z = 0, w = 1 }
)

-- Same extraction logic as apps/raytower_slave.lua's poll handler.
local ok, pos, quat = pcall(function()
    local pose = sublevel.getLogicalPose()
    local p = pose.position
    local q = pose.orientation
    return { x = p.x, y = p.y, z = p.z },
           { x = q.v.x, y = q.v.y, z = q.v.z, w = q.a }
end)

assert(ok, "extraction failed: " .. tostring(pos))
assert(pos.x == 100 and pos.y == 64 and pos.z == 200, "position mismatch")
assert(quat.w == 1 and quat.x == 0, "quaternion mismatch")

print(("Fake sensor: origin=(%.0f,%.0f,%.0f) quat=(%.0f,%.0f,%.0f,%.0f)")
    :format(pos.x, pos.y, pos.z, quat.x, quat.y, quat.z, quat.w))
print("Sensor mock test: PASS")

-- Swap in a different fake reading to prove it's fully substitutable -
-- e.g. simulate the tower having moved and rotated 90 degrees around Y.
sublevel = mocks.makeFakeSublevel(
    { x = 250, y = 70, z = -30 },
    { x = 0, y = 0.7071, z = 0, w = 0.7071 }
)

local ok2, pos2, quat2 = pcall(function()
    local pose = sublevel.getLogicalPose()
    local p = pose.position
    local q = pose.orientation
    return { x = p.x, y = p.y, z = p.z },
           { x = q.v.x, y = q.v.y, z = q.v.z, w = q.a }
end)

assert(ok2, "second extraction failed")
print(("Fake sensor #2: origin=(%.0f,%.0f,%.0f) quat=(%.4f,%.4f,%.4f,%.4f)")
    :format(pos2.x, pos2.y, pos2.z, quat2.x, quat2.y, quat2.z, quat2.w))
print("Sensor mock test #2: PASS")
