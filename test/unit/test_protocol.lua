-- pkt-line framing, side-band demultiplexing and delta application.
local pktline = require("pktline")
local delta = require("delta")
local T = {}

local function source(s, chunk)
  local pos = 1
  return function()
    if pos > #s then return nil end
    local d = s:sub(pos, pos + (chunk or 3) - 1)
    pos = pos + #d
    return d
  end
end

function T.pktline_encode(t)
  t.eq(pktline.encode("a\n"), "0006a\n")
  t.eq(pktline.line("want x"), "000bwant x\n")
  t.eq(pktline.encode(""), "0004")
  t.err(function() pktline.encode(string.rep("x", 65517)) end, "too long")
end

function T.pktline_reader_kinds(t)
  local s = pktline.line("hello") .. pktline.DELIM .. pktline.line("x") ..
            pktline.FLUSH .. pktline.RESPONSE_END
  local r = pktline.reader(source(s, 1)) -- one byte at a time
  local k, d = r:read()
  t.eq(k, "data"); t.eq(d, "hello\n")
  t.eq(r:read(), "delim")
  t.eq(r:read_line(), "x")
  t.eq(r:read(), "flush")
  t.eq(r:read(), "end")
  t.eq(r:read(), nil)
end

function T.pktline_errors(t)
  t.err(function() pktline.reader(source("zzzz")):read() end, "bad pkt%-line header")
  t.err(function() pktline.reader(source("0003")):read() end, "bad pkt%-line length")
  t.err(function() pktline.reader(source("0010abc")):read() end, "unexpected end")
end

function T.sideband_demux(t)
  local s = pktline.encode("\1PACK") .. pktline.encode("\2progress 1\r") ..
            pktline.encode("\1data") .. pktline.FLUSH .. pktline.line("after")
  local r = pktline.reader(source(s, 5))
  local data, prog = {}, {}
  pktline.demux(r, function(d) data[#data + 1] = d end, function(m) prog[#prog + 1] = m end)
  t.eq(table.concat(data), "PACKdata")
  t.eq(prog[1], "progress 1\r")
  t.eq(r:read_line(), "after") -- stops right after the flush
  local bad = pktline.reader(source(pktline.encode("\3access denied\n")))
  t.err(function() pktline.demux(bad, function() end) end, "remote error: access denied")
end

-- Build deltas by hand.
local function varint(n)
  local out = {}
  repeat
    local b = n & 0x7f
    n = n >> 7
    if n > 0 then b = b | 0x80 end
    out[#out + 1] = string.char(b)
  until n == 0
  return table.concat(out)
end

local function copy(off, size)
  local op, args = 0x80, {}
  for i = 0, 3 do
    local b = (off >> (8 * i)) & 0xff
    if b ~= 0 then op = op | (1 << i); args[#args + 1] = string.char(b) end
  end
  if size ~= 0x10000 then
    for i = 0, 2 do
      local b = (size >> (8 * i)) & 0xff
      if b ~= 0 then op = op | (0x10 << i); args[#args + 1] = string.char(b) end
    end
  end
  return string.char(op) .. table.concat(args)
end

local function insert(s) return string.char(#s) .. s end

function T.delta_apply(t)
  local base = "The quick brown fox jumps over the lazy dog"
  local want = "The quick red fox jumps over the lazy dog!"
  local d = varint(#base) .. varint(#want) ..
            copy(0, 10) .. insert("red") .. copy(15, #base - 15) .. insert("!")
  t.eq(delta.apply(base, d), want)
  t.eq(delta.result_size(d), #want)
end

function T.delta_large_copy_and_offsets(t)
  -- size 0 in a copy instruction means 0x10000; offsets above 16 bits
  local base = string.rep("a", 70000) .. "MARK" .. string.rep("b", 0x10000)
  local want = base:sub(70001, 70004) .. base:sub(70005, 70004 + 0x10000)
  local d = varint(#base) .. varint(#want) .. copy(70000, 4) .. copy(70004, 0x10000)
  t.eq(delta.apply(base, d), want)
end

function T.delta_errors(t)
  local base = "abc"
  t.err(function() delta.apply(base, varint(4) .. varint(1) .. insert("x")) end, "base size")
  t.err(function() delta.apply(base, varint(3) .. varint(2) .. insert("x")) end, "size mismatch")
  t.err(function() delta.apply(base, varint(3) .. varint(5) .. copy(1, 5)) end, "out of range")
  t.err(function() delta.apply(base, varint(3) .. varint(1) .. "\0") end, "opcode 0")
  t.err(function() delta.apply(base, varint(3) .. varint(3) .. string.char(5) .. "ab") end, "truncated")
end

return T
