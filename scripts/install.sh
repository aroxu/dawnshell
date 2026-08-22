#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
termux_apk="$root_dir/dist/termux-app_0.118.0_apt-android-7_arm64-v8a_debug.apk"
boot_apk="$root_dir/dist/termux-boot_0.8.1_bfu_debug.apk"

for apk in "$termux_apk" "$boot_apk"; do
  if [[ ! -f "$apk" ]]; then
    echo "Missing APK: $apk" >&2
    exit 1
  fi
done

echo "Installed Termux-family packages:"
adb shell pm list packages | grep -E '^package:com\.termux(\.|$)' || true
echo
echo "This script will not uninstall apps or erase Termux data."
echo "Install only after backup and signing-certificate compatibility checks."

if [[ "${TERMUX_BFU_INSTALL_CONFIRMED:-}" != "yes" ]]; then
  echo "Set TERMUX_BFU_INSTALL_CONFIRMED=yes after completing those checks." >&2
  exit 2
fi

adb install -r "$termux_apk"
adb install -r "$boot_apk"
