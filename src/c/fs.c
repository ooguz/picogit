/* File system helpers missing from the Lua standard library. */
#include <dirent.h>
#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "picogit.h"

static void setint(lua_State *L, const char *k, lua_Integer v)
{
    lua_pushinteger(L, v);
    lua_setfield(L, -2, k);
}

static int push_stat(lua_State *L, const struct stat *st)
{
    const char *type = S_ISREG(st->st_mode) ? "file"
                     : S_ISDIR(st->st_mode) ? "dir"
                     : S_ISLNK(st->st_mode) ? "link"
                     : "other";
    lua_createtable(L, 0, 14);
    lua_pushstring(L, type);
    lua_setfield(L, -2, "type");
    setint(L, "mode", st->st_mode);
    setint(L, "perm", st->st_mode & 07777);
    setint(L, "size", (lua_Integer)st->st_size);
    setint(L, "mtime", (lua_Integer)st->st_mtim.tv_sec);
    setint(L, "mtime_ns", (lua_Integer)st->st_mtim.tv_nsec);
    setint(L, "ctime", (lua_Integer)st->st_ctim.tv_sec);
    setint(L, "ctime_ns", (lua_Integer)st->st_ctim.tv_nsec);
    setint(L, "dev", (lua_Integer)st->st_dev);
    setint(L, "ino", (lua_Integer)st->st_ino);
    setint(L, "uid", (lua_Integer)st->st_uid);
    setint(L, "gid", (lua_Integer)st->st_gid);
    return 1;
}

/* lstat(path) / stat(path) -> table | nil, err, errno */
static int l_lstat(lua_State *L)
{
    const char *p = luaL_checkstring(L, 1);
    struct stat st;
    if (lstat(p, &st) != 0)
        return pg_fail(L, p);
    return push_stat(L, &st);
}

static int l_stat(lua_State *L)
{
    const char *p = luaL_checkstring(L, 1);
    struct stat st;
    if (stat(p, &st) != 0)
        return pg_fail(L, p);
    return push_stat(L, &st);
}

/* readdir(path) -> { names... } (without "." and "..") */
static int l_readdir(lua_State *L)
{
    const char *p = luaL_checkstring(L, 1);
    DIR *d = opendir(p);
    struct dirent *e;
    int i = 0;
    if (!d)
        return pg_fail(L, p);
    lua_newtable(L);
    while ((e = readdir(d)) != NULL) {
        if (e->d_name[0] == '.' &&
            (e->d_name[1] == 0 || (e->d_name[1] == '.' && e->d_name[2] == 0)))
            continue;
        lua_pushstring(L, e->d_name);
        lua_rawseti(L, -2, ++i);
    }
    closedir(d);
    return 1;
}

static int result(lua_State *L, int rc, const char *what)
{
    if (rc != 0)
        return pg_fail(L, what);
    lua_pushboolean(L, 1);
    return 1;
}

/* mkdir(path [, mode]) -> true | nil, err, errno */
static int l_mkdir(lua_State *L)
{
    const char *p = luaL_checkstring(L, 1);
    return result(L, mkdir(p, (mode_t)luaL_optinteger(L, 2, 0777)), p);
}

static int l_rmdir(lua_State *L)
{
    const char *p = luaL_checkstring(L, 1);
    return result(L, rmdir(p), p);
}

static int l_unlink(lua_State *L)
{
    const char *p = luaL_checkstring(L, 1);
    return result(L, unlink(p), p);
}

static int l_rename(lua_State *L)
{
    const char *a = luaL_checkstring(L, 1);
    const char *b = luaL_checkstring(L, 2);
    return result(L, rename(a, b), b);
}

/* symlink(target, path) */
static int l_symlink(lua_State *L)
{
    const char *target = luaL_checkstring(L, 1);
    const char *p = luaL_checkstring(L, 2);
    return result(L, symlink(target, p), p);
}

static int l_readlink(lua_State *L)
{
    const char *p = luaL_checkstring(L, 1);
    char buf[PATH_MAX];
    ssize_t n = readlink(p, buf, sizeof buf);
    if (n < 0)
        return pg_fail(L, p);
    lua_pushlstring(L, buf, (size_t)n);
    return 1;
}

static int l_chmod(lua_State *L)
{
    const char *p = luaL_checkstring(L, 1);
    return result(L, chmod(p, (mode_t)luaL_checkinteger(L, 2)), p);
}

static int l_getcwd(lua_State *L)
{
    char buf[PATH_MAX];
    if (!getcwd(buf, sizeof buf))
        return pg_fail(L, "getcwd");
    lua_pushstring(L, buf);
    return 1;
}

static int l_chdir(lua_State *L)
{
    const char *p = luaL_checkstring(L, 1);
    return result(L, chdir(p), p);
}

static int l_isatty(lua_State *L)
{
    lua_pushboolean(L, isatty((int)luaL_checkinteger(L, 1)));
    return 1;
}

/* umask() -> current umask (without changing it) */
static int l_umask(lua_State *L)
{
    mode_t m = umask(022);
    umask(m);
    lua_pushinteger(L, m);
    return 1;
}

void pg_register_fs(lua_State *L)
{
    static const luaL_Reg fns[] = {
        {"lstat", l_lstat},
        {"stat", l_stat},
        {"readdir", l_readdir},
        {"mkdir", l_mkdir},
        {"rmdir", l_rmdir},
        {"unlink", l_unlink},
        {"rename", l_rename},
        {"symlink", l_symlink},
        {"readlink", l_readlink},
        {"chmod", l_chmod},
        {"getcwd", l_getcwd},
        {"chdir", l_chdir},
        {"isatty", l_isatty},
        {"umask", l_umask},
        {NULL, NULL}};
    luaL_setfuncs(L, fns, 0);
}
