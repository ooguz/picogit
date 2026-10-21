-- Reading .git/config (git's INI dialect) and writing a fresh one.
--
-- Keys are addressed as "section.key" or "section.subsection.key"; section
-- and key names are case-insensitive, subsections are case-sensitive.
local util = require("util")

local M = {}

local function parse_value(raw)
  local out, i, inq = {}, 1, false
  -- strip leading whitespace
  raw = raw:gsub("^%s+", "")
  local trailing_ws = 0
  while i <= #raw do
    local c = raw:sub(i, i)
    if c == '"' then
      inq = not inq
      trailing_ws = 0
    elseif c == "\\" then
      local n = raw:sub(i + 1, i + 1)
      local map = { n = "\n", t = "\t", b = "\b", ['"'] = '"', ["\\"] = "\\" }
      if map[n] then out[#out + 1] = map[n] end
      i = i + 1
      trailing_ws = 0
    elseif not inq and (c == ";" or c == "#") then
      break
    else
      out[#out + 1] = c
      if not inq and c:match("%s") then trailing_ws = trailing_ws + 1 else trailing_ws = 0 end
    end
    i = i + 1
  end
  local s = table.concat(out)
  if trailing_ws > 0 then s = s:sub(1, #s - trailing_ws) end
  return s
end

-- parse(text) -> table mapping full key names to the last value
-- ("remote.origin.url" = "...").
function M.parse(text)
  local values = {}
  local section
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    line = line:gsub("\r$", "")
    local s = line:match("^%s*%[(.-)%]")
    if s then
      local name, sub = s:match('^([%w.-]+)%s+"(.*)"$')
      if name then
        section = name:lower() .. "." .. sub:gsub('\\(.)', "%1")
      else
        section = s:lower()
      end
      line = line:gsub("^%s*%[.-%]", "")
    end
    local key, rest = line:match("^%s*([%a][%w-]*)%s*(.*)$")
    if key and section then
      local v
      if rest:sub(1, 1) == "=" then
        v = parse_value(rest:sub(2))
      elseif rest == "" or rest:match("^[;#]") then
        v = true -- bare key means true
      end
      if v ~= nil then values[section .. "." .. key:lower()] = v end
    end
  end
  return values
end

function M.load(gitdir)
  local text = util.read_file(gitdir .. "/config") or ""
  local cfg = { values = M.parse(text) }
  function cfg:get(key)
    -- lower-case the section and the key, keep the subsection
    local sec, rest = key:match("^([^.]+)%.(.+)$")
    local sub, k = rest:match("^(.*)%.([^.]+)$")
    local full = sec:lower() .. "." .. (sub and sub .. "." or "") .. (k or rest):lower()
    return self.values[full]
  end
  function cfg:get_bool(key, default)
    local v = self:get(key)
    if v == nil then return default end
    if v == true then return true end
    v = tostring(v):lower()
    if v == "true" or v == "yes" or v == "on" or v == "1" then return true end
    if v == "false" or v == "no" or v == "off" or v == "0" or v == "" then return false end
    return default
  end
  return cfg
end

local function quote(v)
  v = tostring(v)
  if v:match('^[%w%p ]*$') and not v:match('[";#\\]') and not v:match("^%s") and not v:match("%s$") then
    return v
  end
  return '"' .. v:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\t", "\\t") .. '"'
end

-- serialize{ { "core", nil, { {"bare", "false"}, ... } }, { "remote", "origin", {...} } }
function M.serialize(sections)
  local out = {}
  for _, sec in ipairs(sections) do
    local name, sub, entries = sec[1], sec[2], sec[3]
    if sub then
      out[#out + 1] = ('[%s "%s"]'):format(name, sub:gsub('\\', '\\\\'):gsub('"', '\\"'))
    else
      out[#out + 1] = "[" .. name .. "]"
    end
    for _, kv in ipairs(entries) do
      out[#out + 1] = "\t" .. kv[1] .. " = " .. quote(kv[2])
    end
  end
  return table.concat(out, "\n") .. "\n"
end

return M
