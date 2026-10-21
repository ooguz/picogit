-- zlib bindings and streaming object helpers.
local core = require("picogit.core")
local T = {}

local function hex(s) return core.tohex(s) end

function T.inflate_reports_consumed_bytes(t)
  local a = core.deflate("first object")
  local b = core.deflate(string.rep("second ", 1000))
  local buf = a .. b .. "trailing junk"
  local out, used = core.inflate(buf)
  t.eq(out, "first object")
  t.eq(used, #a)
  local out2, used2 = core.inflate(buf, used + 1)
  t.eq(out2, string.rep("second ", 1000))
  t.eq(used2, #b)
end

function T.inflate_errors(t)
  local z = core.deflate("hello world")
  t.err(function() core.inflate(z:sub(1, #z - 3)) end, "truncated")
  t.err(function() core.inflate("not zlib at all") end, "inflate")
end

function T.inflate_empty_and_size_hint(t)
  local z = core.deflate("")
  local out, used = core.inflate(z)
  t.eq(out, "")
  t.eq(used, #z)
  local big = string.rep("0123456789", 10000)
  t.eq((core.inflate(core.deflate(big), 1, #big)), big)
end

local function packfile(t, parts)
  local dir = t.tmpdir()
  local path = dir .. "/p"
  t.writefile(path, table.concat(parts))
  return dir, path
end

function T.pack_inflate_from_file(t)
  local z1 = core.deflate("abc")
  local z2 = core.deflate(string.rep("x", 70000))
  local dir, path = packfile(t, { "HDR!", z1, z2, "tail" })
  local fh = assert(io.open(path, "rb"))
  local data, used = core.pack_inflate(fh, 4, 3)
  t.eq(data, "abc")
  t.eq(used, #z1)
  local data2, used2 = core.pack_inflate(fh, 4 + #z1, 70000)
  t.eq(#data2, 70000)
  t.eq(used2, #z2)
  t.err(function() core.pack_inflate(fh, 4, 2) end, "larger")
  t.err(function() core.pack_inflate(fh, 4, 5) end, "mismatch")
  fh:close()
end

function T.pack_inflate_loose_streams_to_object(t)
  local content = string.rep("blob data\n", 5000)
  local z = core.deflate(content)
  local dir, path = packfile(t, { "PACK", z, "more" })
  local objdir = dir .. "/objects"
  assert(core.mkdir(objdir))
  local fh = assert(io.open(path, "rb"))
  local sha, used = core.pack_inflate_loose(fh, 4, #content, objdir, "blob")
  fh:close()
  t.eq(used, #z)
  t.eq(sha, core.sha1("blob " .. #content .. "\0" .. content))
  local h = hex(sha)
  local typ, data = core.loose_read(objdir .. "/" .. h:sub(1, 2) .. "/" .. h:sub(3))
  t.eq(typ, "blob")
  t.eq(data, content)
end

function T.loose_write_matches_git(t)
  local objdir = t.tmpdir()
  -- `printf 'hello\n' | git hash-object --stdin`
  local sha = core.loose_write(objdir, "blob", "hello\n")
  t.eq(hex(sha), "ce013625030ba8dba906f756967f9e9ca394464a")
  t.eq(hex(core.loose_write(nil, "blob", "")), "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
  local p = objdir .. "/ce/013625030ba8dba906f756967f9e9ca394464a"
  t.eq(core.loose_header(p), "blob")
  t.eq(select(2, core.loose_header(p)), 6)
  -- writing the same object again is a no-op
  t.eq(core.loose_write(objdir, "blob", "hello\n"), sha)
  t.err(function() core.loose_write(objdir, "bogus", "x") end, "invalid object type")
end

function T.hash_file_and_checkout(t)
  local dir = t.tmpdir()
  local objdir = dir .. "/objects"
  assert(core.mkdir(objdir))
  local content = {}
  for i = 1, 20000 do content[i] = string.char(i % 256) end
  content = table.concat(content)
  t.writefile(dir .. "/f", content)
  local sha, size = core.hash_file(dir .. "/f")
  t.eq(size, #content)
  t.eq(sha, core.sha1("blob " .. #content .. "\0" .. content))
  local h = hex(sha)
  t.eq(core.lstat(objdir .. "/" .. h:sub(1, 2)), nil) -- hash only
  t.eq(core.hash_file(dir .. "/f", objdir), sha)
  local obj = objdir .. "/" .. h:sub(1, 2) .. "/" .. h:sub(3)
  t.eq(core.loose_to_file(obj, dir .. "/out", tonumber("755", 8)), #content)
  t.eq(t.readfile(dir .. "/out"), content)
  t.eq(core.lstat(dir .. "/out").perm & 64, 64)
  t.ok(not core.hash_file(dir .. "/missing"))
end

function T.loose_to_pack_entry(t)
  local objdir = t.tmpdir()
  local content = string.rep("z", 300)
  local sha = hex(core.loose_write(objdir, "blob", content))
  local out = objdir .. "/pack"
  local fh = assert(io.open(out, "wb"))
  local typ, size = core.loose_to_pack(objdir .. "/" .. sha:sub(1, 2) .. "/" .. sha:sub(3), fh)
  fh:close()
  t.eq(typ, "blob")
  t.eq(size, 300)
  local entry = t.readfile(out)
  -- type 3 (blob), size 300 = 0b1_0010_1100: low nibble 0xC, then 300>>4 = 18
  t.eq(entry:byte(1), 0x80 | (3 << 4) | 0xC)
  t.eq(entry:byte(2), 18)
  t.eq((core.inflate(entry, 3)), content)
end

return T
