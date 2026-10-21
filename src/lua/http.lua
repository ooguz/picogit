-- HTTP requests on top of core.http_request: URL parsing, redirects,
-- credentials and error reporting.
local core = require("picogit.core")
local util = require("util")

local M = {}

M.options = {
  cacert = nil,
  insecure = false,
  timeout = tonumber(os.getenv("PICOGIT_TIMEOUT") or "") or 120,
}

M.user_agent = "git/2.0 (picogit/" .. core.version .. ")"

-- parse_url("https://user:pw@host:8443/path?q") ->
--   { scheme, user, password, host, port, path }
function M.parse_url(url)
  local scheme, rest = url:match("^(%a[%w+.-]*)://(.*)$")
  if not scheme then return nil, "not a URL" end
  scheme = scheme:lower()
  if scheme ~= "http" and scheme ~= "https" then
    return nil, "unsupported protocol '" .. scheme .. "' (only http and https are supported)"
  end
  local authority, path = rest:match("^([^/?#]*)(.*)$")
  local u = { scheme = scheme }
  local userinfo, hostport = authority:match("^(.*)@([^@]*)$")
  if userinfo then
    local user, pw = userinfo:match("^([^:]*):(.*)$")
    u.user = util.percent_decode(user or userinfo)
    u.password = pw and util.percent_decode(pw)
  else
    hostport = authority
  end
  local host, port = hostport:match("^%[([^%]]+)%]:?(%d*)$")
  if not host then
    host, port = hostport:match("^([^:]*):?(%d*)$")
  end
  if not host or host == "" then return nil, "missing host name" end
  u.host = host
  u.port = tonumber(port) or (scheme == "https" and 443 or 80)
  path = path:gsub("#.*$", "")
  if path == "" then path = "/" end
  if path:sub(1, 1) == "?" then path = "/" .. path end
  u.path = path
  return u
end

-- Resolve a Location header against the URL it came from.
function M.resolve(base, loc)
  if loc:match("^%a[%w+.-]*://") then return loc end
  local origin = base:match("^(%a[%w+.-]*://[^/?#]*)")
  if loc:sub(1, 2) == "//" then
    return base:match("^(%a[%w+.-]*:)") .. loc
  elseif loc:sub(1, 1) == "/" then
    return origin .. loc
  end
  local dir = base:match("^([^?#]*/)") or (origin .. "/")
  return dir .. loc
end

-- request{ method=, url=, headers={...}, body={...},
--          authorization=, auth_host=, follow=true }
-- Returns { conn, status, headers, url } where url is the final URL after
-- redirects. The Authorization header is only ever sent to auth_host.
function M.request(req)
  local url = req.url
  local method = req.method or "GET"
  for _ = 1, 10 do
    local u, perr = M.parse_url(url)
    if not u then util.die("invalid URL '%s': %s", util.redact_url(url), perr) end
    local headers = { "User-Agent: " .. M.user_agent }
    for _, h in ipairs(req.headers or {}) do headers[#headers + 1] = h end
    if req.authorization and u.host == req.auth_host then
      headers[#headers + 1] = "Authorization: " .. req.authorization
    end
    util.trace("http: %s %s", method, util.redact_url(url))
    local conn, status, rh, line = core.http_request {
      host = u.host, port = u.port, tls = u.scheme == "https",
      method = method, path = u.path, headers = headers, body = req.body,
      cacert = M.options.cacert, insecure = M.options.insecure,
      timeout = M.options.timeout,
    }
    if not conn then
      util.die("unable to access '%s': %s", util.redact_url(url), status)
    end
    util.trace("http: <- %s", line)
    local loc = rh.location
    local redirect = (status == 301 or status == 302 or status == 303 or
                      status == 307 or status == 308) and loc
    if not redirect or req.follow == false then
      return { conn = conn, status = status, headers = rh, url = url }
    end
    conn:close()
    if method ~= "GET" and status ~= 307 and status ~= 308 then
      util.die("unable to access '%s': redirected with status %d", util.redact_url(url), status)
    end
    url = M.resolve(url, loc)
    if url:match("^http://") and req.url:match("^https://") then
      util.die("refusing to follow a redirect from https to http (%s)", util.redact_url(url))
    end
  end
  util.die("unable to access '%s': too many redirects", util.redact_url(req.url))
end

-- Read a whole (small) response body.
function M.read_all(conn, limit)
  local parts, n = {}, 0
  while true do
    local d = conn:read(65536)
    if not d then break end
    n = n + #d
    if limit and n > limit then util.die("HTTP response too large") end
    parts[#parts + 1] = d
  end
  conn:close()
  return table.concat(parts)
end

return M
