-- .gitignore matching (the subset of gitignore(5) used in practice):
-- comments, "!" negation, trailing "/" for directories, anchoring by a
-- leading or inner "/", "*", "?", "[...]" classes, "\" escapes and "**".
local util = require("util")

local M = {}

local function class_match(p, pi, ch)
  -- p:sub(pi, pi) == "["; returns matched?, index after "]" (or nil)
  local i = pi + 1
  local negate = false
  local c = p:sub(i, i)
  if c == "!" or c == "^" then
    negate = true
    i = i + 1
  end
  local matched, first = false, true
  while i <= #p do
    c = p:sub(i, i)
    if c == "]" and not first then
      if negate then matched = not matched end
      return matched, i + 1
    end
    first = false
    if c == "\\" then
      i = i + 1
      c = p:sub(i, i)
    end
    if p:sub(i + 1, i + 1) == "-" and p:sub(i + 2, i + 2) ~= "]" and i + 2 <= #p then
      local hi = p:sub(i + 2, i + 2)
      if hi == "\\" then
        i = i + 1
        hi = p:sub(i + 2, i + 2)
      end
      if ch >= c and ch <= hi then matched = true end
      i = i + 3
    else
      if ch == c then matched = true end
      i = i + 1
    end
  end
  return nil -- unterminated class: no match
end

local function match(p, pi, s, si)
  while pi <= #p do
    local c = p:sub(pi, pi)
    if c == "*" then
      local pj = pi
      while p:sub(pj, pj) == "*" do pj = pj + 1 end
      local double = pj - pi >= 2
      local full = double and (pi == 1 or p:sub(pi - 1, pi - 1) == "/") and
                   (pj > #p or p:sub(pj, pj) == "/")
      if full then
        if pj > #p then return true end -- "dir/**": everything inside
        -- "**/": zero or more leading directories
        if match(p, pj + 1, s, si) then return true end
        for k = si, #s do
          if s:sub(k, k) == "/" and match(p, pj + 1, s, k + 1) then return true end
        end
        return false
      end
      for k = si, #s + 1 do
        if match(p, pj, s, k) then return true end
        if k <= #s and s:sub(k, k) == "/" then break end
      end
      return false
    elseif c == "?" then
      if si > #s or s:sub(si, si) == "/" then return false end
      pi, si = pi + 1, si + 1
    elseif c == "[" then
      if si > #s or s:sub(si, si) == "/" then return false end
      local ok, nexti = class_match(p, pi, s:sub(si, si))
      if not ok then return false end
      pi, si = nexti, si + 1
    else
      if c == "\\" then
        pi = pi + 1
        c = p:sub(pi, pi)
      end
      if s:sub(si, si) ~= c then return false end
      pi, si = pi + 1, si + 1
    end
  end
  return si > #s
end

function M.glob_match(pattern, str)
  return match(pattern, 1, str, 1)
end

-- Parse the lines of an ignore file defined in directory `base` ("" for
-- the repository root).
function M.parse(text, base)
  local rules = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    line = line:gsub("\r$", "")
    -- trailing spaces are ignored unless escaped
    line = line:gsub("([^\\])%s+$", "%1")
    if line ~= "" and line:sub(1, 1) ~= "#" then
      local r = { base = base }
      if line:sub(1, 1) == "!" then
        r.negate = true
        line = line:sub(2)
      elseif line:sub(1, 2) == "\\!" or line:sub(1, 2) == "\\#" then
        line = line:sub(2)
      end
      if line:sub(-1) == "/" then
        r.dir_only = true
        line = line:sub(1, -2)
      end
      if line:find("/", 1, true) then
        r.anchored = true
        line = line:gsub("^/", "")
      end
      r.pattern = line
      if line ~= "" then rules[#rules + 1] = r end
    end
  end
  return rules
end

local Stack = {}
Stack.__index = Stack

function M.new()
  return setmetatable({ rules = {} }, Stack)
end

function Stack:add(rules)
  for _, r in ipairs(rules) do self.rules[#self.rules + 1] = r end
  return #rules
end

-- Remove the last n rules (when leaving a directory).
function Stack:pop(n)
  for _ = 1, n do self.rules[#self.rules] = nil end
end

-- Load base/.gitignore if present; returns the number of rules added.
function Stack:load_dir(base)
  local data = util.read_file(util.join(base, ".gitignore"))
  if not data then return 0 end
  return self:add(M.parse(data, base))
end

-- Is the path (relative to the repository root) ignored?
function Stack:ignored(path, is_dir)
  for i = #self.rules, 1, -1 do
    local r = self.rules[i]
    if not r.dir_only or is_dir then
      local rel
      if r.base == "" then
        rel = path
      elseif path:sub(1, #r.base + 1) == r.base .. "/" then
        rel = path:sub(#r.base + 2)
      end
      if rel then
        local subject = r.anchored and rel or util.basename(rel)
        if match(r.pattern, 1, subject, 1) then
          return not r.negate
        end
      end
    end
  end
  return false
end

return M
