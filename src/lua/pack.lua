-- Packfile reader (explodes a pack into loose objects) and writer
-- (delta-less packs for push).
--
-- Pack format: "PACK", version, object count, entries, SHA-1 trailer.
-- Each entry has a type/size varint header; OFS_DELTA entries add a
-- negative offset to their base, REF_DELTA entries the base object id.
-- Compressed sizes are not stored: the end of each entry is found from
-- the number of bytes zlib consumed.
local core = require("picogit.core")
local delta = require("delta")
local util = require("util")

local M = {}

local TYPES = { "commit", "tree", "blob", "tag" }
local OFS_DELTA, REF_DELTA = 6, 7

-- Objects up to this size are inflated in memory (and cached as possible
-- delta bases); larger non-delta objects are streamed to disk.
local SMALL_OBJECT = 256 * 1024
local CACHE_BYTES = 8 * 1024 * 1024

local function new_cache(limit)
  local c = { map = {}, queue = {}, head = 1, bytes = 0, limit = limit }
  function c:get(id)
    local e = self.map[id]
    if e then return e[1], e[2] end
  end
  function c:put(id, t, data)
    if #data > self.limit // 4 or self.map[id] then return end
    self.map[id] = { t, data }
    self.queue[#self.queue + 1] = id
    self.bytes = self.bytes + #data
    while self.bytes > self.limit and self.head <= #self.queue do
      local old = self.queue[self.head]
      self.queue[self.head] = nil
      self.head = self.head + 1
      local e = self.map[old]
      if e then
        self.bytes = self.bytes - #e[2]
        self.map[old] = nil
      end
    end
  end
  return c
end

local function read_entry_header(fh, off)
  fh:seek("set", off)
  local h = fh:read(64) or ""
  local byte = string.byte
  local i = 1
  local c = byte(h, i)
  if not c then util.die("pack: truncated entry at offset %d", off) end
  local typ, size, shift = (c >> 4) & 7, c & 15, 4
  while c >= 0x80 do
    i = i + 1
    c = byte(h, i)
    size = size | ((c & 0x7f) << shift)
    shift = shift + 7
  end
  i = i + 1
  local base
  if typ == OFS_DELTA then
    c = byte(h, i)
    i = i + 1
    local ofs = c & 0x7f
    while c >= 0x80 do
      c = byte(h, i)
      i = i + 1
      ofs = ((ofs + 1) << 7) | (c & 0x7f)
    end
    base = off - ofs
    if base < 12 then util.die("pack: bad delta base offset at %d", off) end
  elseif typ == REF_DELTA then
    base = core.tohex(h:sub(i, i + 19))
    i = i + 20
  end
  return typ, size, base, off + i - 1
end

-- Explode the pack at `path` into loose objects in `odb`.
--   opts.progress(done, total) is called periodically.
-- Returns the number of objects.
function M.unpack(path, odb, opts)
  opts = opts or {}
  local fh = assert(io.open(path, "rb"))
  local size = fh:seek("end")
  if size < 32 then
    fh:close()
    util.die("pack: file too small (%d bytes)", size)
  end
  fh:seek("set", 0)
  local sig, version, count = string.unpack(">c4I4I4", fh:read(12))
  if sig ~= "PACK" or (version ~= 2 and version ~= 3) then
    fh:close()
    util.die("pack: bad header")
  end
  fh:seek("set", size - 20)
  local trailer = fh:read(20)
  if core.sha1_file(fh, 0, size - 20) ~= trailer then
    fh:close()
    util.die("pack: checksum mismatch (corrupt download)")
  end

  local cache = new_cache(CACHE_BYTES)
  local by_offset = {}
  local pending = {}
  local done, deltas = 0, 0

  local function base_object(id)
    local t, data = cache:get(id)
    if t then return t, data end
    return odb:read(id)
  end

  local function resolve(off, base_id, d)
    local t, base = base_object(base_id)
    local ok, result = pcall(delta.apply, base, d)
    if not ok then util.die("pack: bad delta at offset %d: %s", off, result) end
    local id = odb:write(t, result)
    cache:put(id, t, result)
    by_offset[off] = id
    done = done + 1
    deltas = deltas + 1
  end

  local off = 12
  for _ = 1, count do
    local typ, osize, base, doff = read_entry_header(fh, off)
    local used
    if TYPES[typ] then
      local id
      if osize <= SMALL_OBJECT then
        local data
        data, used = core.pack_inflate(fh, doff, osize)
        id = odb:write(TYPES[typ], data)
        cache:put(id, TYPES[typ], data)
      else
        local sha
        sha, used = core.pack_inflate_loose(fh, doff, osize, odb.dir, TYPES[typ])
        id = core.tohex(sha)
      end
      by_offset[off] = id
      done = done + 1
    elseif typ == OFS_DELTA or typ == REF_DELTA then
      local base_id = typ == OFS_DELTA and by_offset[base] or nil
      if typ == REF_DELTA and odb:has(base) then base_id = base end
      if base_id then
        local d
        d, used = core.pack_inflate(fh, doff, osize)
        resolve(off, base_id, d)
      else
        -- base not available yet: remember where the delta is and
        -- re-read it later instead of keeping it in memory
        local _
        _, used = core.pack_inflate(fh, doff, osize)
        pending[#pending + 1] = { off = off, typ = typ, base = base, doff = doff, size = osize }
      end
    else
      util.die("pack: invalid object type %d at offset %d", typ, off)
    end
    off = doff + used
    if opts.progress then opts.progress(done, count) end
  end
  if off ~= size - 20 then
    fh:close()
    util.die("pack: %d bytes of garbage after the last object", size - 20 - off)
  end

  while #pending > 0 do
    local rest = {}
    for _, p in ipairs(pending) do
      local base_id
      if p.typ == OFS_DELTA then
        base_id = by_offset[p.base]
      elseif odb:has(p.base) then
        base_id = p.base
      end
      if base_id then
        resolve(p.off, base_id, (core.pack_inflate(fh, p.doff, p.size)))
        if opts.progress then opts.progress(done, count) end
      else
        rest[#rest + 1] = p
      end
    end
    if #rest == #pending then
      fh:close()
      util.die("pack: %d deltas reference missing base objects", #rest)
    end
    pending = rest
  end
  fh:close()
  util.trace("pack: %d objects, %d deltas", count, deltas)
  return count
end

-- Write a pack without deltas containing the given loose objects.
function M.write(path, odb, ids)
  local fh = assert(io.open(path, "w+b"))
  fh:write(string.pack(">c4I4I4", "PACK", 2, #ids))
  for _, id in ipairs(ids) do
    core.loose_to_pack(odb:locate(id) or util.die("object %s is missing", id), fh)
  end
  fh:flush()
  local size = fh:seek("end")
  local sum = core.sha1_file(fh, 0, size)
  fh:seek("end")
  fh:write(sum)
  if not fh:close() then util.die("cannot write %s", path) end
  return size + 20
end

return M
