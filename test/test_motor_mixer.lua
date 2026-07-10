-- Unit tests for apps/drone/_motor_mixer.lua - the ONLY part of the drone
-- control stack that can be verified without a real Minecraft/Create
-- world (see that file's header). These check the mixing math's
-- invariants (symmetry, clamping, correction direction), not real flight
-- behavior - the actual gains still need in-game tuning. Run with
-- (cwd must be game/):
--   cd game
--   lua ../test/test_motor_mixer.lua

dofile("../test/cc_mocks.lua")

local Mixer = dofile("apps/drone/_motor_mixer.lua")

local function assertEq(got, expected, msg)
    if got ~= expected then
        error("FAIL: " .. msg .. "\n  expected: " .. tostring(expected) .. "\n  got:      " .. tostring(got), 2)
    end
end

local function assertClose(got, expected, tol, msg)
    if math.abs(got - expected) > tol then
        error("FAIL: " .. msg .. "\n  expected ~" .. tostring(expected) .. " (tol " .. tol .. ")\n  got:      " .. tostring(got), 2)
    end
end

local function byName(motors)
    local m = {}
    for _, motor in ipairs(motors) do m[motor.name] = motor end
    return m
end

-- Test 1: level attitude + neutral setpoint - all 4 motors get identical
-- thrust (throttle only, no correction) and zero tilt.
do
    local out = Mixer.mix({ throttle = 0.5 }, { roll = 0, pitch = 0 })
    assertEq(#out, 4, "returns exactly 4 motors")
    local expectedThrust = 0.5 * Mixer.THRUST_MAX
    for _, motor in ipairs(out) do
        assertClose(motor.thrust, expectedThrust, 0.001, motor.name .. " thrust at neutral setpoint")
        assertEq(motor.tilt, 0, motor.name .. " tilt at neutral setpoint")
    end
    print("Test 1: neutral setpoint at level attitude - PASS")
end

-- Test 2: throttle=0 with level attitude means every motor is fully off,
-- not just "low" - a stopped drone shouldn't idle-spin.
do
    local out = Mixer.mix({ throttle = 0 }, { roll = 0, pitch = 0 })
    for _, motor in ipairs(out) do
        assertEq(motor.thrust, 0, motor.name .. " thrust at zero throttle")
    end
    print("Test 2: zero throttle -> zero thrust for every motor - PASS")
end

-- Test 3: a positive roll error (tilted one way) must correct with MORE
-- thrust on the low side and LESS on the high side - whichever sign
-- convention, the two sides must differ and be symmetric around the
-- neutral throttle level (attitude correction shouldn't change net lift).
do
    local out = byName(Mixer.mix({ throttle = 0.5 }, { roll = 10, pitch = 0 }))
    -- dy=+1 motors (FL, BL) and dy=-1 motors (FR, BR) must receive equal
    -- and opposite corrections.
    local dyPos = (out.FL.thrust + out.BL.thrust) / 2
    local dyNeg = (out.FR.thrust + out.BR.thrust) / 2
    if dyPos == dyNeg then
        error("FAIL: roll error produced no differential thrust between the two sides", 2)
    end
    assertClose(dyPos + dyNeg, out.FL.thrust + out.FR.thrust, 0.001,
        "roll correction is a pure differential (dyPos+dyNeg should equal any diagonal pair's sum)")
    print("Test 3: nonzero roll error produces differential (not uniform) thrust - PASS")
end

-- Test 4: yawRate alone (level attitude, no throttle-affecting error)
-- must differentiate the two diagonal pairs (FR+BL vs FL+BR) without
-- changing their SUM (yaw shouldn't add or remove net lift).
do
    local out = byName(Mixer.mix({ throttle = 0.5, yawRate = 1 }, { roll = 0, pitch = 0 }))
    assertEq(out.FR.thrust, out.BL.thrust, "FR and BL (same diagonal/prop direction) get equal yaw correction")
    assertEq(out.FL.thrust, out.BR.thrust, "FL and BR (same diagonal/prop direction) get equal yaw correction")
    if out.FR.thrust == out.FL.thrust then
        error("FAIL: yawRate=1 produced no differential between the two diagonals", 2)
    end
    local total = out.FR.thrust + out.FL.thrust + out.BL.thrust + out.BR.thrust
    assertClose(total, 4 * 0.5 * Mixer.THRUST_MAX, 0.001, "yaw correction doesn't change net thrust")
    print("Test 4: yawRate differentiates diagonal pairs without changing net lift - PASS")
end

-- Test 5: translation (moveX/moveY) only ever changes tilt, never
-- thrust - the whole point of the tilt-vectoring design is that
-- attitude/lift stay untouched by commanded horizontal movement.
do
    local level = byName(Mixer.mix({ throttle = 0.5 }, { roll = 0, pitch = 0 }))
    local moving = byName(Mixer.mix({ throttle = 0.5, moveX = 1, moveY = -0.5 }, { roll = 0, pitch = 0 }))
    for _, name in ipairs({ "FR", "FL", "BL", "BR" }) do
        assertClose(level[name].thrust, moving[name].thrust, 0.001, name .. " thrust unaffected by moveX/moveY")
        if moving[name].tilt == 0 then
            error("FAIL: " .. name .. " got zero tilt despite a nonzero move command", 2)
        end
    end
    print("Test 5: moveX/moveY only changes tilt, never thrust - PASS")
end

-- Test 6: every output stays within the documented ranges even for
-- extreme/saturating inputs - a bad joystick value or a big attitude
-- upset must never ask a motor for out-of-range thrust or tilt.
do
    local out = Mixer.mix(
        { throttle = 5, yawRate = -99, moveX = 99, moveY = -99 },
        { roll = 999, pitch = -999 })
    for _, motor in ipairs(out) do
        if motor.thrust < 0 or motor.thrust > Mixer.THRUST_MAX then
            error("FAIL: " .. motor.name .. " thrust out of range: " .. tostring(motor.thrust), 2)
        end
        if motor.tilt < -Mixer.TILT_LIMIT_DEG or motor.tilt > Mixer.TILT_LIMIT_DEG then
            error("FAIL: " .. motor.name .. " tilt out of range: " .. tostring(motor.tilt), 2)
        end
    end
    print("Test 6: extreme/saturating inputs stay within documented output ranges - PASS")
end

-- Test 7: missing setpoint/attitude fields default safely (a drone that
-- hasn't received its first /drone_set command yet, or a sensor read that
-- came back partial) - must not error, and should behave like "do nothing".
do
    local ok, out = pcall(Mixer.mix, {}, {})
    if not ok then error("FAIL: Mixer.mix({}, {}) errored: " .. tostring(out), 2) end
    for _, motor in ipairs(out) do
        assertEq(motor.thrust, 0, motor.name .. " thrust with empty setpoint/attitude")
        assertEq(motor.tilt, 0, motor.name .. " tilt with empty setpoint/attitude")
    end
    print("Test 7: empty setpoint/attitude defaults safely to all-zero output - PASS")
end

print("All motor_mixer tests passed.")
