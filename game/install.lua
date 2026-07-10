-- install.lua
-- One-time bootstrap loader for a FRESH CC:Tweaked computer with nothing
-- installed yet. Fetches fleetos.lua and the bare minimum apps
-- (shell/fleetbridge) from your bridge_server.py, writes a starter
-- config.lua (unless one already exists), then boots straight into
-- fleetos. This is the ONLY file you need to get onto a new computer by
-- hand - everything else it fetches for itself:
--
--   wget http://<bridge-host>:8787/install.lua install.lua
--   install http://<bridge-host>:8787      -- omit the URL to default to
--                                              http://127.0.0.1:8787
--   install http://<bridge-host>:8787 <api-key>   -- only if bridge_server.py
--                                                     was started with
--                                                     FLEET_BRIDGE_KEY set
--
-- Safe to re-run later (e.g. after wiping apps/ by hand) - it won't
-- touch an existing config.lua, so a real deployment's id/role/startup
-- survive.

local bridgeUrl, apiKey = ...
bridgeUrl = bridgeUrl or "http://127.0.0.1:8787"
apiKey = apiKey or ""

if not http then
    print("[install] HTTP API is disabled on this computer - can't bootstrap")
    return
end

local function authHeaders()
    return apiKey ~= "" and { ["X-API-Key"] = apiKey } or nil
end

local HTTP_TIMEOUT = 8 -- seconds - see apps/common/fleetbridge.lua's httpRequest for why

-- Async form + manual timer, same reasoning as apps/common/fleetbridge.lua:
-- http.get blocks with no per-call timeout, so a bridge that never
-- responds would otherwise hang this one-shot bootstrap indefinitely.
local function fetch(path)
    local url = bridgeUrl .. path
    http.request({ url = url, headers = authHeaders(), timeout = HTTP_TIMEOUT })
    local timerId = os.startTimer(HTTP_TIMEOUT)
    local resp, err
    while true do
        local event, a, b = os.pullEvent()
        if event == "http_success" and a == url then
            os.cancelTimer(timerId)
            resp = b
            break
        elseif event == "http_failure" and a == url then
            os.cancelTimer(timerId)
            err = b
            break
        elseif event == "timer" and a == timerId then
            err = "timed out after " .. HTTP_TIMEOUT .. "s"
            break
        end
    end
    if not resp then
        print("[install] failed to fetch " .. path .. ": " .. tostring(err))
        return nil
    end
    local body = resp.readAll()
    resp.close()
    return body
end

local function writeFile(path, content)
    local dir = path:match("^(.*)/[^/]+$")
    if dir and not fs.exists(dir) then fs.makeDir(dir) end
    local f = fs.open(path, "w")
    f.write(content)
    f.close()
end

print("[install] bootstrapping from " .. bridgeUrl .. " ...")

local kernel = fetch("/fleetos.lua")
if not kernel then
    print("[install] aborted - is bridge_server.py running and reachable at " .. bridgeUrl .. "?")
    return
end
writeFile("fleetos.lua", kernel)
print("[install] fetched fleetos.lua")

local BASE_APPS = { "shell", "fleetbridge" }
for _, name in ipairs(BASE_APPS) do
    local code = fetch("/apps/" .. name .. ".lua")
    if not code then
        print("[install] aborted")
        return
    end
    writeFile("apps/" .. name .. ".lua", code)
    print("[install] fetched apps/" .. name .. ".lua")
end

if fs.exists("config.lua") then
    print("[install] config.lua already exists - leaving it as is")
else
    local id = "node_" .. os.getComputerID()
    local apiKeyLine = apiKey ~= "" and ("    apiKey = %q,\n"):format(apiKey) or ""
    writeFile("config.lua", ([[
-- edit freely, or via the dashboard's Remote files panel (path: config.lua)
return {
    id = %q,
    role = "generic",
    startup = { "shell", "fleetbridge" },
    bridgeUrl = %q,
%s}
]]):format(id, bridgeUrl, apiKeyLine))
    print("[install] wrote config.lua (id=" .. id .. ") - edit id/role/startup via the dashboard any time")
end

-- so a reboot (e.g. from the dashboard's "update" command, or the player
-- just restarting the computer) relaunches fleetos on its own
if not fs.exists("startup.lua") then
    writeFile("startup.lua", 'shell.run("fleetos")\n')
    print("[install] wrote startup.lua - fleetos now starts automatically on reboot")
end

print("[install] done - starting fleetos")
shell.run("fleetos")
