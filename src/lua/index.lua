-- The git index (.git/index), version 2 without extensions.
--
-- Version 3 files (extended flags) are read as well; extensions written by
-- git (TREE, UNTR, ...) are skipped on read and not written back, which git
-- accepts. Entries:
--   { name, mode (number, e.g. 0x81a4), id (hex), size, mtime, mtime_ns,
--     ctime, ctime_ns, dev, ino, uid, gid, flags }
local core = require("picogit.core")
local util = require("util")

local M = {}

M.MODE_FILE = tonumber("100644", 8)
M.MODE_EXEC = tonumber("100755", 8)
M.MODE_LINK = tonumber("120000", 8)
M.MODE_GITLINK = tonumber("160000", 8)

local U32 = 0xffffffff

function M.mode_from_tree(mode)
  return tonumber(mode, 8)
end

function M.mode_to_tree(mode)
  return ("%o"):format(mode)
end

function M.read(path)
  local data = util.read_file(path)
  if not data then return {} end
  if #data < 32 then util.die("index file is corrupt (too short)") end
  if core.sha1(data:sub(1, -21)) ~= data:sub(-20) then
    util.die("index file is corrupt (bad checksum)")
  end
  local sig, version, count, pos = string.unpack(">c4I4I4", data)
  if sig ~= "DIRC" then util.die("index file is corrupt (bad signature)") end
  if version ~= 2 and version ~= 3 then
    util.die("index version %d is not supported (run 'git update-index --index-version 2')", version)
  end
  local entries = {}
  for i = 1, count do
    local start = pos
    local e = {}
    e.ctime, e.ctime_ns, e.mtime, e.mtime_ns, e.dev, e.ino, e.mode, e.uid, e.gid, e.size, pos =
      string.unpack(">I4I4I4I4I4I4I4I4I4I4", data, pos)
    e.id = core.tohex(data:sub(pos, pos + 19))
    pos = pos + 20
    e.flags, pos = string.unpack(">I2", data, pos)
    local hdr = 62
    if e.flags & 0x4000 ~= 0 then
      e.flags2, pos = string.unpack(">I2", data, pos)
      hdr = 64
    end
    local nul = data:find("\0", pos, true)
    e.name = data:sub(pos, nul - 1)
    -- entries are NUL padded to a multiple of 8 bytes
    local len = hdr + #e.name
    pos = start + ((len + 8) & ~7)
    entries[i] = e
  end
  return entries
end

local function entry_bytes(e)
  local namelen = #e.name
  local flags = (e.flags or 0) & 0x3000 -- keep the stage bits only
  flags = flags | (namelen < 0xfff and namelen or 0xfff)
  local fixed = string.pack(">I4I4I4I4I4I4I4I4I4I4",
    e.ctime & U32, e.ctime_ns & U32, e.mtime & U32, e.mtime_ns & U32,
    e.dev & U32, e.ino & U32, e.mode, e.uid & U32, e.gid & U32, e.size & U32)
  local len = 62 + namelen
  local pad = ((len + 8) & ~7) - len
  return fixed .. core.fromhex(e.id) .. string.pack(">I2", flags) .. e.name .. string.rep("\0", pad)
end

function M.sort(entries)
  table.sort(entries, function(a, b) return a.name < b.name end)
  return entries
end

function M.write(path, entries)
  M.sort(entries)
  local parts = { string.pack(">c4I4I4", "DIRC", 2, #entries) }
  for i, e in ipairs(entries) do parts[i + 1] = entry_bytes(e) end
  local body = table.concat(parts)
  util.write_file(path, body .. core.sha1(body))
end

-- Build an index entry for a work tree path from lstat() data.
function M.entry(name, mode, id, st)
  return {
    name = name, mode = mode, id = id,
    ctime = st.ctime, ctime_ns = st.ctime_ns, mtime = st.mtime, mtime_ns = st.mtime_ns,
    dev = st.dev, ino = st.ino, uid = st.uid, gid = st.gid, size = st.size,
  }
end

-- Entry for a gitlink (submodule): no work tree file is tracked.
function M.gitlink_entry(name, id)
  return {
    name = name, mode = M.MODE_GITLINK, id = id,
    ctime = 0, ctime_ns = 0, mtime = 0, mtime_ns = 0,
    dev = 0, ino = 0, uid = 0, gid = 0, size = 0,
  }
end

-- Does the cached stat data still describe the file? `racy_before` is the
-- index file's mtime: files modified in the same second the index was
-- written cannot be trusted ("racy git") and must be re-hashed.
function M.stat_matches(e, st, racy_before)
  if (e.mtime & U32) ~= (st.mtime & U32) or (e.mtime_ns & U32) ~= (st.mtime_ns & U32) then
    return false
  end
  if (e.ctime & U32) ~= (st.ctime & U32) or (e.ctime_ns & U32) ~= (st.ctime_ns & U32) then
    return false
  end
  if (e.size & U32) ~= (st.size & U32) or (e.ino & U32) ~= (st.ino & U32) then
    return false
  end
  if racy_before and st.mtime >= racy_before then return false end
  return true
end

return M
