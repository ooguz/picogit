-- Object database, pack read/write, index and config round trips.
local core = require("picogit.core")
local odb_mod = require("odb")
local pack = require("pack")
local index = require("index")
local config = require("config")
local ignore = require("ignore")
local T = {}

local function new_odb(t)
  local dir = t.tmpdir()
  assert(core.mkdir(dir .. "/objects"))
  return odb_mod.new(dir), dir
end

local function varint_hdr(typ, size)
  local out = { (typ << 4) | (size & 15) }
  size = size >> 4
  while size > 0 do
    out[#out] = out[#out] | 0x80
    out[#out + 1] = size & 0x7f
    size = size >> 7
  end
  return string.char(table.unpack(out))
end

local function delta_varint(n)
  local out = {}
  repeat
    local b = n & 0x7f
    n = n >> 7
    if n > 0 then b = b | 0x80 end
    out[#out + 1] = string.char(b)
  until n == 0
  return table.concat(out)
end

local function finish_pack(entries)
  local body = string.pack(">c4I4I4", "PACK", 2, #entries) .. table.concat(entries)
  return body .. core.sha1(body)
end

function T.tree_and_commit_roundtrip(t)
  local entries = {
    { mode = "100644", name = "b.txt", id = string.rep("1", 40) },
    { mode = "40000", name = "a", id = string.rep("2", 40) },
    { mode = "100755", name = "a.sh", id = string.rep("3", 40) },
    { mode = "40000", name = "a-b", id = string.rep("4", 40) },
  }
  local data = odb_mod.serialize_tree(entries)
  local back = odb_mod.parse_tree(data)
  -- git order: "a-b" < "a.sh" < "a/" < "b.txt"
  t.eq(back[1].name, "a-b"); t.eq(back[2].name, "a.sh")
  t.eq(back[3].name, "a"); t.eq(back[4].name, "b.txt")
  t.eq(back[3].mode, "40000")
  t.eq(back[1].id, string.rep("4", 40))
  local c = {
    tree = string.rep("a", 40), parents = { string.rep("b", 40) },
    author = "A U Thor <a@example.com> 1700000000 +0300",
    committer = "C O Mitter <c@example.com> 1700000001 -0130",
    message = "subject\n\nbody\n",
  }
  local cc = odb_mod.parse_commit(odb_mod.serialize_commit(c))
  t.eq(cc.tree, c.tree); t.eq(cc.parents[1], c.parents[1])
  t.eq(cc.author, c.author); t.eq(cc.committer, c.committer); t.eq(cc.message, c.message)
  -- the empty tree has a well-known id
  t.eq(odb_mod.hash("tree", ""), "4b825dc642cb6eb9a060e54bf8d69288fbee4904")
end

function T.pack_write_then_unpack(t)
  local src = new_odb(t)
  local ids = {
    src:write("blob", "hello\n"),
    src:write("blob", string.rep("\0\1\2\255", 100000)),
    src:write("blob", ""),
  }
  ids[#ids + 1] = src:write("tree", odb_mod.serialize_tree {
    { mode = "100644", name = "hello", id = ids[1] },
    { mode = "100644", name = "big", id = ids[2] },
  })
  local _, dir = new_odb(t)
  local path = dir .. "/test.pack"
  pack.write(path, src, ids)
  local dst = new_odb(t)
  t.eq(pack.unpack(path, dst), #ids)
  for _, id in ipairs(ids) do
    local t1, d1 = src:read(id)
    local t2, d2 = dst:read(id)
    t.eq(t2, t1); t.eq(d2, d1)
  end
end

function T.pack_ofs_and_ref_deltas(t)
  local base = "line one\nline two\nline three\n"
  local target = "line one\nline 2\nline three\n"
  -- delta: copy "line one\nline " (14 bytes), insert "2\n", copy "line three\n"
  local d = delta_varint(#base) .. delta_varint(#target) ..
            string.char(0x80 | 0x10, 14) .. string.char(2) .. "2\n" ..
            string.char(0x80 | 0x01 | 0x10, 18, 11)
  local e1 = varint_hdr(3, #base) .. core.deflate(base)
  local off2 = 12 + #e1
  -- OFS_DELTA: negative offset back to entry 1
  local rel = off2 - 12
  local ofs = string.char(rel) -- < 128, single byte
  local e2 = varint_hdr(6, #d) .. ofs .. core.deflate(d)
  -- REF_DELTA against the result of entry 2, placed *before* nothing else:
  -- a delta whose base appears later in the pack must be resolved too.
  local target2 = target .. "line four\n"
  local d2 = delta_varint(#target) .. delta_varint(#target2) ..
             string.char(0x80 | 0x10, #target) .. string.char(10) .. "line four\n"
  local target_id = odb_mod.hash("blob", target)
  local e3 = varint_hdr(7, #d2) .. core.fromhex(target_id) .. core.deflate(d2)
  local _, dir = new_odb(t)
  local path = dir .. "/d.pack"
  -- order: ref-delta first (base not yet known), then base, then ofs-delta
  local pk = string.pack(">c4I4I4", "PACK", 2, 3)
  local ref_first = e3
  local base_entry = e1
  local ofs_rel = 12 + #ref_first + #base_entry - (12 + #ref_first)
  local ofs_entry = varint_hdr(6, #d) .. string.char(ofs_rel) .. core.deflate(d)
  local body = pk .. ref_first .. base_entry .. ofs_entry
  t.writefile(path, body .. core.sha1(body))
  local o = new_odb(t)
  t.eq(pack.unpack(path, o), 3)
  t.eq(select(2, o:read(odb_mod.hash("blob", base))), base)
  t.eq(select(2, o:read(target_id)), target)
  t.eq(select(2, o:read(odb_mod.hash("blob", target2))), target2)
  -- the simple layout (base, then OFS_DELTA) as well
  local o2 = new_odb(t)
  t.writefile(path, finish_pack { e1, e2 })
  t.eq(pack.unpack(path, o2), 2)
  t.eq(select(2, o2:read(target_id)), target)
end

function T.pack_corruption_detected(t)
  local _, dir = new_odb(t)
  local path = dir .. "/bad.pack"
  local p = finish_pack { varint_hdr(3, 5) .. core.deflate("hello") }
  t.writefile(path, p:sub(1, 20) .. "X" .. p:sub(22))
  t.err(function() pack.unpack(path, new_odb(t)) end, "checksum")
  t.writefile(path, "PACK")
  t.err(function() pack.unpack(path, new_odb(t)) end, "too small")
  -- REF_DELTA whose base never shows up
  local d = delta_varint(1) .. delta_varint(1) .. string.char(1) .. "x"
  t.writefile(path, finish_pack { varint_hdr(7, #d) .. string.rep("\7", 20) .. core.deflate(d) })
  t.err(function() pack.unpack(path, new_odb(t)) end, "missing base")
end

function T.quarantine_migrate_and_discard(t)
  local o = new_odb(t)
  local keep = o:write("blob", "existing\n")
  local q = o:quarantine()
  local new = q:write("blob", "new object\n")
  t.ok(q:has(keep), "quarantine sees the main objects")
  t.ok(not o:has(new), "main does not see quarantined objects")
  q:migrate()
  t.ok(o:has(new))
  local q2 = o:quarantine()
  local gone = q2:write("blob", "dropped\n")
  q2:discard()
  t.ok(not o:has(gone))
  t.eq(core.lstat(q2.dir), nil)
end

function T.index_roundtrip(t)
  local dir = t.tmpdir()
  local st = { ctime = 1700000000, ctime_ns = 123, mtime = 1700000001, mtime_ns = 456,
               dev = 2049, ino = 99, uid = 1000, gid = 1000, size = 6 }
  local long = string.rep("d/", 2100) .. "f" -- name longer than 0xfff
  local entries = {
    index.entry("b", index.MODE_FILE, string.rep("1", 40), st),
    index.entry("a/x.sh", index.MODE_EXEC, string.rep("2", 40), st),
    index.entry("link", index.MODE_LINK, string.rep("3", 40), st),
    index.gitlink_entry("sub", string.rep("4", 40)),
    index.entry(long, index.MODE_FILE, string.rep("5", 40), st),
  }
  index.write(dir .. "/index", entries)
  local back = index.read(dir .. "/index")
  t.eq(#back, 5)
  t.eq(back[1].name, "a/x.sh")
  t.eq(back[1].mode, index.MODE_EXEC)
  t.eq(back[2].name, "b")
  t.eq(back[2].mtime_ns, 456)
  t.eq(back[2].ino, 99)
  t.eq(back[3].name, long)
  t.eq(back[5].mode, index.MODE_GITLINK)
  t.eq(back[5].id, string.rep("4", 40))
  -- a damaged index is rejected
  local data = t.readfile(dir .. "/index")
  t.writefile(dir .. "/index", data:sub(1, 30) .. "Z" .. data:sub(32))
  t.err(function() index.read(dir .. "/index") end, "checksum")
end

function T.config_parse(t)
  local c = config.parse([[
# comment
[core]
	repositoryformatversion = 0
	FileMode = false ; trailing comment
	bare
[remote "origin"]
	url = "https://example.com/r.git"
	fetch = +refs/heads/main:refs/remotes/origin/main
[user]
	name = "Jane \"JD\" Doe"   # comment
	email = jane@example.com
[Branch "Main"]
	remote = origin
]])
  t.eq(c["core.filemode"], "false")
  t.eq(c["core.bare"], true)
  t.eq(c["remote.origin.url"], "https://example.com/r.git")
  t.eq(c["user.name"], 'Jane "JD" Doe')
  t.eq(c["branch.Main.remote"], "origin")
  local text = config.serialize { { "user", nil, { { "name", 'a "b"' } } } }
  t.eq(config.parse(text)["user.name"], 'a "b"')
end

function T.ignore_patterns(t)
  local g = ignore.glob_match
  t.ok(g("*.o", "x.o")); t.ok(not g("*.o", "d/x.o"))
  t.ok(g("a?c", "abc")); t.ok(not g("a?c", "a/c"))
  t.ok(g("[a-c]x", "bx")); t.ok(not g("[!a-c]x", "bx")); t.ok(g("[!a-c]x", "dx"))
  t.ok(g("**/foo", "foo")); t.ok(g("**/foo", "a/b/foo"))
  t.ok(g("a/**/b", "a/b")); t.ok(g("a/**/b", "a/x/y/b"))
  t.ok(g("abc/**", "abc/x/y")); t.ok(not g("abc/**", "abc"))
  t.ok(g("\\*x", "*x")); t.ok(not g("\\*x", "ax"))

  local s = ignore.new()
  s:add(ignore.parse("*.log\n!keep.log\nbuild/\n/root-only\ndoc/*.txt\n# c\n\n", ""))
  t.ok(s:ignored("a.log", false))
  t.ok(s:ignored("sub/a.log", false))
  t.ok(not s:ignored("keep.log", false))
  t.ok(s:ignored("build", true)); t.ok(not s:ignored("build", false))
  t.ok(s:ignored("root-only", false)); t.ok(not s:ignored("x/root-only", false))
  t.ok(s:ignored("doc/a.txt", false)); t.ok(not s:ignored("doc/x/a.txt", false))
  local n = s:add(ignore.parse("*.tmp\n!a.log\n", "sub"))
  t.ok(s:ignored("sub/x.tmp", false)); t.ok(not s:ignored("x.tmp", false))
  t.ok(not s:ignored("sub/a.log", false))
  s:pop(n)
  t.ok(s:ignored("sub/a.log", false))
end

return T
