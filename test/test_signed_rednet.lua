-- Unit tests for apps/common/_signed_rednet.lua (signed/replay-protected
-- rednet traffic, shared by apps/raytower/* and apps/common/
-- fleetgateway.lua). Run with (cwd must be game/):
--   cd game
--   lua ../test/test_signed_rednet.lua

dofile("../test/cc_mocks.lua")

local Auth = dofile("apps/common/_signed_rednet.lua")

local function assertTrue(cond, msg)
    if not cond then error("FAIL: " .. msg, 2) end
end

-- Test 1: sign/verify round-trip with a real secret succeeds.
do
    local payload = { type = "poll" }
    Auth.sign(payload, "sekrit")
    local ok, err = Auth.verify(payload, "sekrit")
    assertTrue(ok, "expected valid signature to verify, got: " .. tostring(err))
    print("Test 1: sign/verify round-trip - PASS")
end

-- Test 2: wrong secret fails verification.
do
    local payload = { type = "poll" }
    Auth.sign(payload, "sekrit")
    local ok, err = Auth.verify(payload, "wrong-secret")
    assertTrue(not ok, "expected wrong secret to fail verification")
    assertTrue(err ~= nil, "expected a reason string on failure")
    print("Test 2: wrong secret rejected - PASS")
end

-- Test 3: tampered payload (field changed after signing) fails verification.
do
    local payload = { type = "report", id = "tower_1", origin = { x = 1, y = 2, z = 3 } }
    Auth.sign(payload, "sekrit")
    payload.origin.x = 999 -- attacker tampers with the position after the fact
    local ok = Auth.verify(payload, "sekrit")
    assertTrue(not ok, "expected tampered payload to fail verification")
    print("Test 3: tampered payload rejected - PASS")
end

-- Test 4: missing mac/ts (a genuinely unsigned/forged packet) fails
-- verification when a secret IS configured on the receiving side.
do
    local payload = { type = "poll" }
    local ok = Auth.verify(payload, "sekrit")
    assertTrue(not ok, "expected unsigned payload to fail verification when a secret is set")
    print("Test 4: unsigned payload rejected when secret is set - PASS")
end

-- Test 5: empty secret ("") on BOTH sides means auth is off entirely -
-- backward compatible with a fleet that hasn't configured a shared secret.
do
    local payload = { type = "poll" }
    Auth.sign(payload, "")
    assertTrue(payload.mac == nil, "expected sign() with empty secret to leave payload untouched")
    local ok = Auth.verify(payload, "")
    assertTrue(ok, "expected verify() with empty secret to always pass (auth off)")
    print("Test 5: empty secret disables auth entirely - PASS")
end

-- Test 6: a stale timestamp (older than the replay window) fails
-- verification even with an otherwise-perfectly-valid MAC over that exact
-- (old) timestamp - isolates the freshness check from the MAC check itself
-- by computing the mac directly over the rewound payload (Auth.mac is
-- exposed for exactly this - see its own comment).
do
    local oldTs = 1000000
    local payload = { type = "poll", ts = oldTs }
    payload.mac = Auth.mac("sekrit", Auth.canonicalize(payload))
    local ok = Auth.verify(payload, "sekrit")
    assertTrue(not ok, "expected stale timestamp to fail verification even with a matching mac")
    print("Test 6: stale timestamp rejected - PASS")
end

-- Test 7: regression guard for a real bug found live (intermittent, ~1 in 5
-- runs) - two tables holding the SAME keys/values but built via DIFFERENT
-- construction paths (a literal vs. a pairs()-loop-populated copy, exactly
-- what sign() vs. verify() each do to a real payload) must canonicalize to
-- the identical string. Lua's pairs() iteration order depends on a table's
-- internal hash bucket layout (which depends on build history), not just
-- its contents - textutils.serialize alone doesn't correct for that, which
-- is exactly why Auth.canonicalize exists instead of using it directly.
do
    local literal = { type = "report", id = "tower_9", origin = { x = 1, y = 2, z = 3 }, quat = { x = 0, y = 0, z = 0, w = 1 }, ts = 12345 }
    local copy = {}
    for k, v in pairs(literal) do copy[k] = v end
    assertTrue(Auth.canonicalize(literal) == Auth.canonicalize(copy),
        "canonicalize must be independent of table construction order/history")
    print("Test 7: canonicalize is construction-order-independent - PASS")
end

print("\nAll signed_rednet tests passed.")
