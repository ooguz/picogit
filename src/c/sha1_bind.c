/* SHA-1 for Lua, on top of the Mbed TLS implementation. */
#include <string.h>

#include "mbedtls/sha1.h"

#include "picogit.h"

#define SHA1_MT "picogit.sha1"

/* sha1(data) -> 20-byte digest */
static int l_sha1(lua_State *L)
{
    size_t n;
    const unsigned char *s = (const unsigned char *)luaL_checklstring(L, 1, &n);
    unsigned char out[20];
    mbedtls_sha1(s, n, out);
    lua_pushlstring(L, (const char *)out, 20);
    return 1;
}

/* sha1_new() -> context with :update(data) and :digest() */
static int l_sha1_new(lua_State *L)
{
    mbedtls_sha1_context *c = lua_newuserdatauv(L, sizeof *c, 0);
    mbedtls_sha1_init(c);
    mbedtls_sha1_starts(c);
    luaL_setmetatable(L, SHA1_MT);
    return 1;
}

static int l_sha1_update(lua_State *L)
{
    mbedtls_sha1_context *c = luaL_checkudata(L, 1, SHA1_MT);
    size_t n;
    const unsigned char *s = (const unsigned char *)luaL_checklstring(L, 2, &n);
    mbedtls_sha1_update(c, s, n);
    lua_settop(L, 1);
    return 1;
}

/* digest() finalizes a copy, so the context can continue to be updated. */
static int l_sha1_digest(lua_State *L)
{
    mbedtls_sha1_context *c = luaL_checkudata(L, 1, SHA1_MT), tmp;
    unsigned char out[20];
    mbedtls_sha1_init(&tmp);
    mbedtls_sha1_clone(&tmp, c);
    mbedtls_sha1_finish(&tmp, out);
    mbedtls_sha1_free(&tmp);
    lua_pushlstring(L, (const char *)out, 20);
    return 1;
}

/* sha1_file(fh, offset, length) -> digest of a region of an open file */
static int l_sha1_file(lua_State *L)
{
    FILE *f = pg_checkfile(L, 1);
    lua_Integer off = luaL_checkinteger(L, 2);
    lua_Integer len = luaL_checkinteger(L, 3);
    mbedtls_sha1_context c;
    unsigned char buf[16384], out[20];

    if (fseeko(f, (off_t)off, SEEK_SET) != 0)
        return pg_fail(L, "seek");
    mbedtls_sha1_init(&c);
    mbedtls_sha1_starts(&c);
    while (len > 0) {
        size_t want = len > (lua_Integer)sizeof buf ? sizeof buf : (size_t)len;
        size_t got = fread(buf, 1, want, f);
        if (got == 0) {
            mbedtls_sha1_free(&c);
            return luaL_error(L, "sha1_file: unexpected end of file");
        }
        mbedtls_sha1_update(&c, buf, got);
        len -= (lua_Integer)got;
    }
    mbedtls_sha1_finish(&c, out);
    mbedtls_sha1_free(&c);
    lua_pushlstring(L, (const char *)out, 20);
    return 1;
}

void pg_register_sha1(lua_State *L)
{
    static const luaL_Reg methods[] = {
        {"update", l_sha1_update},
        {"digest", l_sha1_digest},
        {NULL, NULL}};
    if (luaL_newmetatable(L, SHA1_MT)) {
        luaL_newlib(L, methods);
        lua_setfield(L, -2, "__index");
    }
    lua_pop(L, 1);
    lua_pushcfunction(L, l_sha1);
    lua_setfield(L, -2, "sha1");
    lua_pushcfunction(L, l_sha1_new);
    lua_setfield(L, -2, "sha1_new");
    lua_pushcfunction(L, l_sha1_file);
    lua_setfield(L, -2, "sha1_file");
}
