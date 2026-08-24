#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dist_dir="$root_dir/dist"

: "${JAVA_HOME:?Set JAVA_HOME to JDK 17}"
: "${ANDROID_HOME:?Set ANDROID_HOME to the Android SDK}"
ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$ANDROID_HOME/ndk/29.0.14206865}"
export ANDROID_NDK_HOME

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    # The OpenSSH interoperability unit test runs Windows ssh-keygen. MSYS2's
    # default PATH contains System32 but not its OpenSSH subdirectory.
    windows_openssh=/c/Windows/System32/OpenSSH
    if [[ -x "$windows_openssh/ssh-keygen.exe" ]]; then
      export PATH="$windows_openssh:$PATH"
    fi
    ;;
esac

if [[ "${DAWNSHELL_SKIP_BOOTSTRAP_SOURCE_BUILD:-0}" != 1 ]]; then
  "$root_dir/scripts/build-bootstrap-runtime.sh"
fi
"$root_dir/scripts/test-compatibility-policy.sh"
"$root_dir/scripts/test-docker-ipc-wrapper.sh"
"$root_dir/scripts/test-host-usb-policy.sh"
"$root_dir/scripts/test-hardware-codec-bridge.sh"
"$root_dir/scripts/test-ffmpeg-bridge-plan.sh"
"$root_dir/scripts/test-host-reboot-isolation.sh"
"$root_dir/scripts/test-rootfs-path-resolution.sh"
"$root_dir/scripts/test-lifecycle-control-policy.sh"
"$root_dir/gradlew" -p "$root_dir" \
  clean :app:assembleDebug :app:lintDebug :app:testDebugUnitTest

mkdir -p "$dist_dir"
apk_path="$(find "$root_dir/app/build/outputs/apk/debug" -maxdepth 1 \
    -type f -name '*.apk' -print -quit)"
[[ -n "$apk_path" && -s "$apk_path" ]]
output_apk="$dist_dir/$(basename "$apk_path")"
cp "$apk_path" "$output_apk"

sha256sum "$output_apk"
echo "Package: me.aroxu.dawnshell"
echo "Debug APK uses a public development key; use a private key for production."
