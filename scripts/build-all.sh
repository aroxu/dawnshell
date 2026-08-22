#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${JAVA_HOME:?Set JAVA_HOME to JDK 17}"
: "${ANDROID_HOME:?Set ANDROID_HOME to an Android SDK containing platform 34}"

"$root_dir/termux-boot/gradlew" -p "$root_dir/termux-boot" :app:assembleDebug
"$root_dir/termux-app/gradlew" -p "$root_dir/termux-app" :app:assembleDebug

echo "Debug APKs use the public upstream test key. Do not deploy them as a private production signing identity."

