-- Per-drone hardware mapping and tuning, read from config.lua's `drone`
-- table (kept separate from config.lua itself, same reasoning as
-- raytowerForward/raytowerQSign living there rather than hardcoded) - copy
-- the block below into config.lua and edit it per physical drone.
--
-- ASSUMPTIONS this file's defaults make, spelled out because they're the
-- two things most likely to not match your actual build:
--   1. Motor speed is set via redstone.setAnalogOutput(side, 0-15) driving
--      a Create Rotation Speed Controller per motor.
--   2. Tilt angle is set the SAME way (0-15 linearly mapped to
--      -30..+30 degrees) - if your tilt actuator isn't redstone-analog
--      controlled this way, channelSet() in drone_control.lua is the one
--      place to change.
--   3. Orientation comes from an "Advanced Peripherals" gyroscope
--      peripheral (getRotation() -> {yaw, pitch, roll} degrees). If you're
--      using something else, readAttitude() in drone_control.lua is the
--      one place to change.
--
-- A bare CC:Tweaked Computer only has 6 native sides, and this needs 8
-- redstone channels (4 motors x thrust+tilt) - each channel below can
-- point at either a native computer side (peripheralName = nil) or a
-- peripheral that exposes multiple addressable redstone outputs (e.g. a
-- Redstone Integrator/Relay), by name as shown by `peripheral.getNames()`.

return {
    -- Failsafe: if no drone_set command has arrived within this many
    -- seconds, throttle ramps to 0 over rampSeconds instead of holding
    -- the last command forever - a dropped connection must not leave a
    -- drone flying blind. Tune ramp up if a hard cut feels too abrupt for
    -- your build's fall characteristics.
    failsafeTimeoutSeconds = 1.5,
    failsafeRampSeconds = 1.0,

    -- Main control loop tick rate. Faster = more responsive attitude hold,
    -- but more redstone/peripheral calls per second - start conservative.
    tickSeconds = 0.25,

    gyroscopePeripheral = nil, -- nil = peripheral.find("gyroscope") (first one found)

    gains = {
        attitudeP = 0.6,
        yawP = 0.4,
        translateGain = 20,
    },

    -- name must match _motor_mixer.lua's M.MOTORS entries (FR/FL/BL/BR).
    -- side is a native computer side ("top","bottom","front","back",
    -- "left","right") used directly with redstone.setAnalogOutput/
    -- rs.setAnalogOutput; set peripheralName too if this channel instead
    -- goes through an addressable redstone peripheral (then side is
    -- whatever that peripheral's API expects - see channelSet's comment
    -- in drone_control.lua).
    channels = {
        FR = { thrust = { side = "top" }, tilt = { side = "bottom" } },
        FL = { thrust = { side = "front" }, tilt = { side = "back" } },
        BL = { thrust = { side = "left" }, tilt = { side = "right" } },
        BR = { thrust = { side = nil, peripheralName = nil }, tilt = { side = nil, peripheralName = nil } },
        -- BR above is intentionally incomplete - a bare Computer only has
        -- 6 sides and the other 3 motors already used all of them twice
        -- over (thrust+tilt = 8 channels needed). Point BR's two channels
        -- at an addressable redstone peripheral (peripheralName set,
        -- side = that peripheral's channel identifier) before flying -
        -- see this file's header comment.
    },
}
