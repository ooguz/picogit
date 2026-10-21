/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * picogit - entry point.
 *
 * Creates the Lua state, makes the embedded Lua modules the only source for
 * require(), and hands the command line to main.lua.
 */
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#include "picogit.h"

static const luaL_Reg stdlibs[] = {
    {LUA_GNAME, luaopen_base},
    {LUA_LOADLIBNAME, luaopen_package},
    {LUA_COLIBNAME, luaopen_coroutine},
    {LUA_TABLIBNAME, luaopen_table},
    {LUA_IOLIBNAME, luaopen_io},
    {LUA_OSLIBNAME, luaopen_os},
    {LUA_STRLIBNAME, luaopen_string},
    {LUA_MATHLIBNAME, luaopen_math},
    {LUA_UTF8LIBNAME, luaopen_utf8},
#ifdef PICOGIT_DEV
    {LUA_DBLIBNAME, luaopen_debug},
#endif
    {NULL, NULL}};

/* package.searchers entry: look the module up in the embedded table. */
static int searcher_embedded(lua_State *L)
{
    const char *name = luaL_checkstring(L, 1);
    const struct pg_embedded_module *m;
    for (m = pg_embedded_modules; m->name; m++) {
        if (strcmp(m->name, name) == 0) {
            lua_pushfstring(L, "@picogit/%s.lua", name);
            if (luaL_loadbufferx(L, (const char *)m->data, m->len,
                                 lua_tostring(L, -1), NULL) != LUA_OK)
                return lua_error(L);
            lua_pushstring(L, name);
            return 2;
        }
    }
    lua_pushfstring(L, "no embedded module '%s'", name);
    return 1;
}

static void setup_package(lua_State *L)
{
    lua_getglobal(L, "package");

    /* Never load Lua or C code from the file system. */
    lua_pushliteral(L, "");
    lua_setfield(L, -2, "path");
    lua_pushliteral(L, "");
    lua_setfield(L, -2, "cpath");

    lua_getfield(L, -1, "preload");
    lua_pushcfunction(L, luaopen_picogit_core);
    lua_setfield(L, -2, "picogit.core");
    lua_pop(L, 1);

    lua_getfield(L, -1, "searchers");
    lua_rawgeti(L, -1, 1); /* keep the preload searcher */
    lua_newtable(L);
    lua_insert(L, -2);
    lua_rawseti(L, -2, 1);
    lua_pushcfunction(L, searcher_embedded);
    lua_rawseti(L, -2, 2);
    lua_setfield(L, -3, "searchers");
    lua_pop(L, 2);
}

/* Message handler: user-facing errors are plain strings raised with level 0;
 * a traceback is only added when PICOGIT_DEBUG is set. */
static int msghandler(lua_State *L)
{
    const char *msg = lua_tostring(L, 1);
    if (msg == NULL) {
        if (luaL_callmeta(L, 1, "__tostring") && lua_type(L, -1) == LUA_TSTRING)
            return 1;
        msg = lua_pushfstring(L, "(error object is a %s value)", luaL_typename(L, 1));
    }
    if (getenv("PICOGIT_DEBUG"))
        luaL_traceback(L, L, msg, 1);
    else
        lua_pushstring(L, msg);
    return 1;
}

static int run(lua_State *L)
{
    int argc = (int)lua_tointeger(L, 1);
    char **argv = (char **)lua_touserdata(L, 2);
    int i, first = 1;

    luaL_checkversion(L);
    for (const luaL_Reg *lib = stdlibs; lib->func; lib++) {
        luaL_requiref(L, lib->name, lib->func, 1);
        lua_pop(L, 1);
    }
    setup_package(L);

#ifdef PICOGIT_DEV
    /* picogit-dev --dev-run script.lua [args...]: run a Lua file from disk
     * with the embedded modules available (unit tests). */
    if (argc >= 3 && strcmp(argv[1], "--dev-run") == 0) {
        lua_createtable(L, argc, 0);
        for (i = 2; i < argc; i++) {
            lua_pushstring(L, argv[i]);
            lua_rawseti(L, -2, i - 2);
        }
        lua_setglobal(L, "arg");
        if (luaL_loadfile(L, argv[2]) != LUA_OK)
            return lua_error(L);
        for (i = 3; i < argc; i++)
            lua_pushstring(L, argv[i]);
        lua_call(L, argc - 3, 1);
        return 1;
    }
#endif

    lua_getglobal(L, "require");
    lua_pushliteral(L, "main");
    lua_call(L, 1, 1);
    lua_getfield(L, -1, "main");
    lua_createtable(L, argc, 0);
    for (i = first; i < argc; i++) {
        lua_pushstring(L, argv[i]);
        lua_rawseti(L, -2, i);
    }
    lua_call(L, 1, 1);
    return 1;
}

int main(int argc, char **argv)
{
    lua_State *L;
    int status, code;

    signal(SIGPIPE, SIG_IGN);
    L = luaL_newstate();
    if (L == NULL) {
        fputs("picogit: cannot create Lua state: out of memory\n", stderr);
        return 1;
    }
    lua_pushcfunction(L, msghandler);
    lua_pushcfunction(L, run);
    lua_pushinteger(L, argc);
    lua_pushlightuserdata(L, argv);
    status = lua_pcall(L, 2, 1, 1);
    if (status != LUA_OK) {
        const char *msg = lua_tostring(L, -1);
        fprintf(stderr, "picogit: %s\n", msg ? msg : "unknown error");
        code = 1;
    } else if (lua_isinteger(L, -1)) {
        code = (int)lua_tointeger(L, -1);
    } else {
        code = lua_toboolean(L, -1) || lua_isnil(L, -1) ? 0 : 1;
    }
    fflush(stdout);
    lua_close(L);
    return code;
}
