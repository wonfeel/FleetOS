# Writing a FleetOS app

A developer-facing guide for building a new app under this kernel - "I want
to write my own app, what do I need to know." For end-user/operational docs
(installing, the dashboard, the bridge, the API key), see
`docs/fleetos_guide.html`/`docs/quickstart.html` instead - this file is for
*writing code*, not *running the fleet*.

## What an app actually is

A plain Lua file under `apps/<group>/<name>.lua` (or flat `apps/<name>.lua`
for anything not obviously `common`/`raytower`) containing top-level code -
**not** a function you export, not a module you `require`. `fleetos.spawn(name)`
`loadfile()`s it fresh and runs the whole thing as its own coroutine:

```lua
-- apps/common/hello.lua
print("[hello] starting up")
while true do
    print("[hello] tick")
    os.sleep(5)
end
```

Add `"hello"` to `config.lua`'s `startup` list (or `run hello` at a shell)
and it's a real background task, listed in `fleetos.list()`, killable,
minimizable, everything the built-in apps (`clock`, `fleetbridge`) get.

## The rules every app must follow

- **Yield regularly** (`os.sleep`, `os.pullEvent`) - this is cooperative
  multitasking, not preemptive. A `while true do end` with no yield at all
  freezes every other task, including `fleetbridge` (the node goes silent to
  the bridge) - the kernel's instruction-budget watchdog will eventually
  kill a genuinely runaway app like this, but don't rely on that as your
  timing model; yield on purpose.
- **`print()`/`write()` are already captured** - they show up in the
  dashboard's Terminal panel and any attached monitor automatically (see
  `fleetos.lua`'s "Output capture" section). Don't build a separate
  "send this to the dashboard" mechanism.
- **A leading underscore in a filename means "shared helper module, not a
  runnable app"** - `dofile()`'d directly by whatever needs it (see
  `apps/common/_signed_rednet.lua` for a real example), excluded from
  `fleetos.listAvailableApps()`'s listing. Use this for code shared between
  two or more apps instead of copy-pasting it.

## The kernel API (`_G.fleetos`)

Everything a spawned app can call - see `fleetos.lua`'s own comments next to
each for the full detail, this is just the map:

| Function | What it's for |
|---|---|
| `spawn(name)` / `kill(name)` / `list()` | manage other tasks |
| `minimize(name)` / `restore(name)` | Windows-style display flag, doesn't pause anything |
| `claimMonitor()` / `releaseMonitor()` / `forceReleaseMonitor()` | take over the monitor peripheral for your own drawing |
| `getOutput(n)` / `getColoredOutput(n)` | read recent output (yours or another app's) |
| `getMonitorSnapshot()` | read whatever's currently drawn on the monitor |
| `touchMonitor(x, y)` | simulate a tap - same hit-testing a real finger tap goes through |
| `appPath(name)` / `listAvailableApps()` | resolve/enumerate apps on disk |
| `appVersion(name)` | short content checksum - "is this the same code as elsewhere in the fleet?" |
| `setBridge(url, key)` / `clearBridge()` / `getBridgeInfo()` | change what `fleetbridge` talks to |
| `setStartup(list)` / `clearStartup()` / `getStartupOverride()` | change the startup app list (takes effect next boot) |
| `runShellLine(text)` | run a line as if typed at a real shell prompt |
| `setShared(key, val)` / `getShared(key)` | shared key-value store between apps |
| `publish(topic, data)` | broadcast an event any app can `os.pullEvent("fleetos_message")` for - real in-game, a safe no-op under local testing (see below) |

## Talking to other apps

Two deliberately simple primitives, not a full message bus:

```lua
-- app A: publish "something happened"
fleetos.publish("position_updated", { x = 12, y = 64, z = -8 })

-- app B: react to it
while true do
    local _, topic, data, sender = os.pullEvent("fleetos_message")
    if topic == "position_updated" then
        print("got a position from " .. sender .. ": " .. data.x)
    end
end
```

```lua
-- "current state of X" instead of "something just happened" - use the
-- shared store: last writer wins, no event needed to read it.
fleetos.setShared("last_known_position", { x = 12, y = 64, z = -8 })
local pos = fleetos.getShared("last_known_position") -- from any other app
```

`publish()`'s underlying `os.queueEvent` only exists in real CC:Tweaked -
neither `test/cc_mocks.lua` nor `windows/craftos_shim.lua` implement one
(there's no local event queue to broadcast into), so it silently no-ops
outside the game. Test the `setShared`/`getShared` half of your app's IPC
locally; test the `publish`/subscribe half in-game.

## Testing locally without Minecraft

The short version for a NEW app:

```lua
-- test/test_hello.lua
dofile("../test/cc_mocks.lua")
local mainCo = coroutine.create(function() dofile("fleetos.lua") end)
coroutine.resume(mainCo) -- boots the kernel
fleetos.spawn("hello")
coroutine.resume(mainCo, "fleetos_tick") -- pumps one tick
-- ...assert on fleetos.list()/fleetos.getOutput()/whatever your app touched
```

Run with `cd game && lua ../test/test_hello.lua`. If your app needs a
peripheral this project doesn't emulate yet (`windows/craftos_shim.lua`
currently has `modem`/`monitor`/`drive`/`printer`), you'll only be able to
test it fully in-game - see that file's `peripheral.find` section if you
want to add a new fake peripheral yourself.
