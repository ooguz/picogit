-- SPDX-License-Identifier: GPL-3.0-or-later
-- References: HEAD, loose refs, packed-refs and .git/shallow.
local core = require("picogit.core")
local util = require("util")

local M = {}
local Refs = {}
Refs.__index = Refs

function M.new(gitdir)
  return setmetatable({ gitdir = gitdir }, Refs)
end

local function trim(s)
  return (s:gsub("%s+$", ""))
end

function Refs:packed()
  if self._packed then return self._packed end
  local p = {}
  local data = util.read_file(self.gitdir .. "/packed-refs")
  if data then
    for line in data:gmatch("[^\n]+") do
      local id, name = line:match("^(%x+) (%S+)$")
      if id then p[name] = id end
    end
  end
  self._packed = p
  return p
end

-- Raw value of a ref: "ref: <target>" or an id, or nil.
function Refs:read_raw(name)
  local data = util.read_file(self.gitdir .. "/" .. name)
  if data then return trim(data) end
  return self:packed()[name]
end

-- Resolve a ref (following symbolic refs) to an id; nil if unborn.
function Refs:resolve(name)
  for _ = 1, 10 do
    local v = self:read_raw(name)
    if not v then return nil end
    local target = v:match("^ref: (.+)$")
    if not target then
      if not util.is_hex_id(v) then util.die("ref %s is corrupt", name) end
      return v
    end
    name = target
  end
  util.die("symbolic ref loop at %s", name)
end

-- HEAD -> { ref = "refs/heads/x" } or { id = "..." } (detached)
function Refs:head()
  local v = self:read_raw("HEAD")
  if not v then util.die("not a git repository (missing HEAD)") end
  local target = v:match("^ref: (.+)$")
  if target then return { ref = target, id = self:resolve(target) } end
  return { id = v }
end

function Refs:update(name, id)
  util.check_refname(name)
  if not util.is_hex_id(id) then error("bad object id for " .. name) end
  local p = self.gitdir .. "/" .. name
  util.mkdirs(util.dirname(p))
  util.write_file(p, id .. "\n")
end

function Refs:set_symbolic(name, target)
  util.check_refname(name)
  util.check_refname(target)
  util.write_file(self.gitdir .. "/" .. name, "ref: " .. target .. "\n")
end

-- Shallow boundary commits (set of ids).
function Refs:shallow()
  local set = {}
  local data = util.read_file(self.gitdir .. "/shallow")
  if data then
    for id in data:gmatch("%x+") do set[id] = true end
  end
  return set
end

function Refs:write_shallow(set)
  local list = {}
  for id in pairs(set) do list[#list + 1] = id end
  table.sort(list)
  local p = self.gitdir .. "/shallow"
  if #list == 0 then
    core.unlink(p)
  else
    util.write_file(p, table.concat(list, "\n") .. "\n")
  end
end

return M
