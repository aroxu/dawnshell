# DawnShell

[한국어](README.ko.md)

[![Build and release](https://github.com/aroxu/dawnshell/actions/workflows/build.yml/badge.svg)](https://github.com/aroxu/dawnshell/actions/workflows/build.yml)

DawnShell starts a Debian 13 system and SSH server on Android before the first
unlock after reboot. Its package name is `me.aroxu.dawnshell`.

New users should start with the [installation guide](docs/installation.md), then
read the [user manual](docs/user-guide.md). The [glossary](docs/glossary.md)
expands every common abbreviation.

## What it does

The period after reboot and before the first PIN, pattern, or password entry is
BFU (Before First Unlock). DawnShell uses Android's official Direct Boot support
to start Debian during that period. See [Google's Direct Boot guide](https://developer.android.com/privacy-and-security/direct-boot)
and [AOSP's File-Based Encryption guide](https://source.android.com/docs/security/features/encryption/file-based).

After the first unlock—AFU (After First Unlock)—the same Debian and SSH instance
continues running. The unlock event does not stop or restart it.

Main features include:

- verified Debian 13 Trixie rootfs installation;
- BFU startup of systemd and a public-key-only OpenSSH server;
- shared Android Wi-Fi, mobile, and USB Ethernet interfaces;
- Material 3 controls for setup, lifecycle, accounts, SSH keys, and logs;
- source-built bootstrap binaries for `armeabi-v7a`, `arm64-v8a`, and `x86_64`.

## Security boundaries

| Location | Availability | Contents |
| --- | --- | --- |
| App DE (Device Encrypted storage) | Before unlock | Boot settings, public keys, logs, minimal runtime |
| App CE (Credential Encrypted storage) | After first unlock | SSH client private key |
| `/data/local/debian` | Through root access | Complete Debian rootfs |

Google recommends keeping only data genuinely needed during Direct Boot in DE
storage. Passwords, tokens, and private keys must not be placed there. See
[Google's DE and CE guidance](https://developer.android.com/privacy-and-security/direct-boot#access_device_encrypted).

OpenSSH listens on TCP 22 and accepts the registered key for the `debian` user.
SSH password authentication and direct root login are disabled. A user can set a
local root password in the app and run `su root` after connecting as `debian`.

Debian shares the Android kernel and network. It must not be treated as a fully
isolated virtual machine.

## Requirements

- Android 7.0 / API 24 or newer
- File-Based Encryption (FBE)
- Magisk or a compatible `su`, with permanent root approval for DawnShell
- `armeabi-v7a`, `arm64-v8a`, or `x86_64`

See [Google's Android ABI guide](https://developer.android.com/ndk/guides/abis)
for the CPU architecture names.

## Boot flow

```text
Android boot
  -> LOCKED_BOOT_COMPLETED
  -> verify app DE storage and pre-authorized root
  -> verify /data/local/debian
  -> prepare private mount/PID/UTS/cgroup namespaces
  -> start Debian systemd as namespace PID 1
  -> start OpenSSH

First unlock
  -> record USER_UNLOCKED
  -> keep the same Debian and SSH instance running
```

The broadcast names are documented by the
[Android Intent API](https://developer.android.com/reference/android/content/Intent#ACTION_LOCKED_BOOT_COMPLETED).

## Kernel and Docker policy

DawnShell probes capabilities instead of relying only on the kernel version. It
tries cgroup v2 first and falls back to v1 when required. The recommended setting
is **Automatic: v2, then v1**.

Docker defaults to **safe host-network-only** mode. Container bridge networking
can change Android-wide firewall, NAT, forwarding, and routes. Enable it only
after reading the in-app warning and preparing a separate recovery path.

## Build

Requirements:

- JDK 17
- Android SDK Platform 34
- Android NDK `29.0.14206865`
- Bash, GNU make, a C compiler, Autoconf, Automake, libtool, Bison, GNU gettext,
  GNU awk, patch, sed, tar, and coreutils
- MSYS2 with those tools when building on Windows

```sh
export JAVA_HOME=/path/to/jdk17
export ANDROID_HOME=/path/to/android-sdk
export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/29.0.14206865"
./scripts/build-all.sh
```

Compilation defaults to `make -j"$(nproc)"`. Set `DAWNSHELL_BUILD_JOBS` to cap
parallelism. The default output is `dist/dawnshell_0.2.0_debug.apk`.

The public debug key is for development only. Production APKs require a private
signing key; see [Google's app-signing guide](https://developer.android.com/studio/publish/app-signing).

## GitHub Actions and releases

`.github/workflows/build.yml` builds and checks all three native ABIs and the
Android app. Artifacts include the APK, corresponding source, licenses, build
metadata, and `SHA256SUMS`.

Tags matching `vMAJOR.MINOR.PATCH` run the GitHub Release workflow. Release builds
require these Actions secrets:

- `DAWNSHELL_RELEASE_KEYSTORE_BASE64`
- `DAWNSHELL_RELEASE_KEY_ALIAS`
- `DAWNSHELL_RELEASE_STORE_PASSWORD`
- `DAWNSHELL_RELEASE_KEY_PASSWORD`

```sh
git tag -s v0.2.0 -m "DawnShell 0.2.0"
git push origin v0.2.0
```

DawnShell code is MIT licensed. Bundled tools retain their upstream licenses;
see [third-party notices](bfu-runtime/THIRD_PARTY_NOTICES.md) and
`LICENSES/README.md`.

## Documentation

- [Installation guide](docs/installation.md)
- [User manual](docs/user-guide.md)
- [Glossary](docs/glossary.md)
- [Architecture](docs/architecture.md)
- [Security model](docs/security.md)
- [Testing](docs/testing.md)
- [Rootfs installation](docs/rootfs-installation.md)
- [Debian systemd](docs/debian-systemd.md)
- [Progress](docs/progress.md)
