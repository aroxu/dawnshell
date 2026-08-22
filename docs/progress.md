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
- [x] Verify Android command-line-tools archive SHA-256 against the official value.
- [x] Build and sign the Termux:Boot debug APK with portable JDK 17 / SDK 34.
- [x] Verify final APK manifest, target SDK 28, Direct Boot components, and signature.
- [x] Run Gradle lint (0 errors; 2 remaining upstream/design warnings) and unit-test task
  (no unit-test sources exist upstream).
- [ ] Install the APK with a signature-compatible Termux set.
- [ ] Verify milestone 1 on the physical Note 8.
- [ ] Verify milestone 2 on the physical Note 8.
- [ ] Build and integrate server-only ARM64 Dropbear.
- [ ] Verify milestone 3 SSH on the physical Note 8.

## Build environment note

The host had only JDK 26, while Gradle 8.5 failed on class-file major version 70.
A portable Temurin JDK 17 and checksummed Android command-line tools were placed in
the ignored `.tools` directory. After explicit user acceptance, Platform 34 and
Build Tools 34.0.0 were installed. The generated debug APK is
`termux-boot/app/build/outputs/apk/debug/termux-boot-app_v0.8.1+debug.apk` with
SHA-256 `CB4FA7EFEA7A12A6B7D94A6C10EEAF456EFE956B3ABADDE2B6472906E1D014D0`.

No ADB device was connected, so physical milestone validation remains pending.
