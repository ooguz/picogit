-- SPDX-License-Identifier: GPL-3.0-or-later
-- Loose object database plus commit/tree/tag parsing and serialization.
local core = require("picogit.core")
local util = require("util")

local M = {}
local ODB = {}
ODB.__index = ODB

function M.new(gitdir)
  return setmetatable({ dir = gitdir .. "/objects", alt = {} }, ODB)
end

-- Where a new object with this id is written.
function ODB:path(id)
  return self.dir .. "/" .. id:sub(1, 2) .. "/" .. id:sub(3)
end

-- Path of an existing object (own directory first, then alternates).
function ODB:locate(id)
  local rel = "/" .. id:sub(1, 2) .. "/" .. id:sub(3)
  if core.lstat(self.dir .. rel) then return self.dir .. rel end
  for _, d in ipairs(self.alt) do
    if core.lstat(d .. rel) then return d .. rel end
  end
end

function ODB:has(id)
  return self:locate(id) ~= nil
end

-- A quarantine object directory: new objects go to a temporary directory
-- and only become part of the repository with migrate(); discard() drops
-- them (e.g. when a pull turns out not to be a fast-forward).
function ODB:quarantine()
  local q = util.temp_path(self.dir .. "/incoming")
  util.mkdirs(q)
  return setmetatable({ dir = q, alt = { self.dir }, parent = self }, ODB)
end

function ODB:migrate()
  local main = self.parent.dir
  for _, sub in ipairs(core.readdir(self.dir) or {}) do
    local from = self.dir .. "/" .. sub
    if #sub == 2 and core.lstat(from).type == "dir" then
      util.mkdirs(main .. "/" .. sub)
      for _, name in ipairs(core.readdir(from) or {}) do
        local dst = main .. "/" .. sub .. "/" .. name
        if core.lstat(dst) then
          core.unlink(from .. "/" .. name)
        else
          local ok, err = core.rename(from .. "/" .. name, dst)
          if not ok then util.die("cannot move object: %s", err) end
        end
      end
    end
  end
  util.remove_tree(self.dir)
end

function ODB:discard()
  util.remove_tree(self.dir)
end

-- read(id) -> type, data
function ODB:read(id)
  local p = self:locate(id)
  if not p then util.die("object %s is missing", id) end
  return core.loose_read(p)
end

-- header(id) -> type, size (without reading the content)
function ODB:header(id)
  local p = self:locate(id)
  if not p then util.die("object %s is missing", id) end
  return core.loose_header(p)
end

-- read(id) but the type must match
function ODB:read_typed(id, want)
  local t, data = self:read(id)
  if t ~= want then util.die("object %s is a %s, expected a %s", id, t, want) end
  return data
end

-- Hash first and only compress/write objects that are missing: most trees
-- written by commit already exist, and flash writes are expensive.
function ODB:write(otype, data)
  local id = core.tohex(core.loose_write(nil, otype, data))
  if not self:has(id) then core.loose_write(self.dir, otype, data) end
  return id
end

-- Store a work tree file as a blob; returns id, size.
function ODB:write_file(path)
  local sha, size = core.hash_file(path, self.dir)
  return core.tohex(sha), size
end

-- Write a blob to a new file in the work tree.
function ODB:checkout_file(id, path, mode)
  local p = self:locate(id)
  if not p then util.die("object %s is missing", id) end
  return core.loose_to_file(p, path, mode)
end

function M.hash(otype, data)
  return core.tohex(core.loose_write(nil, otype, data))
end

-- Commits -------------------------------------------------------------------

-- parse_commit(data) -> { tree, parents = {...}, author, committer,
--                         message, extra = { "header lines" } }
function M.parse_commit(data)
  local c = { parents = {}, extra = {} }
  local hdr_end = data:find("\n\n", 1, true)
  local headers = hdr_end and data:sub(1, hdr_end) or data .. "\n"
  c.message = hdr_end and data:sub(hdr_end + 2) or ""
  local last
  for line in headers:gmatch("([^\n]*)\n") do
    if line:sub(1, 1) == " " and last then
      last.value = last.value .. "\n" .. line:sub(2) -- continuation (gpgsig)
    else
      local k, v = line:match("^(%S+) (.*)$")
      if k == "tree" then c.tree = v
      elseif k == "parent" then c.parents[#c.parents + 1] = v
      elseif k == "author" then c.author = v
      elseif k == "committer" then c.committer = v
      elseif k then
        last = { key = k, value = v }
        c.extra[#c.extra + 1] = last
      end
    end
  end
  if not c.tree then util.die("malformed commit (no tree)") end
  return c
end

function M.serialize_commit(c)
  local out = { "tree " .. c.tree .. "\n" }
  for _, p in ipairs(c.parents or {}) do out[#out + 1] = "parent " .. p .. "\n" end
  out[#out + 1] = "author " .. c.author .. "\n"
  out[#out + 1] = "committer " .. c.committer .. "\n"
  out[#out + 1] = "\n"
  out[#out + 1] = c.message
  return table.concat(out)
end

-- Trees ---------------------------------------------------------------------

-- parse_tree(data) -> { { mode = "100644", name = "a", id = hex }, ... }
function M.parse_tree(data)
  local entries, pos, len = {}, 1, #data
  while pos <= len do
    local sp = data:find(" ", pos, true)
    local nul = sp and data:find("\0", sp + 1, true)
    if not nul or nul + 20 > len then util.die("malformed tree object") end
    entries[#entries + 1] = {
      mode = data:sub(pos, sp - 1),
      name = data:sub(sp + 1, nul - 1),
      id = core.tohex(data:sub(nul + 1, nul + 20)),
    }
    pos = nul + 21
  end
  return entries
end

local function sort_key(e)
  return e.mode == "40000" and e.name .. "/" or e.name
end

-- Git orders tree entries by name, comparing directories as if their name
-- ended with "/".
function M.sort_tree(entries)
  table.sort(entries, function(a, b) return sort_key(a) < sort_key(b) end)
  return entries
end

function M.serialize_tree(entries)
  M.sort_tree(entries)
  local out = {}
  for i, e in ipairs(entries) do
    out[i] = e.mode .. " " .. e.name .. "\0" .. core.fromhex(e.id)
  end
  return table.concat(out)
end

-- Tags ----------------------------------------------------------------------

function M.parse_tag(data)
  local t = {}
  for line in data:gmatch("([^\n]*)\n") do
    if line == "" then break end
    local k, v = line:match("^(%S+) (.*)$")
    if k and not t[k] then t[k] = v end
  end
  return t
end

-- Follow tag objects until a non-tag object; returns id, type.
function ODB:peel(id)
  for _ = 1, 20 do
    local t, data = self:read(id)
    if t ~= "tag" then return id, t end
    id = M.parse_tag(data).object
  end
  util.die("tag chain too deep")
end

-- Mode helpers --------------------------------------------------------------

M.MODE_FILE = "100644"
M.MODE_EXEC = "100755"
M.MODE_LINK = "120000"
M.MODE_TREE = "40000"
M.MODE_GITLINK = "160000"

-- Normalize odd modes found in old repositories (e.g. 100664).
function M.normalize_mode(mode)
  if mode == "40000" or mode == "040000" then return "40000" end
  if mode == "120000" or mode == "160000" then return mode end
  if mode:match("^100") then
    return (tonumber(mode, 8) & 64) ~= 0 and "100755" or "100644"
  end
  return mode
end

return M
