#ifndef DAWNSHELL_CLOSE_RANGE_GUARD_H
#define DAWNSHELL_CLOSE_RANGE_GUARD_H

/* Neutralises a pathological close_range(2) backport.

   Several Android kernels (for example LineageOS builds on a 4.4 base) carry a
   close_range(2) backport that walks every descriptor number in the requested
   range instead of stopping at the end of the process descriptor table. glibc
   implements closefrom(3) as close_range(lowfd, ~0U, 0), so a single call asks
   the kernel to walk 2^31-1 descriptors. Measured on an affected device this
   costs roughly 50 ns per descriptor, which turns one closefrom(3) call into
   about two minutes of uninterruptible kernel time.

   Debian programs call closefrom(3) during ordinary startup, so this made
   openssh-server installation, D-Bus machine ID initialisation, and systemd
   startup look like hangs. Tools that never call it, such as ssh-keygen,
   stayed instant, which is why the slowness looked selective.

   Reporting ENOSYS for close_range(2) makes glibc fall back to scanning
   /proc/self/fd, which closes the same descriptors in microseconds. The filter
   is inherited by every descendant, so one installation covers apt, dpkg,
   sshd, systemd, and anything else started later. */

#include <errno.h>
#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#if defined(__aarch64__)
#define DAWNSHELL_GUARD_AUDIT_ARCH AUDIT_ARCH_AARCH64
#elif defined(__arm__)
#define DAWNSHELL_GUARD_AUDIT_ARCH AUDIT_ARCH_ARM
#elif defined(__x86_64__)
#define DAWNSHELL_GUARD_AUDIT_ARCH AUDIT_ARCH_X86_64
#endif

/* A healthy kernel clamps the range to the descriptor table and answers in a
   few microseconds. A kernel that walks the range needs about 50 ms for this
   probe, so the two cases are separated by more than an order of magnitude. */
#define DAWNSHELL_CLOSE_RANGE_PROBE_LAST 1000000u
#define DAWNSHELL_CLOSE_RANGE_PROBE_LIMIT_NS 2000000LL

/* 1 pathological, 0 healthy or absent, -1 undetermined. */
static inline int dawnshell_close_range_is_pathological(void) {
#if defined(__NR_close_range) && defined(DAWNSHELL_GUARD_AUDIT_ARCH)
    /* The probe runs in a child because a healthy kernel really does close the
       inherited descriptors, and because a bounded range keeps the cost of the
       measurement itself small even on an affected kernel. */
    pid_t child = fork();
    if (child < 0) {
        return -1;
    }
    if (child == 0) {
        struct timespec started;
        struct timespec finished;
        if (clock_gettime(CLOCK_MONOTONIC, &started) != 0) {
            _exit(0);
        }
        long outcome = syscall(__NR_close_range, 3,
                               (unsigned int) DAWNSHELL_CLOSE_RANGE_PROBE_LAST, 0);
        if (clock_gettime(CLOCK_MONOTONIC, &finished) != 0) {
            _exit(0);
        }
        if (outcome != 0) {
            /* ENOSYS or EINVAL: there is nothing to guard against. */
            _exit(0);
        }
        long long elapsed =
            (long long) (finished.tv_sec - started.tv_sec) * 1000000000LL
            + (long long) (finished.tv_nsec - started.tv_nsec);
        _exit(elapsed > DAWNSHELL_CLOSE_RANGE_PROBE_LIMIT_NS ? 2 : 0);
    }
    int status = 0;
    while (waitpid(child, &status, 0) < 0) {
        if (errno != EINTR) {
            return -1;
        }
    }
    if (!WIFEXITED(status)) {
        return -1;
    }
    return WEXITSTATUS(status) == 2 ? 1 : 0;
#else
    return 0;
#endif
}

/* 1 installed, 0 not needed, -1 failed. */
static inline int dawnshell_install_close_range_guard(void) {
#if defined(__NR_close_range) && defined(DAWNSHELL_GUARD_AUDIT_ARCH)
    const char *policy = getenv("DAWNSHELL_CLOSE_RANGE_GUARD");
    int forced = policy != NULL && strcmp(policy, "force") == 0;
    if (policy != NULL && strcmp(policy, "off") == 0) {
        return 0;
    }
    if (!forced && dawnshell_close_range_is_pathological() <= 0) {
        return 0;
    }
    /* PR_SET_NO_NEW_PRIVS is deliberately not set. It would disable every
       setuid binary inside Debian, which breaks sudo. The caller already runs
       as root, and a privileged process may install a filter without it. */
    struct sock_filter filter[] = {
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
                 offsetof(struct seccomp_data, arch)),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, DAWNSHELL_GUARD_AUDIT_ARCH, 1, 0),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
                 offsetof(struct seccomp_data, nr)),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_close_range, 0, 1),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | ENOSYS),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
    };
    struct sock_fprog program = {
        .len = (unsigned short) (sizeof(filter) / sizeof(filter[0])),
        .filter = filter,
    };
    if (syscall(__NR_seccomp, SECCOMP_SET_MODE_FILTER, 0, &program) != 0) {
        if (prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &program, 0, 0) != 0) {
            return -1;
        }
    }
    return 1;
#else
    return 0;
#endif
}

#endif

