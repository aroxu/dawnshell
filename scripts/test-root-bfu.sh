#!/usr/bin/env bash
set -euo pipefail

boot_log="/data/user_de/0/me.aroxu.dawnshell/files/bfu-boot.log"
root_log="/data/user_de/0/me.aroxu.dawnshell/files/bfu-root.log"

line_count() {
  local path="$1"
  adb shell run-as me.aroxu.dawnshell cat "$path" 2>/dev/null \
    | wc -l | tr -d '[:space:]' || true
}

boot_count_before="$(line_count "$boot_log")"
root_count_before="$(line_count "$root_log")"

adb logcat -c
adb reboot

wait_seconds="${BFU_WAIT_SECONDS:-30}"
echo "Keep the device locked for ${wait_seconds}s; BFU ADB is not expected on this ROM."
sleep "$wait_seconds"
echo "Now unlock the device once so ADB can reconnect and the DE logs can be read."
adb wait-for-device

boot_count_after="$(line_count "$boot_log")"
root_count_after="$(line_count "$root_log")"

adb shell dumpsys user | grep -i unlocked || true
adb shell run-as me.aroxu.dawnshell cat "$boot_log"
root_results="$(adb shell run-as me.aroxu.dawnshell cat "$root_log")"
printf '%s\n' "$root_results"

(( boot_count_after > boot_count_before ))
(( root_count_after > root_count_before ))
latest_result="$(printf '%s\n' "$root_results" | tail -n 1 | tr -d '\r')"
printf '%s\n' "$latest_result" | grep -q '^ROOT_PROBE '
printf '%s\n' "$latest_result" | grep -q ' exit=0 '
printf '%s\n' "$latest_result" | grep -q ' root=true '
printf '%s\n' "$latest_result" | grep -q ' user_unlocked_before=false '
printf '%s\n' "$latest_result" | grep -q ' user_unlocked_after=false '
printf '%s\n' "$latest_result" | grep -q 'output=uid=0('

echo "PASS: su returned uid=0 entirely during BFU and the result persisted in DE storage."
