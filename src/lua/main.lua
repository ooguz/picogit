-- SPDX-License-Identifier: GPL-3.0-or-later
-- picogit command line: argument parsing and command dispatch.
local core = require("picogit.core")
local http = require("http")
local util = require("util")

local M = {}

local USAGE = [[
usage: picogit [options] <command> [<args>]

commands:
  clone [--depth N] [--branch B] <url> [<dir>]
                     clone a repository (default --depth 1; --depth 0 = full)
  pull               fast-forward the current branch from its remote
  commit -a -m MSG   commit all changes in the work tree (new files included,
                     .gitignore respected)
  push               push the current branch (fast-forward only)

options:
  -C <dir>           run as if started in <dir>
  --cacert <file>    trust the CA certificates in <file> instead of the
                     built-in Mozilla bundle
  --insecure         do not verify TLS certificates
  -q, --quiet        suppress progress output
  --version          print the version
  -h, --help         show this help

environment:
  PICOGIT_TOKEN, PICOGIT_USERNAME   HTTP credentials (also: URL, ~/.netrc)
  PICOGIT_AUTHOR_NAME, PICOGIT_AUTHOR_EMAIL   commit identity
  PICOGIT_TIMEOUT    network timeout in seconds (default 120)
  PICOGIT_TRACE=1    protocol trace on stderr (credentials are not shown)
]]

local function usage_error(fmt, ...)
  util.die((fmt .. "\n(run 'picogit --help' for usage)"):format(...))
end

-- Parse options for a command: spec maps option names to "flag" or
-- "value"; short options may be combined ("-am msg").
local function parse(args, i, spec)
  local opts, pos = {}, {}
  while i <= #args do
    local a = args[i]
    if a == "--" then
      for j = i + 1, #args do pos[#pos + 1] = args[j] end
      break
    elseif a:sub(1, 2) == "--" then
      local name, val = a:match("^%-%-([^=]+)=(.*)$")
      name = name or a:sub(3)
      local kind = spec["--" .. name]
      if not kind then usage_error("unknown option '%s'", a) end
      if kind == "value" then
        if not val then
          i = i + 1
          val = args[i]
          if not val then usage_error("option '%s' needs a value", a) end
        end
        opts[name] = val
      else
        if val then usage_error("option '--%s' takes no value", name) end
        opts[name] = true
      end
    elseif a:sub(1, 1) == "-" and #a > 1 then
      local j = 2
      while j <= #a do
        local ch = a:sub(j, j)
        local kind = spec["-" .. ch]
        if not kind then usage_error("unknown option '-%s'", ch) end
        if kind == "value" then
          local val = a:sub(j + 1)
          if val == "" then
            i = i + 1
            val = args[i]
            if not val then usage_error("option '-%s' needs a value", ch) end
          end
          opts[ch] = val
          break
        end
        opts[ch] = true
        j = j + 1
      end
    else
      pos[#pos + 1] = a
    end
    i = i + 1
  end
  return opts, pos
end

local commands = {}

function commands.clone(args, i)
  local o, pos = parse(args, i, {
    ["--depth"] = "value", ["--branch"] = "value", ["-b"] = "value",
  })
  if #pos < 1 or #pos > 2 then usage_error("usage: picogit clone [--depth N] [--branch B] <url> [<dir>]") end
  local depth = tonumber(o.depth or "1")
  if not depth or depth < 0 or depth ~= math.floor(depth) then
    usage_error("invalid --depth '%s'", o.depth)
  end
  return require("commands").clone {
    url = pos[1], dir = pos[2], depth = math.floor(depth), branch = o.branch or o.b,
  }
end

function commands.pull(args, i)
  local _, pos = parse(args, i, {})
  if #pos > 0 then usage_error("picogit pull takes no arguments (it always pulls the upstream branch)") end
  return require("commands").pull()
end

function commands.commit(args, i)
  local o, pos = parse(args, i, {
    ["-a"] = "flag", ["--all"] = "flag", ["-m"] = "value", ["--message"] = "value",
  })
  if #pos > 0 then usage_error("picogit commit does not take paths") end
  if not (o.a or o.all) then
    usage_error("only 'picogit commit -a -m <message>' is supported (there is no staging area)")
  end
  local msg = o.m or o.message
  if not msg then usage_error("a commit message is required (-m)") end
  return require("commands").commit { message = msg }
end

function commands.push(args, i)
  local _, pos = parse(args, i, {})
  if #pos > 0 then usage_error("picogit push takes no arguments (it pushes the current branch)") end
  return require("commands").push()
end

function M.main(args)
  -- collect a little earlier than Lua's default (pause 200): lower peak
  -- memory on small devices for a negligible CPU cost
  collectgarbage("incremental", 150, 100)
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "--version" then
      print("picogit " .. core.version)
      return 0
    elseif a == "-h" or a == "--help" or a == "help" then
      io.write(USAGE)
      return 0
    elseif a == "-q" or a == "--quiet" then
      util.quiet = true
    elseif a == "--insecure" then
      http.options.insecure = true
    elseif a == "--cacert" or a == "-C" then
      local v = args[i + 1]
      if not v then usage_error("option '%s' needs a value", a) end
      if a == "-C" then
        local ok, err = core.chdir(v)
        if not ok then util.die("cannot change to %s", err) end
      else
        http.options.cacert = v
      end
      i = i + 1
    elseif a:match("^%-%-cacert=") then
      http.options.cacert = a:sub(10)
    elseif a:sub(1, 1) == "-" then
      usage_error("unknown option '%s'", a)
    else
      break
    end
    i = i + 1
  end
  local cmd = args[i]
  if not cmd then
    io.stderr:write(USAGE)
    return 1
  end
  local fn = commands[cmd]
  if not fn then usage_error("'%s' is not a picogit command", cmd) end
  -- global options may also follow the command ("clone --insecure URL")
  local rest, j = {}, i + 1
  while j <= #args do
    local a = args[j]
    if a == "--insecure" then
      http.options.insecure = true
    elseif a == "-q" or a == "--quiet" then
      util.quiet = true
    elseif a:match("^%-%-cacert=") then
      http.options.cacert = a:sub(10)
    elseif a == "--cacert" then
      j = j + 1
      http.options.cacert = args[j] or usage_error("option '--cacert' needs a value")
    else
      rest[#rest + 1] = a
    end
    j = j + 1
  end
  return fn(rest, 1)
end

return M
