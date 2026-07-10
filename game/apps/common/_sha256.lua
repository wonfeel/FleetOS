-- Pure-Lua SHA-256 + HMAC-SHA256, built ONLY on the `bit` global's
-- band/bor/bxor/bnot/blshift/blogic_rshift functions - the exact legacy
-- "bit" library shape CC:Tweaked's bios.lua exposes to every computer's
-- user scripts (built internally from bit32, but bit32 itself is NOT
-- exposed directly - only this `bit`-namespaced wrapper is). Confirmed
-- against the real cc-tweaked/CC-Tweaked bios.lua source, mc-1.20.x
-- branch, which still ships this exact stub for backward compatibility.
--
-- apps/common/_signed_rednet.lua previously assumed CC:Tweaked's Lua had
-- NO bitwise operators or bit32 at all, and used a keyed FNV-1a-based MAC
-- instead (explicitly NOT cryptographically secure, by its own header).
-- That assumption was wrong for current CC:Tweaked - this module exists so
-- _signed_rednet.lua can use a real HMAC-SHA256 instead. windows/
-- craftos_shim.lua and test/cc_mocks.lua both provide the same `bit` shim
-- (backed by real Lua 5.4 native bitwise operators there) so this file
-- behaves identically in-game, in the Windows emulation, and under tests.
--
-- Implementation follows FIPS 180-4 (SHA-256) / RFC 2104 (HMAC) directly.
-- Verified against NIST/RFC test vectors (empty string, "abc", the
-- standard two-block test string, several chunk-boundary lengths, and all
-- of RFC 4231's HMAC-SHA256 test cases including keys both shorter and
-- longer than the 64-byte block size) - see test/test_sha256.lua.

local band, bor, bxor, bnot, blshift, blogic_rshift =
    bit.band, bit.bor, bit.bxor, bit.bnot, bit.blshift, bit.blogic_rshift

local function rrotate(x, n)
    return bor(blogic_rshift(x, n), blshift(x, 32 - n)) % 4294967296
end

-- The 64 round constants (first 32 bits of the fractional parts of the
-- cube roots of the first 64 primes) - fixed by the spec, not a secret.
local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

-- Initial hash values (first 32 bits of the fractional parts of the square
-- roots of the first 8 primes) - also fixed by the spec.
local H0 = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }

-- Returns the raw 32-byte digest (not hex) - HMAC needs this to feed one
-- hash's output into another without a wasteful hex round-trip.
local function sha256raw(msg)
    local bitLen = #msg * 8
    msg = msg .. "\128"
    while (#msg % 64) ~= 56 do msg = msg .. "\0" end
    -- Append the original bit-length as a 64-bit big-endian integer. A
    -- message long enough for bitLen to exceed Lua's safe double-precision
    -- integer range (2^53 bits, i.e. exabytes of input) isn't a realistic
    -- case for anything this project signs, so plain arithmetic (no 64-bit
    -- bit ops needed) is fine here.
    local hi = math.floor(bitLen / 4294967296) % 4294967296
    local lo = bitLen % 4294967296
    for _, w in ipairs({ hi, lo }) do
        local b4 = w % 256; w = math.floor(w / 256)
        local b3 = w % 256; w = math.floor(w / 256)
        local b2 = w % 256; w = math.floor(w / 256)
        local b1 = w % 256
        msg = msg .. string.char(b1, b2, b3, b4)
    end

    local h = {}
    for i = 1, 8 do h[i] = H0[i] end

    for chunkStart = 1, #msg, 64 do
        local w = {}
        for i = 0, 15 do
            local o = chunkStart + i * 4
            local b1, b2, b3, b4 = msg:byte(o, o + 3)
            w[i] = ((b1 * 256 + b2) * 256 + b3) * 256 + b4
        end
        for i = 16, 63 do
            local s0 = bxor(bxor(rrotate(w[i - 15], 7), rrotate(w[i - 15], 18)), blogic_rshift(w[i - 15], 3))
            local s1 = bxor(bxor(rrotate(w[i - 2], 17), rrotate(w[i - 2], 19)), blogic_rshift(w[i - 2], 10))
            w[i] = (w[i - 16] + s0 + w[i - 7] + s1) % 4294967296
        end

        local a, b, c, d, e, f, g, hh = h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]
        for i = 0, 63 do
            local S1 = bxor(bxor(rrotate(e, 6), rrotate(e, 11)), rrotate(e, 25))
            local ch = bxor(band(e, f), band(bnot(e), g))
            local temp1 = (hh + S1 + ch + K[i + 1] + w[i]) % 4294967296
            local S0 = bxor(bxor(rrotate(a, 2), rrotate(a, 13)), rrotate(a, 22))
            local maj = bxor(bxor(band(a, b), band(a, c)), band(b, c))
            local temp2 = (S0 + maj) % 4294967296
            hh = g; g = f; f = e; e = (d + temp1) % 4294967296
            d = c; c = b; b = a; a = (temp1 + temp2) % 4294967296
        end

        h[1] = (h[1] + a) % 4294967296
        h[2] = (h[2] + b) % 4294967296
        h[3] = (h[3] + c) % 4294967296
        h[4] = (h[4] + d) % 4294967296
        h[5] = (h[5] + e) % 4294967296
        h[6] = (h[6] + f) % 4294967296
        h[7] = (h[7] + g) % 4294967296
        h[8] = (h[8] + hh) % 4294967296
    end

    local out = {}
    for i = 1, 8 do
        local word = h[i]
        local b1 = math.floor(word / 16777216) % 256
        local b2 = math.floor(word / 65536) % 256
        local b3 = math.floor(word / 256) % 256
        local b4 = word % 256
        out[i] = string.char(b1, b2, b3, b4)
    end
    return table.concat(out)
end

local function toHex(raw)
    local out = {}
    for i = 1, #raw do out[i] = ("%02x"):format(raw:byte(i)) end
    return table.concat(out)
end

local function sha256(msg)
    return toHex(sha256raw(msg))
end

local BLOCK_SIZE = 64
local IPAD, OPAD = 0x36, 0x5c

-- Standard RFC 2104 HMAC construction: a key longer than the block size is
-- hashed down first, a shorter one is zero-padded up to it, then XORed
-- with the inner/outer pad constants before each hash round.
local function hmacSha256(key, message)
    if #key > BLOCK_SIZE then key = sha256raw(key) end
    key = key .. string.rep("\0", BLOCK_SIZE - #key)

    local ipadKey, opadKey = {}, {}
    for i = 1, BLOCK_SIZE do
        local kb = key:byte(i)
        ipadKey[i] = string.char(bxor(kb, IPAD))
        opadKey[i] = string.char(bxor(kb, OPAD))
    end
    ipadKey = table.concat(ipadKey)
    opadKey = table.concat(opadKey)

    local inner = sha256raw(ipadKey .. message)
    return toHex(sha256raw(opadKey .. inner))
end

return { sha256 = sha256, sha256raw = sha256raw, hmacSha256 = hmacSha256 }
