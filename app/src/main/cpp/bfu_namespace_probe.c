#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <sched.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/mount.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#ifndef CLONE_NEWCGROUP
#define CLONE_NEWCGROUP 0x02000000
#endif

static const char *const kAllowedRoot = "/data/local/debian";
static const char *const kReadyMarker = ".termux-bfu-systemd-ready";
static const char *const kLockName = "debian-supervisor.lock";
static const char *const kStateName = "debian-supervisor.state";
static const char *const kLifecycleLogName = "debian-lifecycle.log";
static const char *const kHostRebootFifoName = "host-reboot.fifo";
static const char *const kCgroupMountName = "systemd-cgroup";
static const char *const kCgroupChildName = "termux-bfu";
static const int kStartTimeoutMs = 20000;
static const int kStartGraceMs = 3000;
static const int kStopTimeoutMs = 30000;
static const int kTailscaleBypassRulePriority = 5200;

static volatile sig_atomic_t alarm_child_pid = -1;
static volatile sig_atomic_t stop_requested = 0;
static int failure_report_fd = -1;

typedef struct LauncherState {
    char state[24];
    pid_t supervisor_pid;
    uint64_t supervisor_start_ticks;
    uint64_t supervisor_exe_dev;
    uint64_t supervisor_exe_ino;
    pid_t init_host_pid;
    uint64_t init_start_ticks;
    uint64_t init_exe_dev;
    uint64_t init_exe_ino;
    uint64_t init_pid_ns_ino;
    uint64_t init_mnt_ns_ino;
    uint64_t init_uts_ns_ino;
    uint64_t init_ipc_ns_ino;
    uint64_t init_cgroup_ns_ino;
    uint64_t init_net_ns_ino;
    int wait_status;
    int64_t updated_epoch;
} LauncherState;

static int64_t realtime_seconds(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_REALTIME, &value) != 0) return 0;
    return (int64_t) value.tv_sec;
}

static int64_t monotonic_millis(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_MONOTONIC, &value) != 0) return 0;
    return (int64_t) value.tv_sec * 1000 + value.tv_nsec / 1000000;
}

static void log_file_snapshot(const char *label, const char *path) {
    char contents[8192];
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        dprintf(STDERR_FILENO,
                "[%lld] BFU_DEBIAN_DIAGNOSTIC label=%s read_failed errno=%d\n",
                (long long) realtime_seconds(), label, errno);
        return;
    }
    ssize_t count = read(fd, contents, sizeof(contents) - 1);
    close(fd);
    if (count < 0) {
        dprintf(STDERR_FILENO,
                "[%lld] BFU_DEBIAN_DIAGNOSTIC label=%s read_failed errno=%d\n",
                (long long) realtime_seconds(), label, errno);
        return;
    }
    for (ssize_t index = 0; index < count; index++) {
        if (contents[index] == '\0') contents[index] = ' ';
    }
    contents[count] = '\0';
    dprintf(STDERR_FILENO,
            "[%lld] BFU_DEBIAN_DIAGNOSTIC_BEGIN label=%s path=%s\n%s%s"
            "[%lld] BFU_DEBIAN_DIAGNOSTIC_END label=%s\n",
            (long long) realtime_seconds(), label, path, contents,
            count > 0 && contents[count - 1] == '\n' ? "" : "\n",
            (long long) realtime_seconds(), label);
}

static void log_matching_snapshot(const char *label, const char *path,
                                  const char *pattern) {
    FILE *input = fopen(path, "r");
    if (input == NULL) {
        dprintf(STDERR_FILENO,
                "[%lld] BFU_DEBIAN_DIAGNOSTIC label=%s read_failed errno=%d\n",
                (long long) realtime_seconds(), label, errno);
        return;
    }
    dprintf(STDERR_FILENO,
            "[%lld] BFU_DEBIAN_DIAGNOSTIC_BEGIN label=%s path=%s filter=%s\n",
            (long long) realtime_seconds(), label, path, pattern);
    char line[2048];
    int emitted = 0;
    while (emitted < 64 && fgets(line, sizeof(line), input) != NULL) {
        if (strstr(line, pattern) == NULL) continue;
        dprintf(STDERR_FILENO, "%s", line);
        emitted++;
    }
    fclose(input);
    dprintf(STDERR_FILENO,
            "[%lld] BFU_DEBIAN_DIAGNOSTIC_END label=%s matched_lines=%d\n",
            (long long) realtime_seconds(), label, emitted);
}

static void report_failure_text(const char *message) {
    if (failure_report_fd >= 0 && message != NULL) {
        (void) write(failure_report_fd, message, strlen(message));
    }
}

static int fail_errno(const char *stage, int code) {
    const int saved_errno = errno;
    char message[512];
    snprintf(message, sizeof(message),
             "BFU_DEBIAN_LAUNCHER_FAILED stage=%s errno=%d error=%s\n",
             stage, saved_errno, strerror(saved_errno));
    fputs(message, stderr);
    report_failure_text(message);
    return code;
}

static int fail_message(const char *stage, const char *message_text, int code) {
    char message[512];
    snprintf(message, sizeof(message),
             "BFU_DEBIAN_LAUNCHER_FAILED stage=%s error=%s\n",
             stage, message_text);
    fputs(message, stderr);
    report_failure_text(message);
    return code;
}

static int run_argv(char *const argv[], bool quiet) {
    pid_t pid = fork();
    if (pid < 0) return -1;
    if (pid == 0) {
        if (quiet) {
            int null_fd = open("/dev/null", O_RDWR | O_CLOEXEC);
            if (null_fd >= 0) {
                (void) dup2(null_fd, STDOUT_FILENO);
                (void) dup2(null_fd, STDERR_FILENO);
                if (null_fd > STDERR_FILENO) close(null_fd);
            }
        }
        execv(argv[0], argv);
        _exit(127);
    }
    int status = 0;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno == EINTR) continue;
        return -1;
    }
    if (!WIFEXITED(status)) {
        errno = EINTR;
        return -1;
    }
    if (WEXITSTATUS(status) != 0) {
        errno = EPROTO;
        return -1;
    }
    return 0;
}

static int capture_argv(char *const argv[], char *output, size_t output_size) {
    if (output_size < 2) {
        errno = EINVAL;
        return -1;
    }
    int descriptors[2];
    if (pipe(descriptors) != 0) return -1;
    pid_t pid = fork();
    if (pid < 0) {
        close(descriptors[0]);
        close(descriptors[1]);
        return -1;
    }
    if (pid == 0) {
        close(descriptors[0]);
        (void) dup2(descriptors[1], STDOUT_FILENO);
        int null_fd = open("/dev/null", O_WRONLY | O_CLOEXEC);
        if (null_fd >= 0) {
            (void) dup2(null_fd, STDERR_FILENO);
            if (null_fd > STDERR_FILENO) close(null_fd);
        }
        if (descriptors[1] > STDERR_FILENO) close(descriptors[1]);
        execv(argv[0], argv);
        _exit(127);
    }
    close(descriptors[1]);
    size_t offset = 0;
    while (offset + 1 < output_size) {
        ssize_t count = read(descriptors[0], output + offset,
                             output_size - offset - 1);
        if (count == 0) break;
        if (count < 0) {
            if (errno == EINTR) continue;
            break;
        }
        offset += (size_t) count;
    }
    close(descriptors[0]);
    output[offset] = '\0';
    int status = 0;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno == EINTR) continue;
        return -1;
    }
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        errno = EPROTO;
        return -1;
    }
    return 0;
}

static void alarm_handler(int signal_number) {
    (void) signal_number;
    if (alarm_child_pid > 0) kill((pid_t) alarm_child_pid, SIGKILL);
    _exit(124);
}

static void stop_handler(int signal_number) {
    (void) signal_number;
    stop_requested = 1;
}

static bool is_directory(const char *path) {
    struct stat value;
    return lstat(path, &value) == 0 && S_ISDIR(value.st_mode);
}

static bool is_regular_executable(const char *path) {
    struct stat value;
    /* Debian /bin/sh and /sbin/init are normally symlinks; follow the final link. */
    return stat(path, &value) == 0 && S_ISREG(value.st_mode)
            && access(path, R_OK | X_OK) == 0;
}

static bool is_safe_root_marker(const char *path) {
    struct stat value;
    return lstat(path, &value) == 0 && S_ISREG(value.st_mode)
            && value.st_uid == 0
            && (value.st_mode & (S_IWGRP | S_IWOTH)) == 0;
}

static bool file_has_exact_line(const char *path, const char *expected) {
    char contents[4096];
    int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return false;
    ssize_t count = read(fd, contents, sizeof(contents) - 1);
    close(fd);
    if (count <= 0 || (size_t) count >= sizeof(contents)) return false;
    contents[count] = '\0';

    char *save = NULL;
    for (char *line = strtok_r(contents, "\n", &save);
         line != NULL; line = strtok_r(NULL, "\n", &save)) {
        if (strcmp(line, expected) == 0) return true;
    }
    return false;
}

static int joined_path(char *output, size_t output_size, const char *base,
                       const char *relative) {
    const int count = snprintf(output, output_size, "%s/%s", base, relative);
    if (count < 0 || (size_t) count >= output_size) {
        errno = ENAMETOOLONG;
        return -1;
    }
    return 0;
}

static int validate_rootfs(const char *root, bool require_systemd) {
    char resolved[PATH_MAX];
    char path[PATH_MAX];
    struct stat root_stat;

    if (strcmp(root, kAllowedRoot) != 0) {
        return fail_message("root_not_allowed", "only_/data/local/debian_is_allowed", 20);
    }
    if (lstat(root, &root_stat) != 0) return fail_errno("root_lstat", 21);
    if (!S_ISDIR(root_stat.st_mode)) {
        return fail_message("root_not_directory", "rootfs_is_not_a_directory", 22);
    }
    if (root_stat.st_uid != 0) {
        return fail_message("root_not_owned_by_uid_0", "unsafe_rootfs_owner", 23);
    }
    if ((root_stat.st_mode & (S_IWGRP | S_IWOTH)) != 0) {
        return fail_message("root_group_or_world_writable", "unsafe_rootfs_mode", 23);
    }
    if (realpath(root, resolved) == NULL) return fail_errno("root_realpath", 24);
    if (strcmp(resolved, kAllowedRoot) != 0) {
        return fail_message("root_resolved_elsewhere", "rootfs_symlink_is_forbidden", 25);
    }

    if (joined_path(path, sizeof(path), root, ".termux-bfu-rootfs") != 0
            || !is_safe_root_marker(path)
            || !file_has_exact_line(path, "suite=trixie")
            || !file_has_exact_line(path, "architecture=arm64")) {
        return fail_message("rootfs_marker",
                            "missing_or_unsafe_Trixie_arm64_marker", 26);
    }
    if (joined_path(path, sizeof(path), root, "bin/sh") != 0
            || !is_regular_executable(path)) {
        return fail_message("debian_shell", "missing_readable_executable_bin_sh", 27);
    }

    const char *const directories[] = {"dev", "proc", "sys", "run"};
    const size_t directory_count = sizeof(directories) / sizeof(directories[0]);
    for (size_t index = 0; index < directory_count; index++) {
        if (joined_path(path, sizeof(path), root, directories[index]) != 0) {
            return fail_errno("rootfs_mount_path", 28);
        }
        if (!is_directory(path)) {
            return fail_message("rootfs_mount_directory",
                                "required_mount_directory_is_missing", 29);
        }
    }

    if (require_systemd) {
        if (joined_path(path, sizeof(path), root, kReadyMarker) != 0
                || !is_safe_root_marker(path)
                || !file_has_exact_line(path, "suite=trixie")
                || !file_has_exact_line(path, "architecture=arm64")
                || !file_has_exact_line(path, "ssh_service=ssh.service")
                || !file_has_exact_line(path,
                                        "boot_proof_service=termux-bfu-boot-proof.service")
                || !file_has_exact_line(path, "ssh_user=debian")
                || !file_has_exact_line(path, "ssh_port=22")) {
            return fail_message("systemd_not_provisioned",
                                "run_the_AFU_systemd_and_SSH_provisioner", 30);
        }
        if (joined_path(path, sizeof(path), root, "sbin/init") != 0
                || !is_regular_executable(path)) {
            return fail_message("systemd_init_missing", "missing_/sbin/init", 31);
        }
        const char *const required_tools[] = {
                "usr/bin/systemctl", "usr/bin/journalctl", "usr/bin/busctl",
                "usr/bin/timeout", "usr/bin/ss", "usr/bin/mawk", "usr/bin/touch",
                "usr/sbin/shutdown"
        };
        const size_t tool_count = sizeof(required_tools) / sizeof(required_tools[0]);
        for (size_t index = 0; index < tool_count; index++) {
            if (joined_path(path, sizeof(path), root, required_tools[index]) != 0
                    || !is_regular_executable(path)) {
                return fail_message("systemd_health_tool_missing",
                                    "rerun_the_AFU_systemd_provisioner", 31);
            }
        }
    }
    return 0;
}

static int validate_control_directory(const char *control_dir) {
    struct stat value;
    if (control_dir == NULL || control_dir[0] != '/') {
        return fail_message("control_dir", "control_directory_must_be_absolute", 32);
    }
    if (lstat(control_dir, &value) != 0) return fail_errno("control_dir_lstat", 33);
    if (!S_ISDIR(value.st_mode)) {
        return fail_message("control_dir_type", "control_path_is_not_a_directory", 34);
    }
    if ((value.st_mode & (S_IWGRP | S_IWOTH)) != 0) {
        return fail_message("control_dir_mode", "control_directory_is_not_private", 35);
    }
    return 0;
}

static int open_lock_file(const char *control_dir, char *path, size_t path_size) {
    if (joined_path(path, path_size, control_dir, kLockName) != 0) return -1;
    int fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0) return -1;
    struct stat value;
    if (fstat(fd, &value) != 0 || !S_ISREG(value.st_mode) || value.st_nlink != 1) {
        close(fd);
        errno = EINVAL;
        return -1;
    }
    return fd;
}

static int read_proc_start_ticks(pid_t pid, uint64_t *ticks) {
    char path[64];
    char buffer[4096];
    snprintf(path, sizeof(path), "/proc/%d/stat", pid);
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) return -1;
    ssize_t count = read(fd, buffer, sizeof(buffer) - 1);
    close(fd);
    if (count <= 0) return -1;
    buffer[count] = '\0';

    char *right_parenthesis = strrchr(buffer, ')');
    if (right_parenthesis == NULL || right_parenthesis[1] != ' ') {
        errno = EINVAL;
        return -1;
    }

    char *save = NULL;
    char *token = strtok_r(right_parenthesis + 2, " ", &save);
    int field = 3;
    while (token != NULL) {
        if (field == 22) {
            char *end = NULL;
            errno = 0;
            unsigned long long value = strtoull(token, &end, 10);
            if (errno != 0 || end == token || *end != '\0') {
                errno = EINVAL;
                return -1;
            }
            *ticks = (uint64_t) value;
            return 0;
        }
        token = strtok_r(NULL, " ", &save);
        field++;
    }
    errno = EINVAL;
    return -1;
}

static int read_proc_exe_identity(pid_t pid, uint64_t *device, uint64_t *inode) {
    char path[64];
    struct stat value;
    snprintf(path, sizeof(path), "/proc/%d/exe", pid);
    if (stat(path, &value) != 0) return -1;
    *device = (uint64_t) value.st_dev;
    *inode = (uint64_t) value.st_ino;
    return 0;
}

static int read_proc_namespace_inode(pid_t pid, const char *name, uint64_t *inode) {
    char path[96];
    struct stat value;
    int count = snprintf(path, sizeof(path), "/proc/%d/ns/%s", pid, name);
    if (count < 0 || (size_t) count >= sizeof(path)) {
        errno = ENAMETOOLONG;
        return -1;
    }
    if (stat(path, &value) != 0) return -1;
    *inode = (uint64_t) value.st_ino;
    return 0;
}

static int capture_init_namespace_identity(pid_t pid, LauncherState *state) {
    return read_proc_namespace_inode(pid, "pid", &state->init_pid_ns_ino) == 0
            && read_proc_namespace_inode(pid, "mnt", &state->init_mnt_ns_ino) == 0
            && read_proc_namespace_inode(pid, "uts", &state->init_uts_ns_ino) == 0
            && read_proc_namespace_inode(pid, "ipc", &state->init_ipc_ns_ino) == 0
            && read_proc_namespace_inode(pid, "cgroup",
                                         &state->init_cgroup_ns_ino) == 0
            && read_proc_namespace_inode(pid, "net", &state->init_net_ns_ino) == 0
            ? 0 : -1;
}

static int validate_init_namespace_topology(const LauncherState *state) {
    uint64_t host_pid = 0;
    uint64_t host_mnt = 0;
    uint64_t host_uts = 0;
    uint64_t host_ipc = 0;
    uint64_t host_cgroup = 0;
    uint64_t host_net = 0;
    if (read_proc_namespace_inode(1, "pid", &host_pid) != 0
            || read_proc_namespace_inode(1, "mnt", &host_mnt) != 0
            || read_proc_namespace_inode(1, "uts", &host_uts) != 0
            || read_proc_namespace_inode(1, "ipc", &host_ipc) != 0
            || read_proc_namespace_inode(1, "cgroup", &host_cgroup) != 0
            || read_proc_namespace_inode(1, "net", &host_net) != 0) {
        return -1;
    }
    if (state->init_pid_ns_ino == host_pid
            || state->init_mnt_ns_ino == host_mnt
            || state->init_uts_ns_ino == host_uts
            || state->init_ipc_ns_ino != host_ipc
            || state->init_cgroup_ns_ino == host_cgroup
            || state->init_net_ns_ino != host_net) {
        errno = EXDEV;
        return -1;
    }
    return 0;
}

static void initialize_state(LauncherState *state, const char *name) {
    memset(state, 0, sizeof(*state));
    snprintf(state->state, sizeof(state->state), "%s", name);
    state->wait_status = -1;
    state->updated_epoch = realtime_seconds();
}

static int state_path(char *output, size_t output_size, const char *control_dir) {
    return joined_path(output, output_size, control_dir, kStateName);
}

static int write_all(int fd, const char *buffer, size_t length) {
    size_t offset = 0;
    while (offset < length) {
        ssize_t count = write(fd, buffer + offset, length - offset);
        if (count < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        offset += (size_t) count;
    }
    return 0;
}

static int write_state(const char *control_dir, LauncherState *state) {
    char destination[PATH_MAX];
    char temporary[PATH_MAX];
    char contents[1024];
    if (state_path(destination, sizeof(destination), control_dir) != 0) return -1;
    int count = snprintf(temporary, sizeof(temporary), "%s.new.%d",
                         destination, getpid());
    if (count < 0 || (size_t) count >= sizeof(temporary)) {
        errno = ENAMETOOLONG;
        return -1;
    }

    state->updated_epoch = realtime_seconds();
    count = snprintf(contents, sizeof(contents),
                     "format=4\nstate=%s\nsupervisor_pid=%d\n"
                     "supervisor_start_ticks=%llu\nsupervisor_exe_dev=%llu\n"
                     "supervisor_exe_ino=%llu\ninit_host_pid=%d\n"
                     "init_start_ticks=%llu\ninit_exe_dev=%llu\n"
                     "init_exe_ino=%llu\ninit_pid_ns_ino=%llu\n"
                     "init_mnt_ns_ino=%llu\ninit_uts_ns_ino=%llu\n"
                     "init_ipc_ns_ino=%llu\ninit_cgroup_ns_ino=%llu\n"
                     "init_net_ns_ino=%llu\n"
                     "wait_status=%d\nupdated_epoch=%lld\n",
                     state->state, state->supervisor_pid,
                     (unsigned long long) state->supervisor_start_ticks,
                     (unsigned long long) state->supervisor_exe_dev,
                     (unsigned long long) state->supervisor_exe_ino,
                     state->init_host_pid,
                     (unsigned long long) state->init_start_ticks,
                     (unsigned long long) state->init_exe_dev,
                     (unsigned long long) state->init_exe_ino,
                     (unsigned long long) state->init_pid_ns_ino,
                     (unsigned long long) state->init_mnt_ns_ino,
                     (unsigned long long) state->init_uts_ns_ino,
                     (unsigned long long) state->init_ipc_ns_ino,
                     (unsigned long long) state->init_cgroup_ns_ino,
                     (unsigned long long) state->init_net_ns_ino,
                     state->wait_status, (long long) state->updated_epoch);
    if (count < 0 || (size_t) count >= sizeof(contents)) {
        errno = EOVERFLOW;
        return -1;
    }

    int fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                  0644);
    if (fd < 0) return -1;
    int result = write_all(fd, contents, (size_t) count);
    if (result == 0 && fsync(fd) != 0) result = -1;
    int saved_errno = errno;
    close(fd);
    if (result != 0) {
        unlink(temporary);
        errno = saved_errno;
        return -1;
    }
    if (rename(temporary, destination) != 0) {
        saved_errno = errno;
        unlink(temporary);
        errno = saved_errno;
        return -1;
    }
    return 0;
}

static int parse_u64(const char *value, uint64_t *output) {
    char *end = NULL;
    errno = 0;
    unsigned long long parsed = strtoull(value, &end, 10);
    if (errno != 0 || end == value || *end != '\0') return -1;
    *output = (uint64_t) parsed;
    return 0;
}

static int parse_pid_value(const char *value, pid_t *output) {
    uint64_t parsed;
    if (parse_u64(value, &parsed) != 0 || parsed > INT_MAX) return -1;
    *output = (pid_t) parsed;
    return 0;
}

static int read_state(const char *control_dir, LauncherState *state) {
    char path[PATH_MAX];
    char contents[4096];
    initialize_state(state, "unknown");
    if (state_path(path, sizeof(path), control_dir) != 0) return -1;
    int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return -1;
    ssize_t count = read(fd, contents, sizeof(contents) - 1);
    close(fd);
    if (count <= 0) return -1;
    contents[count] = '\0';

    char *save = NULL;
    for (char *line = strtok_r(contents, "\n", &save);
         line != NULL; line = strtok_r(NULL, "\n", &save)) {
        char *separator = strchr(line, '=');
        if (separator == NULL) continue;
        *separator = '\0';
        const char *value = separator + 1;
        if (strcmp(line, "state") == 0) {
            snprintf(state->state, sizeof(state->state), "%s", value);
        } else if (strcmp(line, "supervisor_pid") == 0) {
            (void) parse_pid_value(value, &state->supervisor_pid);
        } else if (strcmp(line, "supervisor_start_ticks") == 0) {
            (void) parse_u64(value, &state->supervisor_start_ticks);
        } else if (strcmp(line, "supervisor_exe_dev") == 0) {
            (void) parse_u64(value, &state->supervisor_exe_dev);
        } else if (strcmp(line, "supervisor_exe_ino") == 0) {
            (void) parse_u64(value, &state->supervisor_exe_ino);
        } else if (strcmp(line, "init_host_pid") == 0) {
            (void) parse_pid_value(value, &state->init_host_pid);
        } else if (strcmp(line, "init_start_ticks") == 0) {
            (void) parse_u64(value, &state->init_start_ticks);
        } else if (strcmp(line, "init_exe_dev") == 0) {
            (void) parse_u64(value, &state->init_exe_dev);
        } else if (strcmp(line, "init_exe_ino") == 0) {
            (void) parse_u64(value, &state->init_exe_ino);
        } else if (strcmp(line, "init_pid_ns_ino") == 0) {
            (void) parse_u64(value, &state->init_pid_ns_ino);
        } else if (strcmp(line, "init_mnt_ns_ino") == 0) {
            (void) parse_u64(value, &state->init_mnt_ns_ino);
        } else if (strcmp(line, "init_uts_ns_ino") == 0) {
            (void) parse_u64(value, &state->init_uts_ns_ino);
        } else if (strcmp(line, "init_ipc_ns_ino") == 0) {
            (void) parse_u64(value, &state->init_ipc_ns_ino);
        } else if (strcmp(line, "init_cgroup_ns_ino") == 0) {
            (void) parse_u64(value, &state->init_cgroup_ns_ino);
        } else if (strcmp(line, "init_net_ns_ino") == 0) {
            (void) parse_u64(value, &state->init_net_ns_ino);
        } else if (strcmp(line, "wait_status") == 0) {
            state->wait_status = atoi(value);
        } else if (strcmp(line, "updated_epoch") == 0) {
            state->updated_epoch = strtoll(value, NULL, 10);
        }
    }
    return 0;
}

static bool validate_supervisor_identity(const LauncherState *state) {
    if (state->supervisor_pid <= 1 || state->supervisor_start_ticks == 0
            || state->supervisor_exe_ino == 0) return false;
    uint64_t ticks = 0;
    uint64_t device = 0;
    uint64_t inode = 0;
    return read_proc_start_ticks(state->supervisor_pid, &ticks) == 0
            && ticks == state->supervisor_start_ticks
            && read_proc_exe_identity(state->supervisor_pid, &device, &inode) == 0
            && device == state->supervisor_exe_dev
            && inode == state->supervisor_exe_ino
            && kill(state->supervisor_pid, 0) == 0;
}

static bool validate_init_identity(const LauncherState *state) {
    if (state->init_host_pid <= 1 || state->init_start_ticks == 0
            || state->init_exe_ino == 0 || state->init_pid_ns_ino == 0
            || state->init_mnt_ns_ino == 0 || state->init_uts_ns_ino == 0
            || state->init_ipc_ns_ino == 0 || state->init_cgroup_ns_ino == 0
            || state->init_net_ns_ino == 0) return false;
    uint64_t ticks = 0;
    uint64_t device = 0;
    uint64_t inode = 0;
    uint64_t pid_ns_inode = 0;
    uint64_t mnt_ns_inode = 0;
    uint64_t uts_ns_inode = 0;
    uint64_t ipc_ns_inode = 0;
    uint64_t cgroup_ns_inode = 0;
    uint64_t net_ns_inode = 0;
    return read_proc_start_ticks(state->init_host_pid, &ticks) == 0
            && ticks == state->init_start_ticks
            && read_proc_exe_identity(state->init_host_pid, &device, &inode) == 0
            && device == state->init_exe_dev
            && inode == state->init_exe_ino
            && read_proc_namespace_inode(state->init_host_pid, "pid",
                                         &pid_ns_inode) == 0
            && pid_ns_inode == state->init_pid_ns_ino
            && read_proc_namespace_inode(state->init_host_pid, "mnt",
                                         &mnt_ns_inode) == 0
            && mnt_ns_inode == state->init_mnt_ns_ino
            && read_proc_namespace_inode(state->init_host_pid, "uts",
                                         &uts_ns_inode) == 0
            && uts_ns_inode == state->init_uts_ns_ino
            && read_proc_namespace_inode(state->init_host_pid, "ipc",
                                         &ipc_ns_inode) == 0
            && ipc_ns_inode == state->init_ipc_ns_ino
            && read_proc_namespace_inode(state->init_host_pid, "cgroup",
                                         &cgroup_ns_inode) == 0
            && cgroup_ns_inode == state->init_cgroup_ns_ino
            && read_proc_namespace_inode(state->init_host_pid, "net",
                                         &net_ns_inode) == 0
            && net_ns_inode == state->init_net_ns_ino
            && kill(state->init_host_pid, 0) == 0;
}

static int bind_recursively(const char *source, const char *target,
                            const char *bind_stage, const char *slave_stage) {
    if (mount(source, target, NULL, MS_BIND | MS_REC, NULL) != 0) {
        return fail_errno(bind_stage, 40);
    }
    if (mount(NULL, target, NULL, MS_SLAVE | MS_REC, NULL) != 0) {
        return fail_errno(slave_stage, 41);
    }
    return 0;
}

static int make_bind_read_only(const char *path, const char *stage) {
    if (mount(path, path, NULL, MS_BIND, NULL) != 0) return fail_errno(stage, 42);
    if (mount(NULL, path, NULL,
              MS_BIND | MS_REMOUNT | MS_RDONLY | MS_NOSUID | MS_NODEV | MS_NOEXEC,
              NULL) != 0) return fail_errno(stage, 43);
    return 0;
}

static int ensure_directory_path(const char *path, mode_t mode, const char *stage) {
    struct stat value;
    if (lstat(path, &value) == 0) {
        if (S_ISDIR(value.st_mode)) return 0;
        return fail_message(stage, "path_exists_but_is_not_a_directory", 44);
    }
    if (errno != ENOENT) return fail_errno(stage, 44);
    if (mkdir(path, mode) != 0) return fail_errno(stage, 44);
    return 0;
}

static int systemd_cgroup_paths(const char *control_dir, char *mount_path,
                                size_t mount_size, char *child_path,
                                size_t child_size) {
    if (joined_path(mount_path, mount_size, control_dir, kCgroupMountName) != 0) {
        return -1;
    }
    if (joined_path(child_path, child_size, mount_path, kCgroupChildName) != 0) {
        return -1;
    }
    return 0;
}

static int prepare_systemd_cgroup_mount(const char *control_dir) {
    char mount_path[PATH_MAX];
    char child_path[PATH_MAX];
    if (systemd_cgroup_paths(control_dir, mount_path, sizeof(mount_path),
                             child_path, sizeof(child_path)) != 0) {
        return fail_errno("cgroup_path", 45);
    }
    int result = ensure_directory_path(mount_path, 0700, "cgroup_mount_dir");
    if (result != 0) return result;
    if (mount("termux-bfu", mount_path, "cgroup",
              MS_NOSUID | MS_NODEV | MS_NOEXEC, "none,name=systemd") != 0) {
        return fail_errno("cgroup_v1_name_systemd_mount", 46);
    }
    result = ensure_directory_path(child_path, 0755, "cgroup_child_dir");
    if (result != 0) return result;
    dprintf(STDERR_FILENO,
            "[%lld] BFU_DEBIAN_STAGE cgroup_v1_name_systemd_mounted "
            "mount=%s child=%s\n",
            (long long) realtime_seconds(), mount_path, child_path);
    return 0;
}

static int move_self_to_systemd_cgroup(const char *control_dir) {
    char mount_path[PATH_MAX];
    char child_path[PATH_MAX];
    char procs_path[PATH_MAX];
    if (systemd_cgroup_paths(control_dir, mount_path, sizeof(mount_path),
                             child_path, sizeof(child_path)) != 0
            || joined_path(procs_path, sizeof(procs_path), child_path,
                           "cgroup.procs") != 0) {
        return fail_errno("cgroup_procs_path", 47);
    }
    int fd = open(procs_path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return fail_errno("cgroup_procs_open", 48);
    char pid_text[32];
    int count = snprintf(pid_text, sizeof(pid_text), "%d\n", getpid());
    int result = count > 0 && (size_t) count < sizeof(pid_text)
            ? write_all(fd, pid_text, (size_t) count) : -1;
    int saved_errno = errno;
    close(fd);
    if (result != 0) {
        errno = saved_errno;
        return fail_errno("cgroup_move_pid1", 49);
    }
    dprintf(STDERR_FILENO,
            "[%lld] BFU_DEBIAN_STAGE init_moved_to_systemd_cgroup path=%s\n",
            (long long) realtime_seconds(), child_path);
    if (unshare(CLONE_NEWCGROUP) != 0) {
        return fail_errno("unshare_cgroup", 50);
    }
    dprintf(STDERR_FILENO,
            "[%lld] BFU_DEBIAN_STAGE cgroup_namespace_private\n",
            (long long) realtime_seconds());
    return 0;
}

static int mount_systemd_cgroup_view(const char *root, const char *control_dir) {
    char source[PATH_MAX];
    char child_path[PATH_MAX];
    char cgroup_root[PATH_MAX];
    char target[PATH_MAX];
    if (systemd_cgroup_paths(control_dir, source, sizeof(source),
                             child_path, sizeof(child_path)) != 0
            || joined_path(cgroup_root, sizeof(cgroup_root), root,
                           "sys/fs/cgroup") != 0
            || joined_path(target, sizeof(target), cgroup_root, "systemd") != 0) {
        return fail_errno("cgroup_view_path", 51);
    }
    if (mount("tmpfs", cgroup_root, "tmpfs",
              MS_NOSUID | MS_NODEV | MS_NOEXEC, "mode=0755,size=1m") != 0) {
        return fail_errno("cgroup_view_tmpfs", 52);
    }
    int result = ensure_directory_path(target, 0755, "cgroup_view_systemd_dir");
    if (result != 0) return result;
    if (mount(source, target, NULL, MS_BIND | MS_REC, NULL) != 0) {
        return fail_errno("cgroup_view_bind", 53);
    }
    return 0;
}

static int prepare_child_mounts(const char *root, const char *control_dir,
                                bool systemd_mode) {
    char path[PATH_MAX];
    int result;

    if (mount(root, root, NULL, MS_BIND | MS_REC, NULL) != 0) {
        return fail_errno("rootfs_bind", 44);
    }
    if (mount(NULL, root, NULL, MS_PRIVATE | MS_REC, NULL) != 0) {
        return fail_errno("rootfs_make_private", 44);
    }
    /* /data is nosuid on Android. Enable setuid only on this private rootfs
       bind mount so Debian's su(1) can authenticate a configured local root
       password. Keep nodev and never alter the Android host /data mount. */
    if (mount(NULL, root, NULL, MS_BIND | MS_REMOUNT | MS_NODEV, NULL) != 0) {
        return fail_errno("rootfs_enable_private_suid", 44);
    }
    dprintf(STDERR_FILENO,
            "[%lld] BFU_DEBIAN_STAGE rootfs_private_bind_mount\n"
            "[%lld] BFU_DEBIAN_STAGE rootfs_private_suid_enabled nodev=true\n",
            (long long) realtime_seconds(),
            (long long) realtime_seconds());

    if (joined_path(path, sizeof(path), root, "dev") != 0) {
        return fail_errno("dev_path", 44);
    }
    result = bind_recursively("/dev", path, "dev_rbind", "dev_make_rslave");
    if (result != 0) return result;
    dprintf(STDERR_FILENO, "[%lld] BFU_DEBIAN_STAGE dev_rbind_slave\n",
            (long long) realtime_seconds());

    if (joined_path(path, sizeof(path), root, "sys") != 0) {
        return fail_errno("sys_path", 45);
    }
    result = bind_recursively("/sys", path, "sys_rbind", "sys_make_rslave");
    if (result != 0) return result;
    if (mount(NULL, path, NULL,
              MS_BIND | MS_REMOUNT | MS_RDONLY | MS_NOSUID | MS_NODEV | MS_NOEXEC,
              NULL) != 0) {
        return fail_errno("sys_read_only", 45);
    }
    dprintf(STDERR_FILENO, "[%lld] BFU_DEBIAN_STAGE sys_rbind_slave_read_only\n",
            (long long) realtime_seconds());

    if (systemd_mode) {
        result = mount_systemd_cgroup_view(root, control_dir);
        if (result != 0) return result;
        dprintf(STDERR_FILENO,
                "[%lld] BFU_DEBIAN_STAGE private_systemd_cgroup_view_mounted\n",
                (long long) realtime_seconds());
    }

    if (joined_path(path, sizeof(path), root, "proc") != 0) {
        return fail_errno("proc_path", 46);
    }
    if (mount("proc", path, "proc", MS_NOSUID | MS_NODEV | MS_NOEXEC, NULL) != 0) {
        return fail_errno("proc_mount", 47);
    }
    dprintf(STDERR_FILENO, "[%lld] BFU_DEBIAN_STAGE private_proc_mounted\n",
            (long long) realtime_seconds());
    if (joined_path(path, sizeof(path), root, "proc/sys") != 0) {
        return fail_errno("proc_sys_path", 48);
    }
    result = make_bind_read_only(path, "proc_sys_read_only");
    if (result != 0) return result;
    dprintf(STDERR_FILENO, "[%lld] BFU_DEBIAN_STAGE proc_sys_read_only\n",
            (long long) realtime_seconds());

    if (joined_path(path, sizeof(path), root, "run") != 0) {
        return fail_errno("run_path", 49);
    }
    if (mount("tmpfs", path, "tmpfs", MS_NOSUID | MS_NODEV,
              "mode=0755,size=64m") != 0) {
        return fail_errno("run_tmpfs", 50);
    }
    if (joined_path(path, sizeof(path), root, "run/lock") != 0) {
        return fail_errno("run_lock_path", 51);
    }
    if (mkdir(path, 0755) != 0 && errno != EEXIST) {
        return fail_errno("run_lock_mkdir", 52);
    }
    dprintf(STDERR_FILENO, "[%lld] BFU_DEBIAN_STAGE private_run_mounted\n",
            (long long) realtime_seconds());
    if (systemd_mode) {
        char source[PATH_MAX];
        char target[PATH_MAX];
        struct stat fifo_stat;
        if (joined_path(source, sizeof(source), control_dir,
                        kHostRebootFifoName) != 0
                || joined_path(target, sizeof(target), root,
                               "run/termux-bfu-host-reboot") != 0) {
            return fail_errno("host_reboot_fifo_path", 52);
        }
        if (lstat(source, &fifo_stat) != 0 || !S_ISFIFO(fifo_stat.st_mode)
                || fifo_stat.st_uid != 0 || (fifo_stat.st_mode & 0777) != 0600) {
            return fail_message("host_reboot_fifo_validate",
                                "expected_root_owned_mode_0600_fifo", 52);
        }
        int target_fd = open(target, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
                             0600);
        if (target_fd < 0) return fail_errno("host_reboot_target_create", 52);
        close(target_fd);
        if (mount(source, target, NULL, MS_BIND, NULL) != 0) {
            return fail_errno("host_reboot_fifo_bind", 52);
        }
        dprintf(STDERR_FILENO,
                "[%lld] BFU_DEBIAN_STAGE host_reboot_bridge_mounted\n",
                (long long) realtime_seconds());
    }
    return 0;
}

static int prepare_host_reboot_fifo(const char *control_dir,
                                    char *path, size_t path_size) {
    if (joined_path(path, path_size, control_dir, kHostRebootFifoName) != 0) {
        return -1;
    }
    if (unlink(path) != 0 && errno != ENOENT) return -1;
    if (mkfifo(path, 0600) != 0) return -1;
    if (chown(path, 0, 0) != 0 || chmod(path, 0600) != 0) {
        int saved_errno = errno;
        unlink(path);
        errno = saved_errno;
        return -1;
    }
    return 0;
}

static void delete_tailscale_bypass_rule(const char *family) {
    char priority[16];
    snprintf(priority, sizeof(priority), "%d", kTailscaleBypassRulePriority);
    for (int attempt = 0; attempt < 4; attempt++) {
        char *const command[] = {"/system/bin/ip", (char *) family, "rule", "del",
                                 "pref", priority, NULL};
        if (run_argv(command, true) != 0) break;
    }
}

static int reconcile_tailscale_bypass_route(const char *family,
                                            const char *probe_address,
                                            char *active_table,
                                            size_t active_table_size) {
    char output[1024];
    char *const get_route[] = {"/system/bin/ip", (char *) family, "route", "get",
                               (char *) probe_address, NULL};
    if (capture_argv(get_route, output, sizeof(output)) != 0) {
        delete_tailscale_bypass_rule(family);
        active_table[0] = '\0';
        return -1;
    }
    char table[64] = {0};
    char *save = NULL;
    for (char *token = strtok_r(output, " \t\r\n", &save); token != NULL;
         token = strtok_r(NULL, " \t\r\n", &save)) {
        if (strcmp(token, "table") != 0) continue;
        token = strtok_r(NULL, " \t\r\n", &save);
        if (token != NULL) snprintf(table, sizeof(table), "%s", token);
        break;
    }
    if (table[0] == '\0') snprintf(table, sizeof(table), "main");
    if (strcmp(table, active_table) == 0) {
        char rules[4096];
        char *const show_rules[] = {"/system/bin/ip", (char *) family,
                                    "rule", "show", NULL};
        if (capture_argv(show_rules, rules, sizeof(rules)) == 0
                && strstr(rules, "5200:") != NULL
                && strstr(rules, "fwmark 0x80000/0xff0000") != NULL
                && strstr(rules, table) != NULL) {
            return 0;
        }
    }
    char priority[16];
    snprintf(priority, sizeof(priority), "%d", kTailscaleBypassRulePriority);
    delete_tailscale_bypass_rule(family);
    char *const add_active[] = {"/system/bin/ip", (char *) family, "rule", "add",
                                "pref", priority, "fwmark", "0x80000/0xff0000",
                                "lookup", table, NULL};
    if (run_argv(add_active, false) != 0) return -1;
    snprintf(active_table, active_table_size, "%s", table);
    dprintf(STDERR_FILENO,
            "[%lld] BFU_DEBIAN_NETWORK family=%s tailscale_bypass_table=%s\n",
            (long long) realtime_seconds(), family, table);
    return 0;
}

static void network_manager_loop(pid_t supervisor_pid, int ready_fd,
                                 const char *host_reboot_fifo) {
    (void) prctl(PR_SET_PDEATHSIG, SIGTERM);
    if (getppid() != supervisor_pid) _exit(1);
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = stop_handler;
    sigemptyset(&action.sa_mask);
    (void) sigaction(SIGTERM, &action, NULL);
    (void) sigaction(SIGINT, &action, NULL);

    delete_tailscale_bypass_rule("-4");
    delete_tailscale_bypass_rule("-6");
    int reboot_fd = open(host_reboot_fifo, O_RDWR | O_NONBLOCK | O_CLOEXEC);
    if (reboot_fd < 0) {
        unlink(host_reboot_fifo);
        (void) write(ready_fd, "0", 1);
        close(ready_fd);
        _exit(1);
    }
    (void) write(ready_fd, "1", 1);
    close(ready_fd);
    dprintf(STDERR_FILENO,
            "[%lld] BFU_DEBIAN_STAGE network_namespace_android_shared "
            "tailscale_bypass_watcher_ready=true\n",
            (long long) realtime_seconds());
    char active_table_v4[64] = {0};
    char active_table_v6[64] = {0};
    while (!stop_requested && kill(supervisor_pid, 0) == 0) {
        (void) reconcile_tailscale_bypass_route("-4", "1.1.1.1",
                                                active_table_v4,
                                                sizeof(active_table_v4));
        (void) reconcile_tailscale_bypass_route("-6", "2606:4700:4700::1111",
                                                active_table_v6,
                                                sizeof(active_table_v6));
        for (int tick = 0; tick < 20 && !stop_requested; tick++) {
            char request[64];
            ssize_t count = read(reboot_fd, request, sizeof(request) - 1);
            if (count > 0) {
                request[count] = '\0';
                if (strcmp(request, "ANDROID_REBOOT\n") == 0) {
                    dprintf(STDERR_FILENO,
                            "[%lld] BFU_DEBIAN_HOST_REBOOT_REQUEST accepted=true\n",
                            (long long) realtime_seconds());
                    char *const command[] = {"/system/bin/reboot", NULL};
                    if (run_argv(command, false) != 0) {
                        dprintf(STDERR_FILENO,
                                "[%lld] BFU_DEBIAN_HOST_REBOOT_FAILED errno=%d\n",
                                (long long) realtime_seconds(), errno);
                    }
                }
            }
            usleep(100000);
        }
    }
    close(reboot_fd);
    delete_tailscale_bypass_rule("-4");
    delete_tailscale_bypass_rule("-6");
    unlink(host_reboot_fifo);
    dprintf(STDERR_FILENO,
            "[%lld] BFU_DEBIAN_STAGE tailscale_bypass_rules_cleaned\n",
            (long long) realtime_seconds());
    _exit(0);
}

static int start_network_manager(pid_t supervisor_pid, int inherited_lock_fd,
                                 int inherited_app_ready_fd,
                                 const char *host_reboot_fifo,
                                 pid_t *manager_pid, int *ready_fd) {
    int descriptors[2];
    if (pipe(descriptors) != 0) return -1;
    pid_t child = fork();
    if (child < 0) {
        close(descriptors[0]);
        close(descriptors[1]);
        return -1;
    }
    if (child == 0) {
        close(descriptors[0]);
        close(inherited_lock_fd);
        close(inherited_app_ready_fd);
        network_manager_loop(supervisor_pid, descriptors[1], host_reboot_fifo);
    }
    close(descriptors[1]);
    *manager_pid = child;
    *ready_fd = descriptors[0];
    return 0;
}

static int wait_for_network_manager(int manager_ready_fd) {
    struct pollfd descriptor = {.fd = manager_ready_fd, .events = POLLIN | POLLHUP};
    int result;
    do {
        result = poll(&descriptor, 1, 15000);
    } while (result < 0 && errno == EINTR);
    char ready = '0';
    if (result <= 0 || read(manager_ready_fd, &ready, 1) != 1 || ready != '1') {
        close(manager_ready_fd);
        errno = result == 0 ? ETIMEDOUT : EPROTO;
        return -1;
    }
    close(manager_ready_fd);
    return 0;
}

static int set_base_private_namespaces(void) {
    if (unshare(CLONE_NEWNS) != 0) return fail_errno("unshare_mount", 53);
    if (mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL) != 0) {
        return fail_errno("mount_make_rprivate", 54);
    }
    dprintf(STDERR_FILENO,
            "[%lld] BFU_DEBIAN_STAGE mount_namespace_private\n",
            (long long) realtime_seconds());
    if (unshare(CLONE_NEWUTS) != 0) return fail_errno("unshare_uts", 55);
    dprintf(STDERR_FILENO, "[%lld] BFU_DEBIAN_STAGE uts_namespace_private\n",
            (long long) realtime_seconds());
    /* Samsung's 4.4 target kernel dereferences a stale mqueue mount pointer in
       copy_ipcs()->mq_init_ns()->mqueue_mount() when CLONE_NEWIPC is requested.
       The fault panics Android before userspace can handle an errno. IPC is
       therefore deliberately shared. Networking is also shared intentionally
       for native-NIC performance; mount/PID/UTS/cgroup isolation remains
       mandatory. */
    dprintf(STDERR_FILENO,
            "[%lld] BFU_DEBIAN_STAGE ipc_namespace_android_shared "
            "legacy_kernel_compat=true\n",
            (long long) realtime_seconds());
    return 0;
}

static int set_private_namespaces(void) {
    int result = set_base_private_namespaces();
    if (result != 0) return result;
    if (unshare(CLONE_NEWCGROUP) != 0) return fail_errno("unshare_cgroup", 57);
    if (unshare(CLONE_NEWPID) != 0) return fail_errno("unshare_pid", 58);
    return 0;
}

static int set_systemd_parent_namespaces(const char *control_dir,
                                         int network_ready_fd) {
    int result = set_base_private_namespaces();
    if (result != 0) return result;
    if (wait_for_network_manager(network_ready_fd) != 0) {
        return fail_errno("wait_network_manager", 56);
    }
    result = prepare_systemd_cgroup_mount(control_dir);
    if (result != 0) return result;
    if (unshare(CLONE_NEWPID) != 0) return fail_errno("unshare_pid", 58);
    dprintf(STDERR_FILENO, "[%lld] BFU_DEBIAN_STAGE pid_namespace_private\n",
            (long long) realtime_seconds());
    return 0;
}

static int enter_debian_probe(const char *root) {
    static const char probe_command[] =
            "set -u; "
            "fail() { printf 'BFU_DEBIAN_NAMESPACE_FAILED stage=%s\\n' \"$1\"; exit 60; }; "
            "[ \"$$\" -eq 1 ] || fail debian_shell_not_pid1; "
            "IFS= read -r proc1 < /proc/1/comm || fail proc1_read; "
            "[ \"$proc1\" = sh ] || fail proc1_not_debian_shell; "
            "arch=$(/usr/bin/dpkg --print-architecture) || fail dpkg_arch; "
            "[ \"$arch\" = arm64 ] || fail architecture_not_arm64; "
            "version=$(/usr/bin/cut -d. -f1 /etc/debian_version) || fail debian_version_read; "
            "[ \"$version\" = 13 ] || fail debian_version_not_13; "
            "if [ -x /sbin/init ]; then init=present; else init=absent; fi; "
            "if [ -x /usr/bin/systemctl ]; then systemctl=present; else systemctl=absent; fi; "
            "cgroup=$(while IFS= read -r line; do printf '%s,' \"$line\"; done < /proc/self/cgroup); "
            "printf 'BFU_DEBIAN_NAMESPACE_OK pid=%s proc1=%s arch=%s debian=%s init=%s systemctl=%s cgroup=%s\\n' "
            "\"$$\" \"$proc1\" \"$arch\" \"$version\" \"$init\" \"$systemctl\" \"$cgroup\"";

    int result = prepare_child_mounts(root, NULL, false);
    if (result != 0) return result;
    if (syscall(__NR_sethostname, "termux-bfu-probe",
                strlen("termux-bfu-probe")) != 0) {
        return fail_errno("sethostname", 59);
    }
    if (chdir(root) != 0) return fail_errno("chdir_rootfs", 60);
    if (chroot(".") != 0) return fail_errno("chroot", 61);
    if (chdir("/") != 0) return fail_errno("chdir_chroot", 62);

    clearenv();
    setenv("HOME", "/root", 1);
    setenv("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", 1);
    setenv("LANG", "C.UTF-8", 1);
    setenv("container", "termux-bfu", 1);

    char *const arguments[] = {"sh", "-c", (char *) probe_command, NULL};
    execv("/bin/sh", arguments);
    return fail_errno("exec_debian_shell", 63);
}

static int run_probe(const char *root) {
    int result = validate_rootfs(root, false);
    if (result != 0) return result;
    if (geteuid() != 0) {
        return fail_message("not_root", "launcher_requires_euid_0", 64);
    }

    signal(SIGALRM, alarm_handler);
    alarm(25);
    result = set_private_namespaces();
    if (result != 0) return result;

    const pid_t pid = fork();
    if (pid < 0) return fail_errno("fork_pid1", 65);
    if (pid == 0) {
        alarm_child_pid = -1;
        signal(SIGALRM, alarm_handler);
        alarm(20);
        _exit(enter_debian_probe(root));
    }

    alarm_child_pid = pid;
    int status;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno == EINTR) continue;
        return fail_errno("wait_pid1", 66);
    }
    alarm_child_pid = -1;
    alarm(0);

    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) {
        char message[64];
        snprintf(message, sizeof(message), "pid1_killed_by_signal_%d", WTERMSIG(status));
        return fail_message("pid1_signal", message, 67);
    }
    return fail_message("pid1_wait_status", "unexpected_wait_status", 67);
}

static int redirect_supervisor_stdio(const char *log_path) {
    struct stat value;
    int input = open("/dev/null", O_RDONLY | O_CLOEXEC);
    if (input < 0) return -1;
    int output = open(log_path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
                      0600);
    if (output < 0) {
        close(input);
        return -1;
    }
    if (fstat(output, &value) != 0 || !S_ISREG(value.st_mode) || value.st_nlink != 1) {
        close(input);
        close(output);
        errno = EINVAL;
        return -1;
    }
    if (dup2(input, STDIN_FILENO) < 0 || dup2(output, STDOUT_FILENO) < 0
            || dup2(output, STDERR_FILENO) < 0) {
        close(input);
        close(output);
        return -1;
    }
    close(input);
    close(output);
    return 0;
}

static void reset_init_signals(void) {
    const int signals[] = {SIGHUP, SIGINT, SIGTERM, SIGQUIT, SIGCHLD, SIGPIPE,
                           SIGALRM};
    for (size_t index = 0; index < sizeof(signals) / sizeof(signals[0]); index++) {
        signal(signals[index], SIG_DFL);
    }
}

static int enter_debian_systemd(const char *root, const char *control_dir) {
    int result = move_self_to_systemd_cgroup(control_dir);
    if (result != 0) return result;
    result = prepare_child_mounts(root, control_dir, true);
    if (result != 0) return result;
    log_file_snapshot("debian_pid1_cgroup", "/proc/self/cgroup");
    log_matching_snapshot("debian_cgroup_mounts", "/proc/self/mountinfo",
                          "cgroup");
    if (syscall(__NR_sethostname, "termux-bfu",
                strlen("termux-bfu")) != 0) {
        return fail_errno("sethostname", 68);
    }
    if (chdir(root) != 0) return fail_errno("chdir_rootfs", 69);
    if (chroot(".") != 0) return fail_errno("chroot", 70);
    if (chdir("/") != 0) return fail_errno("chdir_chroot", 71);

    clearenv();
    setenv("HOME", "/root", 1);
    setenv("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", 1);
    setenv("LANG", "C.UTF-8", 1);
    setenv("container", "termux-bfu", 1);
    setenv("SYSTEMD_LOG_TARGET", "console", 1);
    setenv("SYSTEMD_LOG_LEVEL", "info", 1);
    setenv("SYSTEMD_LOG_TIME", "1", 1);
    /* v257 requires both flags to retain legacy/hybrid cgroup support. This
       override is process-local and never changes Android's /proc/cmdline. */
    setenv("SYSTEMD_PROC_CMDLINE",
           "systemd.unified_cgroup_hierarchy=0 "
           "SYSTEMD_CGROUP_ENABLE_LEGACY_FORCE=1 "
           "systemd.unit=multi-user.target",
           1);
    reset_init_signals();

    char *const arguments[] = {"init", "--system", "--unit=multi-user.target",
                               "--log-target=console", "--log-level=info",
                               "--show-status=yes", NULL};
    execv("/sbin/init", arguments);
    return fail_errno("exec_systemd", 72);
}

static int wait_for_exec_result(int fd, char *failure, size_t failure_size) {
    struct pollfd descriptor = {.fd = fd, .events = POLLIN | POLLHUP};
    int result;
    do {
        result = poll(&descriptor, 1, 12000);
    } while (result < 0 && errno == EINTR);
    if (result <= 0) {
        if (result == 0) errno = ETIMEDOUT;
        return -1;
    }
    ssize_t count = read(fd, failure, failure_size - 1);
    if (count < 0) return -1;
    failure[count] = '\0';
    return count == 0 ? 0 : 1;
}

static int wait_for_start_grace(pid_t init_pid) {
    const int64_t deadline = monotonic_millis() + kStartGraceMs;
    while (monotonic_millis() < deadline) {
        int status;
        pid_t result = waitpid(init_pid, &status, WNOHANG);
        if (result == init_pid) {
            errno = ECHILD;
            return -1;
        }
        if (result < 0 && errno != EINTR) return -1;
        usleep(100000);
    }
    return kill(init_pid, 0);
}

/* systemd's halt signal eventually reaches the kernel reboot path. On the
   Samsung 4.4 kernel used by the target device that path does not terminate
   this private PID namespace, so a normal stop used to time out and SIGKILL
   PID 1. `systemctl exit` is systemd's container-manager shutdown API: it
   stops units and then exits PID 1 without asking the Android kernel to halt.
   The supervisor's children already enter the same pending PID namespace as
   systemd and share its prepared mount namespace. */
static int request_systemd_manager_exit(const char *root, int lock_fd) {
    pid_t command_pid = fork();
    if (command_pid < 0) return -1;
    if (command_pid == 0) {
        close(lock_fd);
        reset_init_signals();
        if (chdir(root) != 0 || chroot(".") != 0 || chdir("/") != 0) _exit(126);
        clearenv();
        setenv("HOME", "/root", 1);
        setenv("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
               1);
        setenv("LANG", "C.UTF-8", 1);
        setenv("container", "termux-bfu", 1);
        char *const arguments[] = {"systemctl", "--no-block", "exit", NULL};
        execv("/usr/bin/systemctl", arguments);
        _exit(127);
    }

    const int64_t deadline = monotonic_millis() + 5000;
    int status = 0;
    while (monotonic_millis() < deadline) {
        pid_t waited = waitpid(command_pid, &status, WNOHANG);
        if (waited == command_pid) {
            if (WIFEXITED(status) && WEXITSTATUS(status) == 0) return 0;
            errno = EPROTO;
            return -1;
        }
        if (waited < 0 && errno != EINTR) return -1;
        usleep(100000);
    }
    (void) kill(command_pid, SIGKILL);
    while (waitpid(command_pid, NULL, 0) < 0 && errno == EINTR) {}
    errno = ETIMEDOUT;
    return -1;
}

static int supervisor_loop(const char *root, const char *control_dir,
                           const char *log_path, int lock_fd, int ready_fd) {
    if (setsid() < 0) {
        dprintf(ready_fd, "BFU_DEBIAN_START_FAILED stage=setsid errno=%d\n", errno);
        return 73;
    }
    signal(SIGHUP, SIG_IGN);
    if (redirect_supervisor_stdio(log_path) != 0) {
        dprintf(ready_fd, "BFU_DEBIAN_START_FAILED stage=open_lifecycle_log errno=%d\n",
                errno);
        return 74;
    }
    dprintf(STDERR_FILENO,
            "[%lld] BFU_DEBIAN_STAGE supervisor_started pid=%d root=%s\n",
            (long long) realtime_seconds(), getpid(), root);
    log_file_snapshot("host_proc_cgroups", "/proc/cgroups");
    log_file_snapshot("host_self_cgroup", "/proc/self/cgroup");
    log_matching_snapshot("host_cgroup_mounts", "/proc/self/mountinfo", "cgroup");

    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = stop_handler;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGTERM, &action, NULL) != 0
            || sigaction(SIGINT, &action, NULL) != 0) {
        dprintf(ready_fd, "BFU_DEBIAN_START_FAILED stage=signal_setup errno=%d\n", errno);
        return 75;
    }

    LauncherState state;
    initialize_state(&state, "starting");
    state.supervisor_pid = getpid();
    if (read_proc_start_ticks(state.supervisor_pid,
                              &state.supervisor_start_ticks) != 0
            || read_proc_exe_identity(state.supervisor_pid,
                                      &state.supervisor_exe_dev,
                                      &state.supervisor_exe_ino) != 0) {
        dprintf(ready_fd,
                "BFU_DEBIAN_START_FAILED stage=supervisor_identity errno=%d\n", errno);
        return 76;
    }
    if (write_state(control_dir, &state) != 0) {
        dprintf(ready_fd, "BFU_DEBIAN_START_FAILED stage=write_starting_state errno=%d\n",
                errno);
        return 77;
    }

    pid_t network_manager_pid = -1;
    int network_ready_fd = -1;
    char host_reboot_fifo[PATH_MAX];
    if (prepare_host_reboot_fifo(control_dir, host_reboot_fifo,
                                 sizeof(host_reboot_fifo)) != 0) {
        dprintf(ready_fd,
                "BFU_DEBIAN_START_FAILED stage=host_reboot_fifo errno=%d\n",
                errno);
        return 78;
    }
    if (start_network_manager(getpid(), lock_fd, ready_fd,
                              host_reboot_fifo,
                              &network_manager_pid, &network_ready_fd) != 0) {
        unlink(host_reboot_fifo);
        dprintf(ready_fd,
                "BFU_DEBIAN_START_FAILED stage=network_manager_start errno=%d\n",
                errno);
        return 78;
    }

    int result = set_systemd_parent_namespaces(control_dir, network_ready_fd);
    if (result != 0) {
        dprintf(ready_fd, "BFU_DEBIAN_START_FAILED stage=namespace_setup exit=%d\n",
                result);
        return result;
    }

    int exec_pipe[2];
    if (pipe(exec_pipe) != 0) {
        dprintf(ready_fd, "BFU_DEBIAN_START_FAILED stage=exec_pipe errno=%d\n", errno);
        return 78;
    }
    (void) fcntl(exec_pipe[0], F_SETFD, FD_CLOEXEC);
    (void) fcntl(exec_pipe[1], F_SETFD, FD_CLOEXEC);

    pid_t init_pid = fork();
    if (init_pid < 0) {
        dprintf(ready_fd, "BFU_DEBIAN_START_FAILED stage=fork_systemd errno=%d\n", errno);
        close(exec_pipe[0]);
        close(exec_pipe[1]);
        return 79;
    }
    if (init_pid == 0) {
        close(exec_pipe[0]);
        close(lock_fd);
        close(ready_fd);
        failure_report_fd = exec_pipe[1];
        _exit(enter_debian_systemd(root, control_dir));
    }

    close(exec_pipe[1]);
    state.init_host_pid = init_pid;
    for (int attempt = 0; attempt < 20; attempt++) {
        if (read_proc_start_ticks(init_pid, &state.init_start_ticks) == 0) break;
        usleep(50000);
    }
    if (write_state(control_dir, &state) != 0) {
        dprintf(STDERR_FILENO,
                "[%lld] BFU_DEBIAN_WARNING state_write_failed errno=%d\n",
                (long long) realtime_seconds(), errno);
    }

    char failure[1024];
    result = wait_for_exec_result(exec_pipe[0], failure, sizeof(failure));
    close(exec_pipe[0]);
    if (result != 0) {
        if (result > 0) dprintf(STDERR_FILENO, "%s", failure);
        else dprintf(STDERR_FILENO,
                     "[%lld] BFU_DEBIAN_START_FAILED stage=wait_exec errno=%d\n",
                     (long long) realtime_seconds(), errno);
        kill(init_pid, SIGKILL);
        (void) waitpid(init_pid, NULL, 0);
        snprintf(state.state, sizeof(state.state), "failed");
        state.wait_status = 80;
        (void) write_state(control_dir, &state);
        dprintf(ready_fd, "BFU_DEBIAN_START_FAILED stage=exec_systemd\n");
        return 80;
    }

    if (wait_for_start_grace(init_pid) != 0) {
        snprintf(state.state, sizeof(state.state), "failed");
        state.wait_status = 81;
        (void) write_state(control_dir, &state);
        dprintf(ready_fd, "BFU_DEBIAN_START_FAILED stage=systemd_early_exit\n");
        return 81;
    }

    if (read_proc_exe_identity(init_pid, &state.init_exe_dev,
                               &state.init_exe_ino) != 0
            || capture_init_namespace_identity(init_pid, &state) != 0
            || validate_init_namespace_topology(&state) != 0) {
        dprintf(STDERR_FILENO,
                "[%lld] BFU_DEBIAN_START_FAILED stage=init_identity_or_pid_namespace errno=%d\n",
                (long long) realtime_seconds(), errno);
        kill(init_pid, SIGRTMIN + 3);
        snprintf(state.state, sizeof(state.state), "failed");
        state.wait_status = 82;
        (void) write_state(control_dir, &state);
        dprintf(ready_fd,
                "BFU_DEBIAN_START_FAILED stage=init_identity_or_pid_namespace\n");
        return 82;
    }

    snprintf(state.state, sizeof(state.state), "running");
    if (write_state(control_dir, &state) != 0) {
        dprintf(STDERR_FILENO,
                "[%lld] BFU_DEBIAN_WARNING running_state_write_failed errno=%d\n",
                (long long) realtime_seconds(), errno);
    }
    dprintf(STDERR_FILENO,
            "[%lld] BFU_DEBIAN_SYSTEMD_STARTED supervisor_pid=%d init_host_pid=%d "
            "namespaces=pid:%llu,mnt:%llu,uts:%llu,ipc:%llu,cgroup:%llu,net:%llu "
            "ipc_namespace=android-shared network_namespace=android-shared "
            "network_mode=shared-nic\n",
            (long long) realtime_seconds(), getpid(), init_pid,
            (unsigned long long) state.init_pid_ns_ino,
            (unsigned long long) state.init_mnt_ns_ino,
            (unsigned long long) state.init_uts_ns_ino,
            (unsigned long long) state.init_ipc_ns_ino,
            (unsigned long long) state.init_cgroup_ns_ino,
            (unsigned long long) state.init_net_ns_ino);
    dprintf(ready_fd,
            "BFU_DEBIAN_STARTED supervisor_pid=%d init_host_pid=%d namespace_pid=1\n",
            getpid(), init_pid);
    close(ready_fd);

    bool shutdown_sent = false;
    int64_t shutdown_deadline = 0;
    int wait_status = 0;
    while (true) {
        pid_t waited = waitpid(init_pid, &wait_status, WNOHANG);
        if (waited == init_pid) break;
        if (waited < 0 && errno != EINTR) {
            wait_status = 255;
            break;
        }
        if (stop_requested && !shutdown_sent) {
            dprintf(STDERR_FILENO,
                    "[%lld] BFU_DEBIAN_STAGE graceful_stop_requested\n",
                    (long long) realtime_seconds());
            if (request_systemd_manager_exit(root, lock_fd) == 0) {
                dprintf(STDERR_FILENO,
                        "[%lld] BFU_DEBIAN_STAGE systemd_manager_exit_queued\n",
                        (long long) realtime_seconds());
            } else {
                dprintf(STDERR_FILENO,
                        "[%lld] BFU_DEBIAN_WARNING systemd_manager_exit_failed "
                        "errno=%d fallback=SIGRTMIN+3\n",
                        (long long) realtime_seconds(), errno);
                (void) kill(init_pid, SIGRTMIN + 3);
            }
            shutdown_sent = true;
            shutdown_deadline = monotonic_millis() + 20000;
            snprintf(state.state, sizeof(state.state), "stopping");
            (void) write_state(control_dir, &state);
        }
        if (shutdown_sent && monotonic_millis() >= shutdown_deadline) {
            dprintf(STDERR_FILENO,
                    "[%lld] BFU_DEBIAN_WARNING graceful_stop_timeout_killing_pid1\n",
                    (long long) realtime_seconds());
            kill(init_pid, SIGKILL);
            shutdown_deadline = INT64_MAX;
        }
        usleep(200000);
    }

    if (network_manager_pid > 0) {
        (void) kill(network_manager_pid, SIGTERM);
        while (waitpid(network_manager_pid, NULL, 0) < 0 && errno == EINTR) {}
    }
    snprintf(state.state, sizeof(state.state), "stopped");
    state.wait_status = wait_status;
    (void) write_state(control_dir, &state);
    dprintf(STDERR_FILENO,
            "[%lld] BFU_DEBIAN_SYSTEMD_EXITED wait_status=%d\n",
            (long long) realtime_seconds(), wait_status);
    close(lock_fd);
    return 0;
}

static int read_ready_message(int fd, char *output, size_t output_size) {
    struct pollfd descriptor = {.fd = fd, .events = POLLIN | POLLHUP};
    const int64_t deadline = monotonic_millis() + kStartTimeoutMs;
    size_t offset = 0;
    while (monotonic_millis() < deadline && offset + 1 < output_size) {
        int timeout = (int) (deadline - monotonic_millis());
        int result = poll(&descriptor, 1, timeout);
        if (result < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (result == 0) {
            errno = ETIMEDOUT;
            return -1;
        }
        ssize_t count = read(fd, output + offset, output_size - offset - 1);
        if (count < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (count == 0) break;
        offset += (size_t) count;
        if (memchr(output, '\n', offset) != NULL) break;
    }
    output[offset] = '\0';
    return offset > 0 ? 0 : -1;
}

static int run_status(const char *root, const char *control_dir) {
    (void) root;
    int result = validate_control_directory(control_dir);
    if (result != 0) return result;
    char lock_path[PATH_MAX];
    int lock_fd = open_lock_file(control_dir, lock_path, sizeof(lock_path));
    if (lock_fd < 0) return fail_errno("open_lock", 82);

    if (flock(lock_fd, LOCK_EX | LOCK_NB) == 0) {
        LauncherState stale = {0};
        int has_state = read_state(control_dir, &stale) == 0;
        bool orphaned_init = has_state && validate_init_identity(&stale);
        flock(lock_fd, LOCK_UN);
        close(lock_fd);
        if (orphaned_init) {
            printf("BFU_DEBIAN_ORPHANED_INIT init_host_pid=%d identity_valid=true "
                   "updated_epoch=%lld\n", stale.init_host_pid,
                   (long long) stale.updated_epoch);
            return 1;
        }
        printf("BFU_DEBIAN_STOPPED last_state=%s wait_status=%d updated_epoch=%lld\n",
               has_state ? stale.state : "none", has_state ? stale.wait_status : -1,
               (long long) (has_state ? stale.updated_epoch : 0));
        return 0;
    }
    if (errno != EWOULDBLOCK && errno != EAGAIN) {
        close(lock_fd);
        return fail_errno("lock_status", 83);
    }

    LauncherState state = {0};
    bool state_read = read_state(control_dir, &state) == 0;
    bool supervisor_valid = state_read && validate_supervisor_identity(&state);
    bool init_valid = state_read && validate_init_identity(&state);
    bool topology_valid = init_valid
            && validate_init_namespace_topology(&state) == 0;
    close(lock_fd);
    printf("BFU_DEBIAN_%s state=%s supervisor_pid=%d init_host_pid=%d "
           "supervisor_identity_valid=%s init_identity_valid=%s "
           "namespace_topology_valid=%s ipc_namespace=android-shared "
           "network_namespace=android-shared network_mode=shared-nic "
           "pid_ns=%llu mnt_ns=%llu uts_ns=%llu ipc_ns=%llu cgroup_ns=%llu "
           "net_ns=%llu updated_epoch=%lld\n",
           supervisor_valid && (topology_valid || strcmp(state.state, "starting") == 0)
                   ? "RUNNING" : "STARTING_OR_UNKNOWN",
           state.state, state.supervisor_pid, state.init_host_pid,
           supervisor_valid ? "true" : "false", init_valid ? "true" : "false",
           topology_valid ? "true" : "false",
           (unsigned long long) state.init_pid_ns_ino,
           (unsigned long long) state.init_mnt_ns_ino,
           (unsigned long long) state.init_uts_ns_ino,
           (unsigned long long) state.init_ipc_ns_ino,
           (unsigned long long) state.init_cgroup_ns_ino,
           (unsigned long long) state.init_net_ns_ino,
           (long long) state.updated_epoch);
    return 0;
}

static int enter_debian_health(const char *root) {
    static const char health_command[] =
            "set -u; "
            "pid1=$(/usr/bin/cat /proc/1/comm 2>/dev/null || true); "
            "pid1_start_ticks=$(/usr/bin/mawk '{print $22}' /proc/1/stat "
            "2>/dev/null || true); "
            "system_state=$(/usr/bin/timeout -k 1 3 /usr/bin/systemctl "
            "is-system-running 2>/dev/null || true); "
            "dbus_service=$(/usr/bin/timeout -k 1 3 /usr/bin/systemctl "
            "is-active dbus.service 2>/dev/null || true); "
            "ssh_service=$(/usr/bin/timeout -k 1 3 /usr/bin/systemctl "
            "is-active ssh.service 2>/dev/null || true); "
            "boot_proof_service=$(/usr/bin/timeout -k 1 3 /usr/bin/systemctl "
            "is-active termux-bfu-boot-proof.service 2>/dev/null || true); "
            "if [ -f /run/termux-bfu-enabled-service.ready ]; then "
            "boot_proof_marker=present; else boot_proof_marker=missing; fi; "
            "default_target=$(/usr/bin/timeout -k 1 3 /usr/bin/systemctl "
            "get-default 2>/dev/null || true); "
            "target_state=$(/usr/bin/timeout -k 1 3 /usr/bin/systemctl "
            "is-active multi-user.target 2>/dev/null || true); "
            "if /usr/bin/timeout -k 1 3 /usr/bin/busctl --system --no-pager list "
            ">/dev/null 2>&1; then dbus_bus=ok; else dbus_bus=failed; fi; "
            "listen_22=$(/usr/bin/ss -H -ltn 2>/dev/null | /usr/bin/mawk "
            "'$4 ~ /:22$/ { found=1 } END { if (found) print \"true\"; "
            "else print \"false\" }'); "
            "printf 'BFU_DEBIAN_HEALTH pid1=%s pid1_start_ticks=%s "
            "system_state=%s dbus_service=%s dbus_bus=%s ssh_service=%s "
            "boot_proof_service=%s boot_proof_marker=%s "
            "default_target=%s target_state=%s listen_22=%s\\n' "
            "\"$pid1\" \"$pid1_start_ticks\" "
            "\"$system_state\" \"$dbus_service\" \"$dbus_bus\" "
            "\"$ssh_service\" \"$boot_proof_service\" \"$boot_proof_marker\" "
            "\"$default_target\" \"$target_state\" \"$listen_22\"; "
            "if [ \"$pid1\" = systemd ] && [ \"$system_state\" = running ] "
            "&& [ \"$dbus_service\" = active ] "
            "&& [ \"$dbus_bus\" = ok ] && [ \"$ssh_service\" = active ] "
            "&& [ \"$boot_proof_service\" = active ] "
            "&& [ \"$boot_proof_marker\" = present ] "
            "&& [ \"$default_target\" = multi-user.target ] "
            "&& [ \"$target_state\" = active ] "
            "&& [ \"$listen_22\" = true ]; then exit 0; fi; "
            "printf '%s\\n' BFU_DEBIAN_DIAGNOSTICS_BEGIN; "
            "/usr/bin/timeout -k 1 3 /usr/bin/systemctl --no-pager --failed "
            "2>&1 || true; "
            "printf '%s\\n' BFU_DEBIAN_DIAGNOSTICS_END; exit 1";

    if (chdir(root) != 0) return fail_errno("health_chdir_rootfs", 103);
    if (chroot(".") != 0) return fail_errno("health_chroot", 104);
    if (chdir("/") != 0) return fail_errno("health_chdir_chroot", 105);
    clearenv();
    setenv("HOME", "/root", 1);
    setenv("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", 1);
    setenv("LANG", "C.UTF-8", 1);
    setenv("container", "termux-bfu", 1);
    char *const arguments[] = {"sh", "-c", (char *) health_command, NULL};
    execv("/bin/sh", arguments);
    return fail_errno("health_exec_shell", 106);
}

typedef int (*NamespaceChildEntry)(const char *root, const char *argument);

static int enter_debian_health_child(const char *root, const char *argument) {
    (void) argument;
    return enter_debian_health(root);
}

static int enter_debian_systemctl_shutdown(const char *root, const char *mode) {
    if (strcmp(mode, "poweroff") != 0 && strcmp(mode, "reboot") != 0
            && strcmp(mode, "shutdown") != 0) {
        return fail_message("shutdown_test_mode",
                            "only_poweroff_reboot_or_shutdown_allowed", 108);
    }
    if (chdir(root) != 0) return fail_errno("shutdown_test_chdir_rootfs", 108);
    if (chroot(".") != 0) return fail_errno("shutdown_test_chroot", 108);
    if (chdir("/") != 0) return fail_errno("shutdown_test_chdir_chroot", 108);
    clearenv();
    setenv("HOME", "/root", 1);
    setenv("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", 1);
    setenv("LANG", "C.UTF-8", 1);
    setenv("container", "termux-bfu", 1);
    if (strcmp(mode, "shutdown") == 0) {
        char *const arguments[] = {
                "shutdown", "--poweroff", "--no-wall", "now", NULL
        };
        execv("/usr/sbin/shutdown", arguments);
        return fail_errno("shutdown_test_exec_shutdown", 108);
    }
    char *const arguments[] = {"systemctl", "--no-block", (char *) mode, NULL};
    execv("/usr/bin/systemctl", arguments);
    return fail_errno("shutdown_test_exec_systemctl", 108);
}

static int run_in_debian_namespaces(const char *root, const char *control_dir,
                                    NamespaceChildEntry entry,
                                    const char *argument, unsigned int timeout_seconds) {
    int result = validate_rootfs(root, true);
    if (result != 0) return result;
    if (geteuid() != 0) {
        return fail_message("not_root", "namespace_command_requires_euid_0", 100);
    }
    result = validate_control_directory(control_dir);
    if (result != 0) return result;

    char lock_path[PATH_MAX];
    int lock_fd = open_lock_file(control_dir, lock_path, sizeof(lock_path));
    if (lock_fd < 0) return fail_errno("namespace_command_open_lock", 100);
    if (flock(lock_fd, LOCK_EX | LOCK_NB) == 0) {
        flock(lock_fd, LOCK_UN);
        close(lock_fd);
        return fail_message("namespace_command_not_running",
                            "supervisor_lock_is_free", 101);
    }
    if (errno != EWOULDBLOCK && errno != EAGAIN) {
        close(lock_fd);
        return fail_errno("namespace_command_lock", 101);
    }

    LauncherState state = {0};
    if (read_state(control_dir, &state) != 0
            || !validate_supervisor_identity(&state)
            || !validate_init_identity(&state)
            || validate_init_namespace_topology(&state) != 0) {
        close(lock_fd);
        return fail_message("namespace_command_identity",
                            "supervisor_init_or_namespace_identity_invalid", 102);
    }

    char namespace_path[96];
    int count = snprintf(namespace_path, sizeof(namespace_path), "/proc/%d/ns/mnt",
                         state.init_host_pid);
    if (count < 0 || (size_t) count >= sizeof(namespace_path)) {
        close(lock_fd);
        errno = ENAMETOOLONG;
        return fail_errno("namespace_command_mount_path", 102);
    }
    int mount_namespace_fd = open(namespace_path, O_RDONLY | O_CLOEXEC);
    if (mount_namespace_fd < 0) {
        close(lock_fd);
        return fail_errno("namespace_command_open_mount", 102);
    }
    count = snprintf(namespace_path, sizeof(namespace_path), "/proc/%d/ns/pid",
                     state.init_host_pid);
    if (count < 0 || (size_t) count >= sizeof(namespace_path)) {
        close(mount_namespace_fd);
        close(lock_fd);
        errno = ENAMETOOLONG;
        return fail_errno("namespace_command_pid_path", 102);
    }
    int pid_namespace_fd = open(namespace_path, O_RDONLY | O_CLOEXEC);
    if (pid_namespace_fd < 0) {
        close(mount_namespace_fd);
        close(lock_fd);
        return fail_errno("namespace_command_open_pid", 102);
    }
    struct stat mount_namespace_stat;
    struct stat pid_namespace_stat;
    if (fstat(mount_namespace_fd, &mount_namespace_stat) != 0
            || fstat(pid_namespace_fd, &pid_namespace_stat) != 0
            || (uint64_t) mount_namespace_stat.st_ino != state.init_mnt_ns_ino
            || (uint64_t) pid_namespace_stat.st_ino != state.init_pid_ns_ino
            || !validate_init_identity(&state)) {
        close(pid_namespace_fd);
        close(mount_namespace_fd);
        close(lock_fd);
        return fail_message("namespace_command_race",
                            "init_identity_changed_before_setns", 102);
    }
    close(lock_fd);
    if (setns(pid_namespace_fd, CLONE_NEWPID) != 0) {
        close(pid_namespace_fd);
        close(mount_namespace_fd);
        return fail_errno("namespace_command_setns_pid", 102);
    }
    close(pid_namespace_fd);
    if (setns(mount_namespace_fd, CLONE_NEWNS) != 0) {
        close(mount_namespace_fd);
        return fail_errno("namespace_command_setns_mount", 102);
    }
    close(mount_namespace_fd);

    pid_t child_pid = fork();
    if (child_pid < 0) return fail_errno("namespace_command_fork", 107);
    if (child_pid == 0) _exit(entry(root, argument));
    signal(SIGALRM, alarm_handler);
    alarm_child_pid = child_pid;
    alarm(timeout_seconds);
    int wait_status;
    while (waitpid(child_pid, &wait_status, 0) < 0) {
        if (errno == EINTR) continue;
        alarm_child_pid = -1;
        alarm(0);
        return fail_errno("namespace_command_wait", 107);
    }
    alarm_child_pid = -1;
    alarm(0);
    if (WIFEXITED(wait_status)) return WEXITSTATUS(wait_status);
    if (WIFSIGNALED(wait_status)) {
        char message[64];
        snprintf(message, sizeof(message), "child_killed_by_signal_%d",
                 WTERMSIG(wait_status));
        return fail_message("namespace_command_signal", message, 107);
    }
    return fail_message("namespace_command_wait_status", "unexpected_wait_status", 107);
}

static int run_health(const char *root, const char *control_dir) {
    return run_in_debian_namespaces(root, control_dir,
                                    enter_debian_health_child, NULL, 25);
}

static int wait_for_supervisor_exit(const char *control_dir) {
    char lock_path[PATH_MAX];
    int lock_fd = open_lock_file(control_dir, lock_path, sizeof(lock_path));
    if (lock_fd < 0) return fail_errno("shutdown_test_open_lock", 109);
    const int64_t deadline = monotonic_millis() + 45000;
    while (monotonic_millis() < deadline) {
        if (flock(lock_fd, LOCK_EX | LOCK_NB) == 0) {
            flock(lock_fd, LOCK_UN);
            close(lock_fd);
            return 0;
        }
        if (errno != EWOULDBLOCK && errno != EAGAIN) {
            close(lock_fd);
            return fail_errno("shutdown_test_wait_lock", 109);
        }
        usleep(200000);
    }
    close(lock_fd);
    return fail_message("shutdown_test_timeout",
                        "systemd_did_not_release_supervisor_lock", 109);
}

static int run_shutdown_test(const char *root, const char *control_dir,
                             const char *mode) {
    if (strcmp(mode, "poweroff") != 0 && strcmp(mode, "reboot") != 0
            && strcmp(mode, "shutdown") != 0) {
        return fail_message("shutdown_test_mode",
                            "only_poweroff_reboot_or_shutdown_allowed", 108);
    }
    printf("BFU_DEBIAN_SHUTDOWN_TEST_REQUESTED mode=%s\n", mode);
    int command_result = run_in_debian_namespaces(root, control_dir,
                                                  enter_debian_systemctl_shutdown,
                                                  mode, 15);
    int stop_result = wait_for_supervisor_exit(control_dir);
    if (stop_result != 0) return command_result != 0 ? command_result : stop_result;
    printf("BFU_DEBIAN_SHUTDOWN_TEST_COMPLETED mode=%s command_result=%d "
           "android_reboot_not_assessed\n", mode, command_result);
    return 0;
}

static int run_start(const char *root, const char *control_dir,
                     const char *log_path) {
    int result = validate_rootfs(root, true);
    if (result != 0) return result;
    if (geteuid() != 0) {
        return fail_message("not_root", "launcher_requires_euid_0", 84);
    }
    result = validate_control_directory(control_dir);
    if (result != 0) return result;
    if (log_path == NULL || log_path[0] != '/') {
        return fail_message("log_path", "lifecycle_log_must_be_absolute", 85);
    }
    char expected_log_path[PATH_MAX];
    if (joined_path(expected_log_path, sizeof(expected_log_path), control_dir,
                    kLifecycleLogName) != 0
            || strcmp(log_path, expected_log_path) != 0) {
        return fail_message("log_path", "lifecycle_log_must_be_inside_control_dir", 85);
    }

    char lock_path[PATH_MAX];
    int lock_fd = open_lock_file(control_dir, lock_path, sizeof(lock_path));
    if (lock_fd < 0) return fail_errno("open_lock", 86);
    if (flock(lock_fd, LOCK_EX | LOCK_NB) != 0) {
        if (errno == EWOULDBLOCK || errno == EAGAIN) {
            LauncherState state = {0};
            bool valid = read_state(control_dir, &state) == 0
                    && validate_supervisor_identity(&state);
            close(lock_fd);
            printf("BFU_DEBIAN_ALREADY_RUNNING supervisor_pid=%d init_host_pid=%d "
                   "identity_valid=%s\n", state.supervisor_pid, state.init_host_pid,
                   valid ? "true" : "false");
            return valid ? 0 : fail_message("locked_state_invalid",
                                            "active_lock_has_no_valid_supervisor_identity", 87);
        }
        close(lock_fd);
        return fail_errno("lock_start", 88);
    }

    LauncherState stale = {0};
    if (read_state(control_dir, &stale) == 0 && validate_init_identity(&stale)) {
        flock(lock_fd, LOCK_UN);
        close(lock_fd);
        return fail_message("orphaned_init",
                            "verified_systemd_pid1_exists_without_supervisor", 89);
    }

    int ready_pipe[2];
    if (pipe(ready_pipe) != 0) {
        close(lock_fd);
        return fail_errno("ready_pipe", 89);
    }
    (void) fcntl(ready_pipe[0], F_SETFD, FD_CLOEXEC);
    (void) fcntl(ready_pipe[1], F_SETFD, FD_CLOEXEC);

    pid_t supervisor = fork();
    if (supervisor < 0) {
        close(ready_pipe[0]);
        close(ready_pipe[1]);
        close(lock_fd);
        return fail_errno("fork_supervisor", 90);
    }
    if (supervisor == 0) {
        close(ready_pipe[0]);
        int exit_code = supervisor_loop(root, control_dir, log_path,
                                        lock_fd, ready_pipe[1]);
        close(ready_pipe[1]);
        close(lock_fd);
        _exit(exit_code);
    }

    close(ready_pipe[1]);
    close(lock_fd);
    char message[1024];
    result = read_ready_message(ready_pipe[0], message, sizeof(message));
    close(ready_pipe[0]);
    if (result != 0) return fail_errno("start_readiness_timeout", 91);
    fputs(message, stdout);
    return strncmp(message, "BFU_DEBIAN_STARTED ", 19) == 0 ? 0 : 92;
}

static int run_stop(const char *root, const char *control_dir) {
    (void) root;
    if (geteuid() != 0) {
        return fail_message("not_root", "launcher_requires_euid_0", 93);
    }
    int result = validate_control_directory(control_dir);
    if (result != 0) return result;
    char lock_path[PATH_MAX];
    int lock_fd = open_lock_file(control_dir, lock_path, sizeof(lock_path));
    if (lock_fd < 0) return fail_errno("open_lock", 94);
    if (flock(lock_fd, LOCK_EX | LOCK_NB) == 0) {
        LauncherState orphan = {0};
        bool orphaned_init = read_state(control_dir, &orphan) == 0
                && validate_init_identity(&orphan);
        flock(lock_fd, LOCK_UN);
        close(lock_fd);
        if (orphaned_init) {
            if (kill(orphan.init_host_pid, SIGRTMIN + 3) != 0) {
                return fail_errno("signal_orphaned_init", 95);
            }
            const int64_t deadline = monotonic_millis() + 20000;
            while (monotonic_millis() < deadline) {
                if (!validate_init_identity(&orphan)) {
                    printf("BFU_DEBIAN_ORPHANED_INIT_STOPPED init_host_pid=%d\n",
                           orphan.init_host_pid);
                    return 0;
                }
                usleep(200000);
            }
            if (validate_init_identity(&orphan)) {
                (void) kill(orphan.init_host_pid, SIGKILL);
            }
            return fail_message("orphaned_init_stop_timeout",
                                "forced_SIGKILL_after_grace_period", 95);
        }
        printf("BFU_DEBIAN_ALREADY_STOPPED\n");
        return 0;
    }
    if (errno != EWOULDBLOCK && errno != EAGAIN) {
        close(lock_fd);
        return fail_errno("lock_stop", 95);
    }

    LauncherState state = {0};
    if (read_state(control_dir, &state) != 0
            || !validate_supervisor_identity(&state)) {
        close(lock_fd);
        return fail_message("stop_identity_invalid",
                            "refusing_to_signal_unverified_pid", 96);
    }
    if (kill(state.supervisor_pid, SIGTERM) != 0) {
        close(lock_fd);
        return fail_errno("signal_supervisor", 97);
    }

    const int64_t deadline = monotonic_millis() + kStopTimeoutMs;
    while (monotonic_millis() < deadline) {
        if (flock(lock_fd, LOCK_EX | LOCK_NB) == 0) {
            flock(lock_fd, LOCK_UN);
            close(lock_fd);
            printf("BFU_DEBIAN_STOPPED supervisor_pid=%d\n", state.supervisor_pid);
            return 0;
        }
        if (errno != EWOULDBLOCK && errno != EAGAIN) {
            close(lock_fd);
            return fail_errno("wait_stop_lock", 98);
        }
        usleep(200000);
    }
    close(lock_fd);
    return fail_message("stop_timeout", "supervisor_did_not_release_lock", 99);
}

static int run_restart(const char *root, const char *control_dir,
                       const char *log_path) {
    int result = run_stop(root, control_dir);
    if (result != 0) return result;
    return run_start(root, control_dir, log_path);
}

static void usage(const char *program) {
    fprintf(stderr,
            "usage:\n"
            "  %s probe /data/local/debian\n"
            "  %s start /data/local/debian CONTROL_DIR LIFECYCLE_LOG\n"
            "  %s status /data/local/debian CONTROL_DIR\n"
            "  %s health /data/local/debian CONTROL_DIR\n"
            "  %s stop /data/local/debian CONTROL_DIR\n"
            "  %s restart /data/local/debian CONTROL_DIR LIFECYCLE_LOG\n"
            "  %s shutdown-test /data/local/debian CONTROL_DIR poweroff|reboot|shutdown\n",
            program, program, program, program, program, program, program);
}

int main(int argc, char **argv) {
    if (argc == 3 && strcmp(argv[1], "probe") == 0) {
        return run_probe(argv[2]);
    }
    if (argc == 5 && strcmp(argv[1], "start") == 0) {
        return run_start(argv[2], argv[3], argv[4]);
    }
    if (argc == 4 && strcmp(argv[1], "status") == 0) {
        return run_status(argv[2], argv[3]);
    }
    if (argc == 4 && strcmp(argv[1], "health") == 0) {
        return run_health(argv[2], argv[3]);
    }
    if (argc == 4 && strcmp(argv[1], "stop") == 0) {
        return run_stop(argv[2], argv[3]);
    }
    if (argc == 5 && strcmp(argv[1], "restart") == 0) {
        return run_restart(argv[2], argv[3], argv[4]);
    }
    if (argc == 5 && strcmp(argv[1], "shutdown-test") == 0) {
        return run_shutdown_test(argv[2], argv[3], argv[4]);
    }
    usage(argv[0]);
    return 2;
}
