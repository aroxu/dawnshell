#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dist_dir="$root_dir/dist"

: "${JAVA_HOME:?Set JAVA_HOME to JDK 17}"
: "${ANDROID_HOME:?Set ANDROID_HOME to the Android SDK}"
ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$ANDROID_HOME/ndk/29.0.14206865}"
export ANDROID_NDK_HOME

"$root_dir/scripts/build-bfu-namespace-probe.sh"
"$root_dir/gradlew" -p "$root_dir" \
  clean :app:assembleDebug :app:lintDebug :app:testDebugUnitTest

mkdir -p "$dist_dir"
cp "$root_dir/app/build/outputs/apk/debug/dawnshell-app_v0.1.0+debug.apk" \
   "$dist_dir/dawnshell_0.1.0_debug.apk"

sha256sum "$dist_dir/dawnshell_0.1.0_debug.apk"
echo "Package: me.aroxu.dawnshell"
echo "Debug APK uses a public development key; use a private key for production."
