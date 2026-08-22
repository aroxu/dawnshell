#!/usr/bin/env bash
set -euo pipefail

adb logcat -c
adb reboot
adb wait-for-device

echo "Do not unlock the device. Waiting for locked boot delivery..."
for _ in $(seq 1 60); do
  if adb logcat -d -s TermuxBFU:I '*:S' | grep -q 'LOCKED_BOOT_COMPLETED received'; then
    break
  fi
  sleep 2
done

adb shell dumpsys user | grep -i unlocked || true
adb logcat -d -s TermuxBFU:I '*:S'

adb logcat -d -s TermuxBFU:I '*:S' | grep -q 'LOCKED_BOOT_COMPLETED received'
adb logcat -d -s TermuxBFU:I '*:S' | grep -q 'DE executable probe succeeded'

echo "PASS: locked boot broadcast and DE executable probe observed."

