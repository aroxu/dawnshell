# DawnShell progress

[한국어](progress.ko.md) · [Glossary](glossary.md)

This file records the current standalone DawnShell implementation only. Obsolete
prototype package names, signing values, APK hashes, and migration notes have been
removed because they do not describe the current product.

## Completed

### Android Direct Boot

- [x] Dedicated package `me.aroxu.dawnshell` and dedicated app UID.
- [x] Direct-Boot-aware `LOCKED_BOOT_COMPLETED` receiver and foreground service.
- [x] DE provisioning for boot settings, public keys, runtime files, and logs.
- [x] BFU root, CE isolation, rootfs, and chroot gates.
- [x] Persistent Debian instance across `USER_UNLOCKED`.
- [x] Duplicate boot and stale supervisor-state prevention.

The implementation follows [Google's Direct Boot guide](https://developer.android.com/privacy-and-security/direct-boot)
and the [AOSP FBE guide](https://source.android.com/docs/security/features/encryption/file-based).

### Debian 13

- [x] Verified Trixie rootfs installation with live logs and atomic publication.
- [x] systemd, D-Bus, OpenSSH, and the `debian` account.
- [x] Public-key-only SSH with direct root login disabled.
- [x] Local `root` and `debian` password management and `su root` support.
- [x] Validated start, stop, restart, status, and rootfs removal.

### Embedded runtime

- [x] Source builds for `armeabi-v7a`, `arm64-v8a`, and `x86_64`.
- [x] Pinned BusyBox, `pkgdetails`, `gpgv` dependency closure, and Debian keys.
- [x] Source URL, version, and SHA-256 records in `SOURCES.lock`.
- [x] BusyBox formatted `stat -c` preflight.
- [x] Default `make -j"$(nproc)"` parallel compilation.

### Kernel and network

- [x] Delegated cgroup v2 plus device BPF probe with isolated v1 fallback.
- [x] Direct Android NIC sharing for Wi-Fi, mobile, and USB Ethernet.
- [x] Default-off direct and VID:PID-scoped exclusive USB passthrough, with v2
  BPF and v1 devices fallback plus normal-stop driver restoration.
- [x] Tailscale route-mark integration.
- [x] Safe host-network-only Docker default and explicit risky bridge controls.
- [x] Android-wide `reboot now` bridge with isolated `systemctl reboot` behavior.

### UI, documentation, and compliance

- [x] Material 3 dashboard and dedicated selectable live-log readers.
- [x] Complete Korean UI resources.
- [x] Random SSH key generation, file export, and generic local-shell commands.
- [x] Friendly Korean and English guides, glossary, and official Android links.
- [x] Removal of obsolete product names and migration guidance.
- [x] MIT application license and preserved third-party source/license obligations.
- [x] GitHub Actions builds, checks, signed tag releases, corresponding source,
  license bundles, metadata, and checksums.

### Hardware video acceleration

- [x] Added a default-off MediaCodec option and isolated `:codec` process.
- [x] Connected bounded BFU retries and persistence across `USER_UNLOCKED`.
- [x] Added API 29+ platform classification and conservative API 24–28 fallback.
- [x] Excluded secure/DRM and silent software fallback while recording AVC/HEVC
  instance creation in DE JSON and logs.
- [x] Added a root-peer-authenticated binary protocol and static Debian client
  for all three supported ABIs.
- [x] Added deterministic AVC decode/I420 checksum and hardware encode/FFmpeg
  self-tests.
- [x] Added FFmpeg demux/mux wrappers for hardware decode and encode while
  preserving bounded packet framing and timestamps.
- [x] Added `memfd`/`SCM_RIGHTS` media transport with bounded socket fallback.
- [x] Added H.264/HEVC-to-H.264 Surface transcoding without returning full YUV
  frames to Debian.
- [x] Added keyframe requests, broker/session statistics, and malformed-request
  isolation checks.
- [x] Added a 720p shared-memory/socket comparison, 1080p30 realtime Surface
  transcode gate, and abrupt-peer resource cleanup test path.
- [x] Verified Exynos AVC/HEVC encoder and decoder instance creation on Android
  16 after first unlock.
- [ ] Verify Exynos AVC hardware instance creation on a locked real device.
- [ ] Verify fixed-vector decode, encode, shared-memory transport, and Surface
  transcode before and after first unlock.
- [ ] Verify 1080p realtime performance, timestamp stability, and resource
  cleanup on the target device.

## Physical-device validation completed

- [x] Android 16 / ARM64 locked-boot broadcast and DE execution.
- [x] BFU Debian systemd and SSH.
- [x] First-unlock continuity.
- [x] cgroup v1 delegation through Docker cgroup initialization.
- [x] Shared host networking and Tailscale routes.

## Remaining validation

- [ ] Full ARMv7 installation and BFU test.
- [ ] Full x86_64 device or emulator test.
- [ ] Five-cycle regression across additional vendor ROMs.
- [ ] Broader Docker bridge backend coverage.
- [ ] Direct/exclusive USB hot-plug, driver restore, serial, libusb, and storage
  validation on physical devices.
- [ ] Long-running memory, mount, and cgroup leak observation.
- [ ] Five-cycle BFU hardware codec regression with
  `BFU_REQUIRE_HARDWARE_CODEC=1`.

See [testing](testing.md) for the current acceptance procedure.
