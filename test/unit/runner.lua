-- Minimal unit test runner.
--   picogit-dev --dev-run runner.lua <testdir> test_a.lua test_b.lua ...
-- Each test file returns a table of name -> function. Test functions get a
-- helper table `t` with assertion functions and a scratch directory.
local testdir = arg[1]
local pass, fail = 0, 0

local function fmt(v)
  if type(v) == "string" then
    if v:find("[^%g ]") then
      return ("%q"):format(v):gsub("\\\n", "\\n")
    end
    return '"' .. v .. '"'
  end
  return tostring(v)
end

local t = {}
function t.eq(a, b, msg)
  if a ~= b then
    error(("expected %s, got %s%s"):format(fmt(b), fmt(a), msg and (" (" .. msg .. ")") or ""), 2)
  end
end
function t.ok(v, msg)
  if not v then error("assertion failed" .. (msg and (": " .. msg) or ""), 2) end
end
function t.err(fn, pattern)
  local ok, e = pcall(fn)
  if ok then error("expected an error", 2) end
  if pattern and not tostring(e):find(pattern) then
    error("error " .. fmt(tostring(e)) .. " does not match " .. fmt(pattern), 2)
  end
end
function t.tmpdir()
  local p = os.tmpname()
  os.remove(p)
  assert(require("picogit.core").mkdir(p))
  return p
end
function t.readfile(p)
  local f = assert(io.open(p, "rb"))
  local d = f:read("a")
  f:close()
  return d
end
function t.writefile(p, d)
  local f = assert(io.open(p, "wb"))
  f:write(d)
  f:close()
end
t.testdir = testdir

for i = 2, #arg do
  local file = arg[i]
  local tests = dofile(file)
  local names = {}
  for name in pairs(tests) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    local ok, e = xpcall(tests[name], debug.traceback, t)
    local label = file:match("([^/]+)%.lua$") .. "." .. name
    if ok then
      pass = pass + 1
      print("  ok    " .. label)
    else
      fail = fail + 1
      print("  FAIL  " .. label .. "\n        " .. tostring(e):gsub("\n", "\n        "))
    end
  end
end
print(("unit: %d passed, %d failed"):format(pass, fail))
return fail == 0 and 0 or 1
