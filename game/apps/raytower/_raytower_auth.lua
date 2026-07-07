-- keyed message authentication + replay protection for raytower's
-- rednet traffic, which previously went out as plain
-- rednet.broadcast/send with zero signing - any player with a modem in
-- range could forge a fake tower report (spoofing the solved position) or
-- send bogus "poll" messages.
--
-- HONEST SCOPE NOTE: this is NOT HMAC-SHA256/a cryptographically
-- collision-resistant MAC - CC:Tweaked's Lua (Cobalt, Lua 5.1 semantics)
-- has no bitwise operators or bit32 library to build a real SHA-2 on top
-- of without pulling in a large third-party pure-Lua crypto library.
-- Instead this implements a keyed FNV-1a-based MAC (bxor emulated via pure
-- arithmetic - +,-,*,/,%, no bit library needed) plus a timestamp freshness
-- window. This stops a CASUAL spoofer (a player who doesn't know the shared
-- secret trying to inject/replay packets) - it is NOT proof against a
-- determined cryptanalytic attacker. If raytowerSecret is left unset, this
-- silently no-ops back to the historical unsigned behavior (documented,
-- backward compatible - existing fleets aren't broken by upgrading).

local M = {}

-- Pure-arithmetic 32-bit XOR (no bit32/bit library assumed - see header).
-- Classic bit-by-bit technique: peel off each operand's low bit via % 2,
-- compare, accumulate into the result at the current power-of-two place.
local function bxor32(a, b)
    local result, bitval = 0, 1
    a = a % 4294967296
    b = b % 4294967296
    while a > 0 or b > 0 do
        local abit, bbit = a % 2, b % 2
        if abit ~= bbit then result = result + bitval end
        a = (a - abit) / 2
        b = (b - bbit) / 2
        bitval = bitval * 2
    end
    return result
end

local FNV_PRIME = 16777619
local FNV_OFFSET = 2166136261

-- 32-bit FNV-1a over a string - fast, simple, well-distributed, but NOT
-- cryptographically secure (no claim otherwise - see header).
local function fnv1a(str)
    local hash = FNV_OFFSET
    for i = 1, #str do
        hash = bxor32(hash, str:byte(i))
        hash = (hash * FNV_PRIME) % 4294967296
    end
    return hash
end

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

-- Keyed MAC: two rounds of FNV-1a with the secret mixed in on both sides of
-- each round (secret-prefix AND suffix, not just prefix) - cheap insurance
-- against the kind of length-extension weakness a single prefix-only MAC
-- over a Merkle-Damgard-style hash could have (FNV isn't Merkle-Damgard, so
-- this mostly isn't applicable here, but doubling the mixing costs nothing).
local function mac(secret, message)
    local round1 = fnv1a(secret .. "\0" .. message .. "\0" .. secret)
    local round2 = fnv1a(secret .. "\0" .. tostring(round1) .. "\0" .. message)
    return ("%08x%08x"):format(round1, round2)
end

-- Exposed mainly for test/test_raytower_auth.lua to construct exact
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
-- is "" (unset), always returns true (auth off) - a node with no secret
-- configured behaves exactly as before this existed, so upgrading
-- raytower_master.lua/raytower_slave.lua alone doesn't break a fleet that
-- hasn't set raytowerSecret in config.lua yet.
function M.verify(payload, secret)
    if secret == "" then return true end
    if type(payload) ~= "table" or type(payload.mac) ~= "string" or type(payload.ts) ~= "number" then
        return false, "missing mac/ts (sender has no raytowerSecret configured, or a forged/malformed packet)"
    end
    local receivedMac = payload.mac
    local copy = {}
    for k, v in pairs(payload) do
        if k ~= "mac" then copy[k] = v end
    end
    local expected = mac(secret, canonicalize(copy))
    if expected ~= receivedMac then
        return false, "signature mismatch (wrong/missing raytowerSecret, or a forged packet)"
    end
    local now = os.epoch("utc")
    if math.abs(now - payload.ts) > M.REPLAY_WINDOW_MS then
        return false, "stale timestamp (likely a replayed old packet)"
    end
    return true
end

return M
