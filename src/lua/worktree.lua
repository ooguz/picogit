-- Work tree operations: checkout of a tree, fast-forward update between two
-- trees, and building a tree from the work tree (commit -a).
local core = require("picogit.core")
local ignore = require("ignore")
local index = require("index")
local odb_mod = require("odb")
local util = require("util")

local M = {}

local MODE_TREE, MODE_LINK, MODE_GITLINK = "40000", "120000", "160000"
local MODE_FILE, MODE_EXEC = "100644", "100755"
local PERM_FILE, PERM_EXEC = tonumber("644", 8), tonumber("755", 8)

-- Reject tree entry names that could escape the work tree or write into
-- .git (malicious repositories).
local function check_name(name, where)
  local lower = name:lower()
  if name == "" or name == "." or name == ".." or name:find("/", 1, true) or
     name:find("%z") or lower == ".git" or lower:match("^%.git[%. ]+$") then
    util.die("refusing to check out unsafe path '%s'", util.join(where, name))
  end
end

local function read_tree(repo, id, where)
  local entries = odb_mod.parse_tree(repo.odb:read_typed(id, "tree"))
  for _, e in ipairs(entries) do
    check_name(e.name, where)
    e.mode = odb_mod.normalize_mode(e.mode)
  end
  return entries
end

-- Flatten a tree into { path = { mode =, id = } } for every non-tree entry.
function M.flatten(repo, id, prefix, out)
  out = out or {}
  for _, e in ipairs(read_tree(repo, id, prefix)) do
    local path = util.join(prefix, e.name)
    if e.mode == MODE_TREE then
      M.flatten(repo, e.id, path, out)
    else
      out[path] = { mode = e.mode, id = e.id }
    end
  end
  return out
end

-- Remove whatever is at path (file, symlink or directory tree).
local function clear_path(path)
  local st = core.lstat(path)
  if not st then return end
  if st.type == "dir" then
    util.remove_tree(path)
  else
    local ok, err = core.unlink(path)
    if not ok then util.die("cannot remove %s", err) end
  end
end

-- Write one entry to the work tree and return its index entry.
local function write_entry(repo, path, mode, id)
  util.mkdirs(util.dirname(path))
  if mode == MODE_GITLINK then
    if not core.lstat(path) then util.mkdirs(path) end
    util.warn("submodule '%s' is not supported and was not checked out", path)
    return index.gitlink_entry(path, id)
  end
  clear_path(path)
  if mode == MODE_LINK then
    local target = repo.odb:read_typed(id, "blob")
    if repo.symlinks then
      local ok, err = core.symlink(target, path)
      if not ok then util.die("cannot create symlink %s", err) end
    else
      -- like git with core.symlinks=false: a plain file with the target
      local f = assert(io.open(path, "wb"))
      f:write(target)
      f:close()
    end
  else
    repo.odb:checkout_file(id, path, mode == MODE_EXEC and PERM_EXEC or PERM_FILE)
  end
  local st = core.lstat(path)
  if not st then util.die("cannot stat %s after checkout", path) end
  return index.entry(path, index.mode_from_tree(mode), id, st)
end

-- Check out a whole tree into an empty work tree; returns index entries.
function M.checkout(repo, tree_id, progress)
  local entries = {}
  local function walk(id, prefix)
    for _, e in ipairs(read_tree(repo, id, prefix)) do
      local path = util.join(prefix, e.name)
      if e.mode == MODE_TREE then
        util.mkdirs(path)
        walk(e.id, path)
      else
        entries[#entries + 1] = write_entry(repo, path, e.mode, e.id)
        if progress then progress(#entries) end
      end
    end
  end
  walk(tree_id, "")
  return entries
end

-- Changes between two trees: list of { path, old = {mode,id}|nil,
-- new = {mode,id}|nil }, skipping identical subtrees.
function M.diff_trees(repo, old_id, new_id, prefix, out)
  out = out or {}
  if old_id == new_id then return out end
  local old = old_id and read_tree(repo, old_id, prefix) or {}
  local new = new_id and read_tree(repo, new_id, prefix) or {}
  local o, n = {}, {}
  for _, e in ipairs(old) do o[e.name] = e end
  for _, e in ipairs(new) do n[e.name] = e end
  local names = {}
  for k in pairs(o) do names[#names + 1] = k end
  for k in pairs(n) do if not o[k] then names[#names + 1] = k end end
  table.sort(names)
  for _, name in ipairs(names) do
    local a, b = o[name], n[name]
    local path = util.join(prefix, name)
    if a and b and a.mode == b.mode and a.id == b.id then
      -- unchanged
    else
      local a_tree = a and a.mode == MODE_TREE
      local b_tree = b and b.mode == MODE_TREE
      if a_tree or b_tree then
        M.diff_trees(repo, a_tree and a.id or nil, b_tree and b.id or nil, path, out)
      end
      local a_leaf = a and not a_tree and a or nil
      local b_leaf = b and not b_tree and b or nil
      if a_leaf or b_leaf then
        out[#out + 1] = {
          path = path,
          old = a_leaf and { mode = a_leaf.mode, id = a_leaf.id },
          new = b_leaf and { mode = b_leaf.mode, id = b_leaf.id },
        }
      end
    end
  end
  return out
end

local function index_mtime(repo)
  return core.lstat(repo.index_path)
end

-- Is the work tree file at e.name unchanged relative to index entry e?
local function entry_clean(repo, e, racy)
  if e.mode == index.MODE_GITLINK then return true end
  local st = core.lstat(e.name)
  if not st then return false end
  if e.mode == index.MODE_LINK and repo.symlinks then
    if st.type ~= "link" then return false end
  elseif st.type ~= "file" then
    return false
  end
  if repo.filemode and e.mode ~= index.MODE_LINK then
    local exec = st.perm & 64 ~= 0
    if exec ~= (e.mode == index.MODE_EXEC) then return false end
  end
  if index.stat_matches(e, st, racy) then return true end
  local id
  if st.type == "link" then
    id = odb_mod.hash("blob", assert(core.readlink(e.name)))
  else
    id = core.tohex((core.hash_file(e.name)))
  end
  return id == e.id
end

-- Fast-forward the work tree from tree old_id to new_id.
-- `entries` is the current index; returns the updated index entries.
-- Refuses (before touching anything) to overwrite local modifications or
-- untracked files.
function M.update(repo, old_id, new_id, entries)
  local changes = M.diff_trees(repo, old_id, new_id, "")
  local by_name = {}
  for _, e in ipairs(entries) do by_name[e.name] = e end
  local racy = index_mtime(repo)

  local dirty, untracked = {}, {}
  for _, c in ipairs(changes) do
    local e = by_name[c.path]
    if c.old then
      if not e or e.id ~= c.old.id or not entry_clean(repo, e, racy) then
        dirty[#dirty + 1] = c.path
      end
    elseif not e and core.lstat(c.path) then
      local st = core.lstat(c.path)
      -- an existing directory is fine if only tracked files live below it
      if st.type ~= "dir" then untracked[#untracked + 1] = c.path end
    end
  end
  if #dirty > 0 then
    util.die("your local changes to the following files would be overwritten:\n\t%s\n" ..
             "commit them first (picogit commit -a)", table.concat(dirty, "\n\t"))
  end
  if #untracked > 0 then
    util.die("the following untracked work tree files would be overwritten:\n\t%s\n" ..
             "move or remove them first", table.concat(untracked, "\n\t"))
  end

  -- removals first (also clears the way for file <-> directory changes)
  local touched_dirs = {}
  for i = #changes, 1, -1 do
    local c = changes[i]
    if c.old and not c.new then
      local e = by_name[c.path]
      if c.old.mode == MODE_GITLINK then
        core.rmdir(c.path) -- only if empty, like git
      else
        clear_path(c.path)
      end
      by_name[c.path] = nil
      touched_dirs[util.dirname(c.path)] = true
      if e then e.removed = true end
    end
  end
  -- remove directories that became empty, deepest first
  local dirs = {}
  for d in pairs(touched_dirs) do
    while d ~= "" do
      dirs[d] = true
      d = util.dirname(d)
    end
  end
  local dlist = {}
  for d in pairs(dirs) do dlist[#dlist + 1] = d end
  table.sort(dlist, function(a, b) return #a > #b end)
  for _, d in ipairs(dlist) do
    local names = core.readdir(d)
    if names and #names == 0 then core.rmdir(d) end
  end

  for _, c in ipairs(changes) do
    if c.new then
      -- a directory may stand where the new file goes (dir -> file change)
      local st = core.lstat(c.path)
      if st and st.type == "dir" and c.new.mode ~= MODE_GITLINK then
        local names = core.readdir(c.path)
        if names and #names > 0 then
          util.die("cannot replace non-empty directory '%s' with a file", c.path)
        end
        core.rmdir(c.path)
      end
      by_name[c.path] = write_entry(repo, c.path, c.new.mode, c.new.id)
    end
  end

  local out = {}
  for _, e in pairs(by_name) do out[#out + 1] = e end
  return index.sort(out), changes
end

-- Snapshot the work tree for `commit -a`: every tracked file plus all
-- untracked files that are not ignored. Deleted files drop out. Returns new
-- index entries (blobs are written to the object database).
function M.snapshot(repo, entries)
  local by_name, tracked_dirs = {}, {}
  for _, e in ipairs(entries) do
    by_name[e.name] = e
    local d = util.dirname(e.name)
    while d ~= "" and not tracked_dirs[d] do
      tracked_dirs[d] = true
      d = util.dirname(d)
    end
  end
  local racy = index_mtime(repo)
  local ign = ignore.new()
  local excl = util.read_file(repo.gitdir .. "/info/exclude")
  if excl then ign:add(ignore.parse(excl, "")) end

  local out = {}
  local function add_file(path, st)
    local e = by_name[path]
    local mode
    if st.type == "link" then
      mode = index.MODE_LINK
    elseif e and e.mode == index.MODE_LINK and not repo.symlinks then
      mode = index.MODE_LINK -- symlink checked out as a plain file
    elseif repo.filemode then
      mode = st.perm & 64 ~= 0 and index.MODE_EXEC or index.MODE_FILE
    else
      mode = e and (e.mode == index.MODE_EXEC or e.mode == index.MODE_FILE) and e.mode
             or index.MODE_FILE
    end
    if e and e.mode == mode and index.stat_matches(e, st, racy) then
      out[#out + 1] = e -- unchanged: reuse the entry
      return
    end
    local id
    if st.type == "link" then
      id = repo.odb:write("blob", assert(core.readlink(path)))
    else
      id = repo.odb:write_file(path)
    end
    out[#out + 1] = index.entry(path, mode, id, st)
  end

  local function walk(dir, ignored_dir)
    local added = 0
    if not ignored_dir then added = ign:load_dir(dir) end
    local names = core.readdir(dir == "" and "." or dir) or {}
    table.sort(names)
    for _, name in ipairs(names) do
      local path = util.join(dir, name)
      local st = core.lstat(path)
      if dir == "" and name == ".git" then
        -- the repository itself
      elseif not st then
        -- vanished while walking
      elseif by_name[path] and by_name[path].mode == index.MODE_GITLINK then
        out[#out + 1] = by_name[path] -- submodule: keep the recorded commit
      elseif st.type == "dir" then
        local is_ignored = ignored_dir or ign:ignored(path, true)
        if core.lstat(path .. "/.git") then
          if not is_ignored then
            util.warn("skipping '%s': embedded git repositories are not supported", path)
          end
        elseif not is_ignored or tracked_dirs[path] then
          walk(path, is_ignored)
        end
      elseif st.type == "file" or st.type == "link" then
        if by_name[path] or (not ignored_dir and not ign:ignored(path, false)) then
          add_file(path, st)
        end
      end
    end
    ign:pop(added)
  end
  walk("", false)
  return index.sort(out)
end

-- Write tree objects for a sorted list of index entries; returns the root
-- tree id.
function M.write_tree(repo, entries)
  local root = { files = {}, dirs = {}, order = {} }
  for _, e in ipairs(entries) do
    local node = root
    local parts = {}
    for part in e.name:gmatch("[^/]+") do parts[#parts + 1] = part end
    for i = 1, #parts - 1 do
      local p = parts[i]
      if not node.dirs[p] then node.dirs[p] = { files = {}, dirs = {} } end
      node = node.dirs[p]
    end
    node.files[parts[#parts]] = { mode = index.mode_to_tree(e.mode), id = e.id }
  end
  local function write(node)
    local list = {}
    for name, f in pairs(node.files) do
      list[#list + 1] = { mode = f.mode, name = name, id = f.id }
    end
    for name, sub in pairs(node.dirs) do
      list[#list + 1] = { mode = MODE_TREE, name = name, id = write(sub) }
    end
    return repo.odb:write("tree", odb_mod.serialize_tree(list))
  end
  return write(root)
end

return M
