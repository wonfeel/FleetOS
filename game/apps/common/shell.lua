-- Interactive console app: lets you spawn/kill/list apps by typing,
-- using the kernel API exposed as _G.fleetos by fleetos.lua.
-- Add "shell" to config.lua's startup list to get this.
--
-- Commands: list | run <app> | kill <app> | minimize <app> | restore <app> | status | apps | bridge [<url> [key] | clear] | clear | help | exit

local STATUS_COLOR = {
    running = colors.lime,
    suspended = colors.yellow,
    dead = colors.red,
}

local function colorLine(text, color)
    term.setTextColor(color)
    print(text)
    term.setTextColor(colors.white)
end

local function printList()
    for _, t in ipairs(fleetos.list()) do
        term.write(("  %-16s "):format(t.name))
        term.setTextColor(STATUS_COLOR[t.status] or colors.white)
        print(t.status)
        term.setTextColor(colors.white)
    end
end

-- Strips non-printable/control characters (e.g. a stray Ctrl+T landing in
-- the input buffer) so they don't show up as a confusing garbled
-- "unknown command" - they're just silently dropped from the line.
local function sanitize(line)
    return (line:gsub("[%c]", ""))
end

print("[shell] type 'help' for commands")

if _G.CRAFTOS_EMULATION then
    -- Only relevant to windows/craftos_shim.lua's read() (a plain blocking
    -- io.read(), unlike real CraftOS) - see its comment for the full
    -- explanation. Doesn't apply in real Minecraft, so only warn here.
    term.setTextColor(colors.yellow)
    print("[shell] NOTE: this is the Windows emulation - other tasks (fleetbridge,")
    print("  monitor mirror) are paused while this prompt waits for input. Type")
    print("  'exit' when done, or instead run this from your PC, which never")
    print("  blocks anything on this node: python windows\\fleetctl.py shell <node-id>")
    term.setTextColor(colors.white)
end

while true do
    io.write("shell> ")
    io.flush()
    local rawLine = read()
    if not rawLine then break end
    local line = sanitize(rawLine)

    local parts = {}
    for w in line:gmatch("%S+") do parts[#parts + 1] = w end
    local cmd = parts[1]

    if cmd == "list" then
        printList()

    elseif cmd == "status" then
        print(("%d task(s) running:"):format(#fleetos.list()))
        printList()

    elseif cmd == "run" then
        if not parts[2] then
            print("Usage: run <app>")
        else
            local ok, err = fleetos.spawn(parts[2])
            if ok then
                colorLine("started " .. parts[2], colors.lime)
            else
                colorLine("error: " .. tostring(err), colors.red)
            end
        end

    elseif cmd == "kill" then
        if not parts[2] then
            print("Usage: kill <app>")
        elseif parts[2] == fleetos.current() then
            colorLine("can't kill the shell from itself - type 'exit' instead", colors.red)
        else
            local ok, err = fleetos.kill(parts[2])
            if ok then
                colorLine("stopped " .. parts[2], colors.yellow)
            else
                colorLine("error: " .. tostring(err), colors.red)
            end
        end

    elseif cmd == "minimize" then
        if not parts[2] then
            print("Usage: minimize <app>")
        else
            local ok, err = fleetos.minimize(parts[2])
            if ok then
                colorLine("minimized " .. parts[2], colors.lightGray)
            else
                colorLine("error: " .. tostring(err), colors.red)
            end
        end

    elseif cmd == "restore" then
        if not parts[2] then
            print("Usage: restore <app>")
        else
            local ok, err = fleetos.restore(parts[2])
            if ok then
                colorLine("restored " .. parts[2], colors.lime)
            else
                colorLine("error: " .. tostring(err), colors.red)
            end
        end

    elseif cmd == "apps" then
        for _, g in ipairs(fleetos.listAvailableApps()) do
            print("  [" .. g.name .. "] " .. table.concat(g.apps, ", "))
        end

    elseif cmd == "bridge" then
        -- Delegates to fleetos.lua's setBridge/clearBridge/getBridgeInfo -
        -- same functions the kernel's own "type"-command interpreter uses,
        -- so the file I/O and restart logic live in exactly one place.
        if parts[2] == "clear" then
            local _, restarted = fleetos.clearBridge()
            colorLine("bridge override cleared - back to config.lua's bridgeUrl/apiKey", colors.lightGray)
            if restarted then colorLine("fleetbridge restarted", colors.lime) end

        elseif not parts[2] then
            local info = fleetos.getBridgeInfo()
            if info then
                print("bridge override: " .. tostring(info.url)
                    .. ((info.key and info.key ~= "") and " (key set)" or " (no key)"))
            else
                print("no bridge override set - using config.lua's bridgeUrl/apiKey (if any)")
            end
            print("Usage: bridge <url> [key]  |  bridge clear")

        else
            local _, restarted = fleetos.setBridge(parts[2], parts[3])
            colorLine("bridge set to " .. parts[2] .. ((parts[3] and parts[3] ~= "") and " (with key)" or ""), colors.lime)
            if restarted then
                colorLine("fleetbridge restarted with new settings", colors.lime)
            else
                print("fleetbridge isn't running - start it with 'run fleetbridge'")
            end
        end

    elseif cmd == "clear" then
        term.clear()
        term.setCursorPos(1, 1)

    elseif cmd == "help" then
        print("  list                   list every task and its status (running/suspended/dead)")
        print("  status                 same as 'list', with a task count above it")
        print("  run <app>              start an app from apps/ (see 'apps' for what's available)")
        print("  kill <app>             stop a running app (can't kill the shell itself)")
        print("  minimize <app>         hide an app's window without stopping it")
        print("  restore <app>          bring a minimized app's window back")
        print("  apps                   list every app available to 'run', grouped by folder")
        print("  bridge                 show the bridge address/key currently in effect")
        print("  bridge <url> [key]     point this computer at a different bridge, no reboot needed")
        print("  bridge clear           go back to whatever config.lua says (undoes the above)")
        print("  clear                  clear this screen")
        print("  exit                   leave the shell (other tasks keep running)")
        print("Anything else is tried as a real CraftOS program, e.g. 'ls', 'reboot', 'fleetos'.")

    elseif cmd == "exit" then
        print("[shell] exiting (kernel keeps running - Ctrl+C to fully stop)")
        break

    elseif cmd then
        print("unknown command: " .. cmd .. " (try 'help')")
    end
end
