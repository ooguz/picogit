-- SPDX-License-Identifier: GPL-3.0-or-later
-- Shared fetch logic for clone and pull: listing remote refs and
-- downloading + unpacking a pack.
local core = require("picogit.core")
local pack = require("pack")
local pktline = require("pktline")
local transport = require("transport")
local util = require("util")

local M = {}

-- List the remote refs matching `prefixes` (exact names or prefixes).
-- Returns { info, refs = {name = id}, symrefs = {name = target},
--           peeled = {name = id} }.
function M.list_refs(remote, prefixes)
  local info = transport.discover(remote, "git-upload-pack", true)
  util.trace("upload-pack: protocol v%d", info.version)
  if info.version == 2 then
    if not info.caps["ls-refs"] or not info.caps.fetch then
      util.die("server does not support ls-refs/fetch")
    end
    local refs, symrefs, peeled = transport.ls_refs(remote, info.caps, prefixes)
    return { info = info, refs = refs, symrefs = symrefs, peeled = peeled }
  end
  local refs, peeled = {}, {}
  for name, id in pairs(info.refs) do
    local base = name:match("^(.*)%^{}$")
    if base then
      peeled[base] = id
    else
      for _, p in ipairs(prefixes) do
        if name:sub(1, #p) == p then refs[name] = id end
      end
    end
  end
  return { info = info, refs = refs, symrefs = info.symrefs, peeled = peeled }
end

local function human(n)
  if n >= 1024 * 1024 then return ("%.2f MiB"):format(n / 1048576) end
  return ("%.1f KiB"):format(n / 1024)
end

-- Progress output on a terminal only (routers are often run from cron).
local function progress_line()
  if not util.show_progress() then return function() end end
  local last = 0
  return function(text, final)
    local now = os.clock()
    if final or now - last >= 0.2 then
      last = now
      io.stderr:write("\r", text, final and "\n" or "")
    end
  end
end

-- Download the objects for opts.wants and unpack them.
--   opts: wants, haves, shallows, depth, quarantine
-- Returns the object database the objects went to (a quarantine when
-- requested: the caller must migrate() or discard() it) and the
-- shallow-info result.
function M.fetch_objects(repo, remote, listing, opts)
  local target = opts.quarantine and repo.odb:quarantine() or repo.odb
  local tmp = util.temp_path(repo.gitdir .. "/objects/pack/tmp_pack")
  local f, ferr = io.open(tmp, "wb")
  if not f then util.die("cannot create %s", ferr) end
  local show = progress_line()
  local received = 0
  local fopts = {
    wants = opts.wants, haves = opts.haves, shallows = opts.shallows, depth = opts.depth,
    progress = pktline.progress_writer(),
    sink = function(data)
      local ok, err = f:write(data)
      if not ok then util.die("cannot write pack: %s", err) end
      received = received + #data
      show("Receiving objects: " .. human(received))
    end,
  }
  util.trace_mem("before download")
  local ok, res = pcall(function()
    if listing.info.version == 2 then
      return transport.fetch_v2(remote, listing.info.caps, fopts)
    end
    return transport.fetch_v0(remote, listing.info.caps, fopts)
  end)
  local closed = f:close()
  if ok and not closed then ok, res = false, "cannot write " .. tmp end
  util.trace_mem("after download")
  if ok then
    show("Receiving objects: " .. human(received) .. ", done.", true)
    local count
    ok, count = pcall(pack.unpack, tmp, target, {
      progress = function(done, total)
        show(("Unpacking objects: %d/%d"):format(done, total), done == total)
      end,
    })
    if not ok then res = count end
    util.trace("unpacked %s objects from %d bytes", tostring(count), received)
    util.trace_mem("after unpack")
  end
  core.unlink(tmp)
  if not ok then
    if opts.quarantine then target:discard() end
    error(res, 0)
  end
  return target, res
end

return M
