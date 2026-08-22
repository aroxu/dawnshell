#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
boot_apk="$root_dir/termux-boot/app/build/outputs/apk/debug/termux-boot-app_v0.8.1+debug.apk"

if [[ ! -f "$boot_apk" ]]; then
  echo "Missing APK: $boot_apk" >&2
  exit 1
fi

echo "Installed Termux-family packages:"
adb shell pm list packages | grep -E '^package:com\.termux(\.|$)' || true
echo
echo "This script will not uninstall apps or erase Termux data."
echo "Install only after backup and signing-certificate compatibility checks."

if [[ "${TERMUX_BFU_INSTALL_CONFIRMED:-}" != "yes" ]]; then
  echo "Set TERMUX_BFU_INSTALL_CONFIRMED=yes after completing those checks." >&2
  exit 2
fi

adb install -r "$boot_apk"

