-- FleetOS app: runs on a tower computer (needs CC: Sable, on a Sub-Level).
-- Same protocol/logic as the standalone raytower.lua "slave" role.

local RaytowerAuth = dofile("apps/common/_signed_rednet.lua")

local PROTOCOL = "raytower"

local cfg = {}
if fs.exists("config.lua") then
    local ok, c = pcall(dofile, "config.lua")
    if ok and type(c) == "table" then cfg = c end
end
-- see apps/common/_signed_rednet.lua's header - must match the master's
-- raytowerSecret exactly, or every report this tower sends will be
-- rejected as unsigned/forged. "" (unset) keeps the historical unsigned behavior.
local RAYTOWER_SECRET = cfg.raytowerSecret or ""

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
        local okAuth, authErr = RaytowerAuth.verify(message, RAYTOWER_SECRET)
        if not okAuth then
            print("[raytower_slave] ignored poll: " .. tostring(authErr))
        else
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
                rednet.send(senderId, RaytowerAuth.sign({
                    type = "report", id = TOWER_ID, origin = pos, quat = quat,
                }, RAYTOWER_SECRET), PROTOCOL)
                print(("[raytower_slave] reported (%.1f, %.1f, %.1f)"):format(pos.x, pos.y, pos.z))
            else
                print("[raytower_slave] couldn't read position: " .. tostring(pos))
            end
        end
    end
end
