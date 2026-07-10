-- Bridges THIS computer to your real Windows PC over HTTP. Run it on
-- every computer in the fleet - there's no master/slave split, every node
-- polls and executes commands for itself, identified by config.lua's
-- `id`. No modem/rednet is REQUIRED - by default each node talks to your
-- PC directly. If a modem is present AND this fleet is running
-- apps/common/fleetgateway.lua somewhere, poll/report can instead relay
-- through a gateway over rednet - see the "Gateway-relay opt-in path"
-- section further down for the full contract; a node with no modem, or a
-- fleet with no gateways deployed, is completely unaffected.
--
-- CraftOS computers can only make OUTGOING http requests, so this app
-- polls a small local server on your PC (windows/bridge_server.py) for
-- commands addressed to this node's id (or to "*" for everyone),
-- executes them locally, and posts a status report back after every
-- poll. Command types:
--   run / kill    - fleetos.spawn/kill an app on THIS computer
--   deploy        - writes new app code (from `code` or fetched from
--                   `url`) to THIS computer, backing up the old version
--                   as <app>.lua.bak, restarting it if it was running
--   rollback      - restores <app>.lua.bak
--   type          - runs a line of text on THIS computer as if typed at
--                   its real shell prompt (shell.run) - remote terminal
--   readfile      - reads a file from THIS computer's disk
--   writefile     - writes a file to THIS computer's disk (creates it if
--                   missing - also how the dashboard's Explorer makes a
--                   brand new empty file)
--   list          - lists one directory's entries (name/isDir/size) on
--                   THIS computer - powers the dashboard's Explorer. `path`
--                   omitted or "" means the root
--   mkdir         - creates a directory on THIS computer
--   delete        - deletes a file OR directory (recursively - same as
--                   CraftOS's own `fs.delete`) on THIS computer
--   move          - renames/moves a file or directory (`from`/`to`,
--                   fs.move) - dashboard Explorer's rename UI. NOT the
--                   same thing as the "rename" command below (that
--                   renames the node's own id, not a file)
--   update        - re-fetches fleetos.lua itself from this same bridge
--                   and reboots to apply it (fleetos.lua isn't an "app",
--                   so plain "deploy" can't touch it). Backs up the
--                   previously-running fleetos.lua as fleetos.lua.bak first.
--   rollback_kernel - restores fleetos.lua.bak (undoes the last
--                   "update") and reboots, same idea as "rollback" above
--                   but for the kernel itself instead of an app.
--   rename        - changes THIS computer's node id (cmd.newId), then
--                   reboots so every part of fleetos/fleetbridge picks up
--                   the new id cleanly. Doesn't touch config.lua (which
--                   may have comments/formatting worth keeping) - writes
--                   a small node_id.txt override instead, which always
--                   wins over config.lua's `id` field if present.
--   world_call    - executes one real Lua "world" action (cmd.action) on
--                   THIS computer and returns its result - print/
--                   gps_locate/peripheral_call/list_peripherals. Not
--                   issued by the dashboard - queued by bridge_server.py's
--                   POST /world_call on behalf of a windows/compute/<name>.py
--                   script that imported _fleetos_world (see that file) -
--                   lets Python act like a real Lua program instead of a
--                   pure stdin/stdout function.
--   monitor_touch - simulates a real tap at character column/row (cmd.x,
--                   cmd.y) on THIS computer's attached monitor, via
--                   fleetos.touchMonitor() - lets the dashboard's monitor
--                   emulation actually be clicked, not just viewed.
--   force_release_monitor - un-claims the monitor regardless of which
--                   app holds it, without killing that app - for a remote
--                   "the screen is stuck" fix when a terminal isn't handy.
--   drone_set     - flight setpoint (cmd.throttle/yawRate/moveX/moveY) for
--                   apps/drone/drone_control.lua, delivered via
--                   fleetos.publish("drone_set", ...) - a no-op if that
--                   app isn't running on this node. See its own header for
--                   the full control scheme; this is just the transport.
--   configure     - bulk fleet config: push a new bridgeUrl/apiKey
--                   and/or startup app list to this node - see
--                   fleetos.setBridge/setStartup.
--
-- The shell command `bridge <url> [key]` (apps/common/shell.lua) changes
-- BASE_URL/API_KEY the same way - writes bridge_override.txt, then restarts
-- just this app (no reboot needed, unlike rename - the node's identity
-- isn't changing). `bridge` with no args shows what's currently active;
-- `bridge clear` removes the override. windows/run_fleetos.lua and
-- run_sim_node.lua accept the same url/key as command-line arguments and
-- write the same file before first boot, for a one-line emulation start.
-- Every report also includes this computer's recent print()/write()
-- output (fleetos.getOutput()), so the website can show a live terminal
-- for ANY node you pick, not just one designated master. Also includes
-- `pos` (last known {x,y,z} via gps.locate(), or nil if no GPS host
-- constellation answers) for the dashboard's Position column/map.
--
-- IMPORTANT: CC:Tweaked blocks http requests to localhost/LAN addresses
-- by default. You must allow BASE_URL's host in your world/server's
-- computercraft-server.toml under [http.rules] - see windows/README.md.
--
-- Authentication is OPT-IN - bridge_server.py has no login of its own
-- unless you set FLEET_BRIDGE_KEY before starting it, in which case every
-- request needs a matching X-API-Key header (see API_KEY below). Without
-- that, whoever can reach BASE_URL can run code and read/write files on
-- this computer through you. Keep it behind something you trust
-- (127.0.0.1, or a VPN like Radmin that only your own peers can join) -
-- don't port-forward it to the open internet without also setting a key.
--
-- BASE_URL is resolved in this order:
--   1. bridge_override.txt (see the `bridge` shell command above) - the
--      most recent explicit choice, wins over everything else
--   2. FLEET_BRIDGE_URL env var (only set by windows/run_fleetos.lua's
--      command-line-argument handling - real CC:Tweaked computers have no
--      os.getenv, so this is always skipped in-game)
--   3. config.lua's bridgeUrl field (the normal way to set this for a
--      real deployed computer, e.g. "http://<your-radmin-ip>:8787")
--   4. http://127.0.0.1:8787 as a last-resort default
--
-- API_KEY (only needed if bridge_server.py was started with
-- FLEET_BRIDGE_KEY) is resolved the same way: bridge_override.txt, then
-- FLEET_BRIDGE_KEY env var, then config.lua's apiKey field, else blank (no
-- auth sent/expected).
--
-- Every http call goes through httpGet/httpPost (see HTTP_TIMEOUT below),
-- which time out rather than blocking forever if the bridge never
-- responds. readfile/writefile reject any path containing ".." up front
-- (fs already sandboxes to this computer's root regardless, but this gives
-- a clear error instead of relying on that silently).

-- protocol version - reported on every /report so bridge_server.py (or
-- any future alternative bridge implementation) can tell which wire shape a
-- node speaks, instead of just guessing from whichever optional fields
-- happen to be present. Bump this if a /report or /poll response field is
-- ever added/removed/repurposed in a way an older node or bridge couldn't
-- just ignore safely.
-- v2: report() now OMITS apps/appVersions/pos/effectiveConfig/monitor
-- entirely when unchanged since the last successfully-delivered report
-- (was: always sent in full every cycle), and output is a delta
-- (getOutputSince) plus a separate always-present outputTail, not the last
-- 150 lines every time. This is NOT safe against an old (pre-diet)
-- bridge_server.py, which did `node["latest_report"] = body` - a
-- wholesale replace that would silently wipe any field this node omits.
-- A v2-or-later bridge merges instead (keeps the previous value for an
-- omitted key) - see windows/bridge_server.py's /report handler.
local PROTOCOL_VERSION = 2

-- adaptive poll interval - a fleet of many nodes each hitting the
-- bridge adds up linearly (50 nodes = 50 req/s minimum, even when the
-- fleet is completely idle). Stay fast right after real activity (a
-- command was just queued for this node - an admin is actively working),
-- fall back to a slower cadence once things go quiet, mirroring the
-- dashboard's own scheduleNextPoll adaptive-polling pattern. IDLE itself
-- (cfg.pollIntervalIdle default, set further below once cfg exists) was
-- 2.0s before the report payload-diet and the optional gateway-relay path
-- both existed, then 0.5s - each individual request AND the bridge's
-- total request count are cheap enough now that a shorter default is
-- still safe. Note for anyone tuning this further in the Windows emulation
-- specifically: this constant used to have no effect below ~1s at all
-- (measured ~1.2s at the old 0.5s IDLE default, same as at 0.2s) - not a
-- curl.exe subprocess cost (measured separately at ~50-90ms/call, not the
-- bottleneck), but a bug in windows/craftos_shim.lua's os.startTimer,
-- which computed fireAt from os.time() (whole seconds) + math.ceil(delay),
-- silently flooring every sub-1-second sleep up to a full second. Fixed
-- there (and in windows/run_sim_node.lua / run_fleetos.lua's driver loops,
-- which also had a ~1s-floor `ping -n N` sleep for the same reason) - this
-- constant now actually controls the real cadence in the Windows emulation
-- too, not just in real CC:Tweaked.
local POLL_INTERVAL_ACTIVE = 0.1
local ACTIVE_WINDOW_SECONDS = 15 -- how long "recently got a command" still counts as active
local POLL_INTERVAL = POLL_INTERVAL_ACTIVE -- kept as the base unit for POS_REFRESH_EVERY/HEARTBEAT_EVERY below

if not http then
    print("[fleetbridge] HTTP API is disabled on this computer")
    return
end

local function loadNodeConfig()
    if not fs.exists("config.lua") then return {} end
    local ok, cfg = pcall(dofile, "config.lua")
    return (ok and type(cfg) == "table") and cfg or {}
end

-- "rename" writes here instead of touching config.lua's Lua source
-- directly (which may have comments/formatting worth preserving) - if
-- present, this always wins over config.lua's `id` field.
local ID_OVERRIDE_FILE = "node_id.txt"

local function loadIdOverride()
    if not fs.exists(ID_OVERRIDE_FILE) then return nil end
    local f = fs.open(ID_OVERRIDE_FILE, "r")
    local content = f.readAll()
    f.close()
    content = content and content:gsub("%s+$", "") or nil
    return (content ~= "" and content) or nil
end

local cfg = loadNodeConfig()
local NODE_ID = loadIdOverride() or cfg.id or ("node_" .. os.getComputerID())
local ROLE = cfg.role or "generic"

-- see POLL_INTERVAL_ACTIVE's own comment above for the full rationale -
-- configurable per-node for a fleet that wants to tune this further.
local POLL_INTERVAL_IDLE = cfg.pollIntervalIdle or 0.2

-- Written by the `bridge <url> [key]` shell command, or by
-- windows/run_fleetos.lua/run_sim_node.lua's command-line-argument handling
-- before first boot - either way, always wins over env var/config.lua (see
-- the header comment above for the full priority order). Plain
-- textutils.serialize, same style as fleetbridge's other small state files.
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

-- Opt-in, mirrors bridge_server.py's FLEET_BRIDGE_KEY - blank means no
-- auth at all (the historical default). Only ever attached to requests
-- aimed at OUR OWN bridge (see authHeaders below) - "deploy" can fetch
-- code from an arbitrary url, and this key must never be sent anywhere
-- but BASE_URL.
local envKey = os.getenv and os.getenv("FLEET_BRIDGE_KEY")
local API_KEY = bridgeOverride.key or envKey or cfg.apiKey or ""

local function urlEncode(s)
    if textutils.urlEncode then return textutils.urlEncode(s) end
    return (s:gsub("[^%w%-%.~_]", function(c) return ("%%%02X"):format(c:byte()) end))
end

-- Builds headers for a request to `url`, merging in X-API-Key ONLY when
-- `url` actually targets our own BASE_URL - never leaks the key to some
-- other host a "deploy" command's url might point at. A plain prefix
-- check isn't enough here: BASE_URL .. ".evil.com/x" also starts with
-- BASE_URL as a string, so the character right after the prefix must be
-- checked too - only "", "/" or "?" mean the match actually ends at a URL
-- boundary instead of continuing into a different hostname.
local function authHeaders(url, extra)
    local headers = extra or {}
    if API_KEY ~= "" and url:sub(1, #BASE_URL) == BASE_URL then
        local boundary = url:sub(#BASE_URL + 1, #BASE_URL + 1)
        if boundary == "" or boundary == "/" or boundary == "?" then
            headers["X-API-Key"] = API_KEY
        end
    end
    return headers
end

local HTTP_TIMEOUT = 8 -- seconds

-- http.get/http.post block internally until the request resolves, with no
-- per-call timeout of their own - if the bridge process is killed mid
-- request (or a "deploy" url just hangs), this computer would otherwise
-- wait forever. http.request is the async form: it fires an http_success/
-- http_failure event when done, so this races that against a manual timer
-- via os.pullEvent - the same "wait for one specific event, ignore the
-- rest" idiom used elsewhere (e.g. os.sleep). Also passes `timeout` in the
-- options table, which recent CC:Tweaked versions honor natively too -
-- belt and suspenders, harmless if an older version just ignores the field.
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

-- fleetos.checkShellPin (used by apps/common/shell.lua's `bridge` command)
-- lives in the kernel (fleetos.lua), not here - see that file's own
-- comment for why registering it from this file's top-level code (only
-- reached once THIS coroutine gets its first resume) isn't early enough.

-- ============================================================
-- Gateway-relay opt-in path - see apps/common/fleetgateway.lua's header
-- for the full design/rationale. Short version: if a modem is present AND
-- this node has actually heard a signed heartbeat from a gateway
-- recently, poll()/report() below try relaying over rednet FIRST, falling
-- back to the direct-HTTP calls above unchanged if that doesn't produce a
-- result quickly. A node with no modem, or one that's never heard a
-- gateway heartbeat (including every node in a fleet that isn't running
-- fleetgateway.lua anywhere), never attempts this at all - poll()/
-- report() behave EXACTLY as they did before this existed, at no extra
-- cost (not even an extra rednet call - gatewayModem is nil, so
-- pollForGatewayHeartbeat/gatewayIsLikelyAvailable short-circuit
-- immediately).
-- ============================================================

local SignedRednet = dofile("apps/common/_signed_rednet.lua")
local GATEWAY_SECRET = cfg.gatewaySecret or ""
local GATEWAY_HEARTBEAT_PROTOCOL = "fleetgateway-heartbeat"
local GATEWAY_RELAY_PROTOCOL = "fleetgateway-relay"
local GATEWAY_HEARTBEAT_FRESHNESS = 5 -- seconds - older than this, treat as "no gateway around"
local GATEWAY_RELAY_TIMEOUT = 0.5 -- seconds to wait for a gateway's relay response before falling back to direct HTTP this cycle

local gatewayModem = peripheral.find("modem")
if gatewayModem and not rednet.isOpen(peripheral.getName(gatewayModem)) then
    rednet.open(peripheral.getName(gatewayModem))
end

local lastGatewayHeartbeatAt = nil -- os.epoch("utc") of the last heartbeat heard, nil = none yet

-- Non-blocking (timeout=0): a real gateway broadcasts every
-- gatewayHeartbeatInterval (default 1s), so missing one on any given
-- cycle is harmless - the next cycle (or the one after) picks it up.
-- Called every poll() regardless of whether a modem is even present -
-- pollForGatewayHeartbeat itself is the thing that no-ops instantly when
-- gatewayModem is nil.
local function pollForGatewayHeartbeat()
    if not gatewayModem then return end
    local senderId, message = rednet.receive(GATEWAY_HEARTBEAT_PROTOCOL, 0)
    if senderId and type(message) == "table" and SignedRednet.verify(message, GATEWAY_SECRET) then
        lastGatewayHeartbeatAt = os.epoch("utc")
    end
end

local function gatewayIsLikelyAvailable()
    return gatewayModem ~= nil and lastGatewayHeartbeatAt ~= nil
        and (os.epoch("utc") - lastGatewayHeartbeatAt) <= GATEWAY_HEARTBEAT_FRESHNESS * 1000
end

-- Returns commands (possibly an empty table - still a valid, successful
-- result, NOT "try direct HTTP instead") on success, or nil if no gateway
-- answered in time / gave a signed, valid response - nil is poll()'s
-- signal to fall back to its normal direct-HTTP path this cycle.
local function pollViaGateway()
    if not gatewayIsLikelyAvailable() then return nil end
    rednet.broadcast(SignedRednet.sign({ type = "poll", node = NODE_ID }, GATEWAY_SECRET), GATEWAY_RELAY_PROTOCOL)
    local deadline = os.epoch("utc") + GATEWAY_RELAY_TIMEOUT * 1000
    while true do
        local remaining = (deadline - os.epoch("utc")) / 1000
        if remaining <= 0 then return nil end
        local senderId, message = rednet.receive(GATEWAY_RELAY_PROTOCOL, remaining)
        if senderId and type(message) == "table" and message.type == "poll_result" and message.node == NODE_ID
                and SignedRednet.verify(message, GATEWAY_SECRET) then
            if not message.ok then return nil end
            -- same X-Shell-Pin-Set contract a direct /poll response header
            -- gives - relayed through the gateway as a plain field instead
            -- (see fleetgateway.lua's relayPoll) so this node's own
            -- shell-PIN-gate cache works identically either way.
            if message.shellPinSet ~= nil then fleetos.markShellPinSet(message.shellPinSet) end
            return message.commands or {}
        end
        -- anything else on this protocol (another node's relay traffic
        -- overheard on the same broadcast channel) - keep waiting out the
        -- remaining budget for OUR OWN response.
    end
end

-- Returns true if a gateway relayed this report successfully, false
-- otherwise (report()'s signal to fall back to direct HTTP this cycle).
local function reportViaGateway(bodyJSON)
    if not gatewayIsLikelyAvailable() then return false end
    rednet.broadcast(SignedRednet.sign({ type = "report", node = NODE_ID, body = bodyJSON }, GATEWAY_SECRET),
        GATEWAY_RELAY_PROTOCOL)
    local deadline = os.epoch("utc") + GATEWAY_RELAY_TIMEOUT * 1000
    while true do
        local remaining = (deadline - os.epoch("utc")) / 1000
        if remaining <= 0 then return false end
        local senderId, message = rednet.receive(GATEWAY_RELAY_PROTOCOL, remaining)
        if senderId and type(message) == "table" and message.type == "report_result" and message.node == NODE_ID
                and SignedRednet.verify(message, GATEWAY_SECRET) then
            return message.ok == true
        end
    end
end

-- "update"/"rename" both reboot right after sending a one-off ack (the
-- normal end-of-cycle report() never runs for them, since os.reboot() cuts
-- the loop short) - if that ack POST itself is lost (one bad network blip
-- at exactly the wrong moment), the bridge never learns the command
-- finished. For "rename" specifically this is worse than just a missing
-- status: bridge_server.py only migrates a node's dashboard folder
-- assignment from the OLD id to the NEW one when it sees this exact ack -
-- losing it silently orphans that folder assignment forever, since the old
-- id never reports again. A few quick retries make that far less likely
-- without meaningfully delaying the reboot on the common case (first
-- attempt succeeds).
local ACK_RETRY_ATTEMPTS = 3
local ACK_RETRY_DELAY = 0.5

local function postAckWithRetry(url, body, headers)
    for attempt = 1, ACK_RETRY_ATTEMPTS do
        local resp, err = httpPost(url, body, headers)
        if resp then return resp end
        if attempt < ACK_RETRY_ATTEMPTS then
            print("[fleetbridge] ack post failed (attempt " .. attempt .. "/" .. ACK_RETRY_ATTEMPTS
                .. "): " .. tostring(err) .. " - retrying")
            os.sleep(ACK_RETRY_DELAY)
        end
    end
    return nil
end

-- Defense in depth: CC:Tweaked's fs API already sandboxes every path to
-- this computer's own root (no way to reach outside it even with ".."), so
-- this can't actually escape anywhere - but rejecting it explicitly here
-- means a bad path fails with a clear error instead of relying on that
-- sandboxing silently doing the right thing.
local function isSafePath(path)
    return type(path) == "string" and not path:find("%.%.")
end

-- without this, a remote "delete"/"move" could brick the node outright
-- - deleting fleetos.lua or startup.lua means it won't even boot back into
-- FleetOS next restart (and, since fleetbridge itself would be gone with
-- it, there'd be no remote way to fix it either), and deleting/moving
-- config.lua loses the node's identity (id/role/startup list/bridge
-- address). Checked by basename only (not full path), since these files
-- always live at the computer's root regardless of how the path was
-- spelled. `cmd.force = true` bypasses this deliberately. Deliberately NOT
-- applied to "writefile" - see that handler's own comment for why
-- overwriting content is a normal, expected action (unlike losing the file
-- entirely) and guarding it would break routine config.lua editing.
local CRITICAL_BASENAMES = { ["fleetos.lua"] = true, ["startup.lua"] = true, ["config.lua"] = true }

local function isCriticalPath(path)
    local base = tostring(path):match("([^/\\]+)$") or path
    return CRITICAL_BASENAMES[base] == true
end

local function isRunning(name)
    for _, t in ipairs(fleetos.list()) do
        if t.name == name then return true end
    end
    return false
end

local function runCommand(cmd)
    if cmd.type == "run" then
        if not cmd.app then return { error = "run needs 'app'" } end
        local ok, err = fleetos.spawn(cmd.app)
        return { ok = ok, err = err }

    elseif cmd.type == "kill" then
        if not cmd.app then return { error = "kill needs 'app'" } end
        local ok, err = fleetos.kill(cmd.app)
        return { ok = ok, err = err }

    elseif cmd.type == "deploy" then
        if not cmd.app then return { error = "deploy needs 'app'" } end
        local code = cmd.code
        if not code and cmd.url then
            local resp, err = httpGet(cmd.url, authHeaders(cmd.url))
            if not resp then return { error = "fetch failed: " .. tostring(err) } end
            code = resp.readAll()
            resp.close()
        end
        if not code then return { error = "deploy needs 'code' or 'url'" } end

        local path = fleetos.appPath(cmd.app)
        local bak = path .. ".bak"
        if fs.exists(path) then
            if fs.exists(bak) then fs.delete(bak) end
            fs.copy(path, bak)
        end
        local f = fs.open(path, "w")
        f.write(code)
        f.close()

        if isRunning(cmd.app) then
            fleetos.kill(cmd.app)
            local ok, err = fleetos.spawn(cmd.app)
            return { ok = ok, err = err, restarted = true }
        end
        return { ok = true, restarted = false }

    elseif cmd.type == "rollback" then
        if not cmd.app then return { error = "rollback needs 'app'" } end
        local path = fleetos.appPath(cmd.app)
        local bak = path .. ".bak"
        if not fs.exists(bak) then return { error = "no backup for " .. cmd.app } end
        if fs.exists(path) then fs.delete(path) end
        fs.copy(bak, path)

        local wasRunning = isRunning(cmd.app)
        if wasRunning then fleetos.kill(cmd.app) end
        local ok, err = fleetos.spawn(cmd.app)
        return { ok = ok, err = err }

    elseif cmd.type == "type" then
        if not cmd.text then return { error = "type needs 'text'" } end
        local ok, err = fleetos.runShellLine(cmd.text)
        return { ok = ok, err = err }

    elseif cmd.type == "readfile" then
        if not cmd.path then return { error = "readfile needs 'path'" } end
        if not isSafePath(cmd.path) then return { error = "invalid path: " .. tostring(cmd.path) } end
        -- fs.isDir checked before fs.exists - same reason as "list"/"delete"
        -- above: fs.exists (io.open-based, both local shims) can't see
        -- directories at all, so a bare fs.exists() check would report a
        -- real directory as "not found" instead of "it's a folder".
        if fs.isDir(cmd.path) then return { error = "is a directory, not a file: " .. cmd.path } end
        if not fs.exists(cmd.path) then return { error = "not found: " .. cmd.path } end
        local f = fs.open(cmd.path, "r")
        if not f then return { error = "could not open for reading: " .. cmd.path } end
        local content = f.readAll()
        f.close()
        return { ok = true, content = content }

    elseif cmd.type == "writefile" then
        if not cmd.path then return { error = "writefile needs 'path'" } end
        if not isSafePath(cmd.path) then return { error = "invalid path: " .. tostring(cmd.path) } end
        -- Deliberately NOT critical-file-guarded like delete/move below -
        -- editing fleetos.lua/startup.lua/config.lua's CONTENT via the
        -- dashboard's Explorer "Save" is a completely normal, expected admin
        -- action (that's exactly how config.lua gets edited day to day) and
        -- goes through this same generic writefile - guarding it here would
        -- silently break that. The actual risk worth guarding against is
        -- DELETING a critical file entirely and bricking the node, which
        -- overwriting its content doesn't do - see the delete/move guards
        -- below for that.
        --
        -- config.lua/startup.lua/fleetos.lua have no edit history - a
        -- bad edit via the dashboard's Explorer previously just silently
        -- overwrote the last-good version with no way back. Keep ONE
        -- previous version as `<path>.bak` before overwriting - the same
        -- convention "deploy"/"rollback" already use for apps/<name>.lua,
        -- just applied here too. Not full version history (git-style), a
        -- single rollback step - proportionate to what this actually needs.
        if isCriticalPath(cmd.path) and fs.exists(cmd.path) then
            local bak = cmd.path .. ".bak"
            if fs.exists(bak) then fs.delete(bak) end
            fs.copy(cmd.path, bak)
        end

        -- write to a temp file first, then swap it into place, instead
        -- of writing straight into cmd.path - a computer losing power/being
        -- unloaded/crashing mid-write previously left cmd.path holding
        -- whatever partial bytes had flushed so far (neither the old nor
        -- the new content - the worst possible outcome, especially for
        -- config.lua, which would then fail to even dofile()). The real
        -- content-writing now happens entirely on a throwaway `.tmp_write`
        -- file the original is never touched until swapping it in is a
        -- single quick delete+move - a MUCH smaller window than "however
        -- long the full write takes" for a crash to land badly in.
        local tmpPath = cmd.path .. ".tmp_write"
        local f = fs.open(tmpPath, "w")
        if not f then return { error = "could not open for writing: " .. cmd.path } end
        f.write(cmd.content or "")
        f.close()
        if fs.exists(cmd.path) then fs.delete(cmd.path) end
        fs.move(tmpPath, cmd.path)
        return { ok = true }

    elseif cmd.type == "list" then
        -- Powers the dashboard's Explorer. `path` "" (or omitted) lists the
        -- root - unlike readfile/writefile/delete/mkdir, an empty path is a
        -- legitimate, safe request here (read-only), so it's allowed through
        -- isSafePath (which only rejects "..") rather than treated as missing.
        local path = cmd.path or ""
        if not isSafePath(path) then return { error = "invalid path: " .. tostring(path) } end
        -- fs.isDir checked BEFORE fs.exists on purpose: fs.exists (both local
        -- shims) uses io.open, which can't open a directory as a file and so
        -- always reports a real directory as "not found". fs.exists is only
        -- meaningful here once we already know the path is NOT a directory.
        if path ~= "" and not fs.isDir(path) then
            if fs.exists(path) then return { error = "not a directory: " .. path } end
            return { error = "not found: " .. path }
        end
        local ok, names = pcall(fs.list, path)
        if not ok then return { error = "list failed: " .. tostring(names) } end
        local entries = {}
        for _, name in ipairs(names) do
            local full = (path == "") and name or (path .. "/" .. name)
            local isDir = fs.isDir(full)
            entries[#entries + 1] = { name = name, isDir = isDir, size = isDir and 0 or (fs.getSize(full) or 0) }
        end
        -- folders first, then alphabetical - matches a normal file explorer
        table.sort(entries, function(a, b)
            if a.isDir ~= b.isDir then return a.isDir end
            return a.name:lower() < b.name:lower()
        end)
        return { ok = true, path = path, entries = entries }

    elseif cmd.type == "mkdir" then
        if not cmd.path or cmd.path == "" then return { error = "mkdir needs 'path'" } end
        if not isSafePath(cmd.path) then return { error = "invalid path: " .. tostring(cmd.path) } end
        -- fs.makeDir (real CraftOS and both local shims) is a silent no-op
        -- on an already-existing directory - fine as CraftOS semantics, but
        -- it means the dashboard's "New folder" button would otherwise give
        -- zero feedback that nothing actually changed on a name collision.
        -- Check first so the response can say so explicitly.
        if fs.isDir(cmd.path) then return { ok = true, alreadyExisted = true } end
        if fs.exists(cmd.path) then return { error = "a file already exists there: " .. cmd.path } end
        local ok, err = pcall(fs.makeDir, cmd.path)
        if not ok then return { error = "mkdir failed: " .. tostring(err) } end
        return { ok = true }

    elseif cmd.type == "delete" then
        -- The "cmd.path == ''" guard matters here specifically: unlike Lua's
        -- usual falsy values, an empty string IS truthy, so "not cmd.path"
        -- alone would let path="" (the root) straight through to fs.delete.
        if not cmd.path or cmd.path == "" then return { error = "delete needs 'path'" } end
        if not isSafePath(cmd.path) then return { error = "invalid path: " .. tostring(cmd.path) } end
        if isCriticalPath(cmd.path) and not cmd.force then
            return { error = "refusing to delete critical file " .. cmd.path .. " (pass force=true to override)" }
        end
        -- fs.exists alone (io.open-based, both local shims) always reports a
        -- real directory as missing - same fix as "list" above. fs.isDir
        -- catches what fs.exists can't.
        if not fs.exists(cmd.path) and not fs.isDir(cmd.path) then
            return { error = "not found: " .. cmd.path }
        end
        local ok, err = pcall(fs.delete, cmd.path)
        if not ok then return { error = "delete failed: " .. tostring(err) } end
        return { ok = true }

    elseif cmd.type == "move" then
        -- Renames/moves a file or directory (fs.move, not copy+delete) -
        -- powers the dashboard Explorer's rename UI. Distinct from the
        -- "rename" command above, which renames the NODE's own id, not a
        -- file - deliberately different names so the two can't be confused.
        if not cmd.from or not cmd.to then return { error = "move needs 'from' and 'to'" } end
        if not isSafePath(cmd.from) or not isSafePath(cmd.to) then return { error = "invalid path" } end
        if (isCriticalPath(cmd.from) or isCriticalPath(cmd.to)) and not cmd.force then
            return { error = "refusing to move a critical file (pass force=true to override)" }
        end
        if not fs.exists(cmd.from) and not fs.isDir(cmd.from) then return { error = "not found: " .. cmd.from } end
        if fs.exists(cmd.to) or fs.isDir(cmd.to) then return { error = "already exists: " .. cmd.to } end
        local ok, err = pcall(fs.move, cmd.from, cmd.to)
        if not ok then return { error = "move failed: " .. tostring(err) } end
        return { ok = true }

    elseif cmd.type == "world_call" then
        -- See the "world_call" line in the header comment above. `print`
        -- deliberately reuses the REAL print() (goes through fleetos.lua's
        -- output capture, exactly like any app's own output) rather than a
        -- separate "write to monitor" API - that capture is already mirrored
        -- to both the dashboard's Terminal and any attached monitor, so a
        -- second code path would just be redundant and could drift out of
        -- sync with it.
        local action = cmd.action
        local args = cmd.args or {}
        if action == "print" then
            print(tostring(args.text))
            return { value = true }
        elseif action == "gps_locate" then
            if not (gps and gps.locate) then return { error = "no gps API on this computer" } end
            local ok, x, y, z = pcall(gps.locate, args.timeout or 2)
            if not ok or x == nil then return { error = "gps.locate failed or timed out" } end
            return { value = { x = x, y = y, z = z } }
        elseif action == "peripheral_call" then
            if not args.name or not args.method then
                return { error = "peripheral_call needs 'name' and 'method'" }
            end
            if not peripheral.isPresent(args.name) then
                return { error = "no peripheral named " .. tostring(args.name) }
            end
            local ok, result = pcall(peripheral.call, args.name, args.method, table.unpack(args.params or {}))
            if not ok then return { error = "peripheral_call failed: " .. tostring(result) } end
            return { value = result }
        elseif action == "list_peripherals" then
            return { value = peripheral.getNames() }
        else
            return { error = "unknown world_call action: " .. tostring(action) }
        end

    elseif cmd.type == "monitor_touch" then
        -- Lets the dashboard's monitor emulation be genuinely clickable -
        -- simulates tapping character column/row (cmd.x, cmd.y) on this
        -- computer's real monitor, via fleetos.touchMonitor() (fires a real
        -- monitor_touch event, so monitorMirrorLoop's own existing button/
        -- collapse handling runs exactly as it would for a real tap).
        if not cmd.x or not cmd.y then return { error = "monitor_touch needs 'x' and 'y'" } end
        local ok, err = fleetos.touchMonitor(cmd.x, cmd.y)
        if not ok then return { error = err or "monitor_touch failed" } end
        return { ok = true }

    elseif cmd.type == "drone_set" then
        -- Just a transport: forwards the setpoint fields to whatever's
        -- listening for the "drone_set" topic. Deliberately doesn't
        -- validate ranges here (drone_control.lua's motor_mixer already
        -- clamps everything) or check that drone_control is even running -
        -- publish() is a no-op broadcast, so this always succeeds even if
        -- there's no drone app on this node to receive it.
        fleetos.publish("drone_set", {
            throttle = cmd.throttle,
            yawRate = cmd.yawRate,
            moveX = cmd.moveX,
            moveY = cmd.moveY,
        })
        return { ok = true }

    elseif cmd.type == "force_release_monitor" then
        -- belt-and-suspenders (see fleetos.lua's forceReleaseMonitor
        -- comment): un-sticks a claimed monitor remotely without needing to
        -- kill the claiming app, for a claiming app that's alive/yielding
        -- fine but just never redraws/releases on its own.
        fleetos.forceReleaseMonitor()
        return { ok = true }

    elseif cmd.type == "configure" then
        -- bulk fleet configuration - the dashboard can send this to "*"
        -- (or a folder's worth of nodes) to push a new bridge address/key
        -- and/or startup app list to many computers in one action, instead
        -- of hand-editing config.lua on each one. Fields are independent -
        -- send just cmd.bridgeUrl, just cmd.startup, or both. `startup`
        -- takes effect on this node's NEXT boot (fleetos.lua's boot() only
        -- reads it once at startup, same as config.lua's own `startup`
        -- always has) - pair with an "update" or a manual reboot if you need
        -- it to apply immediately.
        if not cmd.bridgeUrl and not cmd.apiKey and not cmd.startup then
            return { error = "configure needs 'bridgeUrl'/'apiKey' and/or 'startup'" }
        end
        local changed = {}
        if cmd.bridgeUrl or cmd.apiKey then
            fleetos.setBridge(cmd.bridgeUrl or BASE_URL, cmd.apiKey or API_KEY)
            changed[#changed + 1] = "bridge"
        end
        if cmd.startup then
            if type(cmd.startup) ~= "table" then return { error = "'startup' must be a list of app names" } end
            fleetos.setStartup(cmd.startup)
            changed[#changed + 1] = "startup (applies next boot)"
        end
        return { ok = true, changed = changed }

    elseif cmd.type == "update" then
        -- Self-update: fleetos.lua isn't an "app" (deploy only ever
        -- touches apps/<name>.lua), so this is the only way to get a
        -- kernel fix onto an already-deployed computer without manually
        -- wget-ing it again on every node. Fetches the current
        -- fleetos.lua from the SAME bridge this node already talks to
        -- (not an arbitrary url, unlike deploy) and reboots to apply it -
        -- CraftOS has no "reload this running program" primitive.
        local resp, err = httpGet(BASE_URL .. "/fleetos.lua", authHeaders(BASE_URL))
        if not resp then return { error = "fetch failed: " .. tostring(err) } end
        local code = resp.readAll()
        resp.close()

        -- back up the CURRENTLY-running kernel before overwriting it -
        -- previously "update" always pulled the latest fleetos.lua with no
        -- way back short of manually re-uploading an old copy by hand. A
        -- bad update can now be undone with "rollback_kernel" below, the
        -- same .bak convention apps/config.lua already use (see/deploy).
        if fs.exists("fleetos.lua") then
            if fs.exists("fleetos.lua.bak") then fs.delete("fleetos.lua.bak") end
            fs.copy("fleetos.lua", "fleetos.lua.bak")
        end

        local f = fs.open("fleetos.lua", "w")
        f.write(code)
        f.close()

        -- so the reboot actually relaunches fleetos instead of dropping
        -- to a bare prompt - harmless if one's already there
        if not fs.exists("startup.lua") then
            local sf = fs.open("startup.lua", "w")
            sf.write('shell.run("fleetos")\n')
            sf.close()
        end

        -- ack now: os.reboot() below means the normal end-of-cycle
        -- report() never runs for this command, so the dashboard would
        -- otherwise never see it resolve
        local ackBody = textutils.serializeJSON({
            id = NODE_ID, role = ROLE, apps = {},
            results = { { command = cmd, result = { ok = true, rebooting = true } } },
            output = fleetos.getOutput(150),
        })
        local ackResp = postAckWithRetry(BASE_URL .. "/report?node=" .. urlEncode(NODE_ID), ackBody,
            authHeaders(BASE_URL, { ["Content-Type"] = "application/json" }))
        if ackResp then ackResp.close() end

        os.sleep(0.5)
        os.reboot()

    elseif cmd.type == "rollback_kernel" then
        -- restores the fleetos.lua.bak an "update" made right before
        -- overwriting it (see above) - per-node kernel rollback, previously
        -- only a manual re-upload could undo a bad "update". Only ever goes
        -- back ONE version, same as app rollback above - not full history.
        if not fs.exists("fleetos.lua.bak") then return { error = "no fleetos.lua.bak on this node" } end
        fs.delete("fleetos.lua")
        fs.copy("fleetos.lua.bak", "fleetos.lua")

        local ackBody = textutils.serializeJSON({
            id = NODE_ID, role = ROLE, apps = {},
            results = { { command = cmd, result = { ok = true, rebooting = true } } },
            output = fleetos.getOutput(150),
        })
        local ackResp = postAckWithRetry(BASE_URL .. "/report?node=" .. urlEncode(NODE_ID), ackBody,
            authHeaders(BASE_URL, { ["Content-Type"] = "application/json" }))
        if ackResp then ackResp.close() end

        os.sleep(0.5)
        os.reboot()

    elseif cmd.type == "rename" then
        if not cmd.newId or cmd.newId == "" then return { error = "rename needs 'newId'" } end

        local f = fs.open(ID_OVERRIDE_FILE, "w")
        f.write(cmd.newId)
        f.close()

        -- ack under the OLD id (that's who the dashboard queued this
        -- command against) before rebooting - same reasoning as "update"
        -- above: os.reboot() means the normal end-of-cycle report() never
        -- runs for this command
        local ackBody = textutils.serializeJSON({
            id = NODE_ID, role = ROLE, apps = {},
            results = { { command = cmd, result = { ok = true, renamed = true, newId = cmd.newId } } },
            output = fleetos.getOutput(150),
        })
        local ackResp = postAckWithRetry(BASE_URL .. "/report?node=" .. urlEncode(NODE_ID), ackBody,
            authHeaders(BASE_URL, { ["Content-Type"] = "application/json" }))
        if ackResp then ackResp.close() end

        os.sleep(0.5)
        os.reboot()
    end

    return { error = "unknown command type: " .. tostring(cmd.type) }
end

-- Returns (commands, err) - err is nil on success. A failed request and "no
-- commands queued" both used to collapse to the same empty {} result, which
-- silently hid every connectivity problem (wrong address, blocked by
-- computercraft-server.toml's [http.rules], curl missing/failing in the
-- Windows shim, wrong key, ...) - the loop below only prints err, so this
-- return value is what makes that visible at all.
local function poll()
    pollForGatewayHeartbeat()
    local viaGateway = pollViaGateway()
    if viaGateway then return viaGateway, nil end

    local resp, httpErr = httpGet(BASE_URL .. "/poll?node=" .. urlEncode(NODE_ID), authHeaders(BASE_URL))
    if not resp then return {}, httpErr or "request failed" end
    -- Refreshes the kernel's LOCAL cache of "does this node have a shell
    -- PIN" from the response header bridge_server.py's /poll always sends
    -- - every poll cycle, at zero extra network cost - so fleetos.lua's
    -- terminate handler never has to make its own round trip just to find
    -- out whether Ctrl+T needs gating at all. See fleetos.lua's
    -- markShellPinSet comment for why that matters. (pollViaGateway above
    -- gets the same signal relayed as a plain `shellPinSet` field instead
    -- of a response header when it's the one that succeeds.)
    local respHeaders = resp.getResponseHeaders() or {}
    for name, value in pairs(respHeaders) do
        if name:lower() == "x-shell-pin-set" then
            fleetos.markShellPinSet(value == "1")
        end
    end
    local body = resp.readAll()
    resp.close()
    local ok, commands = pcall(textutils.unserializeJSON, body)
    if not ok or type(commands) ~= "table" then return {}, "bad response from bridge" end
    return commands, nil
end

-- Powers the dashboard's map/position column. gps.locate() needs a GPS host
-- constellation (4+ wireless-modem computers running the stock gps host
-- program) to resolve anything - most fleets won't have one, and that's
-- fine, `pos` just stays nil and the dashboard shows "unknown". Only
-- refreshed every POS_REFRESH_EVERY cycles (not every poll) with a SHORT
-- timeout, for two reasons: gps.locate() blocks on a rednet round-trip
-- (same event loop everything else here shares), and if no GPS host exists
-- at all it would otherwise block for its full timeout on EVERY single
-- ~1s poll cycle forever. The last successful fix is cached and resent
-- every report even on cycles that didn't re-check.
local POS_REFRESH_EVERY = math.ceil(15 / POLL_INTERVAL)
local GPS_TIMEOUT = 1 -- seconds - short on purpose, see above
local ticksSincePos = POS_REFRESH_EVERY -- so the very first cycle tries once immediately
local lastPos = nil

local function refreshPosIfDue()
    ticksSincePos = ticksSincePos + 1
    if ticksSincePos < POS_REFRESH_EVERY then return end
    ticksSincePos = 0
    if not (gps and gps.locate) then return end
    local ok, x, y, z = pcall(gps.locate, GPS_TIMEOUT)
    if ok and x then lastPos = { x = x, y = y, z = z } end
end

-- Returns err (nil on success) - same reasoning as poll() above.
-- Payload diet: report() used to resend apps/appVersions/pos/
-- effectiveConfig/monitor in FULL every single cycle (as often as every
-- POLL_INTERVAL_ACTIVE = 0.2s while active) even when nothing had changed,
-- and `output` resent the last 150 lines every time instead of just what's
-- new. These locals track what was last SUCCESSFULLY delivered (updated
-- only after httpPost actually succeeds, never on a failed/lost attempt -
-- otherwise a single dropped report would permanently omit data the
-- bridge never actually received). A field is included in the outgoing
-- body only when it differs from its "last sent" value; the bridge's
-- merge logic (see windows/bridge_server.py's /report handler) keeps
-- whatever it already had for anything omitted.
local lastOutputCursor = 0
local lastMonitorHash = nil
local lastAppsJSON = nil
local lastAppVersionsJSON = nil
local lastPosJSON = nil
local lastEffectiveConfigJSON = nil

-- Bounds how stale a bridge restart can leave things: bridge_server.py
-- does NOT persist latest_report across a restart (by design - see its own
-- comment), but THIS node's "last sent" locals above survive fine (this
-- process never restarted) - without a periodic full resend, a field this
-- node correctly considers unchanged would stay silently absent from the
-- bridge's view forever after a bridge restart, not just stale. Forcing
-- every cache to look "unsent" periodically re-includes everything, same
-- as this node's very first report ever (all the locals start nil/0 too).
local FULL_RESYNC_EVERY = math.ceil(60 / POLL_INTERVAL)
local ticksSinceFullResync = 0

local function report(results)
    local apps = {}
    -- name -> short content checksum for every currently-running app,
    -- kept as a SEPARATE field (not appended into the "apps" strings above)
    -- so it can't be confused with a colon-delimited status field by any
    -- existing consumer - see fleetos.appVersion's own comment.
    local appVersions = {}
    for _, t in ipairs(fleetos.list()) do
        apps[#apps + 1] = t.name .. ":" .. t.status
        local version = fleetos.appVersion(t.name)
        if version then appVersions[t.name] = version end
    end

    refreshPosIfDue()

    ticksSinceFullResync = ticksSinceFullResync + 1
    if ticksSinceFullResync >= FULL_RESYNC_EVERY then
        lastMonitorHash, lastAppsJSON, lastAppVersionsJSON = nil, nil, nil
        lastPosJSON, lastEffectiveConfigJSON = nil, nil
        ticksSinceFullResync = 0
    end

    local newOutputLines, newOutputCursor, outputTail = fleetos.getOutputSince(lastOutputCursor)

    -- nil (omitted) if no monitor has ever been found/drawn to this
    -- session - the dashboard shows "no monitor attached" for that. See
    -- fleetos.lua's "Monitor capture" section.
    local monitorSnapshot = fleetos.getMonitorSnapshot()
    local monitorJSON = monitorSnapshot and textutils.serializeJSON(monitorSnapshot)
    local monitorHash = monitorJSON and fleetos.checksum(monitorJSON)

    local appsJSON = textutils.serializeJSON(apps)
    local appVersionsJSON = textutils.serializeJSON(appVersions)
    local posJSON = lastPos and textutils.serializeJSON(lastPos)
    -- config.lua deliberately never gets rewritten by bridgeOverride/
    -- startupOverride (would risk clobbering an admin's own comments/
    -- formatting) - which means config.lua's own bridgeUrl/startup fields
    -- can silently drift out of sync with what's ACTUALLY in effect.
    -- Reporting the resolved/effective values here (not just config.lua's
    -- raw ones) makes that divergence visible to the dashboard/an admin
    -- instead of hidden.
    local effectiveConfig = { bridgeUrl = BASE_URL, startup = fleetos.getStartupOverride() }
    local effectiveConfigJSON = textutils.serializeJSON(effectiveConfig)

    local payload = {
        id = NODE_ID,
        role = ROLE,
        protocolVersion = PROTOCOL_VERSION,
        results = results,
        -- always present (even ""/empty) - see getOutputSince's own
        -- comment for why the in-progress line can't be delta'd like a
        -- completed one.
        outputTail = outputTail,
        -- true only under windows/craftos_shim.lua's Windows emulation
        -- (which sets this global, see its own header comment) - never
        -- present/true on a real in-game computer. Lets the dashboard mark
        -- test/dev nodes so they're not mistaken for real fleet members.
        emulated = _G.CRAFTOS_EMULATION == true,
    }
    if #newOutputLines > 0 then
        payload.output = newOutputLines
        -- bridge_server.py's /report handler needs this to append (not
        -- overwrite) AND to reject an at-least-once HTTP retry resending
        -- this exact same delta twice - see its own _merge_report comment.
        payload.outputCursor = newOutputCursor
    end
    if monitorHash ~= lastMonitorHash then payload.monitor = monitorSnapshot end
    if appsJSON ~= lastAppsJSON then payload.apps = apps end
    if appVersionsJSON ~= lastAppVersionsJSON then payload.appVersions = appVersions end
    if posJSON ~= lastPosJSON then payload.pos = lastPos end
    if effectiveConfigJSON ~= lastEffectiveConfigJSON then payload.effectiveConfig = effectiveConfig end
    -- Set by apps/common/fleetgateway.lua (via fleetos.setShared) if it's
    -- ALSO running on this node - nil (and so omitted here) on every
    -- regular, non-gateway node, which never touches this shared key at
    -- all. Surfaces "am I the current gateway leader" on the dashboard's
    -- Status tab without bridge_server.py needing any gateway-topology
    -- awareness of its own.
    local gatewayIsLeader = fleetos.getShared("gatewayIsLeader")
    if gatewayIsLeader ~= nil then payload.isGatewayLeader = gatewayIsLeader end
    -- Set by apps/drone/drone_control.lua (via fleetos.setShared) if it's
    -- running on this node - nil (and omitted) on every non-drone node,
    -- same pattern as isGatewayLeader above. dashboard.html shows the
    -- drone control panel only for a node that reports this.
    local droneState = fleetos.getShared("droneState")
    if droneState ~= nil then payload.drone = droneState end

    local body = textutils.serializeJSON(payload)

    -- only advance the "already told the bridge" caches once the report
    -- has actually been delivered (via EITHER path below) - see their own
    -- comment above for why a failed/lost attempt must not advance them.
    local function markDelivered()
        lastOutputCursor = newOutputCursor
        lastMonitorHash = monitorHash
        lastAppsJSON = appsJSON
        lastAppVersionsJSON = appVersionsJSON
        lastPosJSON = posJSON
        lastEffectiveConfigJSON = effectiveConfigJSON
    end

    if reportViaGateway(body) then
        markDelivered()
        return nil
    end

    local resp, httpErr = httpPost(BASE_URL .. "/report?node=" .. urlEncode(NODE_ID), body,
        authHeaders(BASE_URL, { ["Content-Type"] = "application/json" }))
    if resp then
        resp.close()
        markDelivered()
        return nil
    end
    return httpErr or "request failed"
end

print("[fleetbridge] '" .. NODE_ID .. "' polling " .. BASE_URL)

-- Otherwise this loop runs forever without printing anything once idle -
-- a periodic heartbeat means anyone watching this computer's terminal (or
-- the dashboard's Terminal panel) can tell it's still alive, not stuck.
local HEARTBEAT_EVERY = math.ceil(30 / POLL_INTERVAL)
local ticksSinceHeartbeat = 0

-- Only reprinted when the error actually CHANGES (appears, disappears, or
-- says something different) - a dead bridge would otherwise spam this line
-- every single cycle forever, same reasoning as the other "print on change"
-- spots in this project (e.g. raytower_master.lua's lastPrintedErr).
local lastPollErr, lastReportErr = nil, nil

-- os.clock() is a monotonic uptime clock (not wall time), fine for a
-- relative "how long since we were last active" check. Starts at
-- ACTIVE_WINDOW_SECONDS in the past so the very first cycle after boot
-- still polls at the slow/idle rate rather than assuming freshly-booted
-- means active.
local lastActiveAt = os.clock() - ACTIVE_WINDOW_SECONDS

while true do
    local commands, pollErr = poll()
    if pollErr ~= lastPollErr then
        if pollErr then print("[fleetbridge] poll failed: " .. tostring(pollErr)) end
        lastPollErr = pollErr
    end
    if #commands > 0 then lastActiveAt = os.clock() end
    local results = {}

    for _, cmd in ipairs(commands) do
        -- A malformed/unexpected command (bad field name, app name that
        -- resolveAppPath chokes on, etc.) must not take down the WHOLE
        -- fleetbridge task - before this pcall, one bad command permanently
        -- silenced this computer's reporting until someone noticed and
        -- restarted it by hand, since this loop IS the report loop too.
        local ok, result = pcall(runCommand, cmd)
        if not ok then result = { error = tostring(result) } end
        results[#results + 1] = { command = cmd, result = result }
        print(("[fleetbridge] %s %s -> %s"):format(
            cmd.type, cmd.app or cmd.path or "", result.ok and "ok" or (result.error or result.err or "?")))
        ticksSinceHeartbeat = 0
    end

    local reportErr = report(results)
    if reportErr ~= lastReportErr then
        if reportErr then print("[fleetbridge] report failed: " .. tostring(reportErr)) end
        lastReportErr = reportErr
    end

    ticksSinceHeartbeat = ticksSinceHeartbeat + 1
    if ticksSinceHeartbeat >= HEARTBEAT_EVERY then
        print("[fleetbridge] '" .. NODE_ID .. "' still polling" .. (pollErr and (" (last error: " .. tostring(pollErr) .. ")") or ""))
        ticksSinceHeartbeat = 0
    end

    local idle = (os.clock() - lastActiveAt) >= ACTIVE_WINDOW_SECONDS
    os.sleep(idle and POLL_INTERVAL_IDLE or POLL_INTERVAL_ACTIVE)
end
