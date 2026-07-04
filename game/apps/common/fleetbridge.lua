-- Bridges THIS computer to your real Windows PC over HTTP. Run it on
-- every computer in the fleet - there's no master/slave split, every node
-- polls and executes commands for itself, identified by config.lua's
-- `id`. No modem/rednet needed for this - each node talks to your PC
-- directly.
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
--   writefile     - writes a file to THIS computer's disk
--   update        - re-fetches fleetos.lua itself from this same bridge
--                   and reboots to apply it (fleetos.lua isn't an "app",
--                   so plain "deploy" can't touch it)
--   rename        - changes THIS computer's node id (cmd.newId), then
--                   reboots so every part of fleetos/fleetbridge picks up
--                   the new id cleanly. Doesn't touch config.lua (which
--                   may have comments/formatting worth keeping) - writes
--                   a small node_id.txt override instead, which always
--                   wins over config.lua's `id` field if present.
-- Every report also includes this computer's recent print()/write()
-- output (fleetos.getOutput()), so the website can show a live terminal
-- for ANY node you pick, not just one designated master.
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
--   1. FLEET_BRIDGE_URL env var (only set by windows/run.bat for local
--      testing - real CC:Tweaked computers have no os.getenv, so this is
--      always skipped in-game)
--   2. config.lua's bridgeUrl field (the normal way to set this for a
--      real deployed computer, e.g. "http://<your-radmin-ip>:8787")
--   3. http://127.0.0.1:8787 as a last-resort default
--
-- API_KEY (only needed if bridge_server.py was started with
-- FLEET_BRIDGE_KEY) is resolved the same way: FLEET_BRIDGE_KEY env var,
-- then config.lua's apiKey field, else blank (no auth sent/expected).

local POLL_INTERVAL = 1

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

local envUrl = os.getenv and os.getenv("FLEET_BRIDGE_URL")
local BASE_URL = envUrl or cfg.bridgeUrl or "http://127.0.0.1:8787"

-- Opt-in, mirrors bridge_server.py's FLEET_BRIDGE_KEY - blank means no
-- auth at all (the historical default). Only ever attached to requests
-- aimed at OUR OWN bridge (see authHeaders below) - "deploy" can fetch
-- code from an arbitrary url, and this key must never be sent anywhere
-- but BASE_URL.
local envKey = os.getenv and os.getenv("FLEET_BRIDGE_KEY")
local API_KEY = envKey or cfg.apiKey or ""

local function urlEncode(s)
    if textutils.urlEncode then return textutils.urlEncode(s) end
    return (s:gsub("[^%w%-%.~_]", function(c) return ("%%%02X"):format(c:byte()) end))
end

-- Builds headers for a request to `url`, merging in X-API-Key ONLY when
-- `url` actually targets our own BASE_URL - never leaks the key to some
-- other host a "deploy" command's url might point at.
local function authHeaders(url, extra)
    local headers = extra or {}
    if API_KEY ~= "" and url:sub(1, #BASE_URL) == BASE_URL then
        headers["X-API-Key"] = API_KEY
    end
    return headers
end

local function isRunning(name)
    for _, t in ipairs(fleetos.list()) do
        if t.name == name then return true end
    end
    return false
end

local function runCommand(cmd)
    if cmd.type == "run" then
        local ok, err = fleetos.spawn(cmd.app)
        return { ok = ok, err = err }

    elseif cmd.type == "kill" then
        local ok, err = fleetos.kill(cmd.app)
        return { ok = ok, err = err }

    elseif cmd.type == "deploy" then
        if not cmd.app then return { error = "deploy needs 'app'" } end
        local code = cmd.code
        if not code and cmd.url then
            local resp, err = http.get(cmd.url, authHeaders(cmd.url))
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
        if not fs.exists(cmd.path) then return { error = "not found: " .. cmd.path } end
        local f = fs.open(cmd.path, "r")
        local content = f.readAll()
        f.close()
        return { ok = true, content = content }

    elseif cmd.type == "writefile" then
        if not cmd.path then return { error = "writefile needs 'path'" } end
        local f = fs.open(cmd.path, "w")
        if not f then return { error = "could not open for writing: " .. cmd.path } end
        f.write(cmd.content or "")
        f.close()
        return { ok = true }

    elseif cmd.type == "update" then
        -- Self-update: fleetos.lua isn't an "app" (deploy only ever
        -- touches apps/<name>.lua), so this is the only way to get a
        -- kernel fix onto an already-deployed computer without manually
        -- wget-ing it again on every node. Fetches the current
        -- fleetos.lua from the SAME bridge this node already talks to
        -- (not an arbitrary url, unlike deploy) and reboots to apply it -
        -- CraftOS has no "reload this running program" primitive.
        local resp, err = http.get(BASE_URL .. "/fleetos.lua", authHeaders(BASE_URL))
        if not resp then return { error = "fetch failed: " .. tostring(err) } end
        local code = resp.readAll()
        resp.close()

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
        local ackResp = http.post(BASE_URL .. "/report?node=" .. urlEncode(NODE_ID), ackBody,
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
        local ackResp = http.post(BASE_URL .. "/report?node=" .. urlEncode(NODE_ID), ackBody,
            authHeaders(BASE_URL, { ["Content-Type"] = "application/json" }))
        if ackResp then ackResp.close() end

        os.sleep(0.5)
        os.reboot()
    end

    return { error = "unknown command type: " .. tostring(cmd.type) }
end

local function poll()
    local resp = http.get(BASE_URL .. "/poll?node=" .. urlEncode(NODE_ID), authHeaders(BASE_URL))
    if not resp then return {} end
    local body = resp.readAll()
    resp.close()
    local ok, commands = pcall(textutils.unserializeJSON, body)
    if not ok or type(commands) ~= "table" then return {} end
    return commands
end

local function report(results)
    local apps = {}
    for _, t in ipairs(fleetos.list()) do
        apps[#apps + 1] = t.name .. ":" .. t.status
    end

    local body = textutils.serializeJSON({
        id = NODE_ID,
        role = ROLE,
        apps = apps,
        results = results,
        output = fleetos.getOutput(150),
    })

    local resp = http.post(BASE_URL .. "/report?node=" .. urlEncode(NODE_ID), body,
        authHeaders(BASE_URL, { ["Content-Type"] = "application/json" }))
    if resp then resp.close() end
end

print("[fleetbridge] '" .. NODE_ID .. "' polling " .. BASE_URL)

-- Otherwise this loop runs forever without printing anything once idle -
-- a periodic heartbeat means anyone watching this computer's terminal (or
-- the dashboard's Terminal panel) can tell it's still alive, not stuck.
local HEARTBEAT_EVERY = math.ceil(30 / POLL_INTERVAL)
local ticksSinceHeartbeat = 0

while true do
    local commands = poll()
    local results = {}

    for _, cmd in ipairs(commands) do
        local result = runCommand(cmd)
        results[#results + 1] = { command = cmd, result = result }
        print(("[fleetbridge] %s %s -> %s"):format(
            cmd.type, cmd.app or cmd.path or "", result.ok and "ok" or (result.error or result.err or "?")))
        ticksSinceHeartbeat = 0
    end

    report(results)

    ticksSinceHeartbeat = ticksSinceHeartbeat + 1
    if ticksSinceHeartbeat >= HEARTBEAT_EVERY then
        print("[fleetbridge] '" .. NODE_ID .. "' still polling")
        ticksSinceHeartbeat = 0
    end

    os.sleep(POLL_INTERVAL)
end
