-- SPDX-License-Identifier: GPL-3.0-or-later
-- Smart HTTP transport: ref discovery, upload-pack (fetch) and
-- receive-pack (push).
--
-- Fetch prefers protocol v2: `ls-refs` with ref prefixes only lists the
-- refs we need, which matters on hosts that advertise thousands of refs
-- (GitHub's refs/pull/*). Servers that do not answer with v2 are handled
-- with protocol v0. Push always uses v0; receive-pack has no v2.
local core = require("picogit.core")
local http = require("http")
local pktline = require("pktline")
local util = require("util")

local M = {}

local AGENT = "picogit/" .. core.version

-- ~/.netrc lookup: returns login, password for host.
local function netrc_lookup(host)
  local path = os.getenv("NETRC")
  if not path then
    local home = os.getenv("HOME")
    if not home then return nil end
    path = home .. "/.netrc"
  end
  local data = util.read_file(path)
  if not data then return nil end
  local tokens = {}
  for tok in data:gmatch("%S+") do tokens[#tokens + 1] = tok end
  local i, current, found, default = 1, nil, nil, nil
  while i <= #tokens do
    local t = tokens[i]
    if t == "machine" then
      current = { host = tokens[i + 1] }
      if current.host == host and not found then found = current end
      i = i + 2
    elseif t == "default" then
      current = { host = "*" }
      default = default or current
      i = i + 1
    elseif (t == "login" or t == "password") and current then
      current[t] = tokens[i + 1]
      i = i + 2
    elseif t == "macdef" then
      break -- macro definitions run to the end of the paragraph; not needed
    else
      i = i + 1
    end
  end
  local e = found or default
  if e and e.password then return e.login or "git", e.password end
  return nil
end

-- Create a remote from a URL. Credentials are taken, in this order, from
-- the URL, from PICOGIT_TOKEN (user: PICOGIT_USERNAME, the URL user or
-- "git") or from ~/.netrc. The base URL never contains credentials.
function M.new(url)
  local u, err = http.parse_url(url)
  if not u then util.die("invalid remote URL '%s': %s", util.redact_url(url), err) end
  local user, pass, source = u.user, u.password, nil
  if pass then
    source = "url"
  elseif os.getenv("PICOGIT_TOKEN") and os.getenv("PICOGIT_TOKEN") ~= "" then
    pass = os.getenv("PICOGIT_TOKEN")
    user = os.getenv("PICOGIT_USERNAME") or user or "git"
    source = "PICOGIT_TOKEN"
  else
    local l, p = netrc_lookup(u.host)
    if p then user, pass, source = l, p, "netrc" end
  end
  local base = util.redact_url(url):gsub("/+$", "")
  local remote = { base = base, origin = http.origin(u), cred_source = source }
  if pass then
    remote.authorization = "Basic " .. util.base64((user or "") .. ":" .. pass)
  end
  return remote
end

local function check_status(remote, r, what)
  if r.status == 200 then return end
  local s = r.status
  r.conn:close()
  if s == 401 then
    if remote.authorization then
      util.die("authentication failed for '%s' (credentials from %s)", remote.base, remote.cred_source)
    end
    util.die("authentication required for '%s': set PICOGIT_TOKEN or add the host to ~/.netrc", remote.base)
  elseif s == 403 then
    util.die("access to '%s' denied (HTTP 403)", remote.base)
  elseif s == 404 then
    util.die("repository '%s' not found", remote.base)
  end
  util.die("%s: unexpected HTTP status %d from '%s'", what, s, remote.base)
end

local function request(remote, method, path, headers, body)
  return http.request {
    method = method,
    url = remote.base .. path,
    headers = headers,
    body = body,
    authorization = remote.authorization,
    auth_origin = remote.origin,
  }
end

local function parse_caps(str, caps)
  for c in str:gmatch("%S+") do
    local k, v = c:match("^([^=]+)=(.*)$")
    if k then caps[k] = v else caps[c] = true end
  end
end

-- GET info/refs. Returns
--   { version = 2, caps = {...} }                      for protocol v2
--   { version = 0, caps = {...}, refs = {name = id}, symrefs = {...} }
function M.discover(remote, service, want_v2)
  local headers = { "Accept: */*", "Pragma: no-cache" }
  if want_v2 then headers[#headers + 1] = "Git-Protocol: version=2" end
  local r = request(remote, "GET", "/info/refs?service=" .. service, headers)
  check_status(remote, r, "ref discovery")
  -- Follow redirects for the rest of the session, like git does.
  local final = r.url:match("^(.*)/info/refs%?service=")
  if final and final ~= remote.base then
    util.trace("remote redirected to %s", final)
    remote.base = final
    local origin = http.origin(http.parse_url(final))
    if origin ~= remote.origin then
      -- never send credentials to a host we were redirected to
      remote.authorization = nil
      remote.origin = origin
    end
  end
  local ctype = r.headers["content-type"] or ""
  if ctype ~= "application/x-" .. service .. "-advertisement" then
    r.conn:close()
    util.die("'%s' is not a smart HTTP git server (dumb HTTP is not supported)", remote.base)
  end
  local rd = pktline.reader(function(n) return r.conn:read(n) end)
  local kind, data = rd:read()
  if kind == "data" and data:match("^# service=") then
    kind = rd:read() -- flush after the service announcement
    kind, data = rd:read()
  end
  local res = { caps = {}, refs = {}, symrefs = {} }
  if kind == "data" and data == "version 2\n" then
    res.version = 2
    while true do
      local line = rd:read_line()
      if not line then break end
      parse_caps(line, res.caps)
    end
    r.conn:close()
    return res
  end
  res.version = 0
  while kind == "data" do
    local line = data:gsub("\n$", "")
    local refpart, caps = line:match("^([^%z]*)%z(.*)$")
    if refpart then
      parse_caps(caps, res.caps)
      -- there may be several symref=A:B capabilities
      for a, b in caps:gmatch("symref=([^:%s]+):(%S+)") do res.symrefs[a] = b end
      line = refpart
    end
    local id, name = line:match("^(%x+) (.+)$")
    if not id then util.die("protocol error: bad ref advertisement %q", line) end
    if name ~= "capabilities^{}" then res.refs[name] = id end
    kind, data = rd:read()
  end
  r.conn:close()
  return res
end

local function upload_pack(remote, body)
  local r = request(remote, "POST", "/git-upload-pack", {
    "Content-Type: application/x-git-upload-pack-request",
    "Accept: application/x-git-upload-pack-result",
    "Git-Protocol: version=2",
  }, body)
  check_status(remote, r, "upload-pack")
  return r, pktline.reader(function(n) return r.conn:read(n) end)
end

local function v2_header(remote, caps, command)
  local parts = {
    pktline.line("command=" .. command),
    pktline.line("agent=" .. AGENT),
  }
  if caps["object-format"] then
    parts[#parts + 1] = pktline.line("object-format=sha1")
  end
  parts[#parts + 1] = pktline.DELIM
  return parts
end

-- Protocol v2 ls-refs. Returns refs {name = id}, symrefs {name = target},
-- peeled {name = id}. Unborn HEAD (empty repository) is reported as a
-- symref without an id.
function M.ls_refs(remote, caps, prefixes)
  local body = v2_header(remote, caps, "ls-refs")
  body[#body + 1] = pktline.line("peel")
  body[#body + 1] = pktline.line("symrefs")
  if tostring(caps["ls-refs"] or ""):match("unborn") then
    body[#body + 1] = pktline.line("unborn")
  end
  for _, p in ipairs(prefixes) do
    body[#body + 1] = pktline.line("ref-prefix " .. p)
  end
  body[#body + 1] = pktline.FLUSH
  local r, rd = upload_pack(remote, { table.concat(body) })
  local refs, symrefs, peeled = {}, {}, {}
  while true do
    local line = rd:read_line()
    if not line then break end
    local id, name, attrs = line:match("^(%S+) (%S+)(.*)$")
    if not id then util.die("protocol error: bad ls-refs line %q", line) end
    if id ~= "unborn" then refs[name] = id end
    for k, v in attrs:gmatch(" ([%w-]+):(%S+)") do
      if k == "symref-target" then symrefs[name] = v end
      if k == "peeled" then peeled[name] = v end
    end
  end
  r.conn:close()
  return refs, symrefs, peeled
end

-- Read the packfile stream, sending pack bytes to opts.sink.
local function receive_pack_data(rd, opts)
  pktline.demux(rd, opts.sink, opts.progress)
end

-- Fetch with protocol v2.
--   opts: wants, haves, shallows (lists of ids), depth, sink(data), progress(msg)
-- Returns { shallow = {...}, unshallow = {...} }.
function M.fetch_v2(remote, caps, opts)
  local body = v2_header(remote, caps, "fetch")
  local function add(s) body[#body + 1] = pktline.line(s) end
  add("ofs-delta")
  if not util.show_progress() then add("no-progress") end
  for _, id in ipairs(opts.wants) do add("want " .. id) end
  for _, id in ipairs(opts.shallows or {}) do add("shallow " .. id) end
  if opts.depth and opts.depth > 0 then add("deepen " .. opts.depth) end
  for _, id in ipairs(opts.haves or {}) do add("have " .. id) end
  add("done")
  body[#body + 1] = pktline.FLUSH
  local r, rd = upload_pack(remote, { table.concat(body) })
  local res = { shallow = {}, unshallow = {} }
  local sections = { acknowledgments = true, ["shallow-info"] = true,
                     ["wanted-refs"] = true, ["packfile-uris"] = true, packfile = true }
  local section
  while true do
    local kind, data = rd:read()
    if kind == nil or kind == "flush" or kind == "end" then break end
    if kind == "data" then
      local line = data:gsub("\n$", "")
      if line:match("^ERR ") then
        util.die("remote error: %s", line:sub(5))
      elseif sections[line] then
        section = line
        if section == "packfile" then
          receive_pack_data(rd, opts)
          break
        end
      elseif section == "shallow-info" then
        local what, id = line:match("^(%a+) (%x+)$")
        if what == "shallow" then res.shallow[#res.shallow + 1] = id
        elseif what == "unshallow" then res.unshallow[#res.unshallow + 1] = id end
      end
      -- acknowledgments are not expected since "done" was sent
    end
  end
  r.conn:close()
  return res
end

-- Fetch with protocol v0 (stateless RPC, single round with "done").
function M.fetch_v0(remote, caps, opts)
  local want_caps = { "side-band-64k", "ofs-delta", "agent=" .. AGENT }
  if not caps["side-band-64k"] then util.die("server does not support side-band-64k") end
  if not util.show_progress() and caps["no-progress"] then want_caps[#want_caps + 1] = "no-progress" end
  local deepen = (opts.depth and opts.depth > 0) or (opts.shallows and #opts.shallows > 0)
  if deepen then
    if not caps.shallow then util.die("server does not support shallow clients") end
    want_caps[#want_caps + 1] = "shallow"
  end
  local body = {}
  for i, id in ipairs(opts.wants) do
    if i == 1 then
      body[#body + 1] = pktline.line("want " .. id .. " " .. table.concat(want_caps, " "))
    else
      body[#body + 1] = pktline.line("want " .. id)
    end
  end
  for _, id in ipairs(opts.shallows or {}) do body[#body + 1] = pktline.line("shallow " .. id) end
  if opts.depth and opts.depth > 0 then body[#body + 1] = pktline.line("deepen " .. opts.depth) end
  body[#body + 1] = pktline.FLUSH
  for _, id in ipairs(opts.haves or {}) do body[#body + 1] = pktline.line("have " .. id) end
  body[#body + 1] = pktline.line("done")
  local r = request(remote, "POST", "/git-upload-pack", {
    "Content-Type: application/x-git-upload-pack-request",
    "Accept: application/x-git-upload-pack-result",
  }, { table.concat(body) })
  check_status(remote, r, "upload-pack")
  local rd = pktline.reader(function(n) return r.conn:read(n) end)
  local res = { shallow = {}, unshallow = {} }
  if opts.depth and opts.depth > 0 then
    -- shallow/unshallow lines, terminated by a flush
    while true do
      local line = rd:read_line()
      if not line then break end
      local what, id = line:match("^(%a+) (%x+)$")
      if what == "shallow" then res.shallow[#res.shallow + 1] = id
      elseif what == "unshallow" then res.unshallow[#res.unshallow + 1] = id
      else util.die("protocol error: unexpected %q", line) end
    end
  end
  -- ACK/NAK, then the side-band pack stream
  while true do
    local line = rd:read_line()
    if not line then util.die("protocol error: missing NAK/ACK") end
    if line == "NAK" or line:match("^ACK ") then break end
    if line:match("^ERR ") then util.die("remote error: %s", line:sub(5)) end
  end
  receive_pack_data(rd, opts)
  r.conn:close()
  return res
end

-- receive-pack (push, protocol v0).
--   commands: list of { old = id, new = id, ref = name }
--   packfile: path of the pack to send (nil when only deleting)
-- Returns { unpack = "ok"|msg, refs = { [ref] = "ok" | error message } }.
function M.push(remote, caps, commands, packfile, progress)
  local want = { "report-status", "agent=" .. AGENT }
  local sideband = caps["side-band-64k"]
  if sideband then table.insert(want, 2, "side-band-64k") end
  if not util.show_progress() and caps.quiet then want[#want + 1] = "quiet" end
  local head = {}
  for i, c in ipairs(commands) do
    local line = c.old .. " " .. c.new .. " " .. c.ref
    if i == 1 then line = line .. "\0" .. table.concat(want, " ") end
    head[#head + 1] = pktline.line(line)
  end
  head[#head + 1] = pktline.FLUSH
  local body = { table.concat(head) }
  if packfile then body[2] = { file = packfile } end
  local r = request(remote, "POST", "/git-receive-pack", {
    "Content-Type: application/x-git-receive-pack-request",
    "Accept: application/x-git-receive-pack-result",
  }, body)
  check_status(remote, r, "receive-pack")
  local rd = pktline.reader(function(n) return r.conn:read(n) end)
  local status_rd = rd
  if sideband then
    -- report-status lines are pkt-lines inside side-band channel 1
    local buf = {}
    pktline.demux(rd, function(d) buf[#buf + 1] = d end, progress)
    local data, pos = table.concat(buf), 1
    status_rd = pktline.reader(function()
      if pos > #data then return nil end
      local s = data:sub(pos)
      pos = #data + 1
      return s
    end)
  end
  local res = { refs = {} }
  while true do
    local line = status_rd:read_line()
    if not line then break end
    if line:match("^unpack ") then
      res.unpack = line:sub(8)
    elseif line:match("^ok ") then
      res.refs[line:sub(4)] = "ok"
    elseif line:match("^ng ") then
      local ref, msg = line:match("^ng (%S+) (.*)$")
      res.refs[ref or line:sub(4)] = msg or "rejected"
    end
  end
  r.conn:close()
  return res
end

return M
