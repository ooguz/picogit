/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * enosys - run a command with selected syscalls failing with ENOSYS, to
 * emulate an old kernel (e.g. Linux 2.6.36 on some ASUS routers):
 *
 *   enosys qemu-arm build/armv7/picogit clone ...
 *
 * Blocked (x86_64 host numbers, i.e. what qemu-user forwards guest
 * syscalls to): getrandom (Linux 3.17+); picogit must fall back to
 * /dev/urandom.
 *
 * statx (4.11+) and clock_gettime64 (5.1+) cannot be tested this way:
 * qemu-user emulates them on top of older host calls, so the guest never
 * sees ENOSYS. musl falls back to fstatat64 / clock_gettime for both (see
 * src/stat/fstatat.c and src/time/clock_gettime.c in musl).
 */
#include <errno.h>
#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <stddef.h>
#include <stdio.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <unistd.h>

#define BLOCK(nr)                                          \
    BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, (nr), 0, 1),       \
    BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | ENOSYS)

int main(int argc, char **argv)
{
    struct sock_filter filter[] = {
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, arch)),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, AUDIT_ARCH_X86_64, 1, 0),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr)),
        BLOCK(SYS_getrandom),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
    };
    struct sock_fprog prog = {sizeof filter / sizeof filter[0], filter};

    if (argc < 2) {
        fputs("usage: enosys command [args...]\n", stderr);
        return 2;
    }
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0 ||
        prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &prog) != 0) {
        perror("enosys: seccomp");
        return 2;
    }
    execvp(argv[1], argv + 1);
    perror(argv[1]);
    return 127;
}
