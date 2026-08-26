# DawnShell embedded bootstrap runtime

[한국어](README.ko.md) · [Documentation](../docs/README.md) · [Build and release](../docs/building.md)

This directory contains the pinned sources, patches, configuration, and build
metadata for the minimal tools used to install and start Debian 13 on Android.

Supported Android ABIs are `armeabi-v7a`, `arm64-v8a`, and `x86_64`, matching
Debian `armhf`, `arm64`, and `amd64`. See
[Google's Android ABI guide](https://developer.android.com/ndk/guides/abis).

Each runtime contains BusyBox, Debian `pkgdetails`, statically linked `gpgv`, and
the namespace launcher. BusyBox formatted `stat -c` support is a required
installer preflight.

- Pinned sources and hashes: `sources/SOURCES.lock`
- Android patches: `patches/`
- Minimal build configuration: `config/`
- Build script: `../scripts/build-bootstrap-runtime.sh`
- Third-party licensing: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)

Users do not copy these files to a phone manually. The app provisions only the
verified output matching the current ABI into DE storage. After any source
change, run `scripts/build-all.sh` so all ABI and license checks run together.

Never commit device keys, PIDs, logs, or `authorized_keys`. Runtime state belongs
only in app Device Encrypted storage or the reviewed Debian rootfs.
