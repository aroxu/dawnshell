#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
apk="$root_dir/dist/dawnshell_0.2.1_debug.apk"

[[ -f "$apk" ]] || {
  echo "Missing APK: $apk" >&2
  exit 1
}

echo "This script does not install or uninstall Android packages."
echo "Pushing the standalone APK to /sdcard/Download for manual installation."
adb push "$apk" /sdcard/Download/dawnshell_0.2.1_debug.apk
