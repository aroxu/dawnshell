# DawnShell build and release

[한국어](building.ko.md) · [Documentation](README.md) · [License bundle](../LICENSES/README.md)

This guide builds all three embedded native ABIs, verifies the app, and creates
a complete release distribution.

## Requirements

- JDK 17
- Android SDK Platform 34 and Build Tools 34.0.0
- Android NDK `29.0.14206865`
- Git and Bash
- Python 3 for documentation validation
- C compiler, GNU make, Autoconf, Automake, libtool, Bison, GNU gettext,
  GNU awk, patch, sed, tar, gzip, bzip2, xz, and coreutils
- MSYS2 plus Windows OpenSSH when building on Windows

## Clone and configure

```sh
git clone https://github.com/aroxu/dawnshell.git
cd dawnshell

export JAVA_HOME=/path/to/jdk17
export ANDROID_HOME=/path/to/android-sdk
export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/29.0.14206865"
```

DawnShell does not depend on separate Termux repositories. BusyBox,
`pkgdetails`, `gpgv`, debootstrap material, and the namespace launcher are built
from pinned source and patches in this repository.

## Full build

```sh
./scripts/build-all.sh
```

The script builds `armeabi-v7a`, `arm64-v8a`, and `x86_64` bootstrap runtimes,
runs policy and bridge regressions, executes Android lint and unit tests, and
copies the debug APK to `dist/`.

Compilation defaults to `make -j"$(nproc)"`. Limit parallelism when necessary:

```sh
DAWNSHELL_BUILD_JOBS=4 ./scripts/build-all.sh
```

For a local Android-only iteration after building identical native sources:

```sh
DAWNSHELL_SKIP_BOOTSTRAP_SOURCE_BUILD=1 ./scripts/build-all.sh
```

Do not use that shortcut as release evidence. The normal output is:

```text
dist/dawnshell-app_v<version>+debug.apk
```

## Individual checks

```sh
./scripts/test-release-compliance.sh
./scripts/test-compatibility-policy.sh
./scripts/test-docker-ipc-wrapper.sh
./scripts/test-host-usb-policy.sh
./scripts/test-hardware-codec-bridge.sh
./scripts/test-ffmpeg-bridge-plan.sh
./scripts/test-live-codec-pipeline.sh
./scripts/test-gpu-status-tool.sh
./scripts/test-host-reboot-isolation.sh
./scripts/test-rootfs-path-resolution.sh
./scripts/test-lifecycle-control-policy.sh
./scripts/test-documentation.sh
./gradlew :app:lintDebug :app:testDebugUnitTest :app:assembleDebug
```

These prove host-build and static policy properties. Direct Boot broadcasts,
Magisk/SELinux behavior, vendor MediaCodec, and network recovery still require
the [physical-device test plan](testing.md).

## Install a debug build

```sh
./scripts/install.sh
# or
adb install -r dist/dawnshell-app_v<version>+debug.apk
```

Android refuses an update signed by a different key. Uninstalling removes app
DE/CE data and its private SSH key, but does not remove `/data/local/debian`.

## Package a release

Use a clean worktree and a prepared signed APK:

```sh
DAWNSHELL_RELEASE_VERSION=0.3.0 \
  ./scripts/package-release.sh path/to/signed.apk dist/release
```

The output contains the signed APK, corresponding source for the exact commit,
a license archive, build metadata, release notes, and `SHA256SUMS`. The packager
verifies that all required source, patches, configuration, and notices are in
the source archive.

## Signing and GitHub Actions

The public debug key is for development only. Tagged production builds require:

- `DAWNSHELL_RELEASE_KEYSTORE_BASE64`
- `DAWNSHELL_RELEASE_KEY_ALIAS`
- `DAWNSHELL_RELEASE_STORE_PASSWORD`
- `DAWNSHELL_RELEASE_KEY_PASSWORD`

```sh
git tag -s v0.3.0 -m "DawnShell 0.3.0"
git push origin v0.3.0
```

`.github/workflows/build.yml` runs on pull requests, `main`, manual dispatch,
and version tags. It also checks shell scripts, Markdown links, heading anchors,
and English/Korean document pairs. `main` updates the debug-signed `continuous`
release and marks it as the latest release; a
`vMAJOR.MINOR.PATCH` tag builds with private signing, verifies the complete
distribution, and publishes a stable release.

The continuously updated release is intentionally signed with the repository's
public development key. Android can update it only with another APK signed by
that same key. Version tags use the configured private production key instead.

## License compliance

DawnShell application code is MIT licensed. Bundled tools and libraries retain
their upstream licenses. Distribute the corresponding-source and license
archives produced by `scripts/package-release.sh` with every APK.

- [Third-party notices](../bfu-runtime/THIRD_PARTY_NOTICES.md)
- [License bundle layout](../LICENSES/README.md)
- [Pinned sources](../bfu-runtime/sources/SOURCES.lock)
