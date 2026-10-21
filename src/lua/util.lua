-- Small helpers shared by the other modules.
local core = require("picogit.core")

local M = {}

-- Raise a user-facing error (no position information).
function M.die(fmt, ...)
  error(select("#", ...) > 0 and fmt:format(...) or fmt, 0)
end

M.verbose = os.getenv("PICOGIT_TRACE") ~= nil and os.getenv("PICOGIT_TRACE") ~= ""
M.quiet = false

-- Should progress be shown? Like git: only when stderr is a terminal.
function M.show_progress()
  return not M.quiet and core.isatty(2)
end

function M.trace(fmt, ...)
  if M.verbose then
    io.stderr:write("trace: ", fmt:format(...), "\n")
  end
end

function M.info(fmt, ...)
  if not M.quiet then
    io.stderr:write(fmt:format(...), "\n")
  end
end

function M.warn(fmt, ...)
  io.stderr:write("warning: ", fmt:format(...), "\n")
end

-- Remove credentials from a URL before it is shown anywhere.
function M.redact_url(url)
  return (url:gsub("^(%a[%w+.-]*://)[^/@]*@", "%1"))
end

function M.percent_decode(s)
  return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
function M.base64(s)
  local out = {}
  for i = 1, #s, 3 do
    local a, b, c = s:byte(i, i + 2)
    local n = (a << 16) | ((b or 0) << 8) | (c or 0)
    local q = {}
    for j = 1, 4 do
      local idx = (n >> (6 * (4 - j))) & 63
      q[j] = b64chars:sub(idx + 1, idx + 1)
    end
    if not b then q[3] = "=" end
    if not c then q[4] = "=" end
    out[#out + 1] = table.concat(q)
  end
  return table.concat(out)
end

M.tohex, M.fromhex = core.tohex, core.fromhex
M.ZERO_ID = string.rep("0", 40)

function M.is_hex_id(s)
  return type(s) == "string" and #s == 40 and s:match("^%x+$") ~= nil
end

-- Path helpers ------------------------------------------------------------

function M.join(a, b)
  if a == "" or a == "." then return b end
  return a .. "/" .. b
end

function M.dirname(p)
  return p:match("^(.*)/[^/]*$") or ""
end

function M.basename(p)
  return p:match("([^/]*)$")
end

function M.exists(p)
  return core.lstat(p) ~= nil
end

function M.isdir(p)
  local st = core.stat(p)
  return st ~= nil and st.type == "dir"
end

-- mkdir -p
function M.mkdirs(p)
  if p == "" or p == "." or p == "/" then return true end
  local st = core.stat(p)
  if st then
    if st.type ~= "dir" then M.die("%s exists and is not a directory", p) end
    return true
  end
  M.mkdirs(M.dirname(p))
  local ok, err, errno = core.mkdir(p)
  if not ok and not core.stat(p) then M.die("cannot create directory %s", err) end
  return true
end

-- rm -rf
function M.remove_tree(p)
  local st = core.lstat(p)
  if not st then return end
  if st.type == "dir" then
    for _, name in ipairs(core.readdir(p) or {}) do
      M.remove_tree(p .. "/" .. name)
    end
    core.rmdir(p)
  else
    core.unlink(p)
  end
end

function M.read_file(p)
  local f, err = io.open(p, "rb")
  if not f then return nil, err end
  local d = f:read("a")
  f:close()
  return d
end

-- Write a file atomically through a temporary file and rename.
function M.write_file(p, data, mode)
  local tmp = p .. ".lock"
  local f, err = io.open(tmp, "wb")
  if not f then M.die("cannot write %s", err) end
  f:write(data)
  if not f:close() then M.die("cannot write %s", p) end
  if mode then core.chmod(tmp, mode) end
  local ok, rerr = core.rename(tmp, p)
  if not ok then
    core.unlink(tmp)
    M.die("cannot write %s", rerr)
  end
end

-- A unique temporary path next to `base` (same file system as the target,
-- never /tmp which is RAM on most routers).
function M.temp_path(base)
  return base .. "_" .. core.tohex(core.random_bytes(6))
end

return M
