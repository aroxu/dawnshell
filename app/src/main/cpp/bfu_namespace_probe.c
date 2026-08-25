#define _GNU_SOURCE

#include <errno.h>
#include <dirent.h>
#include <fcntl.h>
#include <limits.h>
#include <linux/bpf.h>
#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <poll.h>
#include <sched.h>
#include <signal.h>
#include <stddef.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/mount.h>
#include <sys/prctl.h>
#ifndef PR_CAPBSET_DROP
#define PR_CAPBSET_DROP 24
#endif
#ifndef CAP_SYS_BOOT
#define CAP_SYS_BOOT 22
#endif
#ifndef CLONE_NEWIPC
#define CLONE_NEWIPC 0x08000000
#endif
#if defined(__aarch64__)
#define DAWNSHELL_AUDIT_ARCH AUDIT_ARCH_AARCH64
#elif defined(__arm__)
#define DAWNSHELL_AUDIT_ARCH AUDIT_ARCH_ARM
#elif defined(__x86_64__)
#define DAWNSHELL_AUDIT_ARCH AUDIT_ARCH_X86_64
#endif
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#if defined(__aarch64__)
#define DAWNSHELL_DEBIAN_ARCH "arm64"
#elif defined(__arm__)
#define DAWNSHELL_DEBIAN_ARCH "armhf"
#elif defined(__x86_64__)
#define DAWNSHELL_DEBIAN_ARCH "amd64"
#else
#error "DawnShell supports only ARMv7, ARM64, and x86_64"
#endif

#ifndef CLONE_NEWCGROUP
#define CLONE_NEWCGROUP 0x02000000
#endif

static const char *const kAllowedRoot = "/data/local/debian";
static const char *const kArchitectureMarker =
        "architecture=" DAWNSHELL_DEBIAN_ARCH;
static const char *const kReadyMarker = ".dawnshell-systemd-ready";
static const char *const kLockName = "debian-supervisor.lock";
static const char *const kStateName = "debian-supervisor.state";
static const char *const kLifecycleLogName = "debian-lifecycle.log";
static const char *const kHostRebootFifoName = "host-reboot.fifo";
static const char *const kSystemdCgroupMountName = "systemd-cgroup";
static const char *const kDevicesCgroupMountName = "devices-cgroup";
static const char *const kUnifiedCgroupMountName = "unified-cgroup";
static const char *const kCgroupChildName = "dawnshell";
static const char *const kCgroupPayloadName = "payload";
static const char *const kCgroupCommandName = "dawnshell-command";
static const char *const kCgroupProbeName = ".device-probe";
static const int kStartTimeoutMs = 20000;
static const int kStartGraceMs = 3000;
static const int kStopTimeoutMs = 30000;
static const int kTailscaleBypassRulePriority = 5200;
static const int kExclusiveUsbScanIntervalMs = 2000;
static const int kExclusiveUsbRetryIntervalMs = 30000;

#define MAX_USB_DEVICE_FILTERS 32
#define MAX_USB_INTERFACE_RECORDS 64
#define MAX_USB_SYSFS_NAME 128

static volatile sig_atomic_t alarm_child_pid = -1;
static volatile sig_atomic_t stop_requested = 0;
static int failure_report_fd = -1;

typedef enum CgroupMode {
    CGROUP_MODE_UNKNOWN = 0,
    CGROUP_MODE_V1,
    CGROUP_MODE_V2,
} CgroupMode;

typedef enum CgroupPolicy {
    CGROUP_POLICY_AUTO = 0,
    CGROUP_POLICY_FORCE_V2,
    CGROUP_POLICY_FORCE_V1,
} CgroupPolicy;

typedef enum HostUsbPolicy {
    HOST_USB_OFF = 0,
    HOST_USB_DIRECT,
    HOST_USB_EXCLUSIVE,
} HostUsbPolicy;

typedef struct UsbDeviceId {
    unsigned int vendor;
    unsigned int product;
} UsbDeviceId;

typedef struct UsbDeviceFilter {
    UsbDeviceId entries[MAX_USB_DEVICE_FILTERS];
    size_t count;
} UsbDeviceFilter;

typedef struct UsbInterfaceRecord {
    char interface_name[MAX_USB_SYSFS_NAME];
    char driver_name[MAX_USB_SYSFS_NAME];
    bool detached;
    int last_errno;
    int64_t retry_after_ms;
} UsbInterfaceRecord;

typedef struct ExclusiveUsbState {
    UsbInterfaceRecord records[MAX_USB_INTERFACE_RECORDS];
    size_t count;
    int last_scan_errno;
} ExclusiveUsbState;

typedef struct LauncherState {
    char state[24];
    char cgroup_mode[8];
    char host_usb_mode[16];
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

static const char *host_usb_policy_name(HostUsbPolicy policy) {
    if (policy == HOST_USB_DIRECT) return "direct";
    if (policy == HOST_USB_EXCLUSIVE) return "exclusive";
    return "off";
}

static int parse_host_usb_policy(const char *value, HostUsbPolicy *policy) {
    if (value == NULL || strcmp(value, "off") == 0
            || strcmp(value, "blocked") == 0) {
        *policy = HOST_USB_OFF;
        return 0;
    }
    if (strcmp(value, "direct") == 0 || strcmp(value, "shared") == 0) {
        *policy = HOST_USB_DIRECT;
        return 0;
    }
    if (strcmp(value, "exclusive") == 0) {
        *policy = HOST_USB_EXCLUSIVE;
        return 0;
    }
    return -1;
}

static int hex_digit_value(char value) {
    if (value >= '0' && value <= '9') return value - '0';
    if (value >= 'a' && value <= 'f') return value - 'a' + 10;
    if (value >= 'A' && value <= 'F') return value - 'A' + 10;
    return -1;
}

static int parse_usb_hex_word(const char *value, unsigned int *output) {
    unsigned int result = 0;
    for (size_t index = 0; index < 4; index++) {
        int digit = hex_digit_value(value[index]);
        if (digit < 0) return -1;
        result = (result << 4) | (unsigned int) digit;
    }
    *output = result;
    return 0;
}

static int parse_usb_device_filter(const char *value, UsbDeviceFilter *filter) {
    memset(filter, 0, sizeof(*filter));
    if (value == NULL || value[0] == '\0' || strcmp(value, "-") == 0) return 0;

    size_t length = strlen(value);
    if (length > 512) return -1;
    size_t offset = 0;
    while (offset < length) {
        if (filter->count >= MAX_USB_DEVICE_FILTERS
                || length - offset < 9 || value[offset + 4] != ':') {
            return -1;
        }
        if (length - offset > 9 && value[offset + 9] != ',') return -1;

        UsbDeviceId candidate;
        if (parse_usb_hex_word(value + offset, &candidate.vendor) != 0
                || parse_usb_hex_word(value + offset + 5,
                                      &candidate.product) != 0) {
            return -1;
        }
        bool duplicate = false;
        for (size_t index = 0; index < filter->count; index++) {
            if (filter->entries[index].vendor == candidate.vendor
                    && filter->entries[index].product == candidate.product) {
                duplicate = true;
                break;
            }
        }
        if (!duplicate) filter->entries[filter->count++] = candidate;

        offset += 9;
        if (offset == length) break;
        offset++;
        if (offset == length) return -1;
    }
    return 0;
}

static const char *cgroup_mode_name(CgroupMode mode) {
    if (mode == CGROUP_MODE_V2) return "v2";
    if (mode == CGROUP_MODE_V1) return "v1";
    return "unknown";
}

static CgroupMode parse_cgroup_mode(const char *value) {
    if (value != NULL && strcmp(value, "v2") == 0) return CGROUP_MODE_V2;
    if (value != NULL && strcmp(value, "v1") == 0) return CGROUP_MODE_V1;
    return CGROUP_MODE_UNKNOWN;
}

static int parse_cgroup_policy(const char *value, CgroupPolicy *policy) {
    if (value == NULL || strcmp(value, "auto") == 0) {
        *policy = CGROUP_POLICY_AUTO;
        return 0;
    }
    if (strcmp(value, "v2") == 0) {
        *policy = CGROUP_POLICY_FORCE_V2;
        return 0;
    }
    if (strcmp(value, "v1") == 0) {
        *policy = CGROUP_POLICY_FORCE_V1;
        return 0;
    }
    return -1;
}

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

    if (joined_path(path, sizeof(path), root, ".dawnshell-rootfs") != 0
            || !is_safe_root_marker(path)
            || !file_has_exact_line(path, "suite=trixie")
            || !file_has_exact_line(path, kArchitectureMarker)) {
        return fail_message("rootfs_marker",
                            "missing_or_unsafe_Trixie_architecture_marker", 26);
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
                || !file_has_exact_line(path, kArchitectureMarker)
                || !file_has_exact_line(path, "ssh_service=ssh.service")
                || !file_has_exact_line(path,
                                        "boot_proof_service=dawnshell-boot-proof.service")
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
    snprintf(state->cgroup_mode, sizeof(state->cgroup_mode), "unknown");
    snprintf(state->host_usb_mode, sizeof(state->host_usb_mode), "unknown");
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
                     "format=6\nstate=%s\ncgroup_mode=%s\nhost_usb_mode=%s\n"
                     "supervisor_pid=%d\n"
                     "supervisor_start_ticks=%llu\nsupervisor_exe_dev=%llu\n"
                     "supervisor_exe_ino=%llu\ninit_host_pid=%d\n"
                     "init_start_ticks=%llu\ninit_exe_dev=%llu\n"
                     "init_exe_ino=%llu\ninit_pid_ns_ino=%llu\n"
                     "init_mnt_ns_ino=%llu\ninit_uts_ns_ino=%llu\n"
                     "init_ipc_ns_ino=%llu\ninit_cgroup_ns_ino=%llu\n"
                     "init_net_ns_ino=%llu\n"
                     "wait_status=%d\nupdated_epoch=%lld\n",
                     state->state, state->cgroup_mode, state->host_usb_mode,
                     state->supervisor_pid,
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
        } else if (strcmp(line, "cgroup_mode") == 0) {
            snprintf(state->cgroup_mode, sizeof(state->cgroup_mode), "%s", value);
        } else if (strcmp(line, "host_usb_mode") == 0) {
            snprintf(state->host_usb_mode, sizeof(state->host_usb_mode), "%s", value);
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

static int ensure_directory_path(const char *path, mode_t mode,
                                 const char *stage);

static int bind_android_runtime_tree(const char *root, const char *source,
                                     const char *relative, bool required) {
    struct stat source_stat;
    if (lstat(source, &source_stat) != 0) {
        if (!required && errno == ENOENT) return 0;
        return fail_errno("android_runtime_source", 45);
    }
    if (!S_ISDIR(source_stat.st_mode)) {
        if (!required) return 0;
        return fail_message("android_runtime_source",
                            "required_source_is_not_a_directory", 45);
    }
    char target[PATH_MAX];
    if (joined_path(target, sizeof(target), root, relative) != 0) {
        return fail_errno("android_runtime_target_path", 45);
    }
    int result = ensure_directory_path(target, 0755,
                                       "android_runtime_target_directory");
    if (result != 0) return result;
    result = bind_recursively(source, target, "android_runtime_rbind",
                              "android_runtime_make_rslave");
    if (result != 0) return result;
    /* Keep execution enabled for Android's linker and APEX libraries while
       denying writes, devices and set-id transitions inside the chroot. */
    if (mount(NULL, target, NULL,
              MS_BIND | MS_REMOUNT | MS_RDONLY | MS_NOSUID | MS_NODEV,
              NULL) != 0) {
        return fail_errno("android_runtime_read_only", 45);
    }
    dprintf(STDERR_FILENO,
            "[%lld] BFU_DEBIAN_STAGE android_runtime_read_only source=%s target=/%s\n",
            (long long) realtime_seconds(), source, relative);
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

static int delegated_cgroup_paths(const char *control_dir, const char *mount_name,
                                  char *mount_path, size_t mount_size,
                                  char *child_path, size_t child_size) {
    if (joined_path(mount_path, mount_size, control_dir, mount_name) != 0) {
        return -1;
    }
    if (joined_path(child_path, child_size, mount_path, kCgroupChildName) != 0) {
        return -1;
    }
    return 0;
}

static int unified_cgroup_paths(const char *control_dir,
                                char *mount_path, size_t mount_size,
                                char *child_path, size_t child_size,
                                char *payload_path, size_t payload_size) {
    if (delegated_cgroup_paths(control_dir, kUnifiedCgroupMountName,
                               mount_path, mount_size,
                               child_path, child_size) != 0) {
        return -1;
    }
    if (joined_path(payload_path, payload_size, child_path,
                    kCgroupPayloadName) != 0) {
        return -1;
    }
    return 0;
}

static int write_cgroup_value(const char *path, const char *value) {
    int fd = open(path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return -1;
    int result = write_all(fd, value, strlen(value));
    int saved_errno = errno;
    close(fd);
    errno = saved_errno;
    return result;
}

static int enable_available_v2_controllers(const char *child_path) {
    char controllers_path[PATH_MAX];
    char subtree_path[PATH_MAX];
    char contents[4096];
    if (joined_path(controllers_path, sizeof(controllers_path), child_path,
                    "cgroup.controllers") != 0
            || joined_path(subtree_path, sizeof(subtree_path), child_path,
                           "cgroup.subtree_control") != 0) {
        return fail_errno("cgroup_v2_controller_path", 113);
    }
    int fd = open(controllers_path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return fail_errno("cgroup_v2_controllers_open", 113);
    ssize_t count = read(fd, contents, sizeof(contents) - 1);
    int saved_errno = errno;
    close(fd);
    if (count < 0) {
        errno = saved_errno;
        return fail_errno("cgroup_v2_controllers_read", 113);
    }
    contents[count] = '\0';

    int enabled = 0;
    char *save = NULL;
    for (char *name = strtok_r(contents, " \t\r\n", &save);
         name != NULL; name = strtok_r(NULL, " \t\r\n", &save)) {
        char operation[96];
        int operation_length = snprintf(operation, sizeof(operation), "+%s\n", name);
        if (operation_length <= 0 || (size_t) operation_length >= sizeof(operation)) {
            continue;
        }
        if (write_cgroup_value(subtree_path, operation) == 0) {
            enabled++;
        } else {
            dprintf(STDERR_FILENO,
                    "[%lld] BFU_DEBIAN_WARNING cgroup_v2_controller_enable_failed "
                    "controller=%s errno=%d\n",
                    (long long) realtime_seconds(), name, errno);
        }
    }
    dprintf(STDERR_FILENO,
            "[%lld] BFU_DEBIAN_STAGE cgroup_v2_controllers_processed enabled=%d\n",
            (long long) realtime_seconds(), enabled);
    return 0;
}

static int probe_cgroup_device_bpf(const char *child_path) {
#ifdef __NR_bpf
    char probe_path[PATH_MAX];
    if (joined_path(probe_path, sizeof(probe_path), child_path,
                    kCgroupProbeName) != 0) {
        return fail_errno("cgroup_v2_device_probe_path", 114);
    }
    if (mkdir(probe_path, 0755) != 0) {
        return fail_errno("cgroup_v2_device_probe_mkdir", 114);
    }

    struct bpf_insn instructions[2];
    memset(instructions, 0, sizeof(instructions));
    instructions[0].code = BPF_ALU64 | BPF_MOV | BPF_K;
    instructions[0].dst_reg = BPF_REG_0;
    instructions[0].imm = 1;
    instructions[1].code = BPF_JMP | BPF_EXIT;
    const char license[] = "GPL";
    union bpf_attr attributes;
    memset(&attributes, 0, sizeof(attributes));
    attributes.prog_type = BPF_PROG_TYPE_CGROUP_DEVICE;
    attributes.insn_cnt = 2;
    attributes.insns = (uint64_t) (uintptr_t) instructions;
    attributes.license = (uint64_t) (uintptr_t) license;
    int program_fd = (int) syscall(__NR_bpf, BPF_PROG_LOAD,
                                   &attributes, sizeof(attributes));
    if (program_fd < 0) {
        int probe_errno = errno;
        (void) rmdir(probe_path);
        errno = probe_errno;
        return fail_errno("cgroup_v2_device_bpf_load", 114);
    }

    int cgroup_fd = open(probe_path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (cgroup_fd < 0) {
        int probe_errno = errno;
        close(program_fd);
        (void) rmdir(probe_path);
        errno = probe_errno;
        return fail_errno("cgroup_v2_device_probe_open", 114);
    }
    memset(&attributes, 0, sizeof(attributes));
    attributes.target_fd = (uint32_t) cgroup_fd;
    attributes.attach_bpf_fd = (uint32_t) program_fd;
    attributes.attach_type = BPF_CGROUP_DEVICE;
    attributes.attach_flags = BPF_F_ALLOW_MULTI;
    int result = (int) syscall(__NR_bpf, BPF_PROG_ATTACH,
                               &attributes, sizeof(attributes));
    if (result != 0) {
        int probe_errno = errno;
        close(cgroup_fd);
        close(program_fd);
        (void) rmdir(probe_path);
        errno = probe_errno;
        return fail_errno("cgroup_v2_device_bpf_attach", 114);
    }

    memset(&attributes, 0, sizeof(attributes));
    attributes.target_fd = (uint32_t) cgroup_fd;
    attributes.attach_type = BPF_CGROUP_DEVICE;
    if (syscall(__NR_bpf, BPF_PROG_DETACH,
                &attributes, sizeof(attributes)) != 0) {
        dprintf(STDERR_FILENO,
                "[%lld] BFU_DEBIAN_WARNING cgroup_v2_device_bpf_detach_failed "
                "errno=%d\n", (long long) realtime_seconds(), errno);
    }
    close(cgroup_fd);
    close(program_fd);
    if (rmdir(probe_path) != 0) {
        return fail_errno("cgroup_v2_device_probe_rmdir", 114);
    }
    dprintf(STDERR_FILENO,
            "[%lld] BFU_DEBIAN_STAGE cgroup_v2_device_bpf_verified "
            "attach_mode=allow_multi\n",
            (long long) realtime_seconds());
    return 0;
#else
    (void) child_path;
    return fail_message("cgroup_v2_device_bpf_syscall",
                        "bpf_syscall_unavailable", 114);
#endif
}

static int apply_host_usb_v2_policy(const char *payload_path,
                                    HostUsbPolicy host_usb_policy) {
    if (host_usb_policy != HOST_USB_OFF) {
        dprintf(STDERR_FILENO,
                "[%lld] BFU_DEBIAN_USB policy=%s cgroup_backend=v2 "
                "usbfs_major=189 action=allow_parent_policy\n",
                (long long) realtime_seconds(),
                host_usb_policy_name(host_usb_policy));
        return 0;
    }
#ifdef __NR_bpf
    struct bpf_insn instructions[5];
    memset(instructions, 0, sizeof(instructions));
    instructions[0].code = BPF_LDX | BPF_W | BPF_MEM;
    instructions[0].dst_reg = BPF_REG_2;
    instructions[0].src_reg = BPF_REG_1;
    instructions[0].off = (int16_t) offsetof(struct bpf_cgroup_dev_ctx, major);
    instructions[1].code = BPF_ALU64 | BPF_MOV | BPF_K;
    instructions[1].dst_reg = BPF_REG_0;
    instructions[1].imm = 1;
    instructions[2].code = BPF_JMP | BPF_JNE | BPF_K;
    instructions[2].dst_reg = BPF_REG_2;
    instructions[2].off = 1;
    instructions[2].imm = 189;
    instructions[3].code = BPF_ALU64 | BPF_MOV | BPF_K;
    instructions[3].dst_reg = BPF_REG_0;
    instructions[3].imm = 0;
    instructions[4].code = BPF_JMP | BPF_EXIT;

    const char license[] = "GPL";
    union bpf_attr attributes;
    memset(&attributes, 0, sizeof(attributes));
    attributes.prog_type = BPF_PROG_TYPE_CGROUP_DEVICE;
    attributes.insn_cnt = 5;
    attributes.insns = (uint64_t) (uintptr_t) instructions;
    attributes.license = (uint64_t) (uintptr_t) license;
    int program_fd = (int) syscall(__NR_bpf, BPF_PROG_LOAD,
                                   &attributes, sizeof(attributes));
    if (program_fd < 0) {
        return fail_errno("host_usb_v2_bpf_load", 118);
    }
    int cgroup_fd = open(payload_path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (cgroup_fd < 0) {
        int saved_errno = errno;
        close(program_fd);
        errno = saved_errno;
        return fail_errno("host_usb_v2_cgroup_open", 118);
    }
    memset(&attributes, 0, sizeof(attributes));
    attributes.target_fd = (uint32_t) cgroup_fd;
    attributes.attach_bpf_fd = (uint32_t) program_fd;
    attributes.attach_type = BPF_CGROUP_DEVICE;
    attributes.attach_flags = BPF_F_ALLOW_MULTI;
    int result = (int) syscall(__NR_bpf, BPF_PROG_ATTACH,
                               &attributes, sizeof(attributes));
    int saved_errno = errno;
    close(cgroup_fd);
    close(program_fd);
    if (result != 0) {
        errno = saved_errno;
        return fail_errno("host_usb_v2_bpf_attach", 118);
    }
    dprintf(STDERR_FILENO,
            "[%lld] BFU_DEBIAN_USB policy=off cgroup_backend=v2_bpf "
            "usbfs_major=189 action=deny_rwm delegated_subtree_only=true "
            "attach_mode=allow_multi\n",
            (long long) realtime_seconds());
    return 0;
#else
    (void) payload_path;
    return fail_message("host_usb_v2_bpf_syscall",
                        "bpf_syscall_unavailable", 118);
#endif
}

static int prepare_unified_cgroup_mount(const char *control_dir,
                                        HostUsbPolicy host_usb_policy) {
    char mount_path[PATH_MAX];
    char child_path[PATH_MAX];
    char payload_path[PATH_MAX];
    if (unified_cgroup_paths(control_dir,
                             mount_path, sizeof(mount_path),
                             child_path, sizeof(child_path),
                             payload_path, sizeof(payload_path)) != 0) {
        return fail_errno("cgroup_v2_path", 110);
    }
    int result = ensure_directory_path(mount_path, 0700,
                                       "cgroup_v2_mount_dir");
    if (result != 0) return result;
    if (mount("dawnshell-unified", mount_path, "cgroup2",
              MS_NOSUID | MS_NODEV | MS_NOEXEC, NULL) != 0) {
        return fail_errno("cgroup_v2_mount", 111);
    }
    result = ensure_directory_path(child_path, 0755, "cgroup_v2_child_dir");
    if (result != 0) return result;
    result = enable_available_v2_controllers(child_path);
    if (result != 0) return result;
    result = probe_cgroup_device_bpf(child_path);
    if (result != 0) return result;
    result = ensure_directory_path(payload_path, 0755,
                                   "cgroup_v2_payload_dir");
    if (result != 0) return result;
    result = apply_host_usb_v2_policy(payload_path, host_usb_policy);
    if (result != 0) return result;
    dprintf(STDERR_FILENO,
            "[%lld] BFU_DEBIAN_STAGE cgroup_v2_delegated mount=%s "
            "child=%s payload=%s global_root_hidden=true\n",
            (long long) realtime_seconds(), mount_path, child_path, payload_path);
    return 0;
}

static int prepare_systemd_cgroup_mount(const char *control_dir) {
    char mount_path[PATH_MAX];
    char child_path[PATH_MAX];
    if (delegated_cgroup_paths(control_dir, kSystemdCgroupMountName,
                               mount_path, sizeof(mount_path),
                               child_path, sizeof(child_path)) != 0) {
        return fail_errno("cgroup_path", 45);
    }
    int result = ensure_directory_path(mount_path, 0700, "cgroup_mount_dir");
    if (result != 0) return result;
    if (mount("dawnshell", mount_path, "cgroup",
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

static int prepare_devices_cgroup_mount(const char *control_dir,
                                        HostUsbPolicy host_usb_policy) {
    char mount_path[PATH_MAX];
    char child_path[PATH_MAX];
    char interface_path[PATH_MAX];
    if (delegated_cgroup_paths(control_dir, kDevicesCgroupMountName,
                               mount_path, sizeof(mount_path),
                               child_path, sizeof(child_path)) != 0) {
        return fail_errno("devices_cgroup_path", 90);
    }
    int result = ensure_directory_path(mount_path, 0700,
                                       "devices_cgroup_mount_dir");
    if (result != 0) return result;
    /* Controller attachment is global in cgroup v1, but mount visibility is
       confined to this already-private mount namespace. Android tasks remain
       at the hierarchy root with the kernel's default allow-all policy. */
    if (mount("dawnshell-devices", mount_path, "cgroup",
              MS_NOSUID | MS_NODEV | MS_NOEXEC, "devices") != 0) {
        return fail_errno("cgroup_v1_devices_mount", 91);
    }
    result = ensure_directory_path(child_path, 0755,
                                   "devices_cgroup_child_dir");
    if (result != 0) return result;
    if (joined_path(interface_path, sizeof(interface_path), child_path,
                    "devices.list") != 0) {
        return fail_errno("devices_cgroup_interface_path", 92);
    }
    int interface_fd = open(interface_path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (interface_fd < 0) return fail_errno("devices_cgroup_interface", 93);
    close(interface_fd);
    if (host_usb_policy == HOST_USB_OFF) {
        if (joined_path(interface_path, sizeof(interface_path), child_path,
                        "devices.deny") != 0) {
            return fail_errno("host_usb_v1_deny_path", 118);
        }
        if (write_cgroup_value(interface_path, "c 189:* rwm\n") != 0) {
            return fail_errno("host_usb_v1_deny", 118);
        }
        dprintf(STDERR_FILENO,
                "[%lld] BFU_DEBIAN_USB policy=off cgroup_backend=v1 "
                "usbfs_major=189 action=deny_rwm delegated_subtree_only=true\n",
                (long long) realtime_seconds());
    } else {
        dprintf(STDERR_FILENO,
                "[%lld] BFU_DEBIAN_USB policy=%s cgroup_backend=v1 "
                "usbfs_major=189 action=allow_parent_policy\n",
                (long long) realtime_seconds(),
                host_usb_policy_name(host_usb_policy));
    }
    if (joined_path(interface_path, sizeof(interface_path), child_path,
                    "devices.list") != 0) {
        return fail_errno("devices_cgroup_interface_path", 92);
    }
    log_file_snapshot("delegated_devices_list", interface_path);
    dprintf(STDERR_FILENO,
            "[%lld] BFU_DEBIAN_STAGE cgroup_v1_devices_mounted "
            "mount=%s child=%s android_root_policy_unchanged=true\n",
            (long long) realtime_seconds(), mount_path, child_path);
    return 0;
}

static int move_self_to_cgroup(const char *child_path, const char *open_stage,
                               const char *move_stage, int failure_code) {
    char procs_path[PATH_MAX];
    if (joined_path(procs_path, sizeof(procs_path), child_path,
                    "cgroup.procs") != 0) {
        return fail_errno(open_stage, failure_code);
    }
    int fd = open(procs_path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return fail_errno(open_stage, failure_code);
    char pid_text[32];
    int count = snprintf(pid_text, sizeof(pid_text), "%d\n", getpid());
    int result = count > 0 && (size_t) count < sizeof(pid_text)
            ? write_all(fd, pid_text, (size_t) count) : -1;
    int saved_errno = errno;
    close(fd);
    if (result != 0) {
        errno = saved_errno;
        return fail_errno(move_stage, failure_code);
    }
    return 0;
}

static int move_self_to_delegated_subtrees(const char *control_dir,
                                           char *systemd_child,
                                           size_t systemd_child_size,
                                           char *devices_child,
                                           size_t devices_child_size) {
    char systemd_mount[PATH_MAX];
    char devices_mount[PATH_MAX];
    if (delegated_cgroup_paths(control_dir, kSystemdCgroupMountName,
                               systemd_mount, sizeof(systemd_mount),
                               systemd_child, systemd_child_size) != 0
            || delegated_cgroup_paths(control_dir, kDevicesCgroupMountName,
                                      devices_mount, sizeof(devices_mount),
                                      devices_child, devices_child_size) != 0) {
        return fail_errno("cgroup_procs_path", 47);
    }
    int result = move_self_to_cgroup(systemd_child, "cgroup_procs_open",
                                     "cgroup_move_pid1", 49);
    if (result != 0) return result;
    result = move_self_to_cgroup(devices_child, "devices_cgroup_procs_open",
                                 "devices_cgroup_move_pid1", 94);
    if (result != 0) return result;
    return 0;
}

static int move_self_to_delegated_mode(const char *control_dir,
                                       CgroupMode mode) {
    if (mode == CGROUP_MODE_V2) {
        char mount_path[PATH_MAX];
        char child_path[PATH_MAX];
        char payload_path[PATH_MAX];
        if (unified_cgroup_paths(control_dir,
                                 mount_path, sizeof(mount_path),
                                 child_path, sizeof(child_path),
                                 payload_path, sizeof(payload_path)) != 0) {
            return fail_errno("cgroup_v2_procs_path", 115);
        }
        int result = move_self_to_cgroup(payload_path,
                                         "cgroup_v2_procs_open",
                                         "cgroup_v2_move_pid1", 115);
        if (result != 0) return result;
        dprintf(STDERR_FILENO,
                "[%lld] BFU_DEBIAN_STAGE init_moved_to_cgroup_v2_payload "
                "path=%s\n",
                (long long) realtime_seconds(), payload_path);
        return 0;
    }
    if (mode != CGROUP_MODE_V1) {
        return fail_message("cgroup_mode", "unknown_cgroup_mode", 115);
    }
    char systemd_child[PATH_MAX];
    char devices_child[PATH_MAX];
    int result = move_self_to_delegated_subtrees(
            control_dir, systemd_child, sizeof(systemd_child),
            devices_child, sizeof(devices_child));
    if (result != 0) return result;
    dprintf(STDERR_FILENO,
            "[%lld] BFU_DEBIAN_STAGE init_moved_to_systemd_cgroup path=%s\n",
            (long long) realtime_seconds(), systemd_child);
    dprintf(STDERR_FILENO,
            "[%lld] BFU_DEBIAN_STAGE init_moved_to_devices_cgroup path=%s\n",
            (long long) realtime_seconds(), devices_child);
    return 0;
}

/* Once systemd has enabled controllers below payload, cgroup v2's
   no-internal-process rule rejects later management processes with EBUSY.
   Health and shutdown commands therefore enter a dedicated leaf below the
   delegated payload. It inherits the payload's device BPF policy and remains
   outside systemd-owned unit cgroups. */
static int move_self_to_delegated_command(const char *control_dir,
                                          CgroupMode mode) {
    if (mode != CGROUP_MODE_V2) {
        return move_self_to_delegated_mode(control_dir, mode);
    }
    char mount_path[PATH_MAX];
    char child_path[PATH_MAX];
    char payload_path[PATH_MAX];
    char command_path[PATH_MAX];
    if (unified_cgroup_paths(control_dir,
                             mount_path, sizeof(mount_path),
                             child_path, sizeof(child_path),
                             payload_path, sizeof(payload_path)) != 0
            || joined_path(command_path, sizeof(command_path), payload_path,
                           kCgroupCommandName) != 0) {
        return fail_errno("cgroup_v2_command_path", 115);
    }
    int result = ensure_directory_path(command_path, 0755,
                                       "cgroup_v2_command_dir");
    if (result != 0) return result;
    result = move_self_to_cgroup(command_path,
                                 "cgroup_v2_command_procs_open",
                                 "cgroup_v2_move_command", 115);
    if (result != 0) return result;
    dprintf(STDERR_FILENO,
            "[%lld] BFU_DEBIAN_STAGE command_moved_to_cgroup_v2_leaf "
            "path=%s\n",
            (long long) realtime_seconds(), command_path);
    return 0;
}

static int move_self_to_delegated_cgroups(const char *control_dir,
                                          CgroupMode mode) {
    int result = move_self_to_delegated_mode(control_dir, mode);
    if (result != 0) return result;
    if (unshare(CLONE_NEWCGROUP) != 0) {
        return fail_errno("unshare_cgroup", 50);
    }
    dprintf(STDERR_FILENO,
            "[%lld] BFU_DEBIAN_STAGE cgroup_namespace_private mode=%s\n",
            (long long) realtime_seconds(), cgroup_mode_name(mode));
    return 0;
}

static int bind_delegated_cgroup_view(const char *control_dir,
                                      const char *mount_name,
                                      const char *cgroup_root,
                                      const char *view_name,
                                      const char *directory_stage,
                                      const char *bind_stage,
                                      int failure_code) {
    char mount_path[PATH_MAX];
    char source[PATH_MAX];
    char target[PATH_MAX];
    if (delegated_cgroup_paths(control_dir, mount_name,
                               mount_path, sizeof(mount_path),
                               source, sizeof(source)) != 0
            || joined_path(target, sizeof(target), cgroup_root, view_name) != 0) {
        return fail_errno("cgroup_view_path", failure_code);
    }
    int result = ensure_directory_path(target, 0755, directory_stage);
    if (result != 0) return result;
    /* Bind the delegated child itself, never the hierarchy root containing
       Android tasks. Docker may create descendants but cannot walk upward. */
    if (mount(source, target, NULL, MS_BIND | MS_REC, NULL) != 0) {
        return fail_errno(bind_stage, failure_code);
    }
    return 0;
}

static int mount_delegated_cgroup_views(const char *root,
                                        const char *control_dir,
                                        CgroupMode mode) {
    char cgroup_root[PATH_MAX];
    if (joined_path(cgroup_root, sizeof(cgroup_root), root,
                    "sys/fs/cgroup") != 0) {
        return fail_errno("cgroup_view_path", 51);
    }
    if (mode == CGROUP_MODE_V2) {
        char mount_path[PATH_MAX];
        char child_path[PATH_MAX];
        char payload_path[PATH_MAX];
        if (unified_cgroup_paths(control_dir,
                                 mount_path, sizeof(mount_path),
                                 child_path, sizeof(child_path),
                                 payload_path, sizeof(payload_path)) != 0) {
            return fail_errno("cgroup_v2_view_path", 116);
        }
        /* Expose only the delegated payload as the cgroup namespace root. */
        if (mount(payload_path, cgroup_root, NULL,
                  MS_BIND | MS_REC, NULL) != 0) {
            return fail_errno("cgroup_v2_view_bind", 116);
        }
        return 0;
    }
    if (mode != CGROUP_MODE_V1) {
        return fail_message("cgroup_view_mode", "unknown_cgroup_mode", 116);
    }
    if (mount("tmpfs", cgroup_root, "tmpfs",
              MS_NOSUID | MS_NODEV | MS_NOEXEC, "mode=0755,size=1m") != 0) {
        return fail_errno("cgroup_view_tmpfs", 52);
    }
    int result = bind_delegated_cgroup_view(
            control_dir, kSystemdCgroupMountName, cgroup_root, "systemd",
            "cgroup_view_systemd_dir", "cgroup_view_systemd_bind", 53);
    if (result != 0) return result;
    result = bind_delegated_cgroup_view(
            control_dir, kDevicesCgroupMountName, cgroup_root, "devices",
            "cgroup_view_devices_dir", "cgroup_view_devices_bind", 95);
    if (result != 0) return result;
    return 0;
}

static int remove_cgroup_descendants(const char *path, int depth) {
    if (depth > 64) {
        errno = ELOOP;
        return -1;
    }
    DIR *directory = opendir(path);
    if (directory == NULL) return errno == ENOENT ? 0 : -1;
    int result = 0;
    struct dirent *entry;
    while ((entry = readdir(directory)) != NULL) {
        if (strcmp(entry->d_name, ".") == 0
                || strcmp(entry->d_name, "..") == 0) {
            continue;
        }
        char child[PATH_MAX];
        if (joined_path(child, sizeof(child), path, entry->d_name) != 0) {
            result = -1;
            errno = ENAMETOOLONG;
            break;
        }
        struct stat value;
        if (lstat(child, &value) != 0) {
            if (errno == ENOENT) continue;
            result = -1;
            break;
        }
        if (!S_ISDIR(value.st_mode)) continue;
        if (remove_cgroup_descendants(child, depth + 1) != 0
                || (rmdir(child) != 0 && errno != ENOENT)) {
            result = -1;
            break;
        }
    }
    int saved_errno = errno;
    closedir(directory);
    errno = saved_errno;
    return result;
}

static void detach_mount_for_cleanup(const char *path, const char *label) {
    if (umount2(path, MNT_DETACH) == 0) {
        dprintf(STDERR_FILENO,
                "[%lld] BFU_DEBIAN_CLEANUP mount_detached label=%s path=%s\n",
                (long long) realtime_seconds(), label, path);
        return;
    }
    if (errno != EINVAL && errno != ENOENT) {
        dprintf(STDERR_FILENO,
                "[%lld] BFU_DEBIAN_WARNING cleanup_mount_failed "
                "label=%s path=%s errno=%d\n",
                (long long) realtime_seconds(), label, path, errno);
    }
}

static void cleanup_cgroup_hierarchy(const char *control_dir,
                                     const char *mount_name,
                                     const char *label) {
    char mount_path[PATH_MAX];
    char child_path[PATH_MAX];
    if (delegated_cgroup_paths(control_dir, mount_name,
                               mount_path, sizeof(mount_path),
                               child_path, sizeof(child_path)) != 0) {
        dprintf(STDERR_FILENO,
                "[%lld] BFU_DEBIAN_WARNING cleanup_cgroup_path_failed label=%s\n",
                (long long) realtime_seconds(), label);
        return;
    }

    bool child_removed = false;
    int cleanup_errno = 0;
    for (int attempt = 0; attempt < 20; attempt++) {
        int descendants = remove_cgroup_descendants(child_path, 0);
        if (descendants == 0) {
            if (rmdir(child_path) == 0 || errno == ENOENT) {
                child_removed = true;
                break;
            }
        }
        cleanup_errno = errno;
        if (errno != EBUSY && errno != ENOTEMPTY) break;
        usleep(100000);
    }
    if (child_removed) {
        dprintf(STDERR_FILENO,
                "[%lld] BFU_DEBIAN_CLEANUP cgroup_subtree_removed "
                "label=%s child=%s\n",
                (long long) realtime_seconds(), label, child_path);
    } else {
        dprintf(STDERR_FILENO,
                "[%lld] BFU_DEBIAN_WARNING cleanup_cgroup_subtree_failed "
                "label=%s child=%s errno=%d\n",
                (long long) realtime_seconds(), label, child_path,
                cleanup_errno);
    }
    detach_mount_for_cleanup(mount_path, label);
    if (rmdir(mount_path) != 0 && errno != ENOENT) {
        dprintf(STDERR_FILENO,
                "[%lld] BFU_DEBIAN_WARNING cleanup_cgroup_mount_dir_failed "
                "label=%s path=%s errno=%d\n",
                (long long) realtime_seconds(), label, mount_path, errno);
    }
}

static void cleanup_delegated_cgroups(const char *root,
                                      const char *control_dir) {
    char cgroup_root[PATH_MAX];
    char systemd_view[PATH_MAX];
    char devices_view[PATH_MAX];
    if (joined_path(cgroup_root, sizeof(cgroup_root), root,
                    "sys/fs/cgroup") == 0
            && joined_path(systemd_view, sizeof(systemd_view), cgroup_root,
                           "systemd") == 0
            && joined_path(devices_view, sizeof(devices_view), cgroup_root,
                           "devices") == 0) {
        detach_mount_for_cleanup(devices_view, "debian_devices_view");
        detach_mount_for_cleanup(systemd_view, "debian_systemd_view");
        detach_mount_for_cleanup(cgroup_root, "debian_cgroup_root");
    }
    cleanup_cgroup_hierarchy(control_dir, kUnifiedCgroupMountName, "unified");
    cleanup_cgroup_hierarchy(control_dir, kDevicesCgroupMountName, "devices");
    cleanup_cgroup_hierarchy(control_dir, kSystemdCgroupMountName, "systemd");
}

static int count_host_usb_nodes(const char *usb_path) {
    DIR *buses = opendir(usb_path);
    if (buses == NULL) return -1;
    int count = 0;
    struct dirent *bus_entry;
    while ((bus_entry = readdir(buses)) != NULL) {
        if (strcmp(bus_entry->d_name, ".") == 0
                || strcmp(bus_entry->d_name, "..") == 0) {
            continue;
        }
        char bus_path[PATH_MAX];
        if (joined_path(bus_path, sizeof(bus_path), usb_path,
                        bus_entry->d_name) != 0) {
            continue;
        }
        struct stat bus_stat;
        if (lstat(bus_path, &bus_stat) != 0 || !S_ISDIR(bus_stat.st_mode)) continue;
        DIR *devices = opendir(bus_path);
        if (devices == NULL) continue;
        struct dirent *device_entry;
        while ((device_entry = readdir(devices)) != NULL) {
            if (strcmp(device_entry->d_name, ".") == 0
                    || strcmp(device_entry->d_name, "..") == 0) {
                continue;
            }
            char device_path[PATH_MAX];
            if (joined_path(device_path, sizeof(device_path), bus_path,
                            device_entry->d_name) != 0) {
                continue;
            }
            struct stat device_stat;
            if (lstat(device_path, &device_stat) == 0
                    && S_ISCHR(device_stat.st_mode)) {
                count++;
            }
        }
        closedir(devices);
    }
    closedir(buses);
    return count;
}

static int configure_host_usb_mount(const char *root,
                                    HostUsbPolicy host_usb_policy) {
    char usb_path[PATH_MAX];
    if (joined_path(usb_path, sizeof(usb_path), root, "dev/bus/usb") != 0) {
        return fail_errno("host_usb_path", 119);
    }
    struct stat value;
    if (lstat(usb_path, &value) != 0) {
        if (errno != ENOENT) return fail_errno("host_usb_lstat", 119);
        dprintf(STDERR_FILENO,
                "[%lld] BFU_DEBIAN_USB policy=%s usbfs_present=false "
                "future_hotplug_cgroup_enforced=true\n",
                (long long) realtime_seconds(),
                host_usb_policy_name(host_usb_policy));
        return 0;
    }
    if (!S_ISDIR(value.st_mode)) {
        return fail_message("host_usb_path",
                            "dev_bus_usb_is_not_a_directory", 119);
    }
    if (host_usb_policy != HOST_USB_OFF) {
        int node_count = count_host_usb_nodes(usb_path);
        dprintf(STDERR_FILENO,
                "[%lld] BFU_DEBIAN_USB policy=%s usbfs_present=true "
                "hotplug=propagated node_count=%d path=/dev/bus/usb\n",
                (long long) realtime_seconds(),
                host_usb_policy_name(host_usb_policy), node_count);
        return 0;
    }
    if (mount("dawnshell-usb-blocked", usb_path, "tmpfs",
              MS_RDONLY | MS_NOSUID | MS_NODEV | MS_NOEXEC,
              "mode=000,size=4k") != 0) {
        return fail_errno("host_usb_block_mount", 119);
    }
    dprintf(STDERR_FILENO,
            "[%lld] BFU_DEBIAN_USB policy=off usbfs_hidden=true "
            "cgroup_major_189_denied=true path=/dev/bus/usb\n",
            (long long) realtime_seconds());
    return 0;
}

static bool is_safe_usb_sysfs_name(const char *value) {
    if (value == NULL || value[0] == '\0'
            || strlen(value) >= MAX_USB_SYSFS_NAME) {
        return false;
    }
    for (const char *cursor = value; *cursor != '\0'; cursor++) {
        char character = *cursor;
        bool safe = (character >= 'a' && character <= 'z')
                || (character >= 'A' && character <= 'Z')
                || (character >= '0' && character <= '9')
                || character == '-' || character == '_' || character == '.'
                || character == ':';
        if (!safe) return false;
    }
    return true;
}

static int read_usb_sysfs_hex(const char *path, unsigned int *output) {
    char contents[32];
    int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return -1;
    ssize_t count = read(fd, contents, sizeof(contents) - 1);
    int saved_errno = errno;
    close(fd);
    errno = saved_errno;
    if (count < 4 || (size_t) count >= sizeof(contents)) {
        errno = EINVAL;
        return -1;
    }
    contents[count] = '\0';
    if (parse_usb_hex_word(contents, output) != 0) {
        errno = EINVAL;
        return -1;
    }
    for (ssize_t index = 4; index < count; index++) {
        if (contents[index] != '\n' && contents[index] != '\r'
                && contents[index] != ' ' && contents[index] != '\t') {
            errno = EINVAL;
            return -1;
        }
    }
    return 0;
}

static int read_usb_device_id(const char *device_name,
                              unsigned int *vendor,
                              unsigned int *product) {
    if (!is_safe_usb_sysfs_name(device_name)) {
        errno = EINVAL;
        return -1;
    }
    char vendor_path[PATH_MAX];
    char product_path[PATH_MAX];
    int count = snprintf(vendor_path, sizeof(vendor_path),
                         "/sys/bus/usb/devices/%s/idVendor", device_name);
    if (count < 0 || (size_t) count >= sizeof(vendor_path)) {
        errno = ENAMETOOLONG;
        return -1;
    }
    count = snprintf(product_path, sizeof(product_path),
                     "/sys/bus/usb/devices/%s/idProduct", device_name);
    if (count < 0 || (size_t) count >= sizeof(product_path)) {
        errno = ENAMETOOLONG;
        return -1;
    }
    return read_usb_sysfs_hex(vendor_path, vendor) == 0
            && read_usb_sysfs_hex(product_path, product) == 0 ? 0 : -1;
}

static bool usb_filter_matches(const UsbDeviceFilter *filter,
                               unsigned int vendor,
                               unsigned int product) {
    for (size_t index = 0; index < filter->count; index++) {
        if (filter->entries[index].vendor == vendor
                && filter->entries[index].product == product) {
            return true;
        }
    }
    return false;
}

static int read_usb_interface_driver(const char *interface_name,
                                     char *driver_name,
                                     size_t driver_name_size) {
    if (!is_safe_usb_sysfs_name(interface_name) || driver_name_size < 2) {
        errno = EINVAL;
        return -1;
    }
    char path[PATH_MAX];
    int count = snprintf(path, sizeof(path),
                         "/sys/bus/usb/devices/%s/driver", interface_name);
    if (count < 0 || (size_t) count >= sizeof(path)) {
        errno = ENAMETOOLONG;
        return -1;
    }
    char target[PATH_MAX];
    ssize_t target_length = readlink(path, target, sizeof(target) - 1);
    if (target_length < 0) return -1;
    target[target_length] = '\0';
    const char *basename = strrchr(target, '/');
    basename = basename == NULL ? target : basename + 1;
    if (!is_safe_usb_sysfs_name(basename)
            || strlen(basename) >= driver_name_size) {
        errno = EINVAL;
        return -1;
    }
    snprintf(driver_name, driver_name_size, "%s", basename);
    return 0;
}

static int write_usb_driver_control(const char *driver_name,
                                    const char *control,
                                    const char *interface_name) {
    if (!is_safe_usb_sysfs_name(driver_name)
            || !is_safe_usb_sysfs_name(interface_name)
            || (strcmp(control, "bind") != 0
                && strcmp(control, "unbind") != 0)) {
        errno = EINVAL;
        return -1;
    }
    char path[PATH_MAX];
    int count = snprintf(path, sizeof(path),
                         "/sys/bus/usb/drivers/%s/%s",
                         driver_name, control);
    if (count < 0 || (size_t) count >= sizeof(path)) {
        errno = ENAMETOOLONG;
        return -1;
    }
    int fd = open(path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return -1;
    char request[MAX_USB_SYSFS_NAME + 2];
    count = snprintf(request, sizeof(request), "%s\n", interface_name);
    if (count < 0 || (size_t) count >= sizeof(request)) {
        close(fd);
        errno = ENAMETOOLONG;
        return -1;
    }
    int result = write_all(fd, request, (size_t) count);
    int saved_errno = errno;
    close(fd);
    errno = saved_errno;
    return result;
}

static ssize_t find_usb_interface_record(const ExclusiveUsbState *state,
                                         const char *interface_name) {
    for (size_t index = 0; index < state->count; index++) {
        if (strcmp(state->records[index].interface_name,
                   interface_name) == 0) {
            return (ssize_t) index;
        }
    }
    return -1;
}

static void remove_usb_interface_record(ExclusiveUsbState *state,
                                        size_t index) {
    if (index >= state->count) return;
    if (index + 1 < state->count) {
        memmove(&state->records[index], &state->records[index + 1],
                (state->count - index - 1) * sizeof(state->records[0]));
    }
    state->count--;
    memset(&state->records[state->count], 0, sizeof(state->records[0]));
}

static void prune_disconnected_usb_interfaces(ExclusiveUsbState *state) {
    size_t index = 0;
    while (index < state->count) {
        char path[PATH_MAX];
        int count = snprintf(path, sizeof(path),
                             "/sys/bus/usb/devices/%s",
                             state->records[index].interface_name);
        if (count < 0 || (size_t) count >= sizeof(path)) {
            remove_usb_interface_record(state, index);
            continue;
        }
        struct stat value;
        if (lstat(path, &value) != 0 && errno == ENOENT) {
            dprintf(STDERR_FILENO,
                    "[%lld] BFU_DEBIAN_USB action=exclusive_device_removed "
                    "interface=%s restore=not_required\n",
                    (long long) realtime_seconds(),
                    state->records[index].interface_name);
            remove_usb_interface_record(state, index);
            continue;
        }
        index++;
    }
}

static UsbInterfaceRecord *get_or_create_usb_interface_record(
        ExclusiveUsbState *state, const char *interface_name) {
    ssize_t existing = find_usb_interface_record(state, interface_name);
    if (existing >= 0) return &state->records[existing];
    if (state->count >= MAX_USB_INTERFACE_RECORDS) return NULL;
    UsbInterfaceRecord *record = &state->records[state->count++];
    memset(record, 0, sizeof(*record));
    snprintf(record->interface_name, sizeof(record->interface_name), "%s",
             interface_name);
    return record;
}

static void reconcile_exclusive_usb(const UsbDeviceFilter *filter,
                                    ExclusiveUsbState *state) {
    prune_disconnected_usb_interfaces(state);
    DIR *directory = opendir("/sys/bus/usb/devices");
    if (directory == NULL) {
        int scan_errno = errno;
        if (state->last_scan_errno != scan_errno) {
            dprintf(STDERR_FILENO,
                    "[%lld] BFU_DEBIAN_WARNING usb_exclusive_scan_failed "
                    "errno=%d\n",
                    (long long) realtime_seconds(), scan_errno);
        }
        state->last_scan_errno = scan_errno;
        return;
    }
    if (state->last_scan_errno != 0) {
        dprintf(STDERR_FILENO,
                "[%lld] BFU_DEBIAN_USB action=exclusive_scan_recovered\n",
                (long long) realtime_seconds());
    }
    state->last_scan_errno = 0;

    struct dirent *entry;
    while ((entry = readdir(directory)) != NULL) {
        const char *separator = strchr(entry->d_name, ':');
        if (separator == NULL || !is_safe_usb_sysfs_name(entry->d_name)) continue;
        size_t device_name_length = (size_t) (separator - entry->d_name);
        if (device_name_length == 0
                || device_name_length >= MAX_USB_SYSFS_NAME) {
            continue;
        }
        char device_name[MAX_USB_SYSFS_NAME];
        memcpy(device_name, entry->d_name, device_name_length);
        device_name[device_name_length] = '\0';

        unsigned int vendor;
        unsigned int product;
        if (read_usb_device_id(device_name, &vendor, &product) != 0
                || !usb_filter_matches(filter, vendor, product)) {
            continue;
        }

        char driver_name[MAX_USB_SYSFS_NAME];
        if (read_usb_interface_driver(entry->d_name, driver_name,
                                      sizeof(driver_name)) != 0) {
            continue;
        }
        UsbInterfaceRecord *record = get_or_create_usb_interface_record(
                state, entry->d_name);
        if (record == NULL) {
            dprintf(STDERR_FILENO,
                    "[%lld] BFU_DEBIAN_WARNING usb_exclusive_record_limit "
                    "interface=%s limit=%d action=left_bound\n",
                    (long long) realtime_seconds(), entry->d_name,
                    MAX_USB_INTERFACE_RECORDS);
            continue;
        }
        int64_t now = monotonic_millis();
        if (record->retry_after_ms > now) continue;
        snprintf(record->driver_name, sizeof(record->driver_name), "%s",
                 driver_name);
        if (write_usb_driver_control(driver_name, "unbind",
                                     entry->d_name) == 0) {
            record->detached = true;
            record->last_errno = 0;
            record->retry_after_ms = 0;
            dprintf(STDERR_FILENO,
                    "[%lld] BFU_DEBIAN_USB policy=exclusive action=unbind "
                    "vid_pid=%04x:%04x interface=%s driver=%s result=success\n",
                    (long long) realtime_seconds(), vendor, product,
                    entry->d_name, driver_name);
        } else {
            record->detached = false;
            record->last_errno = errno;
            record->retry_after_ms = now + kExclusiveUsbRetryIntervalMs;
            dprintf(STDERR_FILENO,
                    "[%lld] BFU_DEBIAN_WARNING usb_exclusive_unbind_failed "
                    "vid_pid=%04x:%04x interface=%s driver=%s errno=%d "
                    "retry_ms=%d\n",
                    (long long) realtime_seconds(), vendor, product,
                    entry->d_name, driver_name, record->last_errno,
                    kExclusiveUsbRetryIntervalMs);
        }
    }
    closedir(directory);
}

static void restore_exclusive_usb(ExclusiveUsbState *state) {
    for (size_t reverse = state->count; reverse > 0; reverse--) {
        UsbInterfaceRecord *record = &state->records[reverse - 1];
        if (!record->detached) continue;

        char interface_path[PATH_MAX];
        int count = snprintf(interface_path, sizeof(interface_path),
                             "/sys/bus/usb/devices/%s",
                             record->interface_name);
        struct stat value;
        if (count < 0 || (size_t) count >= sizeof(interface_path)
                || lstat(interface_path, &value) != 0) {
            dprintf(STDERR_FILENO,
                    "[%lld] BFU_DEBIAN_USB policy=exclusive action=restore "
                    "interface=%s driver=%s result=device_absent\n",
                    (long long) realtime_seconds(), record->interface_name,
                    record->driver_name);
            continue;
        }

        char current_driver[MAX_USB_SYSFS_NAME];
        if (read_usb_interface_driver(record->interface_name, current_driver,
                                      sizeof(current_driver)) == 0) {
            dprintf(STDERR_FILENO,
                    "[%lld] BFU_DEBIAN_USB policy=exclusive action=restore "
                    "interface=%s driver=%s result=already_bound "
                    "current_driver=%s\n",
                    (long long) realtime_seconds(), record->interface_name,
                    record->driver_name, current_driver);
            continue;
        }
        if (write_usb_driver_control(record->driver_name, "bind",
                                     record->interface_name) == 0) {
            dprintf(STDERR_FILENO,
                    "[%lld] BFU_DEBIAN_USB policy=exclusive action=restore "
                    "interface=%s driver=%s result=success\n",
                    (long long) realtime_seconds(), record->interface_name,
                    record->driver_name);
        } else {
            dprintf(STDERR_FILENO,
                    "[%lld] BFU_DEBIAN_WARNING usb_exclusive_restore_failed "
                    "interface=%s driver=%s errno=%d recovery=unplug_or_reboot\n",
                    (long long) realtime_seconds(), record->interface_name,
                    record->driver_name, errno);
        }
    }
    memset(state, 0, sizeof(*state));
}

static int prepare_child_mounts(const char *root, const char *control_dir,
                                bool systemd_mode, CgroupMode cgroup_mode,
                                HostUsbPolicy host_usb_policy) {
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
    result = configure_host_usb_mount(root, host_usb_policy);
    if (result != 0) return result;

    /* A static Debian-facing client starts one private bionic NDK worker per
       invocation. Expose Android's immutable runtime only; app data and CE
       storage remain outside the chroot in both BFU and AFU. */
    result = bind_android_runtime_tree(root, "/system", "system", true);
    if (result != 0) return result;
    result = bind_android_runtime_tree(root, "/apex", "apex", true);
    if (result != 0) return result;
    result = bind_android_runtime_tree(root, "/linkerconfig", "linkerconfig",
                                       false);
    if (result != 0) return result;

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
        result = mount_delegated_cgroup_views(root, control_dir, cgroup_mode);
        if (result != 0) return result;
        dprintf(STDERR_FILENO,
                "[%lld] BFU_DEBIAN_STAGE private_cgroup_views_mounted "
                "mode=%s delegated_subtree=true\n",
                (long long) realtime_seconds(), cgroup_mode_name(cgroup_mode));
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
                               "run/dawnshell-host-reboot") != 0) {
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

/* Some legacy kernels panic in copy_ipcs()->mq_init_ns()->mqueue_mount() when
   a new IPC namespace is created. Docker cannot be configured to avoid this:
   `default-ipc-mode` rejects "host", and both "private" and "shareable"
   still unshare IPC. A seccomp filter therefore fails those calls with EPERM
   before they reach the kernel, so a container reports a clear error instead
   of taking the device down. The filter is inherited by every descendant,
   which covers dockerd, containerd, runc, and Compose alike. */
static int block_ipc_namespace_creation(void) {
#ifdef DAWNSHELL_AUDIT_ARCH
    /* PR_SET_NO_NEW_PRIVS is deliberately not set. It would disable every
       setuid binary inside Debian, which breaks `sudo`. The launcher already
       runs as root, and a privileged process may install a filter without
       that flag. */
    /* clone(2) and unshare(2) take the flags in different argument slots, and
       clone3(2) passes a struct this filter cannot inspect, so it is denied
       outright; callers fall back to clone(2). */
    struct sock_filter filter[] = {
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
                 offsetof(struct seccomp_data, arch)),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, DAWNSHELL_AUDIT_ARCH, 1, 0),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
                 offsetof(struct seccomp_data, nr)),
#ifdef __NR_unshare
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_unshare, 0, 3),
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
                 offsetof(struct seccomp_data, args[0])),
        BPF_JUMP(BPF_JMP | BPF_JSET | BPF_K, CLONE_NEWIPC, 0, 1),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | EPERM),
#endif
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
                 offsetof(struct seccomp_data, nr)),
#ifdef __NR_clone
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_clone, 0, 3),
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
                 offsetof(struct seccomp_data, args[0])),
        BPF_JUMP(BPF_JMP | BPF_JSET | BPF_K, CLONE_NEWIPC, 0, 1),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | EPERM),
#endif
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS,
                 offsetof(struct seccomp_data, nr)),
#ifdef __NR_clone3
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_clone3, 0, 1),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | ENOSYS),
#endif
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
    };
    struct sock_fprog program = {
        .len = (unsigned short) (sizeof(filter) / sizeof(filter[0])),
        .filter = filter,
    };
    if (syscall(__NR_seccomp, SECCOMP_SET_MODE_FILTER, 0, &program) != 0) {
        if (prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &program, 0, 0) != 0) {
            return fail_errno("seccomp_block_newipc", 53);
        }
    }
    dprintf(STDERR_FILENO,
            "[%lld] BFU_DEBIAN_STAGE ipc_namespace_creation_blocked "
            "reason=legacy_kernel_mqueue_panic\n",
            (long long) realtime_seconds());
    return 0;
#else
    dprintf(STDERR_FILENO,
            "[%lld] BFU_DEBIAN_WARNING ipc_namespace_filter_unavailable "
            "architecture=unsupported\n",
            (long long) realtime_seconds());
    return 0;
#endif
}

static int set_base_private_namespaces(void) {
    /* Some kernels do not confine a container reboot request to the private
       PID namespace; reboot(2) reaches the Android kernel path and restarts
       the phone. Docker's runtime can issue that call while starting or
       cleaning up a container, so the capability is dropped from the bounding
       set before Debian starts. DawnShell's own reboot bridge is unaffected
       because it asks the Android-side supervisor instead. */
    if (prctl(PR_CAPBSET_DROP, CAP_SYS_BOOT, 0, 0, 0) != 0 && errno != EINVAL) {
        return fail_errno("capbset_drop_sys_boot", 53);
    }
    dprintf(STDERR_FILENO,
            "[%lld] BFU_DEBIAN_STAGE cap_sys_boot_dropped "
            "android_reboot_from_container=blocked\n",
            (long long) realtime_seconds());
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
    /* Some legacy 4.4-era kernels dereference a stale mqueue mount pointer in
       copy_ipcs()->mq_init_ns()->mqueue_mount() when CLONE_NEWIPC is requested.
       The fault panics Android before userspace can handle an errno. IPC is
       therefore deliberately shared. Networking is also shared intentionally
       for native-NIC performance; mount/PID/UTS/cgroup isolation remains
       mandatory. */
    dprintf(STDERR_FILENO,
            "[%lld] BFU_DEBIAN_STAGE ipc_namespace_android_shared "
            "legacy_kernel_compat=true\n",
            (long long) realtime_seconds());
    return block_ipc_namespace_creation();
}

static int set_private_namespaces(void) {
    int result = set_base_private_namespaces();
    if (result != 0) return result;
    if (unshare(CLONE_NEWCGROUP) != 0) return fail_errno("unshare_cgroup", 57);
    if (unshare(CLONE_NEWPID) != 0) return fail_errno("unshare_pid", 58);
    return 0;
}

static int prepare_legacy_cgroup_mounts(const char *control_dir,
                                        HostUsbPolicy host_usb_policy) {
    int result = prepare_devices_cgroup_mount(control_dir, host_usb_policy);
    if (result != 0) return result;
    result = prepare_systemd_cgroup_mount(control_dir);
    if (result != 0) return result;
    return 0;
}

static int negotiate_cgroup_mode(const char *control_dir,
                                 CgroupPolicy policy,
                                 HostUsbPolicy host_usb_policy,
                                 CgroupMode *resolved_mode) {
    if (policy != CGROUP_POLICY_FORCE_V1) {
        int result = prepare_unified_cgroup_mount(control_dir, host_usb_policy);
        if (result == 0) {
            *resolved_mode = CGROUP_MODE_V2;
            dprintf(STDERR_FILENO,
                    "[%lld] BFU_DEBIAN_COMPAT cgroup_requested=%s "
                    "cgroup_resolved=v2 fallback=false\n",
                    (long long) realtime_seconds(),
                    policy == CGROUP_POLICY_AUTO ? "auto" : "v2");
            return 0;
        }
        int v2_errno = errno;
        cleanup_cgroup_hierarchy(control_dir, kUnifiedCgroupMountName,
                                 "unified_probe");
        if (policy == CGROUP_POLICY_FORCE_V2) {
            errno = v2_errno;
            return fail_errno("cgroup_v2_forced_unavailable", 117);
        }
        dprintf(STDERR_FILENO,
                "[%lld] BFU_DEBIAN_COMPAT cgroup_requested=auto "
                "cgroup_v2_available=false errno=%d fallback=v1\n",
                (long long) realtime_seconds(), v2_errno);
    }

    int result = prepare_legacy_cgroup_mounts(control_dir, host_usb_policy);
    if (result != 0) {
        cleanup_cgroup_hierarchy(control_dir, kDevicesCgroupMountName,
                                 "devices_probe");
        cleanup_cgroup_hierarchy(control_dir, kSystemdCgroupMountName,
                                 "systemd_probe");
        return result;
    }
    *resolved_mode = CGROUP_MODE_V1;
    dprintf(STDERR_FILENO,
            "[%lld] BFU_DEBIAN_COMPAT cgroup_requested=%s "
            "cgroup_resolved=v1 fallback=%s\n",
            (long long) realtime_seconds(),
            policy == CGROUP_POLICY_FORCE_V1 ? "v1" : "auto",
            policy == CGROUP_POLICY_FORCE_V1 ? "false" : "true");
    return 0;
}

static int set_systemd_parent_namespaces(const char *control_dir,
                                         int network_ready_fd,
                                         CgroupPolicy policy,
                                         HostUsbPolicy host_usb_policy,
                                         CgroupMode *resolved_mode) {
    int result = set_base_private_namespaces();
    if (result != 0) return result;
    if (wait_for_network_manager(network_ready_fd) != 0) {
        return fail_errno("wait_network_manager", 56);
    }
    result = negotiate_cgroup_mode(control_dir, policy, host_usb_policy,
                                   resolved_mode);
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
            "[ \"$arch\" = " DAWNSHELL_DEBIAN_ARCH
            " ] || fail architecture_mismatch; "
            "version=$(/usr/bin/cut -d. -f1 /etc/debian_version) || fail debian_version_read; "
            "[ \"$version\" = 13 ] || fail debian_version_not_13; "
            "if [ -x /sbin/init ]; then init=present; else init=absent; fi; "
            "if [ -x /usr/bin/systemctl ]; then systemctl=present; else systemctl=absent; fi; "
            "cgroup=$(while IFS= read -r line; do printf '%s,' \"$line\"; done < /proc/self/cgroup); "
            "printf 'BFU_DEBIAN_NAMESPACE_OK pid=%s proc1=%s arch=%s debian=%s init=%s systemctl=%s cgroup=%s\\n' "
            "\"$$\" \"$proc1\" \"$arch\" \"$version\" \"$init\" \"$systemctl\" \"$cgroup\"";

    int result = prepare_child_mounts(root, NULL, false, CGROUP_MODE_UNKNOWN,
                                      HOST_USB_OFF);
    if (result != 0) return result;
    if (syscall(__NR_sethostname, "dawnshell-probe",
                strlen("dawnshell-probe")) != 0) {
        return fail_errno("sethostname", 59);
    }
    if (chdir(root) != 0) return fail_errno("chdir_rootfs", 60);
    if (chroot(".") != 0) return fail_errno("chroot", 61);
    if (chdir("/") != 0) return fail_errno("chdir_chroot", 62);

    clearenv();
    setenv("HOME", "/root", 1);
    setenv("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", 1);
    setenv("LANG", "C.UTF-8", 1);
    setenv("container", "dawnshell", 1);

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

static int enter_debian_systemd(const char *root, const char *control_dir,
                                CgroupMode cgroup_mode,
                                HostUsbPolicy host_usb_policy) {
    int result = move_self_to_delegated_cgroups(control_dir, cgroup_mode);
    if (result != 0) return result;
    result = prepare_child_mounts(root, control_dir, true, cgroup_mode,
                                  host_usb_policy);
    if (result != 0) return result;
    log_file_snapshot("debian_pid1_cgroup", "/proc/self/cgroup");
    log_matching_snapshot("debian_cgroup_mounts", "/proc/self/mountinfo",
                          "cgroup");
    if (syscall(__NR_sethostname, "dawnshell",
                strlen("dawnshell")) != 0) {
        return fail_errno("sethostname", 68);
    }
    if (chdir(root) != 0) return fail_errno("chdir_rootfs", 69);
    if (chroot(".") != 0) return fail_errno("chroot", 70);
    if (chdir("/") != 0) return fail_errno("chdir_chroot", 71);

    clearenv();
    setenv("HOME", "/root", 1);
    setenv("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", 1);
    setenv("LANG", "C.UTF-8", 1);
    setenv("container", "dawnshell", 1);
    setenv("SYSTEMD_LOG_TARGET", "console", 1);
    setenv("SYSTEMD_LOG_LEVEL", "info", 1);
    setenv("SYSTEMD_LOG_TIME", "1", 1);
    if (cgroup_mode == CGROUP_MODE_V1) {
        /* v257 requires both flags to retain legacy/hybrid cgroup support. */
        setenv("SYSTEMD_PROC_CMDLINE",
               "systemd.unified_cgroup_hierarchy=0 "
               "SYSTEMD_CGROUP_ENABLE_LEGACY_FORCE=1 "
               "systemd.unit=multi-user.target",
               1);
    } else {
        setenv("SYSTEMD_PROC_CMDLINE",
               "systemd.unified_cgroup_hierarchy=1 "
               "systemd.unit=multi-user.target",
               1);
    }
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

/* systemd's halt signal eventually reaches the kernel reboot path. On some
   legacy 4.4-era kernels that path does not terminate this private PID
   namespace, so a normal stop used to time out and SIGKILL
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
        setenv("container", "dawnshell", 1);
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
                           const char *log_path, int lock_fd, int ready_fd,
                           CgroupPolicy cgroup_policy,
                           HostUsbPolicy host_usb_policy,
                           const UsbDeviceFilter *usb_device_filter) {
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
            "[%lld] BFU_DEBIAN_STAGE supervisor_started pid=%d root=%s "
            "host_usb_mode=%s host_usb_filter_count=%zu\n",
            (long long) realtime_seconds(), getpid(), root,
            host_usb_policy_name(host_usb_policy), usb_device_filter->count);
    log_file_snapshot("host_proc_cgroups", "/proc/cgroups");
    log_file_snapshot("host_cgroup_v2_controllers",
                      "/sys/fs/cgroup/unified/cgroup.controllers");
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
    ExclusiveUsbState exclusive_usb_state;
    memset(&exclusive_usb_state, 0, sizeof(exclusive_usb_state));
    initialize_state(&state, "starting");
    snprintf(state.host_usb_mode, sizeof(state.host_usb_mode), "%s",
             host_usb_policy_name(host_usb_policy));
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

    CgroupMode cgroup_mode = CGROUP_MODE_UNKNOWN;
    int result = set_systemd_parent_namespaces(control_dir, network_ready_fd,
                                               cgroup_policy, host_usb_policy,
                                               &cgroup_mode);
    if (result != 0) {
        cleanup_delegated_cgroups(root, control_dir);
        dprintf(ready_fd, "BFU_DEBIAN_START_FAILED stage=namespace_setup exit=%d\n",
                result);
        return result;
    }
    snprintf(state.cgroup_mode, sizeof(state.cgroup_mode), "%s",
             cgroup_mode_name(cgroup_mode));
    if (write_state(control_dir, &state) != 0) {
        dprintf(STDERR_FILENO,
                "[%lld] BFU_DEBIAN_WARNING cgroup_mode_state_write_failed "
                "mode=%s errno=%d\n",
                (long long) realtime_seconds(), cgroup_mode_name(cgroup_mode), errno);
    }

    int exec_pipe[2];
    if (pipe(exec_pipe) != 0) {
        int saved_errno = errno;
        cleanup_delegated_cgroups(root, control_dir);
        errno = saved_errno;
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
        cleanup_delegated_cgroups(root, control_dir);
        return 79;
    }
    if (init_pid == 0) {
        close(exec_pipe[0]);
        close(lock_fd);
        close(ready_fd);
        failure_report_fd = exec_pipe[1];
        _exit(enter_debian_systemd(root, control_dir, cgroup_mode,
                                   host_usb_policy));
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
        cleanup_delegated_cgroups(root, control_dir);
        dprintf(ready_fd, "BFU_DEBIAN_START_FAILED stage=exec_systemd\n");
        return 80;
    }

    if (wait_for_start_grace(init_pid) != 0) {
        (void) kill(init_pid, SIGKILL);
        while (waitpid(init_pid, NULL, 0) < 0 && errno == EINTR) {}
        snprintf(state.state, sizeof(state.state), "failed");
        state.wait_status = 81;
        (void) write_state(control_dir, &state);
        cleanup_delegated_cgroups(root, control_dir);
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
        (void) kill(init_pid, SIGKILL);
        while (waitpid(init_pid, NULL, 0) < 0 && errno == EINTR) {}
        snprintf(state.state, sizeof(state.state), "failed");
        state.wait_status = 82;
        (void) write_state(control_dir, &state);
        cleanup_delegated_cgroups(root, control_dir);
        dprintf(ready_fd,
                "BFU_DEBIAN_START_FAILED stage=init_identity_or_pid_namespace\n");
        return 82;
    }

    if (host_usb_policy == HOST_USB_EXCLUSIVE) {
        reconcile_exclusive_usb(usb_device_filter, &exclusive_usb_state);
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
            "network_mode=shared-nic cgroup_mode=%s host_usb_mode=%s "
            "host_usb_filter_count=%zu\n",
            (long long) realtime_seconds(), getpid(), init_pid,
            (unsigned long long) state.init_pid_ns_ino,
            (unsigned long long) state.init_mnt_ns_ino,
            (unsigned long long) state.init_uts_ns_ino,
            (unsigned long long) state.init_ipc_ns_ino,
            (unsigned long long) state.init_cgroup_ns_ino,
            (unsigned long long) state.init_net_ns_ino,
            cgroup_mode_name(cgroup_mode), host_usb_policy_name(host_usb_policy),
            usb_device_filter->count);
    dprintf(ready_fd,
            "BFU_DEBIAN_STARTED supervisor_pid=%d init_host_pid=%d "
            "namespace_pid=1 cgroup_mode=%s host_usb_mode=%s "
            "host_usb_filter_count=%zu\n",
            getpid(), init_pid, cgroup_mode_name(cgroup_mode),
            host_usb_policy_name(host_usb_policy), usb_device_filter->count);
    close(ready_fd);

    bool shutdown_sent = false;
    int64_t shutdown_deadline = 0;
    int64_t next_usb_scan = monotonic_millis() + kExclusiveUsbScanIntervalMs;
    int wait_status = 0;
    while (true) {
        pid_t waited = waitpid(init_pid, &wait_status, WNOHANG);
        if (waited == init_pid) break;
        if (waited < 0 && errno != EINTR) {
            wait_status = 255;
            break;
        }
        if (host_usb_policy == HOST_USB_EXCLUSIVE && !stop_requested
                && monotonic_millis() >= next_usb_scan) {
            reconcile_exclusive_usb(usb_device_filter, &exclusive_usb_state);
            next_usb_scan = monotonic_millis() + kExclusiveUsbScanIntervalMs;
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

    if (host_usb_policy == HOST_USB_EXCLUSIVE) {
        restore_exclusive_usb(&exclusive_usb_state);
    }
    if (network_manager_pid > 0) {
        (void) kill(network_manager_pid, SIGTERM);
        while (waitpid(network_manager_pid, NULL, 0) < 0 && errno == EINTR) {}
    }
    cleanup_delegated_cgroups(root, control_dir);
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
        printf("BFU_DEBIAN_STOPPED last_state=%s cgroup_mode=%s host_usb_mode=%s "
               "wait_status=%d updated_epoch=%lld\n",
               has_state ? stale.state : "none",
               has_state ? stale.cgroup_mode : "unknown",
               has_state ? stale.host_usb_mode : "unknown",
               has_state ? stale.wait_status : -1,
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
           "network_namespace=android-shared network_mode=shared-nic cgroup_mode=%s "
           "host_usb_mode=%s "
           "pid_ns=%llu mnt_ns=%llu uts_ns=%llu ipc_ns=%llu cgroup_ns=%llu "
           "net_ns=%llu updated_epoch=%lld\n",
           supervisor_valid && (topology_valid || strcmp(state.state, "starting") == 0)
                   ? "RUNNING" : "STARTING_OR_UNKNOWN",
           state.state, state.supervisor_pid, state.init_host_pid,
           supervisor_valid ? "true" : "false", init_valid ? "true" : "false",
           topology_valid ? "true" : "false", state.cgroup_mode,
           state.host_usb_mode,
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
            "is-active dawnshell-boot-proof.service 2>/dev/null || true); "
            "if [ -f /run/dawnshell-enabled-service.ready ]; then "
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
            "devices_hierarchy=$(/usr/bin/mawk '$1 == \"devices\" { print $2 }' "
            "/proc/cgroups 2>/dev/null || true); "
            "devices_path=$(/usr/bin/mawk -F: '$2 == \"devices\" { print $3 }' "
            "/proc/self/cgroup 2>/dev/null || true); "
            "unified_path=$(/usr/bin/mawk -F: '$1 == \"0\" && $2 == \"\" "
            "{ print $3 }' /proc/self/cgroup 2>/dev/null || true); "
            "if [ -r /sys/fs/cgroup/cgroup.controllers ] "
            "&& [ -w /sys/fs/cgroup/cgroup.procs ] "
            "&& { [ \"$unified_path\" = / ] "
            "|| [ \"$unified_path\" = /dawnshell-command ]; }; then "
            "cgroup_mode=v2; cgroup_delegation=delegated; devices_cgroup=bpf; "
            "elif [ -r /sys/fs/cgroup/devices/devices.list ] "
            "&& [ -w /sys/fs/cgroup/devices/cgroup.procs ] "
            "&& [ \"${devices_hierarchy:-0}\" -gt 0 ] "
            "&& [ \"$devices_path\" = / ]; then "
            "cgroup_mode=v1; cgroup_delegation=delegated; "
            "devices_cgroup=delegated; else cgroup_mode=unknown; "
            "cgroup_delegation=missing; devices_cgroup=missing; fi; "
            "printf 'BFU_DEBIAN_HEALTH pid1=%s pid1_start_ticks=%s "
            "system_state=%s dbus_service=%s dbus_bus=%s ssh_service=%s "
            "boot_proof_service=%s boot_proof_marker=%s "
            "default_target=%s target_state=%s listen_22=%s "
            "cgroup_mode=%s cgroup_delegation=%s devices_cgroup=%s "
            "devices_hierarchy=%s devices_path=%s unified_path=%s\\n' "
            "\"$pid1\" \"$pid1_start_ticks\" "
            "\"$system_state\" \"$dbus_service\" \"$dbus_bus\" "
            "\"$ssh_service\" \"$boot_proof_service\" \"$boot_proof_marker\" "
            "\"$default_target\" \"$target_state\" \"$listen_22\" "
            "\"$cgroup_mode\" \"$cgroup_delegation\" \"$devices_cgroup\" "
            "\"${devices_hierarchy:-0}\" \"${devices_path:-missing}\" "
            "\"${unified_path:-missing}\"; "
            "if [ \"$pid1\" = systemd ] && [ \"$system_state\" = running ] "
            "&& [ \"$dbus_service\" = active ] "
            "&& [ \"$dbus_bus\" = ok ] && [ \"$ssh_service\" = active ] "
            "&& [ \"$boot_proof_service\" = active ] "
            "&& [ \"$boot_proof_marker\" = present ] "
            "&& [ \"$default_target\" = multi-user.target ] "
            "&& [ \"$target_state\" = active ] "
            "&& [ \"$listen_22\" = true ] "
            "&& [ \"$cgroup_delegation\" = delegated ]; then exit 0; fi; "
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
    setenv("container", "dawnshell", 1);
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
    setenv("container", "dawnshell", 1);
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

static int enter_debian_codec_long_run(const char *root, const char *operation) {
    if (strcmp(operation, "start") != 0 && strcmp(operation, "stop") != 0
            && strcmp(operation, "status") != 0
            && strcmp(operation, "report") != 0) {
        return fail_message("codec_long_run_operation",
                            "expected_start_stop_status_or_report", 122);
    }
    if (chdir(root) != 0) return fail_errno("codec_long_run_chdir_rootfs", 122);
    if (chroot(".") != 0) return fail_errno("codec_long_run_chroot", 122);
    if (chdir("/") != 0) return fail_errno("codec_long_run_chdir_chroot", 122);
    clearenv();
    setenv("HOME", "/root", 1);
    setenv("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", 1);
    setenv("LANG", "C.UTF-8", 1);
    setenv("container", "dawnshell", 1);

    static const char unit[] = "dawnshell-codec-long-run.service";
    if (strcmp(operation, "start") == 0 || strcmp(operation, "stop") == 0) {
        char *const arguments[] = {
                "systemctl", "--no-block", (char *) operation, (char *) unit, NULL
        };
        execv("/usr/bin/systemctl", arguments);
        return fail_errno("codec_long_run_exec_systemctl", 123);
    }
    if (strcmp(operation, "status") == 0) {
        char *const arguments[] = {
                "systemctl", "show", "--no-pager",
                "--property=LoadState,ActiveState,SubState,Result,ExecMainCode,ExecMainStatus,StateChangeTimestamp",
                (char *) unit, NULL
        };
        execv("/usr/bin/systemctl", arguments);
        return fail_errno("codec_long_run_exec_status", 123);
    }

    static const char report_command[] =
            "printf '%s\\n' '===== service status ====='; "
            "/usr/bin/systemctl show --no-pager "
            "--property=LoadState,ActiveState,SubState,Result,ExecMainCode,ExecMainStatus,StateChangeTimestamp "
            "dawnshell-codec-long-run.service 2>&1; "
            "printf '\\n%s\\n' '===== journal (newest 240 lines) ====='; "
            "/usr/bin/journalctl --no-pager --lines=240 "
            "--output=short-iso-precise --unit=dawnshell-codec-long-run.service 2>&1";
    char *const arguments[] = {"sh", "-c", (char *) report_command, NULL};
    execv("/bin/sh", arguments);
    return fail_errno("codec_long_run_exec_report", 123);
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
    count = snprintf(namespace_path, sizeof(namespace_path), "/proc/%d/ns/cgroup",
                     state.init_host_pid);
    if (count < 0 || (size_t) count >= sizeof(namespace_path)) {
        close(pid_namespace_fd);
        close(mount_namespace_fd);
        close(lock_fd);
        errno = ENAMETOOLONG;
        return fail_errno("namespace_command_cgroup_path", 102);
    }
    int cgroup_namespace_fd = open(namespace_path, O_RDONLY | O_CLOEXEC);
    if (cgroup_namespace_fd < 0) {
        close(pid_namespace_fd);
        close(mount_namespace_fd);
        close(lock_fd);
        return fail_errno("namespace_command_open_cgroup", 102);
    }
    struct stat mount_namespace_stat;
    struct stat pid_namespace_stat;
    struct stat cgroup_namespace_stat;
    if (fstat(mount_namespace_fd, &mount_namespace_stat) != 0
            || fstat(pid_namespace_fd, &pid_namespace_stat) != 0
            || fstat(cgroup_namespace_fd, &cgroup_namespace_stat) != 0
            || (uint64_t) mount_namespace_stat.st_ino != state.init_mnt_ns_ino
            || (uint64_t) pid_namespace_stat.st_ino != state.init_pid_ns_ino
            || (uint64_t) cgroup_namespace_stat.st_ino
                    != state.init_cgroup_ns_ino
            || !validate_init_identity(&state)) {
        close(cgroup_namespace_fd);
        close(pid_namespace_fd);
        close(mount_namespace_fd);
        close(lock_fd);
        return fail_message("namespace_command_race",
                            "init_identity_changed_before_setns", 102);
    }
    close(lock_fd);
    if (setns(pid_namespace_fd, CLONE_NEWPID) != 0) {
        close(cgroup_namespace_fd);
        close(pid_namespace_fd);
        close(mount_namespace_fd);
        return fail_errno("namespace_command_setns_pid", 102);
    }
    close(pid_namespace_fd);
    if (setns(mount_namespace_fd, CLONE_NEWNS) != 0) {
        close(cgroup_namespace_fd);
        close(mount_namespace_fd);
        return fail_errno("namespace_command_setns_mount", 102);
    }
    close(mount_namespace_fd);

    CgroupMode cgroup_mode = parse_cgroup_mode(state.cgroup_mode);
    if (cgroup_mode == CGROUP_MODE_UNKNOWN) {
        close(cgroup_namespace_fd);
        return fail_message("namespace_command_cgroup_mode",
                            "missing_or_unknown_cgroup_mode_restart_required", 102);
    }
    result = move_self_to_delegated_command(control_dir, cgroup_mode);
    if (result != 0) {
        close(cgroup_namespace_fd);
        return result;
    }
    if (setns(cgroup_namespace_fd, CLONE_NEWCGROUP) != 0) {
        close(cgroup_namespace_fd);
        return fail_errno("namespace_command_setns_cgroup", 102);
    }
    close(cgroup_namespace_fd);

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

static int run_codec_long_run(const char *root, const char *control_dir,
                              const char *operation) {
    return run_in_debian_namespaces(root, control_dir,
                                    enter_debian_codec_long_run,
                                    operation, 20);
}

static int run_start(const char *root, const char *control_dir,
                     const char *log_path, CgroupPolicy cgroup_policy,
                     HostUsbPolicy host_usb_policy,
                     const UsbDeviceFilter *usb_device_filter) {
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
                   "identity_valid=%s cgroup_mode=%s host_usb_mode=%s\n",
                   state.supervisor_pid, state.init_host_pid,
                   valid ? "true" : "false", state.cgroup_mode,
                   state.host_usb_mode);
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
                                        lock_fd, ready_pipe[1], cgroup_policy,
                                        host_usb_policy, usb_device_filter);
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
                       const char *log_path, CgroupPolicy cgroup_policy,
                       HostUsbPolicy host_usb_policy,
                       const UsbDeviceFilter *usb_device_filter) {
    int result = run_stop(root, control_dir);
    if (result != 0) return result;
    return run_start(root, control_dir, log_path, cgroup_policy,
                     host_usb_policy, usb_device_filter);
}

static void usage(const char *program) {
    fprintf(stderr,
            "usage:\n"
            "  %s probe /data/local/debian\n"
            "  %s start /data/local/debian CONTROL_DIR LIFECYCLE_LOG "
            "[auto|v2|v1] [off|direct|exclusive] [VID:PID,...|-]\n"
            "  %s status /data/local/debian CONTROL_DIR\n"
            "  %s health /data/local/debian CONTROL_DIR\n"
            "  %s stop /data/local/debian CONTROL_DIR\n"
            "  %s restart /data/local/debian CONTROL_DIR LIFECYCLE_LOG "
            "[auto|v2|v1] [off|direct|exclusive] [VID:PID,...|-]\n"
            "  %s codec-long-run /data/local/debian CONTROL_DIR "
            "start|stop|status|report\n"
            "  %s shutdown-test /data/local/debian CONTROL_DIR poweroff|reboot|shutdown\n",
            program, program, program, program, program, program, program, program);
}

int main(int argc, char **argv) {
    if (argc == 3 && strcmp(argv[1], "probe") == 0) {
        return run_probe(argv[2]);
    }
    if (argc >= 5 && argc <= 8 && strcmp(argv[1], "start") == 0) {
        CgroupPolicy policy;
        HostUsbPolicy host_usb_policy;
        UsbDeviceFilter usb_device_filter;
        if (parse_cgroup_policy(argc >= 6 ? argv[5] : "auto", &policy) != 0) {
            return fail_message("cgroup_policy", "expected_auto_v2_or_v1", 2);
        }
        if (parse_host_usb_policy(argc >= 7 ? argv[6] : "off",
                                  &host_usb_policy) != 0) {
            return fail_message("host_usb_policy",
                                "expected_off_direct_or_exclusive", 2);
        }
        if (parse_usb_device_filter(argc == 8 ? argv[7] : "-",
                                    &usb_device_filter) != 0) {
            return fail_message("host_usb_filter",
                                "expected_comma_separated_VID:PID_values", 2);
        }
        if (host_usb_policy == HOST_USB_EXCLUSIVE
                && usb_device_filter.count == 0) {
            return fail_message("host_usb_filter",
                                "exclusive_mode_requires_at_least_one_VID:PID", 2);
        }
        return run_start(argv[2], argv[3], argv[4], policy, host_usb_policy,
                         &usb_device_filter);
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
    if (argc >= 5 && argc <= 8 && strcmp(argv[1], "restart") == 0) {
        CgroupPolicy policy;
        HostUsbPolicy host_usb_policy;
        UsbDeviceFilter usb_device_filter;
        if (parse_cgroup_policy(argc >= 6 ? argv[5] : "auto", &policy) != 0) {
            return fail_message("cgroup_policy", "expected_auto_v2_or_v1", 2);
        }
        if (parse_host_usb_policy(argc >= 7 ? argv[6] : "off",
                                  &host_usb_policy) != 0) {
            return fail_message("host_usb_policy",
                                "expected_off_direct_or_exclusive", 2);
        }
        if (parse_usb_device_filter(argc == 8 ? argv[7] : "-",
                                    &usb_device_filter) != 0) {
            return fail_message("host_usb_filter",
                                "expected_comma_separated_VID:PID_values", 2);
        }
        if (host_usb_policy == HOST_USB_EXCLUSIVE
                && usb_device_filter.count == 0) {
            return fail_message("host_usb_filter",
                                "exclusive_mode_requires_at_least_one_VID:PID", 2);
        }
        return run_restart(argv[2], argv[3], argv[4], policy,
                           host_usb_policy, &usb_device_filter);
    }
    if (argc == 5 && strcmp(argv[1], "shutdown-test") == 0) {
        return run_shutdown_test(argv[2], argv[3], argv[4]);
    }
    if (argc == 5 && strcmp(argv[1], "codec-long-run") == 0) {
        return run_codec_long_run(argv[2], argv[3], argv[4]);
    }
    usage(argv[0]);
    return 2;
}
