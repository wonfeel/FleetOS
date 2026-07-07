# Gateway cluster architecture (design doc, not implemented)

Status: **design only**. Fixing "the bridge is a single point of failure"
properly is a genuinely separate, multi-week project, not something to bolt
onto the existing single-bridge architecture in a single pass. State
persistence + graceful shutdown already make a restart fast and lossless,
which covers the *recovery* half of that risk - this document is about the
other half, actual *failover* (the bridge process itself, or the one PC it
runs on, being unavailable for an extended period). Recorded here so this
architecturally significant idea isn't lost, and so a future implementer
has a concrete starting point instead of a blank page.

## The problem, precisely

Every node talks to exactly ONE `bridge_server.py` process over HTTP. If
that process (or the PC it runs on) is down, EVERY node in the fleet is
unreachable from the dashboard for the duration - there is no fallback path,
even between two nodes sitting next to each other in the same world, which
absolutely could talk to each other directly via rednet if anything told
them to.

## Proposed shape

**Gateway nodes** (2-5 trusted computers) run a new `fleetgateway.lua`
instead of `fleetbridge.lua`. Exactly ONE gateway is "leader" at a time -
only the leader polls the real `bridge_server.py` over HTTP; every other
gateway sits idle, watching for the leader to disappear.

**Regular nodes** keep running (a modified) `fleetbridge.lua`, but instead
of HTTP to `bridge_server.py` directly, they poll/report to **whichever
gateway is currently leader**, over rednet (no HTTP dependency for regular
nodes at all - only gateways need one).

```
dashboard.html  <--HTTP-->  bridge_server.py  <--HTTP-->  [leader gateway]
                                                                 ^
                                                        rednet   | rednet
                                                    (leader election +
                                                     heartbeats between
                                                     gateways)
                                                                 v
                                                   [other gateways, idle]
                                                                 ^
                                                          rednet | (poll/report)
                                                                 v
                                                        [regular nodes]
```

If the leader gateway goes down (or loses its own HTTP path to
`bridge_server.py`), the remaining gateways detect the missing heartbeat and
elect a new leader within a few seconds - regular nodes don't need to know
or care which gateway is leader; they just always contact "the current
leader" (see "Discovery" below).

**This does NOT remove `bridge_server.py` as a single point of failure
entirely** - the PC-side bridge is still one process. What it DOES fix: a
regular node losing its OWN HTTP path (e.g. a bad `computercraft-server.toml`
rule, a temporary network blip between that one computer and the PC) no
longer isolates just that node, since it was never talking to the PC
directly - and it reduces `bridge_server.py`'s own HTTP load from
O(all nodes) to O(number of gateways), addressing both the TPS/server-load
concern and the availability concern at once. A TRUE fix for the PC-side
single point of failure would need multiple `bridge_server.py` instances
with their own leader election and shared/replicated state - a further,
separate project on top of this one, not covered here.

## Leader election (Bully algorithm)

Simple, well-understood, easy to reason about with a small (2-5) fixed set
of gateways:

1. Every gateway has a static priority (e.g. its computer ID - lowest wins,
   arbitrary but must be a total order every gateway agrees on without
   needing to ask anyone).
2. Each gateway periodically (every ~2s) broadcasts a signed heartbeat
   `{type="heartbeat", id=<computer id>, isLeader=<bool>}` on a dedicated
   rednet protocol (e.g. `"fleetgateway"`).
3. A gateway that hasn't heard a heartbeat from a HIGHER-priority gateway
   within `ELECTION_TIMEOUT` (~3 heartbeat intervals, to tolerate one missed
   beat) declares itself leader and starts announcing `isLeader=true`.
4. If a gateway ever hears a heartbeat from a higher-priority gateway while
   believing itself leader, it immediately steps down - avoids two gateways
   both believing they're leader (a "split brain") for longer than one
   heartbeat interval.
5. Only the leader actually opens an HTTP connection to `bridge_server.py`;
   every other gateway's `fleetgateway.lua` sits in the election loop only.

This converges in roughly `ELECTION_TIMEOUT` seconds after a leader
disappears - a 2-3 second target with a ~1s heartbeat interval and a
3-beat timeout.

## Discovery (how a regular node finds "the current leader")

Regular nodes don't run their own election logic - they just
`rednet.broadcast` their poll/report and let whichever gateway is
CURRENTLY leader answer (a non-leader gateway simply ignores node
poll/report messages entirely). This means a regular node's `fleetbridge.lua`
needs no leader-tracking state of its own - it always broadcasts, and
whichever gateway happens to be leader at that moment responds. Simpler
than having nodes track "who's leader" themselves, at the cost of every
poll being a broadcast instead of a targeted send (acceptable - rednet
broadcasts are cheap compared to the HTTP round-trips this design removes).

## Security: signed rednet, fleet-wide

Every message on the `"fleetgateway"` protocol (heartbeats, node
poll/report relayed over rednet) MUST be signed with a shared secret, same
principle as Raytower's rednet signing - `apps/raytower/_raytower_auth.lua`'s
keyed-MAC-plus-timestamp approach is directly reusable here (it's already a
standalone module with no Raytower-specific dependencies despite living
under `apps/raytower/` for historical reasons - it would want moving to a
shared location, e.g. `apps/common/_signed_rednet.lua`, if adopted by a
second feature). Without this, any player with a modem in range could
forge a fake heartbeat and hijack leader status, or inject fake
poll/report traffic for a node they don't own.

## Migration path (how to get from today's architecture to this one)

1. Ship `_signed_rednet.lua` as a shared module (promoted out of
   `apps/raytower/`), existing code reusing it instead of its own copy.
2. Ship `fleetgateway.lua` as a NEW, opt-in app - a fleet that doesn't
   install it on any node is completely unaffected, keeps working exactly
   as today (every node still talks to `bridge_server.py` directly). This
   is important: the migration must be incremental, not a flag day.
3. Modify `fleetbridge.lua` to prefer rednet-to-a-gateway over HTTP-to-
   `bridge_server.py` IF AND ONLY IF a modem is present AND at least one
   gateway heartbeat has been heard recently - falls back to today's direct-
   HTTP behavior otherwise (mirrors how `raytower_master.lua`'s
   `solveViaBridge` already falls back to local solving on any failure -
   same "never make the no-extra-infrastructure case worse" principle).
4. `bridge_server.py` itself needs NO changes for a single-gateway-cluster
   deployment - it already just sees fewer, more consolidated HTTP clients
   (the elected leader gateway instead of every node individually).

## Open questions for whoever implements this

- **What happens to results/command IDs during a leader handover?** A
  command mid-flight through the old leader when it steps down needs to
  either complete there first or be safely retriable through the new leader
  - likely reuses the exact `inflight`/requeue mechanism `bridge_server.py`
  already has, just one more hop removed from the dashboard.
- **Should `bridge_server.py` know it's talking to a gateway vs. a plain
  node?** Probably not necessary - from the bridge's perspective, a gateway
  polling on behalf of N nodes could just look like N individual `/report`
  calls relayed through one HTTP client, keeping `bridge_server.py` itself
  unaware of the cluster topology entirely.
- **Gateway hardware requirements**: needs a modem (obviously) and enough
  uptime/reliability to be trusted as a leader candidate - likely wants to
  be a physically protected/admin-only computer, since a compromised
  gateway is a much bigger blast radius than a compromised regular node.
