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
- [x] Add an unlock-time UI reader for the last DE root result; it never reruns the
  probe or substitutes AFU output for BFU evidence.
- [x] Remove unlock-time BFU service shutdown; unlock now performs AFU handoff only.
- [x] Verify Debian gate 1 on-device: `/system/xbin/su`, `exit=0`, `uid=0(root)`,
  Magisk SELinux context, and locked state before/after the probe.
- [x] Add an AFU-only Magisk authorization/verification button with a shared-UID
  scope warning and a DE log that cannot be confused with BFU evidence.
- [x] Implement gated `/data/local/debian` directory, shell-mode, and temporary
  read/write probe with a DE-persistent result.
- [x] Confirm on-device gate-2 probe failure is exactly `stage=root_missing`, not
  a BFU root, DE, or SELinux regression.
- [x] Add an AFU-only upstream Debian rootfs installer with pinned artifacts,
  signature enforcement, private mounts, staging validation, and no overwrite.
- [x] Add a DE-persistent installer status/log and a one-second live tail in the
  Termux:Boot activity.
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
SHA-256 `8A22D89D80338318DAD708C0BE2E218F0304559BA546AD966AD3468031B42E3D`.

The Direct Boot and namespace foundation was validated on the physical target by
the device owner. Magisk root was subsequently proven entirely during BFU; the
next physical-device action is running the new AFU rootfs installer and repeating
the locked-boot rootfs accessibility probe.

The local install pair is staged under ignored `dist/` with these hashes:

```text
31B9A5166CC0C3912D3840D5F14A640C841E1F259886372A5173B0FF88E0A1C6  termux-app_0.118.0_apt-android-7_arm64-v8a_debug.apk
8A22D89D80338318DAD708C0BE2E218F0304559BA546AD966AD3468031B42E3D  termux-boot_0.8.1_bfu_debug.apk
```
