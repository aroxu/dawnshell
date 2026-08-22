# Progress

## 2026-08-22

- [x] Clone current `master` of termux-app, termux-boot, and termux-packages.
- [x] Pin and record all three upstream HEAD commits.
- [x] Confirm target SDK 28 in Termux and Termux:Boot.
- [x] Confirm shared UID `com.termux` and identical upstream debug keystore files.
- [x] Trace BootReceiver -> JobScheduler -> BootJobService -> TermuxService.
- [x] Confirm Termux CE and prefix paths are hardcoded upstream.
- [x] Confirm `USER_UNLOCKED` requires a runtime receiver.
- [x] Add Direct-Boot-aware locked boot receiver and BFU foreground service.
- [x] Add Device Protected settings/provisioning UI.
- [x] Add DE layout and direct executable probe.
- [x] Preserve AFU scheduling and add unlock/boot duplicate suppression.
- [x] Persist every `LOCKED_BOOT_COMPLETED` receipt in the DE-only
  `files/bfu-boot.log` marker and validate a fresh line in the test script.
- [x] Verify Android command-line-tools archive SHA-256 against the official value.
- [x] Build and sign the Termux:Boot debug APK with portable JDK 17 / SDK 34.
- [x] Verify final APK manifest, target SDK 28, Direct Boot components, and signature.
- [x] Run Gradle lint (0 errors; 2 remaining upstream/design warnings) and unit-test task
  (no unit-test sources exist upstream).
- [x] Install Android Platform 36, Build Tools 35/36, and NDK 29.0.14206865.
- [x] Build Termux 0.118.0 `apt-android-7` split and universal debug APKs.
- [x] Select and stage the Note 8 `arm64-v8a` Termux APK with the BFU Boot APK.
- [x] Verify both APKs have target SDK 28, shared UID `com.termux`, and an identical
  signing-certificate digest.
- [x] Verify `LOCKED_BOOT_COMPLETED`, DE storage, foreground service, DE native
  execution, and `USER_UNLOCKED` handoff on the physical SM-N950N / Android 16.
- [x] Verify PID, mount, IPC, UTS, and cgroup namespace creation on kernel 4.4.302.
- [x] Verify a `--mount-proc` PID-namespace helper becomes PID 1 with an isolated
  `/proc` process view.
- [x] Replace the BFU Dropbear milestone with the Debian 12/systemd boot target.
- [x] Add bounded BFU `su -c id` probing and DE-persistent root result logging.
- [x] Remove unlock-time BFU service shutdown; unlock now performs AFU handoff only.
- [ ] Verify Debian gate 1: BFU root probe returns `uid=0` on the physical Note 8.
- [ ] Verify Debian gate 2: BFU access to the selected Debian rootfs.
- [ ] Implement and verify namespace/mount launcher and Debian chroot.
- [ ] Start systemd as namespace PID 1 and verify D-Bus/systemctl.
- [ ] Cold-boot enabled Debian SSH before first unlock.

## Build environment note

The host had only JDK 26, while Gradle 8.5 failed on class-file major version 70.
A portable Temurin JDK 17 and checksummed Android command-line tools were placed in
the ignored `.tools` directory. After explicit user acceptance, Platform 34 and
Build Tools 34.0.0 were installed. The generated debug APK is
`termux-boot/app/build/outputs/apk/debug/termux-boot-app_v0.8.1+debug.apk` with
SHA-256 `78BE1637EBA6DC25925EFDA245807A04F04F04E96FC4C78621F5CA32792FA920`.

The Direct Boot and namespace foundation was validated on the physical target by
the device owner. The newly added Magisk root probe still requires a fresh BFU
device run.

The local install pair is staged under ignored `dist/` with these hashes:

```text
31B9A5166CC0C3912D3840D5F14A640C841E1F259886372A5173B0FF88E0A1C6  termux-app_0.118.0_apt-android-7_arm64-v8a_debug.apk
78BE1637EBA6DC25925EFDA245807A04F04F04E96FC4C78621F5CA32792FA920  termux-boot_0.8.1_bfu_debug.apk
```
