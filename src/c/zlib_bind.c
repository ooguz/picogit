/*
 * zlib bindings and the streaming object helpers built on them.
 *
 * Big blobs never have to pass through a Lua string: file -> loose object,
 * pack entry -> loose object, loose object -> work tree file and loose
 * object -> pack entry are all streamed here with a fixed 16 KiB buffer.
 *
 * A loose object is zlib("<type> <size>\0" <content>) stored at
 * objects/xx/yyyy..., named after sha1("<type> <size>\0" <content>).
 */
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "zlib.h"
#include "mbedtls/sha1.h"

#include "picogit.h"

#define CHUNK 16384

/* zlib level for loose objects; git's core.looseCompression default. */
#define LOOSE_LEVEL 1

static const char *obj_types[] = {"commit", "tree", "blob", "tag", NULL};
/* pack type numbers, same order as obj_types */
static const int obj_type_nums[] = {1, 2, 3, 4};

static void hex20(const unsigned char *sha, char *out)
{
    static const char hx[] = "0123456789abcdef";
    int i;
    for (i = 0; i < 20; i++) {
        out[2 * i] = hx[sha[i] >> 4];
        out[2 * i + 1] = hx[sha[i] & 15];
    }
    out[40] = 0;
}

/* ------------------------------------------------------------------ */
/* Inflating reader over a FILE*                                      */

typedef struct {
    FILE *in;
    z_stream z;
    int zinit;
    int ended;
    int64_t fed;      /* compressed bytes handed to zlib */
    int64_t limit;    /* max compressed bytes to read, -1 = unlimited */
    unsigned char inbuf[CHUNK];
} zreader;

/* The z_stream is created once and reset for every object: allocating
 * and freeing zlib state per object fragments musl's heap badly (tens of
 * MiB of RSS when exploding a pack of a few thousand objects). */
static int zr_init(zreader *r, FILE *in)
{
    r->in = in;
    r->ended = 0;
    r->fed = 0;
    r->limit = -1;
    if (!r->zinit) {
        memset(&r->z, 0, sizeof r->z);
        if (inflateInit(&r->z) != Z_OK)
            return -1;
        r->zinit = 1;
    } else if (inflateReset(&r->z) != Z_OK) {
        return -1;
    }
    r->z.next_in = NULL;
    r->z.avail_in = 0;
    return 0;
}

static void zr_end(zreader *r)
{
    (void)r; /* the stream is kept for the next object */
}

/* Number of compressed bytes zlib actually consumed. */
static int64_t zr_consumed(zreader *r)
{
    return r->fed - (int64_t)r->z.avail_in;
}

/* Read up to n inflated bytes. Returns bytes produced (0 at end of the
 * stream) or -1 with *err set. */
static long zr_read(zreader *r, unsigned char *out, size_t n, const char **err)
{
    int ret;
    if (r->ended || n == 0)
        return 0;
    r->z.next_out = out;
    r->z.avail_out = (uInt)n;
    while (r->z.avail_out == n) {
        if (r->z.avail_in == 0) {
            size_t want = CHUNK, got;
            if (r->limit >= 0 && r->limit - r->fed < (int64_t)want)
                want = (size_t)(r->limit - r->fed);
            got = want ? fread(r->inbuf, 1, want, r->in) : 0;
            if (got == 0) {
                *err = ferror(r->in) ? "read error" : "truncated zlib stream";
                return -1;
            }
            r->fed += (int64_t)got;
            r->z.next_in = r->inbuf;
            r->z.avail_in = (uInt)got;
        }
        ret = inflate(&r->z, Z_NO_FLUSH);
        if (ret == Z_STREAM_END) {
            r->ended = 1;
            break;
        }
        if (ret != Z_OK && ret != Z_BUF_ERROR) {
            *err = r->z.msg ? r->z.msg : "corrupt zlib stream";
            return -1;
        }
    }
    return (long)(n - r->z.avail_out);
}

/* ------------------------------------------------------------------ */
/* Deflating writer over a FILE*                                      */

typedef struct {
    FILE *out;
    z_stream z;
    int zinit;
    int level;
    int64_t written;
    unsigned char outbuf[CHUNK];
} zwriter;

static int zw_init(zwriter *w, FILE *out, int level)
{
    w->out = out;
    w->written = 0;
    if (w->zinit && w->level != level) {
        deflateEnd(&w->z);
    }
    if (!w->zinit) {
        memset(&w->z, 0, sizeof w->z);
        if (deflateInit(&w->z, level) != Z_OK)
            return -1;
        w->zinit = 1;
        w->level = level;
    } else if (deflateReset(&w->z) != Z_OK) {
        return -1;
    }
    return 0;
}

static int zw_run(zwriter *w, const unsigned char *p, size_t n, int flush)
{
    int ret;
    w->z.next_in = (unsigned char *)p;
    w->z.avail_in = (uInt)n;
    do {
        size_t have;
        w->z.next_out = w->outbuf;
        w->z.avail_out = CHUNK;
        ret = deflate(&w->z, flush);
        if (ret == Z_STREAM_ERROR)
            return -1;
        have = CHUNK - w->z.avail_out;
        if (have && fwrite(w->outbuf, 1, have, w->out) != have)
            return -1;
        w->written += (int64_t)have;
    } while (w->z.avail_out == 0 || (flush == Z_FINISH && ret != Z_STREAM_END));
    return 0;
}

static int zw_write(zwriter *w, const void *p, size_t n)
{
    /* zlib's avail_in is 32-bit; feed large inputs in slices. */
    const unsigned char *c = p;
    while (n > 0) {
        size_t part = n > (1u << 30) ? (1u << 30) : n;
        if (zw_run(w, c, part, Z_NO_FLUSH) != 0)
            return -1;
        c += part;
        n -= part;
    }
    return 0;
}

static int zw_finish(zwriter *w)
{
    return zw_run(w, NULL, 0, Z_FINISH);
}

static void zw_end(zwriter *w)
{
    (void)w; /* the stream is kept for the next object */
}

/* ------------------------------------------------------------------ */
/* Loose object writer: hashes and (optionally) stores at the same time */

typedef struct {
    const char *objdir; /* NULL: hash only */
    FILE *f;
    char tmp[PATH_MAX];
    zwriter zw;
    mbedtls_sha1_context sha;
} loose_writer;

static int lw_open(loose_writer *lw, const char *objdir, const char *type, int64_t size)
{
    char hdr[64];
    int n = snprintf(hdr, sizeof hdr, "%s %lld", type, (long long)size);
    int fd;

    lw->objdir = objdir;
    lw->f = NULL;
    mbedtls_sha1_init(&lw->sha);
    mbedtls_sha1_starts(&lw->sha);
    if (objdir) {
        if (snprintf(lw->tmp, sizeof lw->tmp, "%s/tmp_obj_XXXXXX", objdir) >= (int)sizeof lw->tmp)
            return -1;
        fd = mkstemp(lw->tmp);
        if (fd < 0)
            return -1;
        lw->f = fdopen(fd, "wb");
        if (!lw->f) {
            close(fd);
            unlink(lw->tmp);
            return -1;
        }
        if (zw_init(&lw->zw, lw->f, LOOSE_LEVEL) != 0)
            return -1;
    }
    mbedtls_sha1_update(&lw->sha, (const unsigned char *)hdr, (size_t)n + 1);
    if (objdir && zw_write(&lw->zw, hdr, (size_t)n + 1) != 0)
        return -1;
    return 0;
}

static int lw_write(loose_writer *lw, const void *p, size_t n)
{
    mbedtls_sha1_update(&lw->sha, p, n);
    if (lw->objdir && zw_write(&lw->zw, p, n) != 0)
        return -1;
    return 0;
}

static void lw_abort(loose_writer *lw)
{
    mbedtls_sha1_free(&lw->sha);
    zw_end(&lw->zw);
    if (lw->f) {
        fclose(lw->f);
        unlink(lw->tmp);
        lw->f = NULL;
    }
}

/* Finish: compute the name and move the object into place unless an object
 * with that name already exists. */
static int lw_finish(loose_writer *lw, unsigned char sha[20])
{
    char hex[41], path[PATH_MAX];
    struct stat st;
    int rc;

    mbedtls_sha1_finish(&lw->sha, sha);
    mbedtls_sha1_free(&lw->sha);
    if (!lw->objdir)
        return 0;
    rc = zw_finish(&lw->zw);
    zw_end(&lw->zw);
    if (fclose(lw->f) != 0)
        rc = -1;
    lw->f = NULL;
    if (rc != 0) {
        unlink(lw->tmp);
        return -1;
    }
    hex20(sha, hex);
    snprintf(path, sizeof path, "%s/%.2s", lw->objdir, hex);
    if (mkdir(path, 0777) != 0 && errno != EEXIST) {
        unlink(lw->tmp);
        return -1;
    }
    snprintf(path, sizeof path, "%s/%.2s/%s", lw->objdir, hex, hex + 2);
    if (stat(path, &st) == 0) {
        unlink(lw->tmp);
        return 0;
    }
    chmod(lw->tmp, 0444);
    if (rename(lw->tmp, path) != 0) {
        unlink(lw->tmp);
        return -1;
    }
    return 0;
}

/* Single instances, reused by every call (see zr_init). */
static zreader g_reader;
static loose_writer g_lw;
static zwriter g_pw;
static unsigned char g_buf[CHUNK];

static const char *check_type(lua_State *L, int idx)
{
    const char *t = luaL_checkstring(L, idx);
    int i;
    for (i = 0; obj_types[i]; i++)
        if (strcmp(t, obj_types[i]) == 0)
            return t;
    luaL_argerror(L, idx, "invalid object type");
    return NULL;
}

/* ------------------------------------------------------------------ */
/* Lua API                                                            */

/* inflate(data [, pos [, size_hint]]) -> out, consumed
 * Inflates one zlib stream starting at byte pos (1-based) of data and
 * returns the output and the number of input bytes the stream occupied. */
static int l_inflate(lua_State *L)
{
    size_t n;
    const unsigned char *s = (const unsigned char *)luaL_checklstring(L, 1, &n);
    lua_Integer pos = luaL_optinteger(L, 2, 1);
    lua_Integer hint = luaL_optinteger(L, 3, 0);
    z_stream z;
    luaL_Buffer b;
    int ret;

    luaL_argcheck(L, pos >= 1 && (size_t)pos <= n + 1, 2, "out of range");
    s += pos - 1;
    n -= (size_t)(pos - 1);
    memset(&z, 0, sizeof z);
    if (inflateInit(&z) != Z_OK)
        return luaL_error(L, "inflateInit failed");
    z.next_in = (unsigned char *)s;
    z.avail_in = (uInt)n;
    luaL_buffinitsize(L, &b, hint > 0 ? (size_t)hint : 256);
    for (;;) {
        size_t room = hint > 0 && b.n < (size_t)hint ? (size_t)hint - b.n : CHUNK;
        unsigned char *out = (unsigned char *)luaL_prepbuffsize(&b, room);
        z.next_out = out;
        z.avail_out = (uInt)room;
        ret = inflate(&z, Z_NO_FLUSH);
        luaL_addsize(&b, room - z.avail_out);
        if (ret == Z_STREAM_END)
            break;
        if (ret == Z_BUF_ERROR && z.avail_in == 0) {
            inflateEnd(&z);
            return luaL_error(L, "inflate: truncated zlib stream");
        }
        if (ret != Z_OK && ret != Z_BUF_ERROR) {
            const char *msg = z.msg ? z.msg : "corrupt zlib stream";
            inflateEnd(&z);
            return luaL_error(L, "inflate: %s", msg);
        }
    }
    luaL_pushresult(&b);
    lua_pushinteger(L, (lua_Integer)(n - z.avail_in));
    inflateEnd(&z);
    return 2;
}

/* deflate(data [, level]) -> zlib stream */
static int l_deflate(lua_State *L)
{
    size_t n;
    const unsigned char *s = (const unsigned char *)luaL_checklstring(L, 1, &n);
    int level = (int)luaL_optinteger(L, 2, Z_DEFAULT_COMPRESSION);
    uLongf outlen = compressBound((uLong)n);
    luaL_Buffer b;
    unsigned char *out = (unsigned char *)luaL_buffinitsize(L, &b, outlen);
    if (compress2(out, &outlen, s, (uLong)n, level) != Z_OK)
        return luaL_error(L, "deflate failed");
    luaL_pushresultsize(&b, outlen);
    return 1;
}

/* pack_inflate(fh, offset, size) -> content, consumed
 * Inflates the zlib stream at offset of an open pack file. size is the
 * inflated size announced by the pack entry header. */
static int l_pack_inflate(lua_State *L)
{
    FILE *f = pg_checkfile(L, 1);
    lua_Integer off = luaL_checkinteger(L, 2);
    lua_Integer size = luaL_checkinteger(L, 3);
    zreader *r;
    luaL_Buffer b;
    const char *err = NULL;
    char *out;
    long got;
    unsigned char extra;

    if (fseeko(f, (off_t)off, SEEK_SET) != 0)
        return pg_fail(L, "seek");
    r = &g_reader;
    if (zr_init(r, f) != 0)
        return luaL_error(L, "zlib initialisation failed");
    out = luaL_buffinitsize(L, &b, (size_t)size);
    got = size > 0 ? zr_read(r, (unsigned char *)out, (size_t)size, &err) : 0;
    /* Keep reading while the stream continues in tiny pieces. */
    while (got >= 0 && got < size && !r->ended) {
        long more = zr_read(r, (unsigned char *)out + got, (size_t)(size - got), &err);
        if (more <= 0) {
            got = more < 0 ? -1 : got;
            break;
        }
        got += more;
    }
    if (got >= 0 && !r->ended) {
        long more = zr_read(r, &extra, 1, &err);
        if (more > 0)
            err = "object larger than its header says";
        else if (more < 0)
            got = -1;
    }
    if (got >= 0 && got != size && !err)
        err = "object size mismatch";
    if (got < 0 || err) {
        zr_end(r);
        return luaL_error(L, "pack_inflate at %I: %s", off, err ? err : "error");
    }
    luaL_pushresultsize(&b, (size_t)size);
    lua_pushinteger(L, (lua_Integer)zr_consumed(r));
    zr_end(r);
    return 2;
}

/* pack_skip(fh, offset, size) -> consumed
 * Inflates and discards a pack entry, only to learn where it ends (and to
 * validate it) without creating a Lua string. */
static int l_pack_skip(lua_State *L)
{
    FILE *f = pg_checkfile(L, 1);
    lua_Integer off = luaL_checkinteger(L, 2);
    lua_Integer size = luaL_checkinteger(L, 3);
    zreader *r;
    unsigned char *buf;
    const char *err = NULL;
    int64_t total = 0, consumed;

    if (fseeko(f, (off_t)off, SEEK_SET) != 0)
        return pg_fail(L, "seek");
    r = &g_reader;
    buf = g_buf;
    if (zr_init(r, f) != 0)
        return luaL_error(L, "zlib initialisation failed");
    for (;;) {
        long got = zr_read(r, buf, CHUNK, &err);
        if (got <= 0)
            break;
        total += got;
    }
    if (!err && total != size)
        err = "object size mismatch";
    consumed = zr_consumed(r);
    zr_end(r);
    if (err)
        return luaL_error(L, "pack entry at %I: %s", off, err);
    lua_pushinteger(L, (lua_Integer)consumed);
    return 1;
}

/* pack_inflate_loose(fh, offset, size, objdir, type) -> sha, consumed
 * Streams a non-delta pack entry straight into a loose object. */
static int l_pack_inflate_loose(lua_State *L)
{
    FILE *f = pg_checkfile(L, 1);
    lua_Integer off = luaL_checkinteger(L, 2);
    lua_Integer size = luaL_checkinteger(L, 3);
    const char *objdir = luaL_checkstring(L, 4);
    const char *type = check_type(L, 5);
    zreader *r;
    loose_writer *lw;
    unsigned char *buf, sha[20];
    const char *err = NULL;
    int64_t total = 0;
    int64_t consumed;

    if (fseeko(f, (off_t)off, SEEK_SET) != 0)
        return pg_fail(L, "seek");
    r = &g_reader;
    lw = &g_lw;
    buf = g_buf;
    if (zr_init(r, f) != 0)
        return luaL_error(L, "zlib initialisation failed");
    if (lw_open(lw, objdir, type, size) != 0) {
        err = strerror(errno);
        lw_abort(lw);
    } else {
        for (;;) {
            long got = zr_read(r, buf, CHUNK, &err);
            if (got < 0)
                break;
            if (got == 0)
                break;
            total += got;
            if (total > size) {
                err = "object larger than its header says";
                break;
            }
            if (lw_write(lw, buf, (size_t)got) != 0) {
                err = strerror(errno);
                break;
            }
        }
        if (!err && total != size)
            err = "object size mismatch";
        if (err)
            lw_abort(lw);
        else if (lw_finish(lw, sha) != 0)
            err = strerror(errno);
    }
    consumed = zr_consumed(r);
    zr_end(r);
    if (err)
        return luaL_error(L, "pack entry at %I: %s", off, err);
    lua_pushlstring(L, (const char *)sha, 20);
    lua_pushinteger(L, (lua_Integer)consumed);
    return 2;
}

/* Opens a loose object and parses its header. On success *type_idx and
 * *size are set and the reader is positioned at the content. Any content
 * bytes inflated together with the header are returned in pre/prelen. */
static int open_loose(zreader *r, FILE **fp, const char *path, int *type_idx,
                      int64_t *size, unsigned char *pre, size_t *prelen,
                      const char **err)
{
    unsigned char hdr[64];
    size_t have = 0;
    unsigned char *nul = NULL;
    char *sp;
    int i;

    *fp = fopen(path, "rb");
    if (!*fp) {
        *err = strerror(errno);
        return -1;
    }
    if (zr_init(r, *fp) != 0) {
        *err = "zlib initialisation failed";
        return -1;
    }
    while (!nul) {
        long got = zr_read(r, hdr + have, sizeof hdr - have, err);
        if (got <= 0) {
            if (got == 0)
                *err = "bad loose object header";
            return -1;
        }
        have += (size_t)got;
        nul = memchr(hdr, 0, have);
        if (!nul && have == sizeof hdr) {
            *err = "bad loose object header";
            return -1;
        }
    }
    sp = memchr(hdr, ' ', (size_t)(nul - hdr));
    if (!sp) {
        *err = "bad loose object header";
        return -1;
    }
    *sp = 0;
    *type_idx = -1;
    for (i = 0; obj_types[i]; i++)
        if (strcmp((char *)hdr, obj_types[i]) == 0)
            *type_idx = i;
    if (*type_idx < 0) {
        *err = "unknown object type";
        return -1;
    }
    *size = strtoll(sp + 1, NULL, 10);
    *prelen = have - (size_t)(nul + 1 - hdr);
    memcpy(pre, nul + 1, *prelen);
    return 0;
}

/* loose_header(path) -> type, size */
static int l_loose_header(lua_State *L)
{
    const char *path = luaL_checkstring(L, 1);
    zreader *r = &g_reader;
    FILE *f = NULL;
    int t;
    int64_t size;
    unsigned char pre[64];
    size_t prelen;
    const char *err = NULL;
    int rc;

    rc = open_loose(r, &f, path, &t, &size, pre, &prelen, &err);
    zr_end(r);
    if (f)
        fclose(f);
    if (rc != 0) {
        luaL_pushfail(L);
        lua_pushfstring(L, "%s: %s", path, err);
        return 2;
    }
    lua_pushstring(L, obj_types[t]);
    lua_pushinteger(L, (lua_Integer)size);
    return 2;
}

/* loose_read(path) -> type, content */
static int l_loose_read(lua_State *L)
{
    const char *path = luaL_checkstring(L, 1);
    zreader *r = &g_reader;
    FILE *f = NULL;
    int t;
    int64_t size, total;
    unsigned char pre[64];
    size_t prelen;
    const char *err = NULL;
    luaL_Buffer b;
    char *out;

    if (open_loose(r, &f, path, &t, &size, pre, &prelen, &err) != 0)
        goto fail;
    if ((int64_t)prelen > size) {
        err = "object larger than its header says";
        goto fail;
    }
    out = luaL_buffinitsize(L, &b, (size_t)size);
    memcpy(out, pre, prelen);
    total = (int64_t)prelen;
    while (total < size) {
        long got = zr_read(r, (unsigned char *)out + total, (size_t)(size - total), &err);
        if (got <= 0) {
            if (got == 0)
                err = "object shorter than its header says";
            goto fail;
        }
        total += got;
    }
    zr_end(r);
    fclose(f);
    luaL_pushresultsize(&b, (size_t)size);
    lua_pushstring(L, obj_types[t]);
    lua_insert(L, -2);
    return 2;
fail:
    zr_end(r);
    if (f)
        fclose(f);
    return luaL_error(L, "%s: %s", path, err);
}

/* loose_write(objdir_or_nil, type, content) -> sha
 * With objdir nil only the object id is computed. */
static int l_loose_write(lua_State *L)
{
    const char *objdir = luaL_optstring(L, 1, NULL);
    const char *type = check_type(L, 2);
    size_t n;
    const char *s = luaL_checklstring(L, 3, &n);
    loose_writer *lw = &g_lw;
    unsigned char sha[20];

    if (lw_open(lw, objdir, type, (int64_t)n) != 0 || lw_write(lw, s, n) != 0) {
        int en = errno;
        lw_abort(lw);
        return luaL_error(L, "cannot write object: %s", strerror(en));
    }
    if (lw_finish(lw, sha) != 0) {
        int en = errno;
        return luaL_error(L, "cannot write object: %s", strerror(en));
    }
    lua_pushlstring(L, (const char *)sha, 20);
    return 1;
}

/* hash_file(path [, objdir]) -> sha, size
 * Hashes a work tree file as a blob, storing it when objdir is given. */
static int l_hash_file(lua_State *L)
{
    const char *path = luaL_checkstring(L, 1);
    const char *objdir = luaL_optstring(L, 2, NULL);
    loose_writer *lw;
    unsigned char *buf, sha[20];
    struct stat st;
    int64_t total = 0;
    const char *err = NULL;
    FILE *f = fopen(path, "rb");

    if (!f)
        return pg_fail(L, path);
    if (fstat(fileno(f), &st) != 0) {
        fclose(f);
        return pg_fail(L, path);
    }
    lw = &g_lw;
    buf = g_buf;
    if (lw_open(lw, objdir, "blob", (int64_t)st.st_size) != 0) {
        err = strerror(errno);
    } else {
        for (;;) {
            size_t got = fread(buf, 1, CHUNK, f);
            if (got == 0) {
                if (ferror(f))
                    err = strerror(errno);
                break;
            }
            total += (int64_t)got;
            if (total > (int64_t)st.st_size)
                break;
            if (lw_write(lw, buf, got) != 0) {
                err = strerror(errno);
                break;
            }
        }
        if (!err && total != (int64_t)st.st_size)
            err = "file changed while it was being read";
    }
    if (err)
        lw_abort(lw);
    else if (lw_finish(lw, sha) != 0)
        err = strerror(errno);
    fclose(f);
    if (err)
        return luaL_error(L, "%s: %s", path, err);
    lua_pushlstring(L, (const char *)sha, 20);
    lua_pushinteger(L, (lua_Integer)total);
    return 2;
}

/* loose_to_file(objpath, outpath, mode) -> size
 * Writes the content of a loose blob to a (new) file. */
static int l_loose_to_file(lua_State *L)
{
    const char *path = luaL_checkstring(L, 1);
    const char *outpath = luaL_checkstring(L, 2);
    int mode = (int)luaL_checkinteger(L, 3);
    zreader *r = &g_reader;
    unsigned char *buf = g_buf;
    FILE *f = NULL;
    int fd = -1, t;
    int64_t size, total = 0;
    unsigned char pre[64];
    size_t prelen;
    const char *err = NULL;

    if (open_loose(r, &f, path, &t, &size, pre, &prelen, &err) != 0)
        goto done;
    if (t != 2) {
        err = "not a blob";
        goto done;
    }
    fd = open(outpath, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, mode);
    if (fd < 0) {
        err = strerror(errno);
        goto done;
    }
    if (prelen && write(fd, pre, prelen) != (ssize_t)prelen) {
        err = strerror(errno);
        goto done;
    }
    total = (int64_t)prelen;
    for (;;) {
        long got = zr_read(r, buf, CHUNK, &err);
        if (got < 0)
            goto done;
        if (got == 0)
            break;
        total += got;
        if (write(fd, buf, (size_t)got) != got) {
            err = strerror(errno);
            goto done;
        }
    }
    if (total != size)
        err = "object size mismatch";
done:
    if (fd >= 0 && close(fd) != 0 && !err)
        err = strerror(errno);
    zr_end(r);
    if (f)
        fclose(f);
    if (err)
        return luaL_error(L, "checkout %s: %s", outpath, err);
    lua_pushinteger(L, (lua_Integer)total);
    return 1;
}

/* loose_to_pack(objpath, out_fh [, level]) -> type, size
 * Appends a non-delta pack entry for the loose object to an open file. */
static int l_loose_to_pack(lua_State *L)
{
    const char *path = luaL_checkstring(L, 1);
    FILE *out = pg_checkfile(L, 2);
    int level = (int)luaL_optinteger(L, 3, Z_DEFAULT_COMPRESSION);
    zreader *r = &g_reader;
    zwriter *w = &g_pw;
    unsigned char *buf = g_buf;
    FILE *f = NULL;
    int t;
    int64_t size, total = 0;
    unsigned char pre[64], hdr[16];
    size_t prelen, hl = 0;
    uint64_t sz;
    const char *err = NULL;

    if (open_loose(r, &f, path, &t, &size, pre, &prelen, &err) != 0)
        goto done;
    /* entry header: type in bits 4-6 of the first byte, size as a
     * little-endian base-128 varint (4 bits in the first byte). */
    sz = (uint64_t)size;
    hdr[hl] = (unsigned char)(obj_type_nums[t] << 4 | (sz & 15));
    sz >>= 4;
    while (sz) {
        hdr[hl++] |= 0x80;
        hdr[hl] = sz & 0x7f;
        sz >>= 7;
    }
    hl++;
    if (fwrite(hdr, 1, hl, out) != hl || zw_init(w, out, level) != 0) {
        err = "write error";
        goto done;
    }
    if (prelen && zw_write(w, pre, prelen) != 0) {
        err = "write error";
        goto done;
    }
    total = (int64_t)prelen;
    for (;;) {
        long got = zr_read(r, buf, CHUNK, &err);
        if (got < 0)
            goto done;
        if (got == 0)
            break;
        total += got;
        if (zw_write(w, buf, (size_t)got) != 0) {
            err = "write error";
            goto done;
        }
    }
    if (total != size)
        err = "object size mismatch";
    else if (zw_finish(w) != 0)
        err = "write error";
done:
    zw_end(w);
    zr_end(r);
    if (f)
        fclose(f);
    if (err)
        return luaL_error(L, "pack %s: %s", path, err);
    lua_pushstring(L, obj_types[t]);
    lua_pushinteger(L, (lua_Integer)size);
    return 2;
}

void pg_register_zlib(lua_State *L)
{
    static const luaL_Reg fns[] = {
        {"inflate", l_inflate},
        {"deflate", l_deflate},
        {"pack_inflate", l_pack_inflate},
        {"pack_inflate_loose", l_pack_inflate_loose},
        {"pack_skip", l_pack_skip},
        {"loose_header", l_loose_header},
        {"loose_read", l_loose_read},
        {"loose_write", l_loose_write},
        {"hash_file", l_hash_file},
        {"loose_to_file", l_loose_to_file},
        {"loose_to_pack", l_loose_to_pack},
        {NULL, NULL}};
    luaL_setfuncs(L, fns, 0);
}
