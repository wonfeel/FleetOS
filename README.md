# FleetOS Remote Terminal (dashboard)

Static frontend for controlling a [FleetOS](https://github.com/wonfeel) Minecraft
CC:Tweaked fleet from a browser. This is just the UI - it always talks to
`bridge_server.py` running on your own PC, which in turn polls the in-game
master computer over HTTP.

## Using this hosted copy

1. Start `bridge_server.py` on your PC (it listens on `127.0.0.1:8787` by default).
2. Open this page in a browser **on that same PC**.
3. If the address shown in "Bridge address" isn't `http://127.0.0.1:8787`, fix it there and
   click "Save & reload".

That's it - no build step, no server-side code here, just static HTML/JS.

## Why "same PC" matters

This page is served over HTTPS (GitHub Pages), but the bridge only speaks plain HTTP.
Browsers make an exception for `127.0.0.1`/`localhost` (so step 2 above works), but they
block plain-HTTP requests to any other address from an HTTPS page. So opening this page on
a *different* machine than the one running `bridge_server.py` (e.g. pointing "Bridge address"
at a Radmin VPN IP) will be blocked by the browser unless you manually allow insecure content
for this site.

## No authentication

`bridge_server.py` has no login of its own - anyone who can reach it can run code and
read/write files on your in-game computer through it. Keep it bound to `127.0.0.1` (the
default) unless you know what you're doing.

## Source

The full FleetOS project (kernel, in-game apps, bridge server, this dashboard) lives in a
separate local project - this repo only publishes the static dashboard file.
