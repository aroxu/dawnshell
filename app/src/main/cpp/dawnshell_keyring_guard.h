#ifndef DAWNSHELL_KEYRING_GUARD_H
#define DAWNSHELL_KEYRING_GUARD_H

/* Keeps Android's file-encryption key reachable inside Debian.

   /data is protected by fscrypt. On this kernel generation the policies are
   version 1, which means the key is looked up in the calling process's own
   keyrings whenever a new file is created. Android installs that key in the
   session keyring that every process inherits.

   systemd's system manager joins a brand new session keyring while it starts so
   that services get a clean one. The new keyring does not contain Android's
   fscrypt key, so every service loses the ability to create files and fails
   with ENOKEY, reported as "Required key not available". ldconfig.service,
   systemd-update-done.service, and systemd-journal-catalog-update.service fail
   first, which leaves the manager permanently "degraded". Because
   systemd-update-done never gets to record completion, the same three units
   fail again on every later boot. pam_keyinit does the same thing to SSH
   logins.

   Reporting ENOSYS for KEYCTL_JOIN_SESSION_KEYRING keeps the inherited session
   keyring, so the key stays reachable. systemd treats the failure as a kernel
   without keyring support, logs it at debug level, and continues; pam_keyinit
   is configured as optional. The filter is installed only after measuring that
   joining a new session keyring really does break file creation. */

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef DAWNSHELL_GUARD_AUDIT_ARCH
#if defined(__aarch64__)
#define DAWNSHELL_GUARD_AUDIT_ARCH AUDIT_ARCH_AARCH64
#elif defined(__arm__)
#define DAWNSHELL_GUARD_AUDIT_ARCH AUDIT_ARCH_ARM
#elif defined(__x86_64__)
#define DAWNSHELL_GUARD_AUDIT_ARCH AUDIT_ARCH_X86_64
#endif
#endif

#ifndef KEYCTL_JOIN_SESSION_KEYRING
#define KEYCTL_JOIN_SESSION_KEYRING 1
#endif

#define DAWNSHELL_KEYRING_PROBE_NAME ".dawnshell-keyring-probe"

/* 1 affected, 0 unaffected or undetermined, -1 failed. */
static inline int dawnshell_session_keyring_join_breaks_writes(
        const char *directory) {
#if defined(__NR_keyctl) && defined(DAWNSHELL_GUARD_AUDIT_ARCH)
    char path[PATH_MAX];
    int written = snprintf(path, sizeof(path), "%s/%s",
                           strcmp(directory, "/") == 0 ? "" : directory,
                           DAWNSHELL_KEYRING_PROBE_NAME);
    if (written <= 0 || (size_t) written >= sizeof(path)) {
        return -1;
    }
    pid_t child = fork();
    if (child < 0) {
        return -1;
    }
    if (child == 0) {
        /* The same file name is used twice on purpose: the only difference
           between the two attempts is the session keyring. */
        int before = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
        if (before < 0) {
            /* Read-only or otherwise unwritable: nothing can be concluded. */
            _exit(0);
        }
        close(before);
        unlink(path);
        if (syscall(__NR_keyctl, KEYCTL_JOIN_SESSION_KEYRING, NULL, 0, 0, 0) < 0) {
            _exit(0);
        }
        int after = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
        if (after >= 0) {
            close(after);
            _exit(0);
        }
        _exit(errno == ENOKEY ? 2 : 0);
    }
    int status = 0;
    while (waitpid(child, &status, 0) < 0) {
        if (errno != EINTR) {
            return -1;
        }
    }
    /* A failed creation can still leave the name behind, and only a process
       that still holds the key can remove it. */
    unlink(path);
    if (!WIFEXITED(status)) {
        return -1;
    }
    return WEXITSTATUS(status) == 2 ? 1 : 0;
#else
    (void) directory;
    return 0;
#endif
}

/* 1 installed, 0 not needed, -1 failed. */
static inline int dawnshell_install_keyring_guard(const char *directory) {
#if defined(__NR_keyctl) && defined(DAWNSHELL_GUARD_AUDIT_ARCH)
    const char *policy = getenv("DAWNSHELL_SESSION_KEYRING_GUARD");
    int forced = policy != NULL && strcmp(policy, "force") == 0;
    if (policy != NULL && strcmp(policy, "off") == 0) {
        return 0;
    }
    if (!forced && dawnshell_session_keyring_join_breaks_writes(directory) <= 0) {
        return 0;
    }
    /* PR_SET_NO_NEW_PRIVS is deliberately not set. It would disable every
       setuid binary inside Debian, which breaks sudo. */
    struct sock_filter filter[] = {
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
                 offsetof(struct seccomp_data, arch)),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, DAWNSHELL_GUARD_AUDIT_ARCH, 1, 0),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
                 offsetof(struct seccomp_data, nr)),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_keyctl, 0, 3),
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
                 offsetof(struct seccomp_data, args[0])),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, KEYCTL_JOIN_SESSION_KEYRING, 0, 1),
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
    (void) directory;
    return 0;
#endif
}

#endif

