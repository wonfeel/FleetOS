-- Unit tests for apps/common/_sha256.lua (SHA-256 + HMAC-SHA256, used by
-- apps/common/_signed_rednet.lua for real cryptographic signing). Run with
-- (cwd must be game/):
--   cd game
--   lua ../test/test_sha256.lua
--
-- Test vectors are from FIPS 180-4/NIST (plain SHA-256) and RFC 4231
-- (HMAC-SHA256), plus a few chunk-boundary lengths cross-checked
-- independently against Python's hashlib, to make sure the 55/56/57-byte
-- padding boundary and multi-chunk (>64 byte) message handling are both
-- exercised, not just the single-chunk common case.

dofile("../test/cc_mocks.lua")

local Sha256 = dofile("apps/common/_sha256.lua")

local function assertEq(got, expected, msg)
    if got ~= expected then
        error("FAIL: " .. msg .. "\n  expected: " .. tostring(expected) .. "\n  got:      " .. tostring(got), 2)
    end
end

-- Test 1: NIST SHA-256 test vectors (empty string, "abc", the standard
-- two-block message).
do
    assertEq(Sha256.sha256(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "sha256('')")
    assertEq(Sha256.sha256("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "sha256('abc')")
    assertEq(Sha256.sha256("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
        "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1", "sha256(two-block test string)")
    print("Test 1: SHA-256 NIST test vectors - PASS")
end

-- Test 2: chunk-boundary lengths (55/56/57 bytes straddle the padding
-- cutoff; 64/65/1000 bytes exercise single-chunk-exactly, just-over, and
-- multi-chunk message handling) - independently cross-checked against
-- Python's hashlib.sha256, not hand-computed.
do
    assertEq(Sha256.sha256(("x"):rep(55)), "d5e285683cd4efc02d021a5c62014694958901005d6f71e89e0989fac77e4072", "55-byte boundary")
    assertEq(Sha256.sha256(("x"):rep(56)), "04c26261370ee7541549d16dee320c723e3fd14671e66a099afe0a377c16888e", "56-byte boundary")
    assertEq(Sha256.sha256(("x"):rep(57)), "ae14a2563ccf969d99aca69ce6bb74981f734bbf9f655f73b8f06db68cab5217", "57-byte boundary")
    assertEq(Sha256.sha256(("a"):rep(64)), "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb", "exactly one chunk")
    assertEq(Sha256.sha256(("a"):rep(65)), "635361c48bb9eab14198e76ea8ab7f1a41685d6ad62aa9146d301d4f17eb0ae0", "one chunk + 1 byte")
    assertEq(Sha256.sha256(("a"):rep(1000)), "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3", "multi-chunk (1000 bytes)")
    print("Test 2: SHA-256 chunk-boundary lengths - PASS")
end

-- Test 3: RFC 4231 HMAC-SHA256 test vectors, including a key SHORTER than
-- the 64-byte block size (Test Case 2, "Jefe") and a key LONGER than it
-- (Test Case 6/7, 131 bytes - exercises the "hash the key down first"
-- branch) - both code paths in hmacSha256 need their own coverage.
do
    local hexToStr = function(hex) return (hex:gsub("..", function(cc) return string.char(tonumber(cc, 16)) end)) end

    assertEq(Sha256.hmacSha256(hexToStr("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b"), "Hi There"),
        "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7", "RFC 4231 case 1")

    assertEq(Sha256.hmacSha256("Jefe", "what do ya want for nothing?"),
        "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843", "RFC 4231 case 2 (key shorter than block)")

    assertEq(Sha256.hmacSha256(("\170"):rep(131), "Test Using Larger Than Block-Size Key - Hash Key First"),
        "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54", "RFC 4231 case 6 (key longer than block)")

    assertEq(Sha256.hmacSha256(("\170"):rep(131),
        "This is a test using a larger than block-size key and a larger than block-size data. The key needs to be hashed before being used by the HMAC algorithm."),
        "9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2", "RFC 4231 case 7 (key and data both longer than block)")

    print("Test 3: HMAC-SHA256 RFC 4231 test vectors - PASS")
end

-- Test 4: sha256raw()'s output, hex-encoded by hand, matches sha256()'s
-- own hex output - the two must never drift (hmacSha256 relies on
-- sha256raw internally, so a mismatch here would mean HMAC output is
-- silently wrong despite plain sha256() looking correct).
do
    local raw = Sha256.sha256raw("abc")
    local hex = {}
    for i = 1, #raw do hex[i] = ("%02x"):format(raw:byte(i)) end
    assertEq(table.concat(hex), Sha256.sha256("abc"), "sha256raw hex-encoded must match sha256()")
    print("Test 4: sha256raw/sha256 consistency - PASS")
end

print("\nAll sha256 tests passed.")
