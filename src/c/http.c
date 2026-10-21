/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * Minimal HTTP/1.1 client over plain TCP or TLS (Mbed TLS).
 *
 * One request per connection ("Connection: close"). The response body is
 * read incrementally by Lua through conn:read(n), so large packfiles can
 * be streamed to disk; request bodies can be assembled from strings and
 * files and are streamed as well.
 *
 * Redirects, authentication and URL parsing are handled in Lua
 * (transport.lua); this file only speaks to one host:port.
 */
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#include "zlib.h"
#include "mbedtls/ssl.h"
#include "mbedtls/x509_crt.h"
#include "psa/crypto.h"

#include "picogit.h"

#define HTTP_MT "picogit.http"
#define BUFSZ 16384
#define MAX_HEADER 65536
#define PG_ERR_IO (-0x7F00)

enum { BODY_NONE, BODY_LENGTH, BODY_CHUNKED, BODY_CLOSE };

typedef struct {
    int fd;
    int use_tls;
    int tls_ready;
    mbedtls_ssl_context ssl;
    char err[256];
    unsigned char *buf; /* BUFSZ bytes, unread data is buf[pos..len) */
    size_t pos, len;
    int body;
    int64_t remaining;
    int in_chunk;
    int eof;
} http_conn;

/* ------------------------------------------------------------------ */
/* TLS configuration (shared by all connections of the process)       */

static struct {
    int init;
    int insecure;
    mbedtls_ssl_config conf;
    mbedtls_x509_crt ca;
    unsigned char *ca_der;
    int ca_count;
} tlsg;

static int rng_cb(void *ctx, unsigned char *out, size_t n)
{
    (void)ctx;
    return pg_random(out, n) == 0 ? 0 : MBEDTLS_ERR_SSL_INTERNAL_ERROR;
}

static int load_embedded_ca(char *err, size_t errlen)
{
    uLongf len = (uLongf)pg_cabundle_len;
    size_t off = 0;

    tlsg.ca_der = malloc(pg_cabundle_len);
    if (!tlsg.ca_der) {
        snprintf(err, errlen, "out of memory");
        return -1;
    }
    if (uncompress(tlsg.ca_der, &len, pg_cabundle_z, (uLong)pg_cabundle_z_len) != Z_OK ||
        len != pg_cabundle_len) {
        snprintf(err, errlen, "embedded CA bundle is corrupt");
        return -1;
    }
    /* The bundle is a plain concatenation of DER certificates; each one
     * starts with a SEQUENCE header that gives its length. */
    while (off + 4 <= len) {
        const unsigned char *p = tlsg.ca_der + off;
        size_t hl, cl;
        if (p[0] != 0x30)
            break;
        if (p[1] < 0x80) {
            hl = 2;
            cl = p[1];
        } else {
            size_t nb = p[1] & 0x7f, i;
            if (nb < 1 || nb > 3 || off + 2 + nb > len)
                break;
            hl = 2 + nb;
            cl = 0;
            for (i = 0; i < nb; i++)
                cl = cl << 8 | p[2 + i];
        }
        if (off + hl + cl > len)
            break;
        /* Certificates using algorithms we do not support are skipped. */
        if (mbedtls_x509_crt_parse_der_nocopy(&tlsg.ca, p, hl + cl) == 0)
            tlsg.ca_count++;
        off += hl + cl;
    }
    if (tlsg.ca_count == 0) {
        snprintf(err, errlen, "no usable certificate in the embedded CA bundle");
        return -1;
    }
    return 0;
}

static int load_ca_file(const char *path, char *err, size_t errlen)
{
    FILE *f = fopen(path, "rb");
    struct stat st;
    unsigned char *data;
    int rc;

    if (!f || fstat(fileno(f), &st) != 0) {
        snprintf(err, errlen, "cannot read CA file %s: %s", path, strerror(errno));
        if (f)
            fclose(f);
        return -1;
    }
    data = malloc((size_t)st.st_size + 1);
    if (!data || fread(data, 1, (size_t)st.st_size, f) != (size_t)st.st_size) {
        snprintf(err, errlen, "cannot read CA file %s", path);
        free(data);
        fclose(f);
        return -1;
    }
    fclose(f);
    data[st.st_size] = 0;
    /* PEM input must include the terminating NUL in its length. */
    rc = mbedtls_x509_crt_parse(&tlsg.ca, data,
                                memmem(data, (size_t)st.st_size, "-----BEGIN", 10)
                                    ? (size_t)st.st_size + 1 : (size_t)st.st_size);
    free(data);
    if (rc < 0 || tlsg.ca.version == 0) {
        snprintf(err, errlen, "no usable certificate in %s", path);
        return -1;
    }
    return 0;
}

static int tls_setup(const char *cafile, int insecure, char *err, size_t errlen)
{
    if (tlsg.init)
        return 0;
    if (psa_crypto_init() != PSA_SUCCESS) {
        snprintf(err, errlen, "TLS: crypto initialisation failed");
        return -1;
    }
    mbedtls_ssl_config_init(&tlsg.conf);
    mbedtls_x509_crt_init(&tlsg.ca);
    if (mbedtls_ssl_config_defaults(&tlsg.conf, MBEDTLS_SSL_IS_CLIENT,
                                    MBEDTLS_SSL_TRANSPORT_STREAM,
                                    MBEDTLS_SSL_PRESET_DEFAULT) != 0) {
        snprintf(err, errlen, "TLS: configuration failed");
        return -1;
    }
    mbedtls_ssl_conf_rng(&tlsg.conf, rng_cb, NULL);
    tlsg.insecure = insecure;
    if (insecure) {
        mbedtls_ssl_conf_authmode(&tlsg.conf, MBEDTLS_SSL_VERIFY_NONE);
    } else {
        if (cafile ? load_ca_file(cafile, err, errlen) : load_embedded_ca(err, errlen))
            return -1;
        mbedtls_ssl_conf_authmode(&tlsg.conf, MBEDTLS_SSL_VERIFY_REQUIRED);
        mbedtls_ssl_conf_ca_chain(&tlsg.conf, &tlsg.ca, NULL);
    }
    tlsg.init = 1;
    return 0;
}

/* Router clocks are often wrong (no RTC, NTP not yet synced). A clock that
 * is behind the date of the embedded CA bundle is certainly wrong. */
static int clock_is_suspect(void)
{
    struct tm tm;
    memset(&tm, 0, sizeof tm);
    if (sscanf(PICOGIT_CA_DATE, "%d-%d-%d", &tm.tm_year, &tm.tm_mon, &tm.tm_mday) != 3)
        return 0;
    tm.tm_year -= 1900;
    tm.tm_mon -= 1;
    return time(NULL) < timegm(&tm);
}

static void append(char *out, size_t n, const char *s)
{
    size_t l = strlen(out);
    snprintf(out + l, n - l, "%s%s", l ? "; " : "", s);
}

static void clock_hint(char *out, size_t n)
{
    char tmp[160];
    time_t now = time(NULL);
    struct tm tm;
    gmtime_r(&now, &tm);
    snprintf(tmp, sizeof tmp,
             "the device clock says %04d-%02d-%02d %02d:%02d UTC - "
             "check the system time / NTP",
             tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday, tm.tm_hour, tm.tm_min);
    append(out, n, tmp);
}

static void verify_message(char *out, size_t n, uint32_t flags)
{
    char why[400] = "";
    if (flags & MBEDTLS_X509_BADCERT_FUTURE)
        append(why, sizeof why, "a certificate is not valid yet");
    if (flags & MBEDTLS_X509_BADCERT_EXPIRED)
        append(why, sizeof why, "a certificate has expired");
    if (flags & MBEDTLS_X509_BADCERT_CN_MISMATCH)
        append(why, sizeof why, "the certificate does not match the host name");
    if (flags & MBEDTLS_X509_BADCERT_NOT_TRUSTED)
        append(why, sizeof why, "the certificate is not signed by a trusted CA "
                                "(use --cacert FILE for a private CA)");
    if (flags & (MBEDTLS_X509_BADCERT_BAD_MD | MBEDTLS_X509_BADCERT_BAD_PK |
                 MBEDTLS_X509_BADCERT_BAD_KEY))
        append(why, sizeof why, "the certificate uses an unsupported algorithm or key");
    if (flags & MBEDTLS_X509_BADCERT_REVOKED)
        append(why, sizeof why, "the certificate was revoked");
    if (!why[0])
        snprintf(why, sizeof why, "verification flags 0x%08x", (unsigned)flags);
    if ((flags & (MBEDTLS_X509_BADCERT_FUTURE | MBEDTLS_X509_BADCERT_EXPIRED)) ||
        clock_is_suspect())
        clock_hint(why, sizeof why);
    snprintf(out, n, "TLS certificate verification failed: %s", why);
}

/* ------------------------------------------------------------------ */
/* Socket I/O                                                         */

static int bio_send(void *ctx, const unsigned char *p, size_t n)
{
    http_conn *c = ctx;
    for (;;) {
        ssize_t r = send(c->fd, p, n, MSG_NOSIGNAL);
        if (r >= 0)
            return (int)r;
        if (errno == EINTR)
            continue;
        snprintf(c->err, sizeof c->err, "send: %s",
                 errno == EAGAIN ? "timed out" : strerror(errno));
        return PG_ERR_IO;
    }
}

static int bio_recv(void *ctx, unsigned char *p, size_t n)
{
    http_conn *c = ctx;
    for (;;) {
        ssize_t r = recv(c->fd, p, n, 0);
        if (r >= 0)
            return (int)r;
        if (errno == EINTR)
            continue;
        snprintf(c->err, sizeof c->err, "receive: %s",
                 errno == EAGAIN ? "timed out" : strerror(errno));
        return PG_ERR_IO;
    }
}

static int conn_write(http_conn *c, const void *data, size_t n)
{
    const unsigned char *p = data;
    while (n > 0) {
        int r = c->use_tls ? mbedtls_ssl_write(&c->ssl, p, n) : bio_send(c, p, n);
        if (r == MBEDTLS_ERR_SSL_WANT_READ || r == MBEDTLS_ERR_SSL_WANT_WRITE)
            continue;
        if (r < 0) {
            if (!c->err[0])
                snprintf(c->err, sizeof c->err, "TLS write error -0x%04x", -r);
            return -1;
        }
        p += r;
        n -= (size_t)r;
    }
    return 0;
}

/* Returns bytes read, 0 on EOF, -1 on error. */
static long conn_recv(http_conn *c, unsigned char *p, size_t n)
{
    for (;;) {
        int r;
        if (!c->use_tls) {
            r = bio_recv(c, p, n);
            return r == PG_ERR_IO ? -1 : r;
        }
        r = mbedtls_ssl_read(&c->ssl, p, n);
        if (r >= 0)
            return r;
        if (r == MBEDTLS_ERR_SSL_WANT_READ || r == MBEDTLS_ERR_SSL_WANT_WRITE)
            continue;
        if (r == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY || r == MBEDTLS_ERR_SSL_CONN_EOF)
            return 0;
        if (!c->err[0])
            snprintf(c->err, sizeof c->err, "TLS read error -0x%04x", -r);
        return -1;
    }
}

/* Make sure there is unread data in the buffer. Returns 1 if data is
 * available, 0 on EOF, -1 on error. */
static int conn_fill(http_conn *c)
{
    long r;
    if (c->pos < c->len)
        return 1;
    c->pos = c->len = 0;
    r = conn_recv(c, c->buf, BUFSZ);
    if (r < 0)
        return -1;
    c->len = (size_t)r;
    return r > 0;
}

/* Read one CRLF (or LF) terminated line into out (without the line end).
 * Returns line length or -1. */
static long conn_readline(http_conn *c, char *out, size_t max)
{
    size_t n = 0;
    for (;;) {
        int r = conn_fill(c);
        if (r <= 0) {
            if (r == 0)
                snprintf(c->err, sizeof c->err, "connection closed unexpectedly");
            return -1;
        }
        while (c->pos < c->len) {
            char ch = (char)c->buf[c->pos++];
            if (ch == '\n') {
                if (n > 0 && out[n - 1] == '\r')
                    n--;
                out[n] = 0;
                return (long)n;
            }
            if (n + 1 >= max) {
                snprintf(c->err, sizeof c->err, "HTTP line too long");
                return -1;
            }
            out[n++] = ch;
        }
    }
}

static int set_blocking_timeouts(int fd, int timeout_ms)
{
    struct timeval tv;
    int fl = fcntl(fd, F_GETFL);
    if (fl < 0 || fcntl(fd, F_SETFL, fl & ~O_NONBLOCK) < 0)
        return -1;
    tv.tv_sec = timeout_ms / 1000;
    tv.tv_usec = (timeout_ms % 1000) * 1000;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
    return 0;
}

static int tcp_connect(http_conn *c, const char *host, int port, int timeout_ms)
{
    struct addrinfo hints, *res = NULL, *ai;
    char portstr[16];
    int rc, last_err = 0;

    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    snprintf(portstr, sizeof portstr, "%d", port);
    rc = getaddrinfo(host, portstr, &hints, &res);
    if (rc != 0) {
        snprintf(c->err, sizeof c->err, "cannot resolve host '%s': %s", host,
                 rc == EAI_SYSTEM ? strerror(errno) : gai_strerror(rc));
        return -1;
    }
    for (ai = res; ai; ai = ai->ai_next) {
        int fd = socket(ai->ai_family, ai->ai_socktype | SOCK_CLOEXEC, ai->ai_protocol);
        if (fd < 0) {
            last_err = errno;
            continue;
        }
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
        rc = connect(fd, ai->ai_addr, ai->ai_addrlen);
        if (rc != 0 && errno == EINPROGRESS) {
            struct pollfd pfd = {fd, POLLOUT, 0};
            int err = 0;
            socklen_t el = sizeof err;
            rc = poll(&pfd, 1, timeout_ms);
            if (rc == 0) {
                errno = ETIMEDOUT;
                rc = -1;
            } else if (rc > 0) {
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &el);
                errno = err;
                rc = err ? -1 : 0;
            }
        }
        if (rc == 0 && set_blocking_timeouts(fd, timeout_ms) == 0) {
            c->fd = fd;
            freeaddrinfo(res);
            return 0;
        }
        last_err = errno;
        close(fd);
    }
    freeaddrinfo(res);
    snprintf(c->err, sizeof c->err, "cannot connect to %s port %d: %s", host, port,
             strerror(last_err ? last_err : ECONNREFUSED));
    return -1;
}

static int tls_handshake(http_conn *c, const char *host)
{
    int r;
    mbedtls_ssl_init(&c->ssl);
    c->tls_ready = 1;
    if (mbedtls_ssl_setup(&c->ssl, &tlsg.conf) != 0 ||
        mbedtls_ssl_set_hostname(&c->ssl, host) != 0) {
        snprintf(c->err, sizeof c->err, "TLS setup failed");
        return -1;
    }
    mbedtls_ssl_set_bio(&c->ssl, c, bio_send, bio_recv, NULL);
    while ((r = mbedtls_ssl_handshake(&c->ssl)) != 0) {
        if (r == MBEDTLS_ERR_SSL_WANT_READ || r == MBEDTLS_ERR_SSL_WANT_WRITE)
            continue;
        if (r == MBEDTLS_ERR_X509_CERT_VERIFY_FAILED) {
            verify_message(c->err, sizeof c->err, mbedtls_ssl_get_verify_result(&c->ssl));
        } else if (r != PG_ERR_IO || !c->err[0]) {
            char why[256];
            snprintf(why, sizeof why, "TLS handshake with %s failed (-0x%04x)", host, -r);
            if (clock_is_suspect())
                clock_hint(why, sizeof why);
            snprintf(c->err, sizeof c->err, "%s", why);
        }
        return -1;
    }
    return 0;
}

static void conn_close(http_conn *c)
{
    if (c->tls_ready) {
        mbedtls_ssl_free(&c->ssl);
        c->tls_ready = 0;
    }
    if (c->fd >= 0) {
        close(c->fd);
        c->fd = -1;
    }
    free(c->buf);
    c->buf = NULL;
}

/* ------------------------------------------------------------------ */
/* Request / response                                                 */

static int send_file(http_conn *c, const char *path, int64_t expect)
{
    FILE *f = fopen(path, "rb");
    unsigned char *b = c->buf; /* the read buffer is free while sending */
    int64_t total = 0;
    if (!f) {
        snprintf(c->err, sizeof c->err, "%s: %s", path, strerror(errno));
        return -1;
    }
    for (;;) {
        size_t n = fread(b, 1, BUFSZ, f);
        if (n == 0)
            break;
        total += (int64_t)n;
        if (conn_write(c, b, n) != 0) {
            fclose(f);
            return -1;
        }
    }
    fclose(f);
    if (total != expect) {
        snprintf(c->err, sizeof c->err, "%s changed while sending", path);
        return -1;
    }
    return 0;
}

/* Strict parser for Content-Length (base 10) and chunk sizes (base 16):
 * digits only (a chunk size may be followed by ";extensions"), no sign, no
 * overflow. Returns -1 for anything else. A negative value reaching the
 * body reader would otherwise turn into a huge memcpy length. */
static int64_t parse_size(const char *s, int base)
{
    int64_t v = 0;
    int digits = 0;
    while (*s == ' ' || *s == '\t')
        s++;
    for (; *s; s++) {
        int d;
        if (*s >= '0' && *s <= '9')
            d = *s - '0';
        else if (base == 16 && *s >= 'a' && *s <= 'f')
            d = *s - 'a' + 10;
        else if (base == 16 && *s >= 'A' && *s <= 'F')
            d = *s - 'A' + 10;
        else
            break;
        if (v > (INT64_MAX - d) / base)
            return -1;
        v = v * base + d;
        digits++;
    }
    while (*s == ' ' || *s == '\t')
        s++;
    if (!digits || (*s && !(base == 16 && *s == ';')))
        return -1;
    return v;
}

static int parse_response_head(lua_State *L, http_conn *c, int *status)
{
    char line[8192];
    long n;
    size_t total = 0;
    int interim = 0;
    for (;;) {
        int major, minor;
        n = conn_readline(c, line, sizeof line);
        if (n < 0)
            return -1;
        if (sscanf(line, "HTTP/%d.%d %d", &major, &minor, status) != 3) {
            snprintf(c->err, sizeof c->err, "malformed HTTP status line");
            return -1;
        }
        lua_pushstring(L, line);
        lua_newtable(L);
        for (;;) {
            char *colon, *v, *k;
            n = conn_readline(c, line, sizeof line);
            if (n < 0)
                return -1;
            if (n == 0)
                break;
            total += (size_t)n;
            if (total > MAX_HEADER) {
                snprintf(c->err, sizeof c->err, "HTTP response header too large");
                return -1;
            }
            colon = strchr(line, ':');
            if (!colon)
                continue;
            *colon = 0;
            for (k = line; *k; k++)
                if (*k >= 'A' && *k <= 'Z')
                    *k = (char)(*k + 32);
            for (v = colon + 1; *v == ' ' || *v == '\t'; v++)
                ;
            for (k = v + strlen(v); k > v && (k[-1] == ' ' || k[-1] == '\t'); k--)
                k[-1] = 0;
            lua_getfield(L, -1, line);
            if (lua_isstring(L, -1)) {
                lua_pushliteral(L, ", ");
                lua_pushstring(L, v);
                lua_concat(L, 3);
            } else {
                lua_pop(L, 1);
                lua_pushstring(L, v);
            }
            lua_setfield(L, -2, line);
        }
        if (*status >= 100 && *status < 200) {
            lua_pop(L, 2); /* interim response (100 Continue): ignore */
            if (++interim > 10) {
                snprintf(c->err, sizeof c->err, "too many interim HTTP responses");
                return -1;
            }
            continue;
        }
        return 0;
    }
}

/* http_request{host=, port=, tls=, method=, path=, headers={...}, body={...},
 *              cacert=, insecure=, timeout=}
 *   -> conn, status, headers, status_line | nil, err
 * headers: array of "Name: value" strings.
 * body: array of parts, each a string or {file=path}. */
static int l_http_request(lua_State *L)
{
    const char *host, *method, *path, *cafile = NULL;
    int port, use_tls, insecure, timeout_ms, status, i, nparts;
    int64_t content_len = 0;
    int has_body;
    http_conn *c;

    luaL_checktype(L, 1, LUA_TTABLE);
    lua_getfield(L, 1, "host");
    host = luaL_checkstring(L, -1);
    lua_getfield(L, 1, "port");
    port = (int)luaL_checkinteger(L, -1);
    lua_getfield(L, 1, "tls");
    use_tls = lua_toboolean(L, -1);
    lua_getfield(L, 1, "method");
    method = luaL_optstring(L, -1, "GET");
    lua_getfield(L, 1, "path");
    path = luaL_optstring(L, -1, "/");
    lua_getfield(L, 1, "cacert");
    if (!lua_isnil(L, -1))
        cafile = luaL_checkstring(L, -1);
    lua_getfield(L, 1, "insecure");
    insecure = lua_toboolean(L, -1);
    lua_getfield(L, 1, "timeout");
    timeout_ms = (int)(luaL_optnumber(L, -1, 120) * 1000);
    lua_pop(L, 1);
    lua_getfield(L, 1, "body");
    has_body = !lua_isnil(L, -1);
    nparts = has_body ? (int)luaL_len(L, -1) : 0;
    for (i = 1; i <= nparts; i++) {
        lua_rawgeti(L, -1, i);
        if (lua_type(L, -1) == LUA_TSTRING) {
            content_len += (int64_t)lua_rawlen(L, -1);
        } else {
            struct stat st;
            const char *fp;
            lua_getfield(L, -1, "file");
            fp = luaL_checkstring(L, -1);
            if (stat(fp, &st) != 0)
                return pg_fail(L, fp);
            content_len += (int64_t)st.st_size;
            lua_pop(L, 1);
        }
        lua_pop(L, 1);
    }
    /* The option strings stay referenced by the opts table. */
    lua_settop(L, 1);

    c = lua_newuserdatauv(L, sizeof *c, 0);
    memset(c, 0, sizeof *c);
    c->fd = -1;
    c->use_tls = use_tls;
    luaL_setmetatable(L, HTTP_MT);
    c->buf = malloc(BUFSZ);
    if (!c->buf)
        return luaL_error(L, "out of memory");

    if (use_tls && tls_setup(cafile, insecure, c->err, sizeof c->err) != 0)
        goto fail;
    if (tcp_connect(c, host, port, timeout_ms) != 0)
        goto fail;
    if (use_tls && tls_handshake(c, host) != 0)
        goto fail;

    /* request head */
    {
        char head[8192];
        size_t hl = 0;
        int ok = 1;
#define HEAD_ADD(...) do { \
        int w_ = snprintf(head + hl, sizeof head - hl, __VA_ARGS__); \
        if (w_ < 0 || (size_t)w_ >= sizeof head - hl) ok = 0; else hl += (size_t)w_; \
    } while (0)
        HEAD_ADD("%s %s HTTP/1.1\r\nHost: %s", method, path, host);
        if (port != (use_tls ? 443 : 80))
            HEAD_ADD(":%d", port);
        HEAD_ADD("\r\n");
        lua_getfield(L, 1, "headers");
        if (!lua_isnil(L, -1)) {
            int nh = (int)luaL_len(L, -1);
            for (i = 1; i <= nh; i++) {
                lua_rawgeti(L, -1, i);
                HEAD_ADD("%s\r\n", luaL_checkstring(L, -1));
                lua_pop(L, 1);
            }
        }
        lua_pop(L, 1);
        if (has_body)
            HEAD_ADD("Content-Length: %lld\r\n", (long long)content_len);
        HEAD_ADD("Connection: close\r\n\r\n");
#undef HEAD_ADD
        if (!ok) {
            snprintf(c->err, sizeof c->err, "HTTP request header too large");
            goto fail;
        }
        if (conn_write(c, head, hl) != 0)
            goto fail;
    }

    /* body */
    if (has_body) {
        lua_getfield(L, 1, "body");
        for (i = 1; i <= nparts; i++) {
            lua_rawgeti(L, -1, i);
            if (lua_type(L, -1) == LUA_TSTRING) {
                size_t pl;
                const char *part = lua_tolstring(L, -1, &pl);
                if (conn_write(c, part, pl) != 0)
                    goto fail;
            } else {
                struct stat st;
                const char *fp;
                lua_getfield(L, -1, "file");
                fp = lua_tostring(L, -1);
                if (stat(fp, &st) != 0 || send_file(c, fp, (int64_t)st.st_size) != 0) {
                    if (!c->err[0])
                        snprintf(c->err, sizeof c->err, "%s: %s", fp, strerror(errno));
                    goto fail;
                }
                lua_pop(L, 1);
            }
            lua_pop(L, 1);
        }
        lua_pop(L, 1);
    }

    /* response head: pushes status line and header table */
    lua_settop(L, 2);
    if (parse_response_head(L, c, &status) != 0)
        goto fail;

    c->body = BODY_CLOSE;
    lua_getfield(L, -1, "transfer-encoding");
    if (lua_isstring(L, -1) && strstr(lua_tostring(L, -1), "chunked"))
        c->body = BODY_CHUNKED;
    lua_pop(L, 1);
    if (c->body != BODY_CHUNKED) {
        lua_getfield(L, -1, "content-length");
        if (lua_isstring(L, -1)) {
            c->body = BODY_LENGTH;
            c->remaining = parse_size(lua_tostring(L, -1), 10);
            if (c->remaining < 0) {
                snprintf(c->err, sizeof c->err, "invalid Content-Length");
                goto fail;
            }
        }
        lua_pop(L, 1);
    }
    if (strcmp(method, "HEAD") == 0 || status == 204 || status == 304)
        c->body = BODY_NONE;
    if (c->body == BODY_NONE || (c->body == BODY_LENGTH && c->remaining == 0))
        c->eof = 1;

    /* stack: opts, conn, status_line, headers -> conn, status, headers, line */
    lua_pushvalue(L, 2);
    lua_pushinteger(L, status);
    lua_pushvalue(L, 4);
    lua_pushvalue(L, 3);
    return 4;

fail:
    lua_pushstring(L, c->err[0] ? c->err : "HTTP request failed");
    conn_close(c);
    luaL_pushfail(L);
    lua_insert(L, -2);
    return 2;
}

/* Read up to n body bytes into out; returns >0, 0 at end of body, -1. */
static long body_read(http_conn *c, unsigned char *out, size_t n)
{
    char line[1024];
    for (;;) {
        size_t avail, take;
        int r;
        if (c->eof)
            return 0;
        if (c->body == BODY_CHUNKED && !c->in_chunk) {
            long ll = conn_readline(c, line, sizeof line);
            if (ll < 0)
                return -1;
            if (ll == 0)
                continue; /* CRLF after the previous chunk */
            c->remaining = parse_size(line, 16);
            if (c->remaining < 0) {
                snprintf(c->err, sizeof c->err, "invalid chunk size in HTTP response");
                return -1;
            }
            if (c->remaining == 0) {
                /* trailer section up to an empty line */
                do {
                    ll = conn_readline(c, line, sizeof line);
                    if (ll < 0)
                        return -1;
                } while (ll > 0);
                c->eof = 1;
                return 0;
            }
            c->in_chunk = 1;
        }
        r = conn_fill(c);
        if (r < 0)
            return -1;
        if (r == 0) {
            if (c->body == BODY_CLOSE) {
                c->eof = 1;
                return 0;
            }
            snprintf(c->err, sizeof c->err, "connection closed before the end of the response");
            return -1;
        }
        avail = c->len - c->pos;
        take = avail < n ? avail : n;
        if (c->body != BODY_CLOSE && (int64_t)take > c->remaining)
            take = (size_t)c->remaining;
        memcpy(out, c->buf + c->pos, take);
        c->pos += take;
        if (c->body != BODY_CLOSE) {
            c->remaining -= (int64_t)take;
            if (c->remaining == 0) {
                if (c->body == BODY_LENGTH)
                    c->eof = 1;
                else
                    c->in_chunk = 0;
            }
        }
        if (take > 0)
            return (long)take;
    }
}

/* conn:read([n]) -> string | nil at end of body. Raises on errors. */
static int l_conn_read(lua_State *L)
{
    http_conn *c = luaL_checkudata(L, 1, HTTP_MT);
    lua_Integer n = luaL_optinteger(L, 2, BUFSZ);
    luaL_Buffer b;
    unsigned char *out;
    long got;
    if (!c->buf)
        return luaL_error(L, "read from a closed connection");
    luaL_argcheck(L, n > 0, 2, "must be positive");
    out = (unsigned char *)luaL_buffinitsize(L, &b, (size_t)n);
    got = body_read(c, out, (size_t)n);
    if (got < 0) {
        /* no Lua position prefix: this is a message for the user */
        lua_pushfstring(L, "network error: %s", c->err);
        return lua_error(L);
    }
    if (got == 0) {
        luaL_pushfail(L);
        return 1;
    }
    luaL_pushresultsize(&b, (size_t)got);
    return 1;
}

static int l_conn_close(lua_State *L)
{
    http_conn *c = luaL_checkudata(L, 1, HTTP_MT);
    conn_close(c);
    return 0;
}

void pg_register_http(lua_State *L)
{
    static const luaL_Reg methods[] = {
        {"read", l_conn_read},
        {"close", l_conn_close},
        {NULL, NULL}};
    if (luaL_newmetatable(L, HTTP_MT)) {
        luaL_newlib(L, methods);
        lua_setfield(L, -2, "__index");
        lua_pushcfunction(L, l_conn_close);
        lua_setfield(L, -2, "__gc");
        lua_pushcfunction(L, l_conn_close);
        lua_setfield(L, -2, "__close");
    }
    lua_pop(L, 1);
    lua_pushcfunction(L, l_http_request);
    lua_setfield(L, -2, "http_request");
    lua_pushinteger(L, (lua_Integer)pg_cabundle_len);
    lua_setfield(L, -2, "cabundle_size");
}
