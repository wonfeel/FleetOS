-- FleetOS app: runs on a tower computer (needs CC: Sable, on a Sub-Level).
-- Same protocol/logic as the standalone raytower.lua "slave" role.

local PROTOCOL = "raytower"

local ok, uid = pcall(function() return sublevel.getUniqueId() end)
if not ok then
    print("[raytower_slave] Computer is not on a Sub-Level (CC: Sable)")
    return
end
local TOWER_ID = "tower_" .. uid

local modem = peripheral.find("modem")
if not modem then
    print("[raytower_slave] No modem found")
    return
end
if not rednet.isOpen(peripheral.getName(modem)) then
    rednet.open(peripheral.getName(modem))
end

print("[raytower_slave] '" .. TOWER_ID .. "' ready")

while true do
    local senderId, message = rednet.receive(PROTOCOL)

    if type(message) == "table" and message.type == "poll" then
        -- NOTE: field names below come from CC:Sable's sublevel.getLogicalPose().
        -- If this errors, run print(textutils.serialize(sublevel.getLogicalPose()))
        -- in-game once and fix the two key names.
        local ok2, pos, quat = pcall(function()
            local pose = sublevel.getLogicalPose()
            local p = pose.position
            local q = pose.orientation
            return { x = p.x, y = p.y, z = p.z },
                   { x = q.v.x, y = q.v.y, z = q.v.z, w = q.a }
        end)

        if ok2 then
            rednet.send(senderId, {
                type = "report", id = TOWER_ID, origin = pos, quat = quat,
            }, PROTOCOL)
            print(("[raytower_slave] reported (%.1f, %.1f, %.1f)"):format(pos.x, pos.y, pos.z))
        else
            print("[raytower_slave] couldn't read position: " .. tostring(pos))
        end
    end
end
