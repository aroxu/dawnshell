#!/usr/bin/env bash
set -euo pipefail

boot_log="/data/user_de/0/com.termux.boot/files/bfu-boot.log"
root_log="/data/user_de/0/com.termux.boot/files/bfu-root.log"
rootfs_log="/data/user_de/0/com.termux.boot/files/bfu-rootfs.log"

line_count() {
  local path="$1"
  adb shell run-as com.termux.boot cat "$path" 2>/dev/null \
    | wc -l | tr -d '[:space:]' || true
}

boot_count_before="$(line_count "$boot_log")"
root_count_before="$(line_count "$root_log")"
rootfs_count_before="$(line_count "$rootfs_log")"

adb logcat -c
adb reboot

wait_seconds="${BFU_WAIT_SECONDS:-30}"
echo "Keep the device locked for ${wait_seconds}s; BFU ADB is not expected on this ROM."
sleep "$wait_seconds"
echo "Now unlock the device once so ADB can reconnect and the DE logs can be read."
adb wait-for-device

boot_count_after="$(line_count "$boot_log")"
root_count_after="$(line_count "$root_log")"
rootfs_count_after="$(line_count "$rootfs_log")"

boot_results="$(adb shell run-as com.termux.boot cat "$boot_log")"
root_results="$(adb shell run-as com.termux.boot cat "$root_log")"
rootfs_results="$(adb shell run-as com.termux.boot cat "$rootfs_log")"
printf '%s\n' "$boot_results"
printf '%s\n' "$root_results"
printf '%s\n' "$rootfs_results"

(( boot_count_after > boot_count_before ))
(( root_count_after > root_count_before ))
(( rootfs_count_after > rootfs_count_before ))

latest_root="$(printf '%s\n' "$root_results" | tail -n 1 | tr -d '\r')"
printf '%s\n' "$latest_root" | grep -Fq ' exit=0 '
printf '%s\n' "$latest_root" | grep -Fq ' root=true '
printf '%s\n' "$latest_root" | grep -Fq ' user_unlocked_before=false '
printf '%s\n' "$latest_root" | grep -Fq ' user_unlocked_after=false '

latest_rootfs="$(printf '%s\n' "$rootfs_results" | tail -n 1 | tr -d '\r')"
printf '%s\n' "$latest_rootfs" | grep -q '^ROOTFS_PROBE '
printf '%s\n' "$latest_rootfs" | grep -Fq ' rootfs=/data/local/debian '
printf '%s\n' "$latest_rootfs" | grep -Fq ' exit=0 '
printf '%s\n' "$latest_rootfs" | grep -Fq ' accessible=true '
printf '%s\n' "$latest_rootfs" | grep -Fq ' user_unlocked_before=false '
printf '%s\n' "$latest_rootfs" | grep -Fq ' user_unlocked_after=false '
printf '%s\n' "$latest_rootfs" | grep -Fq \
  'output=Debian-rootfs-access-ok root=/data/local/debian shell=/data/local/debian/bin/sh rw=true'

echo "PASS: /data/local/debian read/write access was proven entirely during BFU."
