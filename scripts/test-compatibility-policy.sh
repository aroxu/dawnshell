#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
preferences="$repo_dir/app/src/main/java/me/aroxu/dawnshell/BfuPreferences.java"
launcher="$repo_dir/app/src/main/java/me/aroxu/dawnshell/DebianLauncher.java"
native_launcher="$repo_dir/app/src/main/cpp/bfu_namespace_probe.c"
policy_script="$repo_dir/app/src/main/assets/bfu/configure-docker-network.sh"
usb_policy_script="$repo_dir/app/src/main/assets/bfu/configure-host-usb.sh"
layout="$repo_dir/app/src/main/res/layout/activity_boot.xml"
strings="$repo_dir/app/src/main/res/values/strings.xml"
boot_activity="$repo_dir/app/src/main/java/me/aroxu/dawnshell/BootActivity.java"
boot_service="$repo_dir/app/src/main/java/me/aroxu/dawnshell/BfuBootService.java"
runtime_probe="$repo_dir/app/src/main/java/me/aroxu/dawnshell/BfuDebianRuntimeProbe.java"
system_configurator="$repo_dir/app/src/main/assets/bfu/configure-debian-systemd.sh"

bash -n "$policy_script"
bash -n "$usb_policy_script"
bash -n "$system_configurator"

grep -Fq 'CGROUP_AUTO = "auto"' "$preferences"
grep -Fq 'DOCKER_HOST_ONLY = "host"' "$preferences"
grep -Fq 'DOCKER_NATIVE_NFT_BRIDGE = "native_nft"' "$preferences"
grep -Fq 'DOCKER_IPTABLES_NFT_BRIDGE = "iptables_nft"' "$preferences"
grep -Fq 'USB_PASSTHROUGH_OFF = "off"' "$preferences"
grep -Fq 'USB_PASSTHROUGH_DIRECT = "direct"' "$preferences"
grep -Fq 'USB_PASSTHROUGH_EXCLUSIVE = "exclusive"' "$preferences"
grep -Fq 'BfuPreferences.usbPassthroughMode(context)' "$launcher"
grep -Fq 'BfuPreferences.usbExclusiveDeviceIds(context)' "$launcher"
grep -Fq 'BfuPreferences.cgroupPolicy(context)' "$launcher"
grep -Fq 'BfuPreferences.pidNamespaceFallback(context)' "$launcher"
grep -Fq 'cgroup_delegation=delegated' "$launcher"
grep -Fq 'KEY_PID_NAMESPACE_FALLBACK, false' "$preferences"
grep -Fq '"fallback" : "strict"' "$launcher"
grep -Fq '"probe-compat" : "probe"' "$runtime_probe"

grep -Fq 'trying native Docker nftables first' "$policy_script"
grep -Fq 'trying iptables-nft' "$policy_script"
grep -Fq 'trying iptables-legacy' "$policy_script"
grep -Fq -- '-m addrtype --dst-type LOCAL' "$policy_script"
grep -Fq -- '-j MASQUERADE' "$policy_script"
grep -Fq -- '-m conntrack' "$policy_script"
grep -Fq 'FALLBACK: using safe host-network-only mode' "$policy_script"
native_line="$(grep -nF 'trying native Docker nftables first' "$policy_script" | cut -d: -f1)"
nft_line="$(grep -nF 'trying iptables-nft' "$policy_script" | cut -d: -f1)"
legacy_line="$(grep -nF 'trying iptables-legacy' "$policy_script" | cut -d: -f1)"
(( native_line < nft_line && nft_line < legacy_line ))

grep -Fq 'existing unmanaged /etc/docker/daemon.json was preserved' "$policy_script"
grep -Fq '"bridge": "none"' "$policy_script"
grep -Fq '"iptables": false' "$policy_script"
grep -Fq '"ip6tables": false' "$policy_script"
grep -Fq '"ip-forward": false' "$policy_script"
grep -Fq '"ip-masq": false' "$policy_script"
[[ "$(grep -Fc '"exec-opts": ["native.cgroupdriver=cgroupfs"]' "$policy_script")" -eq 4 ]]
grep -Fq 'cgroup_driver=cgroupfs' "$policy_script"
# shellcheck disable=SC2016 # Assert literal shell source, not this test's variables.
grep -Fq 'host_ipc_compatibility=$host_ipc_compatibility' "$policy_script"
grep -Fq 'rewritten+=(--ipc=host)' "$policy_script"
# Host IPC must be the default rather than an opt-in switch.
grep -Fq 'KEY_DOCKER_HOST_IPC_COMPATIBILITY, true' \
    "$repo_dir/app/src/main/java/me/aroxu/dawnshell/BfuPreferences.java"
# dockerd rejects "host" for default-ipc-mode, and both accepted values still
# unshare IPC, so the daemon configuration must not try to set it.
if grep -Fq 'default-ipc-mode' "$policy_script"; then
    echo "dockerd rejects a host default-ipc-mode; do not emit it" >&2
    exit 1
fi
# The launcher blocks IPC namespace creation outright, which covers every
# client including `docker compose` and the API.
launcher_source="$repo_dir/app/src/main/cpp/bfu_namespace_probe.c"
grep -Fq 'block_ipc_namespace_creation' "$launcher_source"
grep -Fq 'ipc_namespace_creation_blocked' "$launcher_source"
grep -Fq 'SECCOMP_RET_ERRNO | EPERM' "$launcher_source"
grep -Fq 'CLONE_NEWIPC' "$launcher_source"
# PR_SET_NO_NEW_PRIVS would disable every setuid binary in Debian and break
# `sudo`. The launcher runs as root, so the filter must be installed without it.
if grep -Fq 'PR_SET_NO_NEW_PRIVS, 1' "$launcher_source"; then
    echo "no_new_privs breaks sudo inside Debian; do not set it" >&2
    exit 1
fi

# A root shell has a minimal PATH, so every chroot call must name the
# provisioned toolbox applet instead of relying on command lookup.
password_manager="$repo_dir/app/src/main/java/me/aroxu/dawnshell/DebianPasswordManager.java"
grep -Fq 'toolboxBinary' "$password_manager"
if grep -Eq '"chroot ' "$password_manager"; then
    echo "chroot must be invoked through the provisioned toolbox path" >&2
    exit 1
fi
# shellcheck disable=SC2016 # Assert literal shell source, not this test's variables.
grep -Fq 'exec "$real_docker" "${rewritten[@]}"' "$policy_script"
# shellcheck disable=SC2016 # Assert literal shell source, not this test's variables.
grep -Fq 'existing unmanaged $docker_wrapper was preserved' "$policy_script"
grep -Fq 'use /usr/bin/docker to bypass' "$policy_script"
grep -Fq 'android:id="@+id/docker_network_policy_group"' "$layout"
grep -Fq 'android:id="@+id/switch_docker_host_ipc_compatibility"' "$layout"
grep -Fq 'android:id="@+id/cgroup_policy_group"' "$layout"
grep -Fq 'android:id="@+id/switch_pid_namespace_fallback"' "$layout"
grep -Fq 'android:id="@+id/usb_passthrough_group"' "$layout"
grep -Fq 'android:id="@+id/usb_passthrough_direct"' "$layout"
grep -Fq 'android:id="@+id/usb_passthrough_exclusive"' "$layout"
grep -Fq 'android:id="@+id/usb_exclusive_device_ids"' "$layout"
grep -Fq 'android:id="@+id/settings_apply_bar"' "$layout"
grep -Fq 'android:id="@+id/save_provision_button"' "$layout"
grep -Fq 'android:id="@+id/dashboard_navigation"' "$layout"
grep -Fq 'requestRuntimeSettingsApply(this' "$boot_activity"
grep -Fq 'ACTION_APPLY_RUNTIME_SETTINGS' "$boot_service"
grep -Fq 'RUNTIME_SETTINGS_APPLIED' "$boot_service"
if grep -Fq 'android:id="@+id/apply_host_usb_policy_button"' "$layout" \
        || grep -Fq 'android:id="@+id/apply_docker_policy_button"' "$layout"; then
    echo "USB and Docker must use the single global settings apply action" >&2
    exit 1
fi
[[ "$(grep -Fc 'android:text="@string/dawnshell_host_usb_title"' "$layout")" -eq 1 ]]
grep -Fq 'lsusb_legacy_sysfs_filter=enabled' "$usb_policy_script"
grep -Fq '/rx_lanes:\ No\ such\ file\ or\ directory' "$usb_policy_script"
grep -Fq '/tx_lanes:\ No\ such\ file\ or\ directory' "$usb_policy_script"
grep -Fq 'Android-global firewall, NAT, forwarding, and routes' "$strings"
grep -Fq 'Never mount one USB storage filesystem from both systems' "$strings"
grep -Fq 'Off does not stop Android from detecting USB hardware' "$strings"
grep -Fq '/dev/block/sd* storage' "$strings"
grep -Fq 'not complete USB-device isolation' "$strings"
grep -Fq 'starts OpenSSH directly' "$strings"
grep -Fq 'Docker/container support' "$strings"

grep -Fq '"c 189:* rwm\n"' "$native_launcher"
grep -Fq 'BPF_PROG_TYPE_CGROUP_DEVICE' "$native_launcher"
test "$(grep -Fc 'attributes.attach_flags = BPF_F_ALLOW_MULTI' "$native_launcher")" -eq 2
grep -Fq 'move_self_to_delegated_command(control_dir, cgroup_mode)' "$native_launcher"
grep -Fq 'command_moved_to_cgroup_v2_leaf' "$native_launcher"
grep -Fq '/dawnshell-command' "$native_launcher"
grep -Fq 'host_usb_mode=%s' "$native_launcher"
grep -Fq 'future_hotplug_cgroup_enforced=true' "$native_launcher"
grep -Fq 'exclusive_mode_requires_at_least_one_VID:PID' "$native_launcher"
grep -Fq 'action=unbind' "$native_launcher"
grep -Fq 'action=restore' "$native_launcher"
grep -Fq 'kExclusiveUsbScanIntervalMs' "$native_launcher"
grep -Fq 'LAUNCH_MODE_COMPAT' "$native_launcher"
grep -Fq 'BFU_DEBIAN_FALLBACK_STARTED' "$native_launcher"
grep -Fq 'BFU_DEBIAN_COMPATIBILITY_OK' "$native_launcher"
grep -Fq 'fallback=direct_sshd' "$native_launcher"
grep -Fq 'validate_compat_namespace_topology' "$native_launcher"
grep -Fq 'compat_ready=%s' "$native_launcher"
grep -Fq 'read_optional_proc_namespace_inode(pid, "ipc"' "$native_launcher"
grep -Fq 'read_optional_proc_namespace_inode(pid, "net"' "$native_launcher"
grep -Fq 'state->init_ipc_ns_ino == 0' "$native_launcher"
grep -Fq 'state->init_net_ns_ino == 0' "$native_launcher"
grep -Fq 'stage=%s child_exit=%d' "$native_launcher"
grep -Fq 'stage=%s child_signal=%d' "$native_launcher"

# Package recovery must run inside the configurator's private mounted chroot.
# Assign Android's Internet GID before either dpkg maintainer scripts or apt
# drop privileges to _apt, then repair interrupted packages before downloads.
grep -Fq 'STAGE: Preparing Android AID_INET access for Debian package downloads' \
    "$system_configurator"
# shellcheck disable=SC2016 # Assert literal configurator source.
grep -Fq 'usermod --append --groups "$inet_group_name" _apt' \
    "$system_configurator"
# shellcheck disable=SC2016 # Assert literal configurator source.
grep -Fq 'usermod --gid "$inet_group_name" _apt' "$system_configurator"
grep -Fq 'STAGE: Repairing interrupted Debian package configuration' \
    "$system_configurator"
grep -Fq 'dpkg --configure -a' "$system_configurator"
inet_line="$(grep -nF 'STAGE: Preparing Android AID_INET access' \
    "$system_configurator" | cut -d: -f1)"
dpkg_line="$(grep -nF 'dpkg --configure -a' "$system_configurator" \
    | cut -d: -f1)"
apt_line="$(grep -nF 'apt-get -o Acquire::Retries=3 update' \
    "$system_configurator" | head -n 1 | cut -d: -f1)"
(( inet_line < dpkg_line && dpkg_line < apt_line ))

echo "PASS: capability negotiation, opt-in host-PID fallback, Docker IPC wrapper, USB policies, safe defaults, fallback order, and warnings are pinned."
