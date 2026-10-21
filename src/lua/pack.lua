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
--
-- Like git index-pack this works in two passes so that memory use does not
-- grow with the pack: the first pass streams every non-delta object
-- straight to a loose object (in C, no Lua strings) and only records where
-- the deltas are; the second pass walks each delta tree from its base,
-- keeping just the current chain of base/result contents in memory.
function M.unpack(path, odb, opts)
  opts = opts or {}
  local fh = assert(io.open(path, "rb"))
  local function fail(...)
    fh:close()
    util.die(...)
  end
  local size = fh:seek("end")
  if size < 32 then fail("pack: file too small (%d bytes)", size) end
  fh:seek("set", 0)
  local sig, version, count = string.unpack(">c4I4I4", fh:read(12))
  if sig ~= "PACK" or (version ~= 2 and version ~= 3) then fail("pack: bad header") end
  fh:seek("set", size - 20)
  local trailer = fh:read(20)
  if core.sha1_file(fh, 0, size - 20) ~= trailer then
    fail("pack: checksum mismatch (corrupt download)")
  end

  local bases = {}          -- offsets of the non-delta entries
  local id_at = {}          -- entry offset -> object id (once known)
  local type_at = {}        -- entry offset -> object type
  local by_base_off = {}    -- base offset -> { delta entries }
  local by_base_id = {}     -- base id -> { delta entries }
  local ndeltas, done = 0, 0
  local progress = opts.progress or function() end

  -- pass 1
  local off = 12
  for _ = 1, count do
    local typ, osize, base, doff = read_entry_header(fh, off)
    local used
    if TYPES[typ] then
      local sha
      sha, used = core.pack_inflate_loose(fh, doff, osize, odb.dir, TYPES[typ])
      id_at[off] = core.tohex(sha)
      type_at[off] = TYPES[typ]
      bases[#bases + 1] = off
      done = done + 1
    elseif typ == OFS_DELTA or typ == REF_DELTA then
      used = core.pack_skip(fh, doff, osize)
      local d = { off = off, doff = doff, size = osize }
      local list = typ == OFS_DELTA and by_base_off or by_base_id
      local l = list[base]
      if not l then
        l = {}
        list[base] = l
      end
      l[#l + 1] = d
      ndeltas = ndeltas + 1
    else
      fail("pack: invalid object type %d at offset %d", typ, off)
    end
    off = doff + used
    progress(done, count)
  end
  if off ~= size - 20 then
    fail("pack: %d bytes of garbage after the last object", size - 20 - off)
  end

  -- pass 2: resolve the deltas depending on (off, id), whose content is
  -- `data` (loaded on demand)
  local resolved = 0
  local function resolve(off_, id, t, data)
    local children = {}
    for _, d in ipairs(off_ and by_base_off[off_] or {}) do children[#children + 1] = d end
    for _, d in ipairs(by_base_id[id] or {}) do children[#children + 1] = d end
    if #children == 0 then return end
    if off_ then by_base_off[off_] = nil end
    by_base_id[id] = nil
    if not data then
      t, data = odb:read(id)
    end
    for i, d in ipairs(children) do
      local ok, result = pcall(delta.apply, data, (core.pack_inflate(fh, d.doff, d.size)))
      if not ok then fail("pack: bad delta at offset %d: %s", d.off, result) end
      local cid = odb:write(t, result)
      id_at[d.off], type_at[d.off] = cid, t
      resolved = resolved + 1
      done = done + 1
      progress(done, count)
      if i == #children then
        -- tail call: this frame (and its base) is released, so a long
        -- delta chain only keeps one base/result pair alive
        return resolve(d.off, cid, t, result)
      end
      resolve(d.off, cid, t, result)
    end
  end

  for _, o in ipairs(bases) do
    local id = id_at[o]
    if by_base_off[o] or by_base_id[id] then resolve(o, id, type_at[o]) end
  end
  -- REF_DELTA against objects that were already in the repository
  local ext = {}
  for id in pairs(by_base_id) do ext[#ext + 1] = id end
  for _, id in ipairs(ext) do
    if by_base_id[id] and odb:has(id) then resolve(nil, id) end
  end
  if resolved ~= ndeltas then
    fail("pack: %d deltas reference missing base objects", ndeltas - resolved)
  end
  fh:close()
  util.trace("pack: %d objects, %d deltas", count, ndeltas)
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
