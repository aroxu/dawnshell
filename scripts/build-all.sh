#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dist_dir="$root_dir/dist"

: "${JAVA_HOME:?Set JAVA_HOME to JDK 17}"
: "${ANDROID_HOME:?Set ANDROID_HOME to an Android SDK containing platforms 34 and 36 plus NDK 29.0.14206865}"
ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$ANDROID_HOME/ndk/29.0.14206865}"
export ANDROID_NDK_HOME

export TERMUX_PACKAGE_VARIANT="apt-android-7"

"$root_dir/termux-boot/scripts/build-bfu-namespace-probe.sh"
"$root_dir/termux-app/gradlew" -p "$root_dir/termux-app" :app:assembleDebug
"$root_dir/termux-boot/gradlew" -p "$root_dir/termux-boot" \
  clean :app:assembleDebug :app:lintDebug :app:testDebugUnitTest

mkdir -p "$dist_dir"
cp "$root_dir/termux-app/app/build/outputs/apk/debug/termux-app_apt-android-7-debug_arm64-v8a.apk" \
   "$dist_dir/termux-app_0.118.0_apt-android-7_arm64-v8a_debug.apk"
cp "$root_dir/termux-boot/app/build/outputs/apk/debug/termux-boot-app_v0.8.1+debug.apk" \
   "$dist_dir/termux-boot_0.8.1_bfu_debug.apk"

sha256sum \
  "$dist_dir/termux-app_0.118.0_apt-android-7_arm64-v8a_debug.apk" \
  "$dist_dir/termux-boot_0.8.1_bfu_debug.apk"

echo "Debug APKs use the public upstream test key. Do not deploy them as a private production signing identity."
