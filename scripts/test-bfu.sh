#!/usr/bin/env bash
set -euo pipefail

marker_path="/data/user_de/0/me.aroxu.termux.bfu/files/bfu-boot.log"

marker_count() {
  adb shell run-as me.aroxu.termux.bfu cat "$marker_path" 2>/dev/null \
    | grep -c '^LOCKED_BOOT_COMPLETED ' || true
}

marker_count_before="$(marker_count)"

adb logcat -c
adb reboot
adb wait-for-device

echo "Do not unlock the device. Waiting for locked boot delivery..."
marker_count_after="$marker_count_before"
for _ in $(seq 1 60); do
  marker_count_after="$(marker_count)"
  if (( marker_count_after > marker_count_before )); then
    break
  fi
  sleep 2
done

adb shell dumpsys user | grep -i unlocked || true
adb logcat -d -s TermuxBFU:I '*:S'
adb shell run-as me.aroxu.termux.bfu cat "$marker_path"

(( marker_count_after > marker_count_before ))
adb logcat -d -s TermuxBFU:I '*:S' | grep -q 'LOCKED_BOOT_COMPLETED received'
adb logcat -d -s TermuxBFU:I '*:S' | grep -q 'DE executable probe succeeded'

echo "PASS: fresh DE locked-boot marker, receiver log, and DE executable probe observed."
