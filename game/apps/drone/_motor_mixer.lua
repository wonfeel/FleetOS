-- Pure control-mixing math for a 4-motor tilt-rotor drone. Deliberately
-- has ZERO redstone/peripheral I/O in this file - drone_control.lua does
-- the real world I/O and calls into here for the arithmetic, so this can
-- be exercised on a desktop Lua interpreter (test/test_motor_mixer.lua)
-- without Minecraft. The gains below are starting points, NOT tuned
-- against real Create-mod physics - expect to retune attitudeP/yawP/
-- translateGain in-game.
--
-- Design (see drone_control.lua's header for the full writeup of why):
--   - Attitude hold (roll/pitch always driven toward 0 - the platform
--     must stay level at all times) uses classic quad-X DIFFERENTIAL
--     THRUST, same as any ordinary quadcopter. Never touches tilt.
--   - Yaw uses differential thrust between diagonal motor pairs (assumes
--     alternating CW/CCW propellers, same as a real quad's reaction-
--     torque yaw). Also never touches tilt.
--   - Horizontal translation is the ONLY thing that uses the tilt
--     actuators: each motor tilts radially along its own arm, allocated
--     by projecting the desired horizontal direction onto that arm's
--     direction. This is what lets the drone move sideways while staying
--     perfectly level - tilt the thrust vector, never the body.

local M = {}

M.TILT_LIMIT_DEG = 30
M.THRUST_MAX = 15 -- redstone analog output ceiling (0-15)

-- Quad-X layout: dx/dy is each motor's arm direction (unit-ish, just
-- signs) from the drone's center - FR/BL are one diagonal (CW props),
-- FL/BR are the other (CCW props), matching how a real quadcopter cancels
-- net reaction torque at rest and yaws when that balance is deliberately
-- broken.
M.MOTORS = {
    { name = "FR", dx = 1, dy = -1 },
    { name = "FL", dx = 1, dy = 1 },
    { name = "BL", dx = -1, dy = 1 },
    { name = "BR", dx = -1, dy = -1 },
}

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- gut-feel numbers, not derived from anything - first real flight will
-- probably prove all three wrong in one direction or another
M.DEFAULT_GAINS = {
    attitudeP = 0.6,   -- thrust units per degree of roll/pitch error
    yawP = 0.4,        -- thrust units per unit of yawRate (-1..1)
    translateGain = 20, -- degrees of tilt per unit of moveX/moveY (-1..1), pre-clamp
}

-- setpoint: { throttle = 0..1, yawRate = -1..1, moveX = -1..1, moveY = -1..1 }
--   throttle    - overall lift, 0 = motors off, 1 = full thrust
--   yawRate     - desired rotation about the vertical axis (+1 = one way,
--                 sign convention fixed by which diagonal is CW in-game -
--                 verify and flip yawP's sign if it spins the wrong way)
--   moveX/moveY - desired horizontal thrust direction, body-relative,
--                 -1..1 each (not normalized - a joystick's raw x/y)
-- attitude: { roll = degrees, pitch = degrees } - CURRENT measured tilt
--   from level (from the drone's orientation sensor). This function's job
--   is to drive both back toward zero regardless of what setpoint asks
--   for - the platform stays level no matter what the pilot commands.
-- gains: optional override of M.DEFAULT_GAINS (any subset).
--
-- Returns an array of 4 { name, thrust (0..15), tilt (-30..30) } tables,
-- one per M.MOTORS entry, in the same order.
function M.mix(setpoint, attitude, gains)
    setpoint = setpoint or {}
    attitude = attitude or {}
    local g = {}
    for k, v in pairs(M.DEFAULT_GAINS) do g[k] = (gains and gains[k]) or v end

    local throttle = clamp(setpoint.throttle or 0, 0, 1)
    local yawRate = clamp(setpoint.yawRate or 0, -1, 1)
    local moveX = clamp(setpoint.moveX or 0, -1, 1)
    local moveY = clamp(setpoint.moveY or 0, -1, 1)

    -- Error, not measured value: positive error means "tilted this way,
    -- push back the other way" - the sign convention here only needs to
    -- be internally consistent (verified by the "settles toward zero"
    -- test), the real sign vs. the sensor's roll/pitch convention needs
    -- confirming in-game.
    local rollErr = -(attitude.roll or 0)
    local pitchErr = -(attitude.pitch or 0)

    local baseThrust = throttle * M.THRUST_MAX
    local out = {}
    for i, motor in ipairs(M.MOTORS) do
        local yawSign = (motor.dx * motor.dy > 0) and 1 or -1
        local attitudeCorrection = g.attitudeP * (motor.dy * rollErr + motor.dx * pitchErr)
        local yawCorrection = g.yawP * yawSign * yawRate
        local thrust = clamp(baseThrust + attitudeCorrection + yawCorrection, 0, M.THRUST_MAX)

        -- Projects the desired horizontal direction onto this motor's arm
        -- direction - each motor only needs to tilt as much as its own
        -- arm's alignment with the target direction calls for, and the
        -- four together (quad-X arms are 90 degrees apart) span every
        -- horizontal direction.
        local tilt = clamp(g.translateGain * (motor.dx * moveX + motor.dy * moveY),
            -M.TILT_LIMIT_DEG, M.TILT_LIMIT_DEG)

        out[i] = { name = motor.name, thrust = thrust, tilt = tilt }
    end
    return out
end

return M
