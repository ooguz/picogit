-- The picogit commands: clone, pull, commit -a, push.
local core = require("picogit.core")
local fetch = require("fetch")
local index = require("index")
local odb_mod = require("odb")
local pack = require("pack")
local pktline = require("pktline")
local repo_mod = require("repo")
local transport = require("transport")
local util = require("util")
local worktree = require("worktree")

local M = {}

local function short(id)
  return id and id:sub(1, 7) or "0000000"
end

-- Is `anc` reachable from `desc` through parent links? The walk stops at
-- shallow boundaries and at commits missing from the object database.
local function is_ancestor(odb, shallow, anc, desc)
  if anc == desc then return true end
  local seen, queue, head = { [desc] = true }, { desc }, 1
  while queue[head] do
    local id = queue[head]
    head = head + 1
    if not shallow[id] and odb:has(id) then
      for _, p in ipairs(odb_mod.parse_commit(odb:read_typed(id, "commit")).parents) do
        if p == anc then return true end
        if not seen[p] then
          seen[p] = true
          queue[#queue + 1] = p
        end
      end
    end
  end
  return false
end

local function commit_tree(odb, id)
  return odb_mod.parse_commit(odb:read_typed(id, "commit")).tree
end

local function set_list(set)
  local l = {}
  for k in pairs(set) do l[#l + 1] = k end
  table.sort(l)
  return l
end

-- clone ---------------------------------------------------------------------

local function default_dir(url)
  local path = util.redact_url(url):match("^%a[%w+.-]*://[^/]*(.*)$") or url
  path = path:gsub("[?#].*$", ""):gsub("/+$", ""):gsub("%.git$", ""):gsub("/+$", "")
  local name = util.basename(path)
  if name == "" then util.die("cannot guess a directory name from the URL; please give one") end
  return name
end

local function clone_into(args, remote)
  repo_mod.init(".git", "refs/heads/main")
  local fs = repo_mod.probe(".git")

  local prefixes = { "HEAD" }
  if args.branch then
    prefixes[2] = "refs/heads/" .. args.branch
    prefixes[3] = "refs/tags/" .. args.branch
  end
  local listing = fetch.list_refs(remote, prefixes)

  local branch, want, is_tag
  if args.branch then
    if listing.refs["refs/heads/" .. args.branch] then
      branch = args.branch
      want = listing.refs["refs/heads/" .. branch]
    elseif listing.refs["refs/tags/" .. args.branch] then
      want, is_tag = listing.refs["refs/tags/" .. args.branch], true
    else
      util.die("remote branch '%s' not found in upstream origin", args.branch)
    end
  else
    local target = listing.symrefs.HEAD
    branch = target and target:match("^refs/heads/(.+)$")
    want = listing.refs.HEAD
    if not want and not branch then
      -- empty repository without unborn support: assume "main"
      branch = "main"
    end
  end

  repo_mod.write_config(".git", {
    filemode = fs.filemode, symlinks = fs.symlinks, ignorecase = fs.ignorecase,
    url = args.url, branch = branch, track = branch ~= nil,
  })
  local r = repo_mod.load(".git")

  if not want then
    r.refs:set_symbolic("HEAD", "refs/heads/" .. branch)
    util.warn("You appear to have cloned an empty repository.")
    return
  end

  util.info("Cloning into '%s'...", args.dir)
  local _, res = fetch.fetch_objects(r, remote, listing, { wants = { want }, depth = args.depth })
  if args.depth > 0 then
    local set = {}
    for _, id in ipairs(res.shallow) do set[id] = true end
    r.refs:write_shallow(set)
  end

  local commit_id, otype = r.odb:peel(want)
  if otype ~= "commit" then util.die("%s does not point to a commit", args.branch or "HEAD") end
  if branch then
    r.refs:update("refs/heads/" .. branch, commit_id)
    r.refs:update("refs/remotes/origin/" .. branch, commit_id)
    if not args.branch then
      r.refs:set_symbolic("refs/remotes/origin/HEAD", "refs/remotes/origin/" .. branch)
    end
    r.refs:set_symbolic("HEAD", "refs/heads/" .. branch)
  else
    r.refs:update("refs/tags/" .. args.branch, want)
    util.write_file(".git/HEAD", commit_id .. "\n")
    util.info("Note: checking out tag '%s' (detached HEAD)", args.branch)
  end

  local n = 0
  local entries = worktree.checkout(r, commit_tree(r.odb, commit_id), function(c) n = c end)
  index.write(r.index_path, entries)
  util.info("Checked out %d files at %s", n, short(commit_id))
end

function M.clone(args)
  local remote = transport.new(args.url)
  if remote.cred_source == "url" then
    util.warn("the credentials in the URL will be stored in .git/config; " ..
              "consider ~/.netrc or PICOGIT_TOKEN instead")
  end
  args.dir = args.dir or default_dir(args.url)
  local st = core.lstat(args.dir)
  if st then
    if st.type ~= "dir" or #(core.readdir(args.dir) or {}) > 0 then
      util.die("destination path '%s' already exists and is not an empty directory", args.dir)
    end
  else
    util.mkdirs(args.dir)
  end
  local abs_dir = args.dir:sub(1, 1) == "/" and args.dir or (core.getcwd() .. "/" .. args.dir)
  local cwd = core.getcwd()
  assert(core.chdir(abs_dir))
  local ok, err = pcall(clone_into, args, remote)
  core.chdir(cwd)
  if not ok then
    -- leave nothing half-done behind
    if st then
      for _, name in ipairs(core.readdir(abs_dir) or {}) do
        util.remove_tree(abs_dir .. "/" .. name)
      end
    else
      util.remove_tree(abs_dir)
    end
    error(err, 0)
  end
  return 0
end

-- pull ----------------------------------------------------------------------

local function current_branch(r)
  local head = r.refs:head()
  local branch = head.ref and head.ref:match("^refs/heads/(.+)$")
  if not branch then util.die("HEAD is detached; check out a branch first") end
  local remote_name = r.config:get("branch." .. branch .. ".remote") or "origin"
  local url = r.config:get("remote." .. remote_name .. ".url")
  if not url or url == true then util.die("no URL configured for remote '%s'", remote_name) end
  local merge = r.config:get("branch." .. branch .. ".merge") or ("refs/heads/" .. branch)
  local merge_branch = merge:match("^refs/heads/(.+)$") or branch
  return {
    head = head, branch = branch, remote_name = remote_name, url = url, merge = merge,
    tracking = "refs/remotes/" .. remote_name .. "/" .. merge_branch,
  }
end

local function print_changes(changes)
  local added, removed, modified = 0, 0, 0
  for _, c in ipairs(changes) do
    if c.old and c.new then modified = modified + 1
    elseif c.new then added = added + 1
    else removed = removed + 1 end
  end
  util.info(" %d file%s changed (%d added, %d modified, %d deleted)", #changes,
            #changes == 1 and "" or "s", added, modified, removed)
end

function M.pull()
  local r = repo_mod.open()
  local b = current_branch(r)
  local remote = transport.new(b.url)
  local listing = fetch.list_refs(remote, { b.merge })
  local rid = listing.refs[b.merge]
  if not rid then util.die("remote branch '%s' not found", b.merge) end
  local lid = b.head.id
  local shallow = r.refs:shallow()

  if rid == lid or (lid and r.odb:has(rid) and is_ancestor(r.odb, shallow, rid, lid)) then
    r.refs:update(b.tracking, rid)
    util.info("Already up to date.")
    return 0
  end

  local haves = {}
  if lid then haves[1] = lid end
  local tracked = r.refs:resolve(b.tracking)
  if tracked and tracked ~= lid and r.odb:has(tracked) then haves[#haves + 1] = tracked end
  local q, res = fetch.fetch_objects(r, remote, listing, {
    wants = { rid }, haves = haves, shallows = set_list(shallow),
    depth = lid == nil and 1 or nil, -- first fetch into an empty clone
    quarantine = true,
  })
  local ok, err = pcall(function()
    local otype = q:header(rid)
    if otype ~= "commit" then util.die("remote %s is not a commit", b.merge) end
    if lid and not is_ancestor(q, shallow, lid, rid) then
      util.die("not possible to fast-forward: '%s' and '%s' have diverged.\n" ..
               "picogit pull only supports fast-forward; resolve the divergence with a full git client",
               b.branch, b.tracking:gsub("^refs/remotes/", ""))
    end
  end)
  if not ok then
    q:discard()
    error(err, 0)
  end
  q:migrate()
  for _, id in ipairs(res.shallow) do shallow[id] = true end
  for _, id in ipairs(res.unshallow) do shallow[id] = nil end
  r.refs:write_shallow(shallow)

  local old_tree = lid and commit_tree(r.odb, lid) or nil
  local new_tree = commit_tree(r.odb, rid)
  local entries = index.read(r.index_path)
  local new_entries, changes = worktree.update(r, old_tree, new_tree, entries)
  index.write(r.index_path, new_entries)
  r.refs:update(b.head.ref, rid)
  r.refs:update(b.tracking, rid)
  util.info("Updating %s..%s", short(lid), short(rid))
  util.info("Fast-forward")
  print_changes(changes)
  return 0
end

-- commit -a -----------------------------------------------------------------

local function tz_offset(t)
  local utc = os.date("!*t", t)
  utc.isdst = os.date("*t", t).isdst
  local off = (t - os.time(utc)) // 60
  local sign = off < 0 and "-" or "+"
  off = math.abs(off)
  return ("%s%02d%02d"):format(sign, off // 60, off % 60)
end

local function identity(r)
  local name = os.getenv("PICOGIT_AUTHOR_NAME")
  local email = os.getenv("PICOGIT_AUTHOR_EMAIL")
  if not name or name == "" then name = r.config:get("user.name") end
  if not email or email == "" then email = r.config:get("user.email") end
  if type(name) ~= "string" or name == "" or type(email) ~= "string" or email == "" then
    util.die("author identity unknown: set user.name and user.email in .git/config\n" ..
             "or PICOGIT_AUTHOR_NAME and PICOGIT_AUTHOR_EMAIL")
  end
  name = name:gsub("[<>\n]", ""):gsub("^%s+", ""):gsub("%s+$", "")
  email = email:gsub("[<>\n]", ""):gsub("^%s+", ""):gsub("%s+$", "")
  local t = os.time()
  return ("%s <%s> %d %s"):format(name, email, t, tz_offset(t))
end

-- git's "whitespace" cleanup for -m messages.
local function cleanup_message(msg)
  local lines = {}
  for line in (msg .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = (line:gsub("%s+$", ""))
  end
  local out, blank = {}, false
  for _, l in ipairs(lines) do
    if l == "" then
      blank = #out > 0
    else
      if blank then out[#out + 1] = "" end
      blank = false
      out[#out + 1] = l
    end
  end
  if #out == 0 then return nil end
  return table.concat(out, "\n") .. "\n"
end

function M.commit(args)
  local message = cleanup_message(args.message)
  if not message then util.die("aborting commit due to empty commit message") end
  local r = repo_mod.open()
  local head = r.refs:head()
  local entries = index.read(r.index_path)
  local new_entries = worktree.snapshot(r, entries)
  local tree = worktree.write_tree(r, new_entries)
  local parent_tree = head.id and commit_tree(r.odb, head.id)
  if tree == parent_tree or (not head.id and #new_entries == 0) then
    index.write(r.index_path, new_entries) -- refresh stat data
    print("nothing to commit, working tree clean")
    return 1
  end
  local ident = identity(r)
  local id = r.odb:write("commit", odb_mod.serialize_commit {
    tree = tree, parents = { head.id }, author = ident, committer = ident, message = message,
  })
  if head.ref then
    r.refs:update(head.ref, id)
  else
    util.write_file(r.gitdir .. "/HEAD", id .. "\n")
  end
  index.write(r.index_path, new_entries)
  local changes = worktree.diff_trees(r, parent_tree, tree, "")
  local label = head.ref and head.ref:gsub("^refs/heads/", "") or "detached HEAD"
  print(("[%s%s %s] %s"):format(label, head.id and "" or " (root-commit)", short(id),
        message:match("^[^\n]*")))
  print_changes(changes)
  return 0
end

-- push ----------------------------------------------------------------------

-- Objects that `new_tree` has and `old_tree` does not (tree diff that
-- skips identical subtrees).
local function collect_tree(odb, old_tree, new_tree, out)
  if old_tree == new_tree then return end
  out[new_tree] = true
  local old = {}
  if old_tree then
    for _, e in ipairs(odb_mod.parse_tree(odb:read_typed(old_tree, "tree"))) do
      old[e.name] = e
    end
  end
  for _, e in ipairs(odb_mod.parse_tree(odb:read_typed(new_tree, "tree"))) do
    local o = old[e.name]
    local mode = odb_mod.normalize_mode(e.mode)
    if not (o and o.id == e.id) then
      if mode == "40000" then
        local omode = o and odb_mod.normalize_mode(o.mode)
        collect_tree(odb, omode == "40000" and o.id or nil, e.id, out)
      elseif mode ~= "160000" then
        out[e.id] = true
      end
    end
  end
end

-- Commits reachable from `tip` that the remote (at `remote_id`) lacks, and
-- the objects they introduce.
local function objects_to_push(r, shallow, tip, remote_id)
  local have = {}
  if remote_id then
    -- everything reachable from the remote tip that we know of
    local queue, head = { remote_id }, 1
    have[remote_id] = true
    while queue[head] do
      local id = queue[head]
      head = head + 1
      if not shallow[id] and r.odb:has(id) then
        for _, p in ipairs(odb_mod.parse_commit(r.odb:read_typed(id, "commit")).parents) do
          if not have[p] then
            have[p] = true
            queue[#queue + 1] = p
          end
        end
      end
    end
  end
  local objects, commits = {}, {}
  local seen, queue, head = { [tip] = true }, { tip }, 1
  while queue[head] do
    local id = queue[head]
    head = head + 1
    if not have[id] then
      if shallow[id] then
        util.die("cannot push: the history reaches the shallow boundary at %s;\n" ..
                 "the remote is missing commits that this shallow clone does not have", short(id))
      end
      local c = odb_mod.parse_commit(r.odb:read_typed(id, "commit"))
      commits[#commits + 1] = id
      objects[id] = true
      local ptree = c.parents[1] and commit_tree(r.odb, c.parents[1]) or nil
      collect_tree(r.odb, ptree, c.tree, objects)
      for _, p in ipairs(c.parents) do
        if not seen[p] then
          seen[p] = true
          queue[#queue + 1] = p
        end
      end
    end
  end
  return set_list(objects), commits
end

function M.push()
  local r = repo_mod.open()
  local b = current_branch(r)
  local lid = b.head.id
  if not lid then util.die("nothing to push: branch '%s' has no commits", b.branch) end
  local remote = transport.new(b.url)
  local info = transport.discover(remote, "git-receive-pack", false)
  if info.version ~= 0 then util.die("unexpected protocol version from receive-pack") end
  if not info.caps["report-status"] then util.die("server does not support report-status") end
  local target = b.merge
  local rid = info.refs[target]
  local shallow = r.refs:shallow()
  if rid == lid then
    util.info("Everything up-to-date")
    return 0
  end
  if rid then
    if not r.odb:has(rid) then
      util.die("rejected: the remote branch contains commits you do not have locally;\n" ..
               "run 'picogit pull' first")
    end
    if not is_ancestor(r.odb, shallow, rid, lid) then
      util.die("rejected (non-fast-forward): the remote branch has diverged; " ..
               "picogit cannot force-push")
    end
  end
  local objects, commits = objects_to_push(r, shallow, lid, rid)
  util.trace("pushing %d commits, %d objects", #commits, #objects)
  local tmp = util.temp_path(r.gitdir .. "/objects/pack/tmp_push")
  local ok, res = pcall(function()
    pack.write(tmp, r.odb, objects)
    return transport.push(remote, info.caps,
      { { old = rid or util.ZERO_ID, new = lid, ref = target } }, tmp,
      pktline.progress_writer())
  end)
  core.unlink(tmp)
  if not ok then error(res, 0) end
  if res.unpack ~= "ok" then
    util.die("remote failed to unpack the pushed objects: %s", tostring(res.unpack))
  end
  local status = res.refs[target]
  if status ~= "ok" then
    util.die("remote rejected %s: %s", target, tostring(status or "no status reported"))
  end
  r.refs:update(b.tracking, lid)
  util.info("To %s", remote.base)
  util.info("   %s..%s  %s -> %s", short(rid), short(lid), b.branch,
            (target:gsub("^refs/heads/", "")))
  return 0
end

return M
