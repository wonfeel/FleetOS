-- Unit test for apps/common/fleetgateway.lua's actual relay path
-- (handleRelay -> relayPoll/relayReport) - the piece test_fleetgateway.lua
-- deliberately doesn't cover (that file only tests leader election). This
-- verifies the full round trip: a simulated regular node broadcasts a
-- signed poll/report request, the (leader) gateway verifies it, makes an
-- HTTP call (faked here - see below), and sends back a correctly-signed
-- result the node can verify and use.
--
-- Run with (cwd must be game/):
--   cd game
--   lua ../test/test_gateway_relay.lua
--
-- HTTP is faked, not skipped: fleetgateway.lua's httpRequest calls
-- http.request(...) then os.pullEvent()'s for http_success/http_failure -
-- this test's fake http.request is a no-op (the real work happens on the
-- NEXT resume, where the test driver hands the gateway coroutine a
-- synthetic ("http_success", url, fakeResponse) event via
-- coroutine.resume's own varargs, exactly what os.pullEvent's
-- coroutine.yield(filter) receives as its return value - see
-- cc_mocks.lua's os.pullEvent for why that plumbing works at all).

local CcMocks = dofile("../test/cc_mocks.lua")
local SignedRednet = dofile("apps/common/_signed_rednet.lua")

local GATEWAY_ID = 1
local NODE_ID_COMPUTER = 2 -- the simulated regular node's rednet computer id (distinct from its FleetOS node id string below)
local SECRET = "test-gateway-secret"
local FLEET_NODE_ID = "farm_north" -- the FleetOS node id string a real fleetbridge.lua would use

local capturedHttpRequests = {}
http = {
    request = function(opts) capturedHttpRequests[#capturedHttpRequests + 1] = opts end,
}

-- Normally the real kernel (fleetos.lua) exposes this as _G.fleetos before
-- ever spawning an app - this test dofiles fleetgateway.lua directly,
-- skipping the kernel entirely, so a minimal stub covers just what it
-- touches (setShared, to publish leader status).
fleetos = { setShared = function(_, _) end }

peripheral.find = function(kind)
    if kind == "modem" then return { name = "mock modem" } end
    return nil
end

local realDofile = dofile
local TEST_CONFIG = { gatewaySecret = SECRET, gatewayHeartbeatInterval = 0.02, gatewayElectionTimeout = 0.06 }
dofile = function(path)
    if path == "config.lua" then return TEST_CONFIG end
    return realDofile(path)
end

local virtualTimeMs = 0
os.epoch = function(_) return virtualTimeMs end

local function assertEq(actual, expected, msg)
    if actual ~= expected then
        error(("FAIL: %s (expected %s, got %s)"):format(msg, tostring(expected), tostring(actual)), 2)
    end
end

-- The gateway: a real fleetgateway.lua coroutine. lastHigherPriorityHeartbeatAt
-- is stamped to os.epoch() AT BOOT (during this first resume), so time has
-- to advance AFTER that point, not before - two resumes with a time jump
-- in between fast-forwards it to leader status without waiting out a real
-- election (test_fleetgateway.lua already proves convergence itself).
local gatewayCo = coroutine.create(function() dofile("apps/common/fleetgateway.lua") end)
local function resumeGateway(...)
    CcMocks.rednetSetCurrentComputer(GATEWAY_ID)
    local ok, err = coroutine.resume(gatewayCo, ...)
    if not ok then error("gateway crashed: " .. tostring(err)) end
end

os.getComputerID = function() return GATEWAY_ID end
resumeGateway() -- boot: stamps lastHigherPriorityHeartbeatAt=0, broadcasts one heartbeat as non-leader, parks in receive()
virtualTimeMs = TEST_CONFIG.gatewayElectionTimeout * 1000 + 1
resumeGateway() -- election timeout has now elapsed - becomes leader, broadcasts again, parks in receive()

-- Test 1: a poll relay request gets a correctly-signed, correct poll_result back.
do
    CcMocks.rednetSetCurrentComputer(NODE_ID_COMPUTER)
    rednet.broadcast(SignedRednet.sign({ type = "poll", node = FLEET_NODE_ID }, SECRET), "fleetgateway-relay")

    resumeGateway() -- picks up the relay request, verifies it, calls relayPoll -> http.request -> parks on os.pullEvent
    assertEq(#capturedHttpRequests, 1, "expected exactly one HTTP request for the relayed poll")
    assertEq(capturedHttpRequests[1].url:find("/poll%?node=" .. FLEET_NODE_ID) ~= nil, true,
        "expected the relayed HTTP call to target /poll?node=" .. FLEET_NODE_ID)

    local fakeResponse = {
        readAll = function() return textutils.serializeJSON({ { type = "run", app = "clock", id = 42 } }) end,
        close = function() end,
        getResponseHeaders = function() return { ["X-Shell-Pin-Set"] = "1" } end,
    }
    resumeGateway("http_success", capturedHttpRequests[1].url, fakeResponse)

    CcMocks.rednetSetCurrentComputer(NODE_ID_COMPUTER)
    local senderId, message = CcMocks.rednetTryReceive(NODE_ID_COMPUTER, "fleetgateway-relay")
    assertEq(senderId, GATEWAY_ID, "expected the response to come from the gateway")
    assertEq(message.type, "poll_result", "expected a poll_result message")
    assertEq(message.node, FLEET_NODE_ID, "expected the response addressed to the right node")
    assertEq(message.ok, true, "expected ok=true")
    assertEq(message.shellPinSet, true, "expected the X-Shell-Pin-Set header forwarded as shellPinSet")
    assertEq(#message.commands, 1, "expected exactly one relayed command")
    assertEq(message.commands[1].app, "clock", "expected the relayed command's content to survive the round trip")
    local verifyOk = SignedRednet.verify(message, SECRET)
    assertEq(verifyOk, true, "expected the gateway's response to verify against the shared secret")
    print("Test 1: poll relay round-trips correctly, including shellPinSet - PASS")
end

-- Test 2: a REPORT relay request forwards the exact body bytes and gets a
-- correctly-signed report_result back.
do
    local reportBody = textutils.serializeJSON({ id = FLEET_NODE_ID, role = "farm", results = {} })

    CcMocks.rednetSetCurrentComputer(NODE_ID_COMPUTER)
    rednet.broadcast(SignedRednet.sign({ type = "report", node = FLEET_NODE_ID, body = reportBody }, SECRET),
        "fleetgateway-relay")

    resumeGateway()
    assertEq(#capturedHttpRequests, 2, "expected a second HTTP request for the relayed report")
    assertEq(capturedHttpRequests[2].url:find("/report%?node=" .. FLEET_NODE_ID) ~= nil, true,
        "expected the relayed HTTP call to target /report?node=" .. FLEET_NODE_ID)
    assertEq(capturedHttpRequests[2].body, reportBody, "expected the exact report body forwarded byte-for-byte")

    local fakeResponse = {
        readAll = function() return textutils.serializeJSON({ ok = true }) end,
        close = function() end,
        getResponseHeaders = function() return {} end,
    }
    resumeGateway("http_success", capturedHttpRequests[2].url, fakeResponse)

    CcMocks.rednetSetCurrentComputer(NODE_ID_COMPUTER)
    local senderId, message = CcMocks.rednetTryReceive(NODE_ID_COMPUTER, "fleetgateway-relay")
    assertEq(senderId, GATEWAY_ID, "expected the response to come from the gateway")
    assertEq(message.type, "report_result", "expected a report_result message")
    assertEq(message.ok, true, "expected ok=true")
    assertEq(SignedRednet.verify(message, SECRET), true, "expected the gateway's response to verify")
    print("Test 2: report relay forwards the body byte-for-byte and confirms ok - PASS")
end

-- Test 3: an unsigned/forged relay request (wrong secret) is rejected -
-- no HTTP call is made at all, and no response is sent back.
do
    CcMocks.rednetSetCurrentComputer(NODE_ID_COMPUTER)
    rednet.broadcast(SignedRednet.sign({ type = "poll", node = "attacker_node" }, "wrong-secret"), "fleetgateway-relay")

    local requestsBefore = #capturedHttpRequests
    resumeGateway()
    assertEq(#capturedHttpRequests, requestsBefore, "expected no HTTP request for a badly-signed relay message")

    CcMocks.rednetSetCurrentComputer(NODE_ID_COMPUTER)
    local senderId = CcMocks.rednetTryReceive(NODE_ID_COMPUTER, "fleetgateway-relay")
    assertEq(senderId, nil, "expected no response at all to a rejected relay request")
    print("Test 3: badly-signed relay requests are rejected, no HTTP call, no response - PASS")
end

print("\nAll gateway-relay tests passed.")
