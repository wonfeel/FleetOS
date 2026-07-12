-- FleetOS app: real-time flight control for a 4-motor tilt-rotor drone.
-- Add "drone_control" to config.lua's startup list (alongside
-- "fleetbridge", which is what actually gets commands TO this app - see
-- below) on any node that's a physical drone.
--
-- Control flow, end to end:
--   dashboard.html joystick UI -> POST /command {type="drone_set", ...}
--   -> bridge_server.py queues it (generic, no drone-specific code needed
--      there - see /command's own comment) -> apps/common/fleetbridge.lua
--      polls it on its next cycle, validates it, and does
--      fleetos.publish("drone_set", setpoint) -> THIS file's main loop
--      (subscribed via os.pullEvent("fleetos_message")) updates
--      currentSetpoint and lastSetpointAt.
-- Every tick (independent of when a new setpoint arrives - the network
-- round trip above is poll-cycle latency, seconds; the local control loop
-- below runs at tickSeconds), this file:
--   1. reads the orientation sensor (readAttitude)
--   2. applies the failsafe ramp to currentSetpoint if it's gone stale
--   3. calls _motor_mixer.lua's pure Mixer.mix() for the actual math
--   4. writes each motor's thrust+tilt to redstone (channelSet)
--   5. publishes a telemetry snapshot via fleetos.setShared, which
--      apps/common/fleetbridge.lua's report() picks up and sends to the
--      bridge as payload.drone - see that file's own comment for the hook.
--
-- UNTESTED against real Create-mod physics/redstone - only _motor_mixer.lua's
-- pure math has automated tests (test/test_motor_mixer.lua). The channel
-- map, gyroscope peripheral name, and every gain in _drone_config.lua are
-- starting points that need real in-game verification and tuning before
-- this should fly anything.

local Mixer = dofile("apps/drone/_motor_mixer.lua")

local cfg = {}
if fs.exists("config.lua") then
    local ok, c = pcall(dofile, "config.lua")
    if ok and type(c) == "table" then cfg = c end
end
local defaults = dofile("apps/drone/_drone_config.lua")
local dcfg = cfg.drone or defaults
-- Fields not present in the node's own config.lua fall back to the
-- shipped defaults, field by field, so a config.lua that only overrides
-- (say) the channel map doesn't lose the failsafe/gain defaults.
for k, v in pairs(defaults) do
    if dcfg[k] == nil then dcfg[k] = v end
end
if dcfg.gains then
    for k, v in pairs(defaults.gains) do
        if dcfg.gains[k] == nil then dcfg.gains[k] = v end
    end
end

local gyroscope = dcfg.gyroscopePeripheral and peripheral.wrap(dcfg.gyroscopePeripheral) or peripheral.find("gyroscope")
if not gyroscope then
    print("[drone_control] WARNING: no gyroscope peripheral found - attitude hold will not work, every motor will just run at raw throttle")
end

local warnedMissingChannel = {}

-- Writes `value` to one channel (a {side=..., peripheralName=...} entry
-- from _drone_config.lua's `channels` table). peripheralName set means an
-- addressable redstone peripheral (e.g. Redstone Integrator/Relay) -
-- adjust the peripheral call below to match whatever API yours exposes if
-- it isn't setAnalogOutput(side, value); peripheralName nil means a
-- native computer side via the global redstone/rs API.
local function channelSet(channel, value)
    if not channel or (not channel.side and not channel.peripheralName) then
        local key = tostring(channel)
        if not warnedMissingChannel[key] then
            print("[drone_control] WARNING: unconfigured channel - see _drone_config.lua's channels table")
            warnedMissingChannel[key] = true
        end
        return
    end
    local intVal = math.floor(value + 0.5)
    if channel.peripheralName then
        local p = peripheral.wrap(channel.peripheralName)
        if p and p.setAnalogOutput then
            p.setAnalogOutput(channel.side, intVal)
        elseif not warnedMissingChannel[channel.peripheralName] then
            print("[drone_control] WARNING: peripheral '" .. channel.peripheralName .. "' not found or has no setAnalogOutput")
            warnedMissingChannel[channel.peripheralName] = true
        end
    else
        redstone.setAnalogOutput(channel.side, intVal)
    end
end

-- Maps a redstone-analog channel (0-15) to a signed tilt angle
-- (-TILT_LIMIT_DEG..+TILT_LIMIT_DEG): 0 = full negative, 15 = full
-- positive, 7.5 = center/neutral. Matches _drone_config.lua's assumption 2.
-- TODO: this assumes the tilt actuator responds linearly across the whole
-- 0-15 range - if it doesn't in practice, this is the one place to add a
-- curve/deadzone. Not doing that preemptively, no data yet either way.
local function tiltDegToChannel(deg)
    local frac = (deg + Mixer.TILT_LIMIT_DEG) / (2 * Mixer.TILT_LIMIT_DEG) -- 0..1
    return frac * Mixer.THRUST_MAX
end

-- Returns {roll=, pitch=} in degrees, or nil if no gyroscope is present.
-- The ONLY place to change if your orientation source isn't Advanced
-- Peripherals' gyroscope - see _drone_config.lua's header assumption 3.
local function readAttitude()
    if not gyroscope then return nil end
    local ok, rotation = pcall(gyroscope.getRotation)
    if not ok or type(rotation) ~= "table" then return nil end
    return { roll = rotation.roll or 0, pitch = rotation.pitch or 0 }
end

-- setpoint fields default to 0/neutral - see _motor_mixer.lua's M.mix doc.
local currentSetpoint = { throttle = 0, yawRate = 0, moveX = 0, moveY = 0 }
local lastSetpointAt = os.epoch("utc") / 1000

-- Ramps throttle to 0 over failsafeRampSeconds once a setpoint has been
-- stale for longer than failsafeTimeoutSeconds - a dropped connection (or
-- the dashboard tab just closing) must not leave a drone flying at its
-- last-known throttle forever. Only throttle ramps down; yaw/move zero
-- out immediately since they have no "hold position" meaning on their own.
local function effectiveSetpoint()
    local staleFor = (os.epoch("utc") / 1000) - lastSetpointAt - dcfg.failsafeTimeoutSeconds
    if staleFor <= 0 then return currentSetpoint end
    local rampFrac = math.max(0, 1 - (staleFor / dcfg.failsafeRampSeconds))
    return {
        throttle = currentSetpoint.throttle * rampFrac,
        yawRate = 0,
        moveX = 0,
        moveY = 0,
    }
end

-- not merging this into the tick loop below even though it's only called
-- from one place - keeping it separate made it much easier to test the
-- mixing math in isolation earlier, leaving it as-is
local function applyMix(motors)
    for _, motor in ipairs(motors) do
        local ch = dcfg.channels[motor.name]
        if ch then
            channelSet(ch.thrust, motor.thrust)
            channelSet(ch.tilt, tiltDegToChannel(motor.tilt))
        end
    end
end

-- Picked up by apps/common/fleetbridge.lua's report() (see its own hook
-- comment) - sent to the bridge as payload.drone whenever it changes,
-- same pattern fleetgateway.lua uses for isGatewayLeader.
local function publishTelemetry(attitude, motors, setpointIsStale)
    fleetos.setShared("droneState", {
        attitude = attitude,
        motors = motors,
        setpointStale = setpointIsStale,
        setpoint = currentSetpoint,
    })
end

print("[drone_control] running - " .. (gyroscope and "gyroscope OK" or "NO gyroscope, attitude hold disabled"))

local tickTimer = os.startTimer(dcfg.tickSeconds)
while true do
    local event, a, b = os.pullEvent()

    if event == "fleetos_message" and a == "drone_set" and type(b) == "table" then
        currentSetpoint = {
            throttle = b.throttle or 0,
            yawRate = b.yawRate or 0,
            moveX = b.moveX or 0,
            moveY = b.moveY or 0,
        }
        lastSetpointAt = os.epoch("utc") / 1000

    elseif event == "timer" and a == tickTimer then
        tickTimer = os.startTimer(dcfg.tickSeconds)

        local attitude = readAttitude()
        local isStale = ((os.epoch("utc") / 1000) - lastSetpointAt) > dcfg.failsafeTimeoutSeconds
        local motors = Mixer.mix(effectiveSetpoint(), attitude or { roll = 0, pitch = 0 }, dcfg.gains)
        applyMix(motors)
        publishTelemetry(attitude, motors, isStale)
    end
end
