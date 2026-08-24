#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
apk="${DAWNSHELL_APK:-}"
if [[ -z "$apk" ]]; then
  for candidate in "$root_dir"/dist/dawnshell-app_v*+debug.apk; do
    [[ -f "$candidate" ]] || continue
    if [[ -z "$apk" || "$candidate" -nt "$apk" ]]; then
      apk="$candidate"
    fi
  done
fi

[[ -n "$apk" && -f "$apk" ]] || {
  echo "Missing debug APK in $root_dir/dist (or set DAWNSHELL_APK)" >&2
  exit 1
}

echo "This script does not install or uninstall Android packages."
echo "Pushing the standalone APK to /sdcard/Download for manual installation."
adb push "$apk" "/sdcard/Download/$(basename "$apk")"
