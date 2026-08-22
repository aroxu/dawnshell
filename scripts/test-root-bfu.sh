#!/usr/bin/env bash
set -euo pipefail

boot_log="/data/user_de/0/com.termux.boot/files/bfu-boot.log"
root_log="/data/user_de/0/com.termux.boot/files/bfu-root.log"

line_count() {
  local path="$1"
  adb shell run-as com.termux.boot cat "$path" 2>/dev/null \
    | wc -l | tr -d '[:space:]' || true
}

boot_count_before="$(line_count "$boot_log")"
root_count_before="$(line_count "$root_log")"

adb logcat -c
adb reboot
adb wait-for-device

echo "Do not unlock the device. Waiting for a fresh BFU root probe..."
boot_count_after="$boot_count_before"
root_count_after="$root_count_before"
for _ in $(seq 1 60); do
  boot_count_after="$(line_count "$boot_log")"
  root_count_after="$(line_count "$root_log")"
  if (( boot_count_after > boot_count_before && root_count_after > root_count_before )); then
    break
  fi
  sleep 2
done

adb shell dumpsys user | grep -i unlocked || true
adb shell run-as com.termux.boot cat "$boot_log"
root_results="$(adb shell run-as com.termux.boot cat "$root_log")"
printf '%s\n' "$root_results"

(( boot_count_after > boot_count_before ))
(( root_count_after > root_count_before ))
latest_result="$(printf '%s\n' "$root_results" | tail -n 1 | tr -d '\r')"
printf '%s\n' "$latest_result" | grep -q '^ROOT_PROBE '
printf '%s\n' "$latest_result" | grep -q ' exit=0 '
printf '%s\n' "$latest_result" | grep -q ' root=true '
printf '%s\n' "$latest_result" | grep -q 'output=uid=0('

echo "PASS: BFU su returned uid=0 and the result was persisted in DE storage."
