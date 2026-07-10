-- Unit tests for apps/common/fleetgateway.lua's Bully leader election
-- (convergence to the lowest computer id, and failover when the current
-- leader goes silent). Does NOT exercise the HTTP relay path (relayPoll/
-- relayReport) - that needs a real/mocked bridge_server.py, out of scope
-- here; this only verifies who becomes/stays leader.
--
-- Run with (cwd must be game/):
--   cd game
--   lua ../test/test_fleetgateway.lua
--
-- How multiple "computers" are simulated in one Lua process: each gateway
-- is its own coroutine running apps/common/fleetgateway.lua fresh via
-- dofile. os.getComputerID is a single global (not per-coroutine), so it's
-- reassigned right before EACH gateway's very FIRST resume (fleetgateway.lua
-- reads it exactly once, into a local MY_ID, before entering its main
-- loop) - safe to change again afterward since that local has already
-- captured its value. cc_mocks.lua's rednet mock is what actually keys
-- broadcast/send/receive by "whichever computer is currently resumed" -
-- see its own comment for why CcMocks.rednetSetCurrentComputer must be
-- called before every single resume, not just the first.

local CcMocks = dofile("../test/cc_mocks.lua")

-- fleetgateway.lua needs `http` to be non-nil to get past its own early
-- "HTTP API disabled" guard - never actually called here since no test
-- below ever triggers the relay path (only election messages flow).
http = {}

-- Normally the real kernel (fleetos.lua) exposes this as _G.fleetos before
-- ever spawning an app - these tests dofile fleetgateway.lua directly,
-- skipping the kernel entirely for speed, so a minimal stub covers just
-- what it touches (setShared, to publish leader status - see this file's
-- own comment on that call).
fleetos = { setShared = function(_, _) end }

-- A fake modem so fleetgateway.lua doesn't bail out at "No modem found" -
-- the base cc_mocks.lua peripheral.find always returns nil (see its own
-- comment), which is right for every OTHER test but wrong here.
peripheral.find = function(kind)
    if kind == "modem" then return { name = "mock modem" } end
    return nil
end

-- A single shared fake config.lua for every simulated gateway (a real
-- fleet shares one gatewaySecret/interval across all of them too - only
-- os.getComputerID varies per simulated computer, not this).
local realDofile = dofile
local HEARTBEAT_INTERVAL = 0.02 -- seconds
local ELECTION_TIMEOUT = HEARTBEAT_INTERVAL * 3
local TEST_CONFIG = {
    gatewaySecret = "test-gateway-secret",
    gatewayHeartbeatInterval = HEARTBEAT_INTERVAL,
    gatewayElectionTimeout = ELECTION_TIMEOUT,
}
dofile = function(path)
    if path == "config.lua" then return TEST_CONFIG end
    return realDofile(path)
end

-- A manually-advanced fake clock, standing in for cc_mocks.lua's default
-- os.epoch (real os.clock()-based time) - lets this test deterministically
-- simulate "N seconds passed with no message" (driving both
-- fleetgateway.lua's own deadline tracking AND the rednet mock's
-- receive() timeout - see that function's own comment) without any real
-- wall-clock delay, and without depending on how fast this machine
-- happens to execute Lua bytecode.
local virtualTimeMs = 0
os.epoch = function(_) return virtualTimeMs end

local function assertEq(actual, expected, msg)
    if actual ~= expected then
        error(("FAIL: %s (expected %s, got %s)"):format(msg, tostring(expected), tostring(actual)), 2)
    end
end

-- Spawns a simulated gateway computer with the given id. Returns a
-- resume() closure that advances just THIS gateway's coroutine by one
-- step, selecting it as the "current computer" on the shared rednet mock
-- first so its broadcast/send/receive calls are attributed correctly.
local function makeGateway(id)
    local co = coroutine.create(function() dofile("apps/common/fleetgateway.lua") end)
    local firstResume = true
    return function()
        if firstResume then
            os.getComputerID = function() return id end
            firstResume = false
        end
        CcMocks.rednetSetCurrentComputer(id)
        local ok, err = coroutine.resume(co)
        if not ok then error("gateway " .. id .. " crashed: " .. tostring(err)) end
    end
end

-- Runs every gateway's resume() once each, `rounds` times, in id order,
-- advancing the virtual clock by slightly more than one heartbeat interval
-- before each round - enough for whichever receive() call a gateway is
-- currently parked in (waiting on its own outer-loop deadline) to see
-- that deadline has passed and return, letting that gateway's outer loop
-- re-broadcast and re-evaluate the leader condition. A handful of rounds
-- (enough for the accumulated virtual time to exceed
-- gatewayElectionTimeout) is enough for election to converge.
local function runRounds(gateways, rounds)
    for _ = 1, rounds do
        virtualTimeMs = virtualTimeMs + (HEARTBEAT_INTERVAL * 1000 + 1)
        for _, resume in ipairs(gateways) do resume() end
    end
end

-- isLeader isn't exposed by fleetgateway.lua (it's a plain script, not a
-- module) - inferred instead from what it actually DOES: a leader
-- broadcasts heartbeats with isLeader=true. A neutral observer computer
-- (id 0, never itself a gateway) sits on the heartbeat protocol and
-- records whichever `isLeader` value it last saw from each sender.
local OBSERVER_ID = 0
CcMocks.rednetSetCurrentComputer(OBSERVER_ID) -- registers id 0 so broadcasts start reaching it

local function drainObserver(lastIsLeaderById)
    while true do
        local senderId, message = CcMocks.rednetTryReceive(OBSERVER_ID, "fleetgateway-heartbeat")
        if not senderId then break end
        if type(message) == "table" then
            lastIsLeaderById[senderId] = message.isLeader
        end
    end
end

-- Test 1: with two gateways (ids 5 and 9), only the lower id (5) should
-- end up leader after enough rounds for the election timeout to elapse.
do
    local resumeA = makeGateway(5)
    local resumeB = makeGateway(9)

    runRounds({ resumeA, resumeB }, 8)
    local lastIsLeaderById = {}
    drainObserver(lastIsLeaderById)

    assertEq(lastIsLeaderById[5], true, "lower id (5) should be leader")
    assertEq(lastIsLeaderById[9], false, "higher id (9) should not be leader")
    print("Test 1: election converges to the lowest computer id - PASS")
end

-- Test 2: three gateways (ids 1, 2, 3) - only id 1 (lowest) should be
-- leader, not 2 or 3, even though 2 also outranks 3.
do
    local resumeA = makeGateway(1)
    local resumeB = makeGateway(2)
    local resumeC = makeGateway(3)

    runRounds({ resumeA, resumeB, resumeC }, 8)
    local lastIsLeaderById = {}
    drainObserver(lastIsLeaderById)

    assertEq(lastIsLeaderById[1], true, "lowest id (1) should be leader")
    assertEq(lastIsLeaderById[2], false, "id 2 should not be leader while id 1 is alive")
    assertEq(lastIsLeaderById[3], false, "id 3 should not be leader while id 1 is alive")
    print("Test 2: election converges to the lowest of three ids - PASS")
end

-- Test 3: failover - once the current leader stops being resumed
-- (simulating it going offline), the next-lowest surviving gateway must
-- take over within a few more rounds.
do
    local resumeA = makeGateway(10) -- will "go offline" after converging as leader
    local resumeB = makeGateway(20)

    runRounds({ resumeA, resumeB }, 8)
    local before = {}
    drainObserver(before)
    assertEq(before[10], true, "id 10 should be leader before going offline")
    assertEq(before[20], false, "id 20 should not be leader yet")

    -- id 10 stops resuming entirely (as if the computer lost power) - only
    -- id 20 keeps running from here on.
    runRounds({ resumeB }, 8)
    local after = {}
    drainObserver(after)
    assertEq(after[20], true, "id 20 should take over leadership after id 10 goes silent")
    print("Test 3: failover promotes the next-lowest surviving gateway - PASS")
end

print("\nAll fleetgateway tests passed.")
