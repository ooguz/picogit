-- SPDX-License-Identifier: GPL-3.0-or-later
-- Test helper for picogit-dev --dev-run: performs one HTTP request with the
-- picogit HTTP stack and prints "<status> <sha1 of body> <body length>".
--   http_fetch.lua [--cacert F] [--insecure] [--post FILE] [--auth USER:PW] URL
local core = require("picogit.core")
local http = require("http")
local util = require("util")

local i, url, post, auth = 1, nil, nil, nil
while i <= #arg do
  local a = arg[i]
  if a == "--cacert" then i = i + 1; http.options.cacert = arg[i]
  elseif a == "--insecure" then http.options.insecure = true
  elseif a == "--post" then i = i + 1; post = arg[i]
  elseif a == "--auth" then i = i + 1; auth = arg[i]
  else url = a end
  i = i + 1
end

local ok, err = pcall(function()
  local u = assert(http.parse_url(url))
  local r = http.request {
    method = post and "POST" or "GET",
    url = url,
    body = post and { "prefix:", { file = post } } or nil,
    headers = post and { "Content-Type: application/octet-stream" } or nil,
    authorization = auth and ("Basic " .. util.base64(auth)),
    auth_origin = http.origin(u),
  }
  local h = core.sha1_new()
  local n = 0
  while true do
    local d = r.conn:read(1000)
    if not d then break end
    h:update(d)
    n = n + #d
  end
  r.conn:close()
  print(r.status, core.tohex(h:digest()), n)
end)
if not ok then
  print("ERROR " .. tostring(err))
  return 1
end
return 0
