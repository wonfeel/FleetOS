-- keyed message authentication + replay protection for rednet traffic.
-- Originally built for apps/raytower/*.lua's rednet.broadcast/send (which
-- previously went out unsigned - any player with a modem in range could
-- forge a fake tower report or send bogus "poll" messages), then promoted
-- here (no raytower-specific dependencies) once a second feature
-- (apps/common/fleetgateway.lua's leader-election + relay traffic) needed
-- the exact same thing.
--
-- This is a real HMAC-SHA256 (apps/common/_sha256.lua), not a home-grown
-- MAC - an earlier version of this file used a keyed FNV-1a construction
-- instead, on the belief that CC:Tweaked's Lua had no bitwise operators or
-- bit32 library to build real SHA-2 on top of. That belief was wrong: CC:
-- Tweaked's bios.lua exposes a `bit` global (band/bor/bxor/bnot/blshift/
-- blogic_rshift) for exactly this kind of thing, confirmed directly against
-- the current cc-tweaked/CC-Tweaked source. See _sha256.lua's own header
-- for the verification/test-vector details. If the caller's secret is left
-- unset (""), this silently no-ops back to unsigned behavior (documented,
-- backward compatible - existing fleets aren't broken by upgrading).

local M = {}

-- Same "apps/common/<name>.lua" path convention every caller already uses
-- to dofile() THIS file, since _sha256.lua lives right next to it.
local Sha256 = dofile("apps/common/_sha256.lua")

-- Bug fix: this used to hash textutils.serialize(payload) directly - but
-- Lua's pairs() iteration order for a table depends on its internal hash
-- bucket layout, which depends on how the table was BUILT (insertion
-- history/resizing), not just which keys it holds. sign() hashes the
-- ORIGINAL payload table; verify() hashes a freshly-built `copy` table with
-- the same keys/values reinserted via a pairs() loop - two DIFFERENT
-- construction paths that CAN (and, confirmed live via 5 repeated test
-- runs, intermittently DID - roughly 1 run in 5) produce different
-- serialize() key orderings for logically-identical data, making a
-- perfectly valid signature randomly fail verification. Real rednet
-- traffic has the exact same exposure: the receiver's payload is a freshly
-- deserialized table, never the sender's original one.
-- Fix: hash a CANONICAL string that sorts keys at every table level, so the
-- result only ever depends on the data itself, never on how a particular
-- table happened to get built.
local function canonicalize(value)
    local t = type(value)
    if t == "table" then
        local keys = {}
        for k in pairs(value) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        local parts = {}
        for _, k in ipairs(keys) do
            parts[#parts + 1] = tostring(k) .. "=" .. canonicalize(value[k])
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return tostring(value)
end

-- Real HMAC-SHA256 (RFC 2104), via apps/common/_sha256.lua.
local function mac(secret, message)
    return Sha256.hmacSha256(secret, message)
end

-- Exposed mainly for test/test_signed_rednet.lua to construct exact
-- scenarios (e.g. a validly-signed-but-stale packet) that M.sign()'s
-- always-use-current-time behavior can't produce directly. Not a security
-- concern to expose - knowing the hash function doesn't help forge a MAC
-- without the secret, same as HMAC's algorithm being public knowledge.
M.mac = mac
M.canonicalize = canonicalize

M.REPLAY_WINDOW_MS = 5000 -- generous vs. rednet's real-world latency jitter, tight enough to reject a captured-and-replayed old packet

-- Signs `payload` (a plain table) in place: stamps payload.ts, computes the
-- MAC over everything else, sets payload.mac. If `secret` is "" (unset),
-- returns payload completely untouched (auth off, matches previous behavior).
function M.sign(payload, secret)
    if secret == "" then return payload end
    payload.ts = os.epoch("utc")
    payload.mac = mac(secret, canonicalize(payload))
    return payload
end

-- Verifies a received payload. Returns true, or false+reason. If `secret`
-- is "" (unset), always returns true (auth off) - a caller with no secret
-- configured behaves exactly as before this existed, so upgrading one side
-- alone doesn't break a fleet that hasn't set a shared secret yet.
function M.verify(payload, secret)
    if secret == "" then return true end
    if type(payload) ~= "table" or type(payload.mac) ~= "string" or type(payload.ts) ~= "number" then
        return false, "missing mac/ts (sender has no shared secret configured, or a forged/malformed packet)"
    end
    local receivedMac = payload.mac
    local copy = {}
    for k, v in pairs(payload) do
        if k ~= "mac" then copy[k] = v end
    end
    local expected = mac(secret, canonicalize(copy))
    if expected ~= receivedMac then
        return false, "signature mismatch (wrong/missing shared secret, or a forged packet)"
    end
    local now = os.epoch("utc")
    if math.abs(now - payload.ts) > M.REPLAY_WINDOW_MS then
        return false, "stale timestamp (likely a replayed old packet)"
    end
    return true
end

return M
