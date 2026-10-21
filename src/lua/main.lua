-- picogit command line entry point.
local core = require("picogit.core")

local M = {}

function M.main(argv)
  if argv[1] == "--version" then
    print("picogit " .. core.version)
    return 0
  end
  print("hello from embedded Lua (picogit " .. core.version .. ")")
  return 0
end

return M
