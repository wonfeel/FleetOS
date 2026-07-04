-- Interactive console app: lets you spawn/kill/list apps by typing,
-- using the kernel API exposed as _G.fleetos by fleetos.lua.
-- Add "shell" to config.lua's startup list to get this.
--
-- Commands: list | run <app> | kill <app> | minimize <app> | restore <app> | status | apps | clear | help | exit

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

    elseif cmd == "clear" then
        term.clear()
        term.setCursorPos(1, 1)

    elseif cmd == "help" then
        print("list | run <app> | kill <app> | minimize <app> | restore <app> | status | apps | clear | exit")

    elseif cmd == "exit" then
        print("[shell] exiting (kernel keeps running - Ctrl+C to fully stop)")
        break

    elseif cmd then
        print("unknown command: " .. cmd .. " (try 'help')")
    end
end
