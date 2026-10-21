-- SPDX-License-Identifier: GPL-3.0-or-later
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
local STAT_FMT = ">I4I4I4I4I4I4I4I4I4"

local function pack_stat(st)
  return string.pack(STAT_FMT, st.ctime & U32, st.ctime_ns & U32, st.mtime & U32,
    st.mtime_ns & U32, st.dev & U32, st.ino & U32, st.uid & U32, st.gid & U32, st.size & U32)
end

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
    -- ctime, ctime_ns, mtime, mtime_ns, dev, ino | mode | uid, gid, size
    local e = { stat = data:sub(pos, pos + 23) .. data:sub(pos + 28, pos + 39) }
    e.mode = string.unpack(">I4", data, pos + 24)
    pos = pos + 40
    e.id = core.tohex(data:sub(pos, pos + 19))
    pos = pos + 20
    e.flags, pos = string.unpack(">I2", data, pos)
    local hdr = 62
    if e.flags & 0x4000 ~= 0 then
      pos = pos + 2 -- extended flags (v3), not needed
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
  local fixed = e.stat:sub(1, 24) .. string.pack(">I4", e.mode) .. e.stat:sub(25)
  local len = 62 + namelen
  local pad = ((len + 8) & ~7) - len
  return fixed .. core.fromhex(e.id) .. string.pack(">I2", flags) .. e.name .. string.rep("\0", pad)
end

function M.sort(entries)
  table.sort(entries, function(a, b) return a.name < b.name end)
  return entries
end

-- Entries are streamed to the file (with a running checksum) rather than
-- joined into one string first.
function M.write(path, entries)
  M.sort(entries)
  local tmp = path .. ".lock"
  local f, err = io.open(tmp, "wb")
  if not f then util.die("cannot write index: %s", err) end
  local sum = core.sha1_new()
  local function put(s)
    sum:update(s)
    f:write(s)
  end
  put(string.pack(">c4I4I4", "DIRC", 2, #entries))
  for _, e in ipairs(entries) do put(entry_bytes(e)) end
  f:write(sum:digest())
  if not f:close() then util.die("cannot write index %s", path) end
  local ok, rerr = core.rename(tmp, path)
  if not ok then
    core.unlink(tmp)
    util.die("cannot write index: %s", rerr)
  end
end

-- Build an index entry for a work tree path from lstat() data.
function M.entry(name, mode, id, st)
  return { name = name, mode = mode, id = id, stat = pack_stat(st) }
end

local ZERO_STAT = string.rep("\0", 36)

-- Entry for a gitlink (submodule): no work tree file is tracked.
function M.gitlink_entry(name, id)
  return { name = name, mode = M.MODE_GITLINK, id = id, stat = ZERO_STAT }
end

-- Does the cached stat data still describe the file? `racy` is the index
-- file's lstat(): a file modified at or after the moment the index was
-- written may have changed without its stat data changing ("racy git"),
-- so it must be re-hashed. Nanoseconds are used where the file system
-- has them; on FAT/jffs2 (whole seconds) the same second counts as racy.
function M.stat_matches(e, st, racy)
  if e.stat ~= pack_stat(st) then return false end
  if racy and (st.mtime > racy.mtime or
               (st.mtime == racy.mtime and st.mtime_ns >= racy.mtime_ns)) then
    return false
  end
  return true
end

return M
