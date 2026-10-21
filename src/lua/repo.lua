-- Repository layout: discovery, creation, file system capability probes.
local core = require("picogit.core")
local config = require("config")
local odb = require("odb")
local refs = require("refs")
local util = require("util")

local M = {}

-- Find the work tree root containing .git, starting at the current
-- directory.
function M.find_root()
  local dir = assert(core.getcwd())
  while true do
    local st = core.stat(dir .. "/.git")
    if st and st.type == "dir" then return dir end
    if st then
      util.die("'%s/.git' is not a directory (git worktrees and submodules are not supported)", dir)
    end
    if dir == "/" or dir == "" then
      util.die("not a git repository (or any of the parent directories): .git")
    end
    dir = util.dirname(dir)
    if dir == "" then dir = "/" end
  end
end

-- Load the repository whose .git directory is `gitdir` (relative paths
-- are resolved against the current directory, which must be the work
-- tree root).
function M.load(gitdir)
  local cfg = config.load(gitdir)
  local fmt = tonumber(cfg:get("core.repositoryformatversion") or "0")
  if fmt and fmt > 1 then
    util.die("unsupported repository format version %d", fmt)
  end
  local objfmt = cfg:get("extensions.objectformat")
  if objfmt and objfmt ~= "sha1" then
    util.die("unsupported object format '%s' (only sha1 is supported)", objfmt)
  end
  return {
    gitdir = gitdir,
    odb = odb.new(gitdir),
    refs = refs.new(gitdir),
    config = cfg,
    filemode = cfg:get_bool("core.filemode", true),
    symlinks = cfg:get_bool("core.symlinks", true),
    index_path = gitdir .. "/index",
  }
end

-- Find the repository, change to its work tree root and load it.
function M.open()
  local root = M.find_root()
  assert(core.chdir(root))
  local r = M.load(".git")
  r.root = root
  return r
end

-- Create the .git directory layout.
function M.init(gitdir, head_ref)
  for _, d in ipairs { "", "/objects", "/objects/info", "/objects/pack",
                       "/refs", "/refs/heads", "/refs/tags", "/info" } do
    util.mkdirs(gitdir .. d)
  end
  util.write_file(gitdir .. "/HEAD", "ref: " .. head_ref .. "\n")
  util.write_file(gitdir .. "/description",
    "Unnamed repository; edit this file 'description' to name the repository.\n")
end

-- Probe the file system the way git init does: can it keep the exec bit,
-- store symlinks, and is it case sensitive?
function M.probe(gitdir)
  local res = { filemode = false, symlinks = false, ignorecase = false }
  local p = gitdir .. "/config.probe"
  util.write_file(p, "")
  core.chmod(p, tonumber("755", 8))
  local st = core.lstat(p)
  if st and st.perm & 64 ~= 0 then
    core.chmod(p, tonumber("644", 8))
    st = core.lstat(p)
    res.filemode = st ~= nil and st.perm & 64 == 0
  end
  res.ignorecase = core.lstat(gitdir .. "/CoNfIg.PrObE") ~= nil
  core.unlink(p)
  local l = gitdir .. "/symlink.probe"
  if core.symlink("testing", l) then
    st = core.lstat(l)
    res.symlinks = st ~= nil and st.type == "link"
    core.unlink(l)
  end
  return res
end

-- Write .git/config for a fresh clone.
function M.write_config(gitdir, opts)
  local core_sec = {
    { "repositoryformatversion", "0" },
    { "filemode", opts.filemode and "true" or "false" },
    { "bare", "false" },
    { "logallrefupdates", "true" },
  }
  if not opts.symlinks then core_sec[#core_sec + 1] = { "symlinks", "false" } end
  if opts.ignorecase then core_sec[#core_sec + 1] = { "ignorecase", "true" } end
  local sections = { { "core", nil, core_sec } }
  if opts.url then
    local remote = { { "url", opts.url } }
    if opts.branch then
      remote[#remote + 1] = { "fetch", "+refs/heads/" .. opts.branch ..
                                       ":refs/remotes/origin/" .. opts.branch }
    else
      remote[#remote + 1] = { "fetch", "+refs/heads/*:refs/remotes/origin/*" }
    end
    sections[#sections + 1] = { "remote", "origin", remote }
  end
  if opts.branch and opts.track then
    sections[#sections + 1] = { "branch", opts.branch, {
      { "remote", "origin" },
      { "merge", "refs/heads/" .. opts.branch },
    } }
  end
  util.write_file(gitdir .. "/config", config.serialize(sections))
end

return M
