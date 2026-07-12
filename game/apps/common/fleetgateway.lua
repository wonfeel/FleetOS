-- FleetOS app: opt-in - add "fleetgateway" to config.lua's startup list on
-- 2-5 trusted computers to turn this on for the fleet.
--
-- fleetbridge.lua normally talks HTTP straight to bridge_server.py every
-- poll cycle - fine small-scale, but load grows with every node and
-- there's no failover if the bridge is briefly unreachable. See
-- docs/ARCHITECTURE_GATEWAY_CLUSTER.html for the full design.
--
-- Gateways elect one leader (Bully algorithm, lowest computer id wins) via
-- signed heartbeats; only the leader opens an HTTP connection to the
-- bridge. A regular node opted into the relay path broadcasts poll/report
-- over rednet instead, and whichever gateway is currently leader answers -
-- the bridge can't tell the difference. Zero gateways running = every node
-- falls back to talking straight to the bridge, unaffected.
--
-- SECURITY: gatewaySecret (config.lua) MUST be a real shared secret - see
-- _signed_rednet.lua's header for what signing does/doesn't protect
-- against. Matters MORE here than for raytower's use of the same module:
-- an ender modem has unlimited range (even cross-dimension), so there's no
-- physical-proximity protection at all - anyone anywhere with one could
-- forge a heartbeat and hijack leader status, or inject fake poll/report
-- traffic for a node they don't own.

local SignedRednet = dofile("apps/common/_signed_rednet.lua")

local HEARTBEAT_PROTOCOL = "fleetgateway-heartbeat"
local RELAY_PROTOCOL = "fleetgateway-relay"

local cfg = {}
if fs.exists("config.lua") then
    local ok, c = pcall(dofile, "config.lua")
    if ok and type(c) == "table" then cfg = c end
end

local GATEWAY_SECRET = cfg.gatewaySecret or ""
if GATEWAY_SECRET == "" then
    print("[fleetgateway] WARNING: gatewaySecret not set in config.lua - "
        .. "rednet traffic is UNSIGNED (unsafe with ender modems - see this file's header)")
end

if not http then
    print("[fleetgateway] HTTP API is disabled on this computer - a gateway needs it to relay to bridge_server.py")
    return
end

local modem = peripheral.find("modem")
if not modem then
    print("[fleetgateway] No modem found")
    return
end
if not rednet.isOpen(peripheral.getName(modem)) then
    rednet.open(peripheral.getName(modem))
end

-- ---- this gateway's OWN bridge address/key - a small, deliberately
-- self-contained resolution rather than sharing apps/common/fleetbridge.lua's
-- copy, since this runs as its own independent coroutine/task (a gateway
-- node typically ALSO runs fleetbridge.lua for itself, reporting its own
-- status like any other node - this is purely for the relay HTTP calls
-- below). Mirrors fleetbridge.lua's own BASE_URL/API_KEY priority order
-- (override file > env var > config.lua > default) - see that file's
-- header for the full explanation.
local BRIDGE_OVERRIDE_FILE = "bridge_override.txt"

local function loadBridgeOverride()
    if not fs.exists(BRIDGE_OVERRIDE_FILE) then return nil end
    local f = fs.open(BRIDGE_OVERRIDE_FILE, "r")
    local content = f.readAll()
    f.close()
    local ok, decoded = pcall(textutils.unserialize, content)
    return (ok and type(decoded) == "table") and decoded or nil
end

local bridgeOverride = loadBridgeOverride() or {}
local envUrl = os.getenv and os.getenv("FLEET_BRIDGE_URL")
local BASE_URL = bridgeOverride.url or envUrl or cfg.bridgeUrl or "http://127.0.0.1:8787"
local envKey = os.getenv and os.getenv("FLEET_BRIDGE_KEY")
local API_KEY = bridgeOverride.key or envKey or cfg.apiKey or ""

local function urlEncode(s)
    if textutils.urlEncode then return textutils.urlEncode(s) end
    return (s:gsub("[^%w%-%.~_]", function(c) return ("%%%02X"):format(c:byte()) end))
end

local function authHeaders(extra)
    local headers = extra or {}
    if API_KEY ~= "" then headers["X-API-Key"] = API_KEY end
    return headers
end

local HTTP_TIMEOUT = 8 -- seconds, same as fleetbridge.lua's own

local function httpRequest(url, body, headers)
    http.request({ url = url, body = body, headers = headers, timeout = HTTP_TIMEOUT })
    local timerId = os.startTimer(HTTP_TIMEOUT)
    while true do
        local event, a, b = os.pullEvent()
        if event == "http_success" and a == url then
            os.cancelTimer(timerId)
            return b
        elseif event == "http_failure" and a == url then
            os.cancelTimer(timerId)
            return nil, b
        elseif event == "timer" and a == timerId then
            return nil, "timed out after " .. HTTP_TIMEOUT .. "s"
        end
    end
end

local function httpGet(url, headers) return httpRequest(url, nil, headers) end
local function httpPost(url, body, headers) return httpRequest(url, body, headers) end

-- Relays a `poll` request from a regular node (reached us over signed
-- rednet) to bridge_server.py's real /poll?node=<id> - the exact same call
-- apps/common/fleetbridge.lua's own poll() makes when talking to the
-- bridge directly. Also forwards the X-Shell-Pin-Set response header (see
-- bridge_server.py's /poll handler) as `shellPinSet` in the reply, so a
-- relayed node's own shell-PIN-gate cache (fleetos.markShellPinSet) still
-- works exactly like a direct-HTTP node's.
local function relayPoll(senderId, nodeId)
    local resp, err = httpGet(BASE_URL .. "/poll?node=" .. urlEncode(nodeId), authHeaders())
    local response
    if not resp then
        response = { type = "poll_result", node = nodeId, ok = false, error = tostring(err) }
    else
        local body = resp.readAll()
        local respHeaders = resp.getResponseHeaders() or {}
        resp.close()
        local pinSet = false
        for name, value in pairs(respHeaders) do
            if name:lower() == "x-shell-pin-set" then pinSet = (value == "1") end
        end
        local ok, commands = pcall(textutils.unserializeJSON, body)
        if ok and type(commands) == "table" then
            response = { type = "poll_result", node = nodeId, ok = true, commands = commands, shellPinSet = pinSet }
        else
            response = { type = "poll_result", node = nodeId, ok = false, error = "bad response from bridge" }
        end
    end
    rednet.send(senderId, SignedRednet.sign(response, GATEWAY_SECRET), RELAY_PROTOCOL)
end

-- Relays a `report` - `bodyJSON` is the EXACT JSON string the requesting
-- node's own report() already built (including its outputCursor/delta
-- fields - see that function's own comment in fleetbridge.lua). This
-- gateway never needs to understand the contents, just forward them
-- byte-for-byte to bridge_server.py's /report?node=<id>.
local function relayReport(senderId, nodeId, bodyJSON)
    local resp, err = httpPost(BASE_URL .. "/report?node=" .. urlEncode(nodeId), bodyJSON,
        authHeaders({ ["Content-Type"] = "application/json" }))
    local response
    if resp then
        resp.close()
        response = { type = "report_result", node = nodeId, ok = true }
    else
        response = { type = "report_result", node = nodeId, ok = false, error = tostring(err) }
    end
    rednet.send(senderId, SignedRednet.sign(response, GATEWAY_SECRET), RELAY_PROTOCOL)
end

-- ---- Bully leader election ----
-- Priority = computer id, lowest wins (arbitrary but a total order every
-- gateway agrees on without needing to ask anyone). A gateway that hasn't
-- heard a heartbeat from a LOWER id within ELECTION_TIMEOUT declares
-- itself leader; hearing one while believing itself leader steps it down
-- immediately - keeps a "two leaders at once" window to at most one
-- heartbeat interval.
local MY_ID = os.getComputerID()
-- Configurable (same "trade off responsiveness vs. load, default fine for
-- most setups" precedent as raytowerPollInterval) mainly so
-- test/test_fleetgateway.lua can shrink these to a few milliseconds -
-- election correctness doesn't depend on the actual interval, only on the
-- ratio, so a real deployment has no reason to change these defaults.
local HEARTBEAT_INTERVAL = cfg.gatewayHeartbeatInterval or 1.0 -- seconds
local ELECTION_TIMEOUT = cfg.gatewayElectionTimeout or (HEARTBEAT_INTERVAL * 3) -- tolerate one missed beat

local isLeader = false
-- Starts as "just heard one" (not "never heard one") so a freshly-(re)booted
-- gateway waits a full ELECTION_TIMEOUT before ever claiming leadership
-- itself, giving any ALREADY-running gateway a fair chance to be heard
-- first - avoids an unnecessary brief split-brain on every restart.
local lastHigherPriorityHeartbeatAt = os.epoch("utc")

print("[fleetgateway] computer " .. MY_ID .. " starting election"
    .. (GATEWAY_SECRET == "" and " (UNSIGNED)" or " (signed)"))

local function handleHeartbeat(message)
    if message.type ~= "heartbeat" or type(message.id) ~= "number" then return end
    if message.id < MY_ID then
        lastHigherPriorityHeartbeatAt = os.epoch("utc")
        if isLeader then
            isLeader = false
            print("[fleetgateway] stepping down - heard heartbeat from higher-priority gateway " .. message.id)
        end
    end
end

local function handleRelay(senderId, message)
    if not isLeader then return end -- non-leaders ignore relay traffic entirely
    if message.type == "poll" and type(message.node) == "string" then
        relayPoll(senderId, message.node)
    elseif message.type == "report" and type(message.node) == "string" and type(message.body) == "string" then
        relayReport(senderId, message.node, message.body)
    end
end

while true do
    if not isLeader and (os.epoch("utc") - lastHigherPriorityHeartbeatAt) >= ELECTION_TIMEOUT * 1000 then
        isLeader = true
        print("[fleetgateway] no higher-priority gateway heard in " .. ELECTION_TIMEOUT .. "s - becoming leader")
    end

    rednet.broadcast(SignedRednet.sign({ type = "heartbeat", id = MY_ID, isLeader = isLeader }, GATEWAY_SECRET),
        HEARTBEAT_PROTOCOL)
    -- Shared with THIS node's own apps/common/fleetbridge.lua (if it's
    -- also running here, which a gateway normally is - see this file's
    -- header) via the kernel's setShared/getShared IPC (fleetos.lua) - lets
    -- report() surface "am I the current gateway leader" to the dashboard
    -- without bridge_server.py needing any awareness of gateway topology
    -- at all (report() just includes it as a plain field like any other).
    fleetos.setShared("gatewayIsLeader", isLeader)

    local deadline = os.epoch("utc") + HEARTBEAT_INTERVAL * 1000
    while true do
        local remaining = (deadline - os.epoch("utc")) / 1000
        if remaining <= 0 then break end

        local senderId, message, protocol = rednet.receive(nil, remaining)
        if senderId and type(message) == "table" then
            if protocol == HEARTBEAT_PROTOCOL then
                if SignedRednet.verify(message, GATEWAY_SECRET) then
                    handleHeartbeat(message)
                end
            elseif protocol == RELAY_PROTOCOL then
                local ok, err = SignedRednet.verify(message, GATEWAY_SECRET)
                if ok then
                    handleRelay(senderId, message)
                else
                    print("[fleetgateway] rejected relay from " .. tostring(senderId) .. ": " .. tostring(err))
                end
            end
        end
    end
end
