#!/usr/bin/env bash
set -euo pipefail

boot_log="/data/user_de/0/me.aroxu.termux.bfu/files/bfu-boot.log"
root_log="/data/user_de/0/me.aroxu.termux.bfu/files/bfu-root.log"
rootfs_log="/data/user_de/0/me.aroxu.termux.bfu/files/bfu-rootfs.log"
runtime_log="/data/user_de/0/me.aroxu.termux.bfu/files/bfu-debian-runtime.log"

line_count() {
  local path="$1"
  adb shell run-as me.aroxu.termux.bfu cat "$path" 2>/dev/null \
    | wc -l | tr -d '[:space:]' || true
}

boot_count_before="$(line_count "$boot_log")"
root_count_before="$(line_count "$root_log")"
rootfs_count_before="$(line_count "$rootfs_log")"
runtime_count_before="$(line_count "$runtime_log")"

adb logcat -c
adb reboot

wait_seconds="${BFU_WAIT_SECONDS:-45}"
echo "Keep the device locked for ${wait_seconds}s while the namespace probe runs."
sleep "$wait_seconds"
echo "Now unlock once so ADB can reconnect and the DE evidence can be read."
adb wait-for-device

boot_results="$(adb shell run-as me.aroxu.termux.bfu cat "$boot_log")"
root_results="$(adb shell run-as me.aroxu.termux.bfu cat "$root_log")"
rootfs_results="$(adb shell run-as me.aroxu.termux.bfu cat "$rootfs_log")"
runtime_results="$(adb shell run-as me.aroxu.termux.bfu cat "$runtime_log")"

printf '%s\n' "$boot_results"
printf '%s\n' "$root_results"
printf '%s\n' "$rootfs_results"
printf '%s\n' "$runtime_results"

(( $(line_count "$boot_log") > boot_count_before ))
(( $(line_count "$root_log") > root_count_before ))
(( $(line_count "$rootfs_log") > rootfs_count_before ))
(( $(line_count "$runtime_log") > runtime_count_before ))

latest_runtime="$(printf '%s\n' "$runtime_results" | tail -n 1 | tr -d '\r')"
printf '%s\n' "$latest_runtime" | grep -q '^DEBIAN_RUNTIME_PROBE '
printf '%s\n' "$latest_runtime" | grep -Fq ' exit=0 '
printf '%s\n' "$latest_runtime" | grep -Fq ' timeout=false '
printf '%s\n' "$latest_runtime" | grep -Fq ' namespace_chroot=true '
printf '%s\n' "$latest_runtime" | grep -Fq ' user_unlocked_before=false '
printf '%s\n' "$latest_runtime" | grep -Fq ' user_unlocked_after=false '
printf '%s\n' "$latest_runtime" | grep -Fq \
  'BFU_DEBIAN_NAMESPACE_OK pid=1 proc1=sh arch=arm64 debian=13'

echo "PASS: private namespaces, PID-namespace /proc, and Debian chroot worked during BFU."
