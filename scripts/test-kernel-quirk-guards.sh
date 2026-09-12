#!/usr/bin/env bash
# Pins the guards for two Android kernel quirks that break Debian.
#
# Some Android kernels walk every descriptor number in the requested range
# instead of stopping at the process descriptor table, so one closefrom(3) call
# costs minutes of uninterruptible kernel time. That made openssh-server
# configuration, D-Bus machine ID initialisation, and systemd startup look like
# hangs.
#
# Separately, /data uses fscrypt version 1 policies, where the encryption key
# is looked up in the calling process keyring. systemd joins a fresh session
# keyring at startup and loses that key, so every service fails to create files
# with ENOKEY and the manager stays degraded.
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
guard_header="$repo_dir/app/src/main/cpp/dawnshell_close_range_guard.h"
keyring_header="$repo_dir/app/src/main/cpp/dawnshell_keyring_guard.h"
guard_source="$repo_dir/app/src/main/cpp/dawnshell_fdguard.c"
launcher="$repo_dir/app/src/main/cpp/bfu_namespace_probe.c"
configurator="$repo_dir/app/src/main/assets/bfu/configure-debian-systemd.sh"
docker_network="$repo_dir/app/src/main/assets/bfu/configure-docker-network.sh"
installer="$repo_dir/app/src/main/assets/bfu/install-debian-rootfs.sh"
runtime="$repo_dir/app/src/main/java/me/aroxu/dawnshell/BfuRuntime.java"
bootstrap_builder="$repo_dir/scripts/build-bootstrap-runtime.sh"

for required in "$guard_header" "$guard_source" "$launcher" "$configurator" \
        "$docker_network" "$installer" "$runtime" "$bootstrap_builder" \
        "$keyring_header"; do
    test -f "$required"
done

# The filter must answer ENOSYS so glibc falls back to scanning /proc/self/fd.
grep -Fq 'SECCOMP_RET_ERRNO | ENOSYS' "$guard_header"
grep -Fq '__NR_close_range' "$guard_header"
grep -Fq 'SECCOMP_SET_MODE_FILTER' "$guard_header"

# Setting PR_SET_NO_NEW_PRIVS would disable setuid binaries and break sudo
# inside Debian. A privileged installer does not need it.
if grep -Fq 'prctl(PR_SET_NO_NEW_PRIVS' "$guard_header"; then
    echo "FAIL: the close_range guard must not set PR_SET_NO_NEW_PRIVS" >&2
    exit 1
fi
# The reason must stay documented next to the code.
grep -Fq 'PR_SET_NO_NEW_PRIVS is deliberately not set' "$guard_header"

# The guard must measure the running kernel instead of assuming it is affected.
grep -Fq 'dawnshell_close_range_is_pathological' "$guard_header"
grep -Fq 'CLOCK_MONOTONIC' "$guard_header"
grep -Fq 'DAWNSHELL_CLOSE_RANGE_GUARD' "$guard_header"

# The bounded probe must not ask for the full range; that is the slow call the
# guard exists to avoid.
if grep -Eq 'close_range, 3, *(~0U|4294967295|2147483647)' "$guard_header"; then
    echo "FAIL: the probe itself must use a bounded descriptor range" >&2
    exit 1
fi

# The wrapper must execute the requested command after installing the filter.
grep -Fq 'execvp(argv[1], argv + 1)' "$guard_source"
grep -Fq 'dawnshell_install_close_range_guard' "$guard_source"

# The Debian launcher installs the same filter, so systemd and every service
# inherit it.
grep -Fq '#include "dawnshell_close_range_guard.h"' "$launcher"
grep -Fq 'install_close_range_guard' "$launcher"
grep -Fq 'close_range_guard_installed' "$launcher"

# Package configuration, Docker negotiation, and rootfs installation all enter
# Debian through the guard.
# The patterns below are literal script text, not expansions.
# shellcheck disable=SC2016
grep -Fq '$CHROOT_GUARD chroot "$ROOT"' "$configurator"
# shellcheck disable=SC2016
grep -Fq '$CHROOT_GUARD chroot "$ROOT"' "$docker_network"
# shellcheck disable=SC2016
grep -Fq 'dawnshell-fdguard $BIN/chroot' "$installer"

# The binary must be built for every supported ABI and provisioned to Device
# Protected Storage.
grep -Fq 'build_fdguard' "$bootstrap_builder"
grep -Fq 'dawnshell-fdguard' "$runtime"

for abi in armeabi-v7a arm64-v8a x86_64; do
    binary="$repo_dir/app/src/main/assets/bfu/bin/$abi/dawnshell-fdguard"
    test -s "$binary"
    # ELF magic keeps a stray text file from being shipped as an executable.
    magic="$(head -c 4 "$binary" | od -An -tx1 | tr -d ' \n')"
    if [[ "$magic" != "7f454c46" ]]; then
        echo "FAIL: $abi dawnshell-fdguard is not an ELF binary" >&2
        exit 1
    fi
done



# Every Java caller must enter Debian through the guard helper, otherwise a
# short-timeout command such as chpasswd fails on an affected kernel.
grep -Fq 'static String guardedChroot(Layout layout)' "$runtime"
# Only the helper itself may build the literal chroot command.
unguarded="$(grep -rn '" chroot "' "$repo_dir/app/src/main/java" \
    | grep -v '/BfuRuntime.java:' || true)"
if [[ -n "$unguarded" ]]; then
    echo "FAIL: a Java caller builds a chroot command without the guard:" >&2
    echo "$unguarded" >&2
    exit 1
fi

# --- fscrypt session-keyring guard ---

# The filter must report ENOSYS for KEYCTL_JOIN_SESSION_KEYRING so systemd
# keeps the inherited keyring and treats the failure as an unsupported kernel.
grep -Fq 'KEYCTL_JOIN_SESSION_KEYRING' "$keyring_header"
grep -Fq 'SECCOMP_RET_ERRNO | ENOSYS' "$keyring_header"
grep -Fq '__NR_keyctl' "$keyring_header"

# It must measure the filesystem instead of assuming, and the measurement must
# be the ENOKEY failure the quirk actually produces.
grep -Fq 'dawnshell_session_keyring_join_breaks_writes' "$keyring_header"
grep -Fq 'ENOKEY' "$keyring_header"
grep -Fq 'DAWNSHELL_SESSION_KEYRING_GUARD' "$keyring_header"

# sudo must keep working inside Debian.
if grep -Fq 'prctl(PR_SET_NO_NEW_PRIVS' "$keyring_header"; then
    echo "FAIL: the keyring guard must not set PR_SET_NO_NEW_PRIVS" >&2
    exit 1
fi

# The guard has to run in the chroot, immediately before systemd is executed.
grep -Fq '#include "dawnshell_keyring_guard.h"' "$launcher"
grep -Fq 'dawnshell_install_keyring_guard("/")' "$launcher"
grep -Fq 'session_keyring_join_blocked' "$launcher"
perl - "$launcher" <<'PERL_ORDER'
use strict;
use warnings;
open(my $source, "<", $ARGV[0]) or die "cannot read $ARGV[0]: $!\n";
local $/ = undef;
my $text = <$source>;
close($source);
my $guard = index($text, "dawnshell_install_keyring_guard(\"/\")");
my $exec = index($text, "execv(\"/sbin/init\"");
die "keyring guard call not found\n" if $guard < 0;
die "systemd exec not found\n" if $exec < 0;
die "the keyring guard must be installed before systemd is executed\n"
    if $guard > $exec;
PERL_ORDER

echo "PASS: close_range(2) and fscrypt session-keyring guards are built, provisioned, and wired into every Debian entry point"
