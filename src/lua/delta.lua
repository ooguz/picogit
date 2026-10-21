-- SPDX-License-Identifier: GPL-3.0-or-later
-- Git delta (OFS_DELTA / REF_DELTA payload) application.
--
-- A delta starts with the base and result sizes as little-endian base-128
-- varints, followed by instructions: copy (MSB set; offset/size bytes are
-- selected by the low 7 bits) or insert (1..127 literal bytes).
local M = {}

local byte, sub = string.byte, string.sub

local function varint(s, pos)
  local v, shift = 0, 0
  repeat
    local c = byte(s, pos)
    if not c then error("delta: truncated header", 0) end
    v = v | ((c & 0x7f) << shift)
    shift = shift + 7
    pos = pos + 1
  until c < 0x80
  return v, pos
end

-- Size of the object a delta produces (without applying it).
function M.result_size(d)
  local _, pos = varint(d, 1)
  return (varint(d, pos))
end

function M.apply(base, d)
  local src_size, pos = varint(d, 1)
  local dst_size
  dst_size, pos = varint(d, pos)
  if src_size ~= #base then
    error(("delta: base size mismatch (%d != %d)"):format(src_size, #base), 0)
  end
  local out, n, total = {}, 0, 0
  local len = #d
  while pos <= len do
    local op = byte(d, pos)
    pos = pos + 1
    if op >= 0x80 then
      local off, size = 0, 0
      if op & 0x01 ~= 0 then off = byte(d, pos); pos = pos + 1 end
      if op & 0x02 ~= 0 then off = off | (byte(d, pos) << 8); pos = pos + 1 end
      if op & 0x04 ~= 0 then off = off | (byte(d, pos) << 16); pos = pos + 1 end
      if op & 0x08 ~= 0 then off = off | (byte(d, pos) << 24); pos = pos + 1 end
      if op & 0x10 ~= 0 then size = byte(d, pos); pos = pos + 1 end
      if op & 0x20 ~= 0 then size = size | (byte(d, pos) << 8); pos = pos + 1 end
      if op & 0x40 ~= 0 then size = size | (byte(d, pos) << 16); pos = pos + 1 end
      if pos > len + 1 then error("delta: truncated copy instruction", 0) end
      if size == 0 then size = 0x10000 end
      if off + size > src_size then error("delta: copy out of range", 0) end
      n = n + 1
      out[n] = sub(base, off + 1, off + size)
      total = total + size
    elseif op > 0 then
      if pos + op - 1 > len then error("delta: truncated insert", 0) end
      n = n + 1
      out[n] = sub(d, pos, pos + op - 1)
      pos = pos + op
      total = total + op
    else
      error("delta: invalid opcode 0", 0)
    end
    if total > dst_size then error("delta: result larger than announced", 0) end
  end
  if total ~= dst_size then error("delta: result size mismatch", 0) end
  return table.concat(out)
end

return M
