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

bash -n "$policy_script"
bash -n "$usb_policy_script"

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
grep -Fq 'cgroup_delegation=delegated' "$launcher"

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
# A private IPC namespace panics some kernels, so the protection must also
# reach clients the CLI wrapper never sees, such as `docker compose`.
grep -Fq 'default-ipc-mode' "$policy_script"
grep -Fq 'ipc_mode_entry' "$policy_script"
# Host IPC must be the default rather than an opt-in switch.
grep -Fq 'KEY_DOCKER_HOST_IPC_COMPATIBILITY, true' \
    "$repo_dir/app/src/main/java/me/aroxu/dawnshell/BfuPreferences.java"
# shellcheck disable=SC2016 # Assert literal shell source, not this test's variables.
grep -Fq 'exec "$real_docker" "${rewritten[@]}"' "$policy_script"
# shellcheck disable=SC2016 # Assert literal shell source, not this test's variables.
grep -Fq 'existing unmanaged $docker_wrapper was preserved' "$policy_script"
grep -Fq 'use /usr/bin/docker to bypass' "$policy_script"
grep -Fq 'android:id="@+id/docker_network_policy_group"' "$layout"
grep -Fq 'android:id="@+id/switch_docker_host_ipc_compatibility"' "$layout"
grep -Fq 'android:id="@+id/cgroup_policy_group"' "$layout"
grep -Fq 'android:id="@+id/usb_passthrough_group"' "$layout"
grep -Fq 'android:id="@+id/usb_passthrough_direct"' "$layout"
grep -Fq 'android:id="@+id/usb_passthrough_exclusive"' "$layout"
grep -Fq 'android:id="@+id/usb_exclusive_device_ids"' "$layout"
grep -Fq 'android:id="@+id/apply_host_usb_policy_button"' "$layout"
[[ "$(grep -Fc 'android:text="@string/dawnshell_host_usb_title"' "$layout")" -eq 1 ]]
grep -Fq 'lsusb_legacy_sysfs_filter=enabled' "$usb_policy_script"
grep -Fq '/rx_lanes:\ No\ such\ file\ or\ directory' "$usb_policy_script"
grep -Fq '/tx_lanes:\ No\ such\ file\ or\ directory' "$usb_policy_script"
grep -Fq 'Android-global firewall, NAT, forwarding, and routes' "$strings"
grep -Fq 'Never mount one USB storage filesystem from both systems' "$strings"
grep -Fq 'Off does not stop Android from detecting USB hardware' "$strings"
grep -Fq '/dev/block/sd* storage' "$strings"
grep -Fq 'not complete USB-device isolation' "$strings"

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

echo "PASS: capability negotiation, Docker IPC wrapper, USB policies, safe defaults, fallback order, and warnings are pinned."
