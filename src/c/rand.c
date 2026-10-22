/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * Randomness from the kernel CSPRNG.
 *
 * getrandom(2) exists since Linux 3.17; older kernels (some ASUS models
 * still ship 2.6.36) return ENOSYS, in which case /dev/urandom is used.
 * The syscall is issued directly so that the libc wrapper's own policy does
 * not matter.
 */
#include <errno.h>
#include <fcntl.h>
#include <sys/syscall.h>
#include <unistd.h>

#include "psa/crypto.h"

#include "picogit.h"

static int urandom_fill(unsigned char *p, size_t n)
{
    int fd = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return -1;
    while (n > 0) {
        ssize_t r = read(fd, p, n);
        if (r < 0 && errno == EINTR)
            continue;
        if (r <= 0) {
            close(fd);
            return -1;
        }
        p += r;
        n -= (size_t)r;
    }
    close(fd);
    return 0;
}

int pg_random(void *buf, size_t n)
{
    unsigned char *p = buf;
#ifdef SYS_getrandom
    static int no_getrandom;
    while (!no_getrandom && n > 0) {
        long r = syscall(SYS_getrandom, p, n, 0);
        if (r < 0) {
            if (errno == EINTR)
                continue;
            if (errno == ENOSYS) {
                no_getrandom = 1;
                break;
            }
            return -1;
        }
        p += r;
        n -= (size_t)r;
    }
    if (n == 0)
        return 0;
#endif
    return urandom_fill(p, n);
}

#ifdef MBEDTLS_PSA_CRYPTO_EXTERNAL_RNG
/* Random source for PSA crypto in the bundled Mbed TLS build; a system
 * Mbed TLS uses its own entropy collection instead. */
psa_status_t mbedtls_psa_external_get_random(
    mbedtls_psa_external_random_context_t *context,
    uint8_t *output, size_t output_size, size_t *output_length)
{
    (void)context;
    if (pg_random(output, output_size) != 0)
        return PSA_ERROR_INSUFFICIENT_ENTROPY;
    *output_length = output_size;
    return PSA_SUCCESS;
}
#endif

/* random_bytes(n) -> string */
static int l_random_bytes(lua_State *L)
{
    lua_Integer n = luaL_checkinteger(L, 1);
    luaL_Buffer b;
    char *p;
    luaL_argcheck(L, n >= 0 && n <= 4096, 1, "out of range");
    p = luaL_buffinitsize(L, &b, (size_t)n);
    if (pg_random(p, (size_t)n) != 0)
        return luaL_error(L, "cannot read random bytes");
    luaL_pushresultsize(&b, (size_t)n);
    return 1;
}

void pg_register_rand(lua_State *L)
{
    lua_pushcfunction(L, l_random_bytes);
    lua_setfield(L, -2, "random_bytes");
}
