/* SPDX-License-Identifier: GPL-3.0-or-later */
/* picogit.core - aggregates the C helpers exposed to Lua. */
#include <errno.h>
#include <string.h>

#include "picogit.h"

int pg_fail(lua_State *L, const char *what)
{
    int en = errno;
    luaL_pushfail(L);
    if (what)
        lua_pushfstring(L, "%s: %s", what, strerror(en));
    else
        lua_pushstring(L, strerror(en));
    lua_pushinteger(L, en);
    return 3;
}

FILE *pg_checkfile(lua_State *L, int idx)
{
    luaL_Stream *p = (luaL_Stream *)luaL_checkudata(L, idx, LUA_FILEHANDLE);
    if (p->closef == NULL)
        luaL_argerror(L, idx, "attempt to use a closed file");
    return p->f;
}

static const char hexdigits[] = "0123456789abcdef";

/* tohex(bin) -> lowercase hex string */
static int l_tohex(lua_State *L)
{
    size_t n, i;
    const unsigned char *s = (const unsigned char *)luaL_checklstring(L, 1, &n);
    luaL_Buffer b;
    char *out = luaL_buffinitsize(L, &b, n * 2);
    for (i = 0; i < n; i++) {
        out[2 * i] = hexdigits[s[i] >> 4];
        out[2 * i + 1] = hexdigits[s[i] & 15];
    }
    luaL_pushresultsize(&b, n * 2);
    return 1;
}

static int hexval(int c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/* fromhex(hex) -> bin, or nil if the input is not valid hex */
static int l_fromhex(lua_State *L)
{
    size_t n, i;
    const char *s = luaL_checklstring(L, 1, &n);
    luaL_Buffer b;
    char *out;
    if (n % 2) {
        luaL_pushfail(L);
        return 1;
    }
    out = luaL_buffinitsize(L, &b, n / 2);
    for (i = 0; i < n / 2; i++) {
        int hi = hexval(s[2 * i]), lo = hexval(s[2 * i + 1]);
        if (hi < 0 || lo < 0) {
            luaL_pushfail(L);
            return 1;
        }
        out[i] = (char)(hi << 4 | lo);
    }
    luaL_pushresultsize(&b, n / 2);
    return 1;
}

int luaopen_picogit_core(lua_State *L)
{
    lua_newtable(L);
    lua_pushcfunction(L, l_tohex);
    lua_setfield(L, -2, "tohex");
    lua_pushcfunction(L, l_fromhex);
    lua_setfield(L, -2, "fromhex");
    lua_pushliteral(L, PICOGIT_VERSION);
    lua_setfield(L, -2, "version");
    pg_register_zlib(L);
    pg_register_sha1(L);
    pg_register_fs(L);
    pg_register_http(L);
    pg_register_rand(L);
    return 1;
}
