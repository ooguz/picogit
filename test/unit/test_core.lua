-- picogit.core basics: hex, SHA-1, randomness.
local core = require("picogit.core")
local T = {}

function T.hex_roundtrip(t)
  t.eq(core.tohex("\0\1\254\255"), "0001feff")
  t.eq(core.fromhex("0001FEff"), "\0\1\254\255")
  t.eq(core.fromhex("abc"), nil)
  t.eq(core.fromhex("zz"), nil)
end

function T.sha1_vectors(t)
  t.eq(core.tohex(core.sha1("")), "da39a3ee5e6b4b0d3255bfef95601890afd80709")
  t.eq(core.tohex(core.sha1("abc")), "a9993e364706816aba3e25717850c26c9cd0d89d")
  local c = core.sha1_new()
  c:update("a"):update("bc")
  t.eq(core.tohex(c:digest()), "a9993e364706816aba3e25717850c26c9cd0d89d")
  -- digest() does not finalize the running context
  c:update("d")
  t.eq(c:digest(), core.sha1("abcd"))
end

function T.random(t)
  local a, b = core.random_bytes(32), core.random_bytes(32)
  t.eq(#a, 32)
  t.ok(a ~= b)
end

return T
