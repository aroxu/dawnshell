# Termux BFU

Direct Boot bootstrap for starting a root-owned Debian 13 Trixie arm64 environment with
systemd before the first user unlock. Normal Termux remains an AFU management
frontend, not the server runtime.

The project does not unlock, bind-mount over, copy, or otherwise bypass Termux CE
storage. BFU state belongs only in the Device Protected Storage returned by
`createDeviceProtectedStorageContext()`.

## Current status

The Direct Boot foundation has been verified on the target SM-N950N running
Android 16. The `bfu/direct-boot-poc` branch in `termux-boot` currently:

- receives and logs `LOCKED_BOOT_COMPLETED` with tag `TermuxBFU`;
- appends each locked-boot receipt to the persistent DE marker
  `files/bfu-boot.log` before any BFU setting or service checks;
- starts a Direct-Boot-aware foreground service when BFU mode is enabled;
- provisions `files/bfu/{bin,etc,home,run,scripts,tmp}` in DE storage;
- directly executes the DE file `files/bfu/scripts/test.sh`;
- runs a bounded `su -c id` probe and persists its sanitized result in
  `files/bfu-root.log`;
- provides an unlock-time **Request / verify Magisk root permission** action that
  opens the normal Magisk authorization flow, verifies `uid=0`, and records the
  AFU-only result separately from BFU evidence;
- shows the latest persistent root result in the launcher after unlock, without
  requiring BFU ADB;
- after BFU root succeeds, probes `/data/local/debian` directory, shell mode, and
  temporary read/write access and records `files/bfu-rootfs.log`;
- offers an AFU-only, checksum-pinned Debian 13 Trixie arm64 rootfs installer that uses
  a private mount namespace and publishes only a fully validated staging tree;
- streams installer stdout/stderr to a DE-persistent log shown in a selectable,
  console-style view; live follow pauses while selecting text or reading older
  lines;
- dynamically receives `USER_UNLOCKED` and hands off to the unchanged normal
  Termux boot-script scheduling path without stopping the BFU service;
- also handles `BOOT_COMPLETED` as an AFU fallback and suppresses the unlock/boot
  race for 60 seconds;
- stores BFU settings in Device Protected SharedPreferences.

The former BFU Dropbear milestone has been superseded. Pre-authorized Magisk root
during BFU is verified on-device. The latest physical-device probe correctly
reported `stage=root_missing`; the app now provides the rootfs preparation path,
but gate 2 remains open until the resulting tree passes a fresh locked-boot
probe. Only after it passes will namespaces, chroot, and systemd follow. See
[rootfs installation](docs/rootfs-installation.md) and
[Debian systemd plan](docs/debian-systemd.md).

## Built APK pair

Both debug APKs were successfully built on 2026-08-22 with the byte-identical
upstream `testkey_untrusted.jks` files:

| APK | Target/ABI | SHA-256 |
| --- | --- | --- |
| `dist/termux-app_0.118.0_apt-android-7_arm64-v8a_debug.apk` | target 28 / arm64-v8a | `31B9A5166CC0C3912D3840D5F14A640C841E1F259886372A5173B0FF88E0A1C6` |
| `dist/termux-boot_0.8.1_bfu_debug.apk` | target 28 / no native ABI | `B999BF072A81B1BF0F73B06E3B5864286A4B343D511372CB3B6527FE04E044CB` |

Both APKs declare `sharedUserId=com.termux` and have signing-certificate SHA-256
`B6DA01480EEFD5FBF2CD3771B8D1021EC791304BDD6C4BF41D3FAABAD48EE5E1`.
They verify with APK signature schemes v1 and v2.

## Magisk authorization

The Debian launcher requires root on every cold boot. Open Termux:Boot while
Android is unlocked and press **Request / verify Magisk root permission**. In the
Magisk prompt choose the permanent/forever duration. The button proves that root
works at that moment; only the next locked-boot `bfu-root.log` entry proves that
the saved policy is usable during BFU.

Magisk policy is keyed by Linux UID. Because Termux and Termux:Boot use the
shared UID `com.termux`, allowing this request grants root to every trusted,
same-signature app installed under that UID, not only the Boot UI. The app lists
those packages before requesting root.

The APKs in `dist/` are local ignored build artifacts, not committed binaries.
The upstream debug key is public and must not be treated as a private production
identity. This pair also cannot update or coexist with F-Droid-signed Termux apps.

## Upstream snapshots

| Repository | Branch | Commit |
| --- | --- | --- |
| `termux/termux-app` | `master` | `3df69d1da197dd9bd71a3bafd902dffd720576b4` |
| `termux/termux-boot` | `master` | `a8493bd6ba016bc370af34aa65fcbe065cc00ced` |
| `termux/termux-packages` | `master` | `84d74e940acd959cb5ebfdb38a012477f05f531a` |

Snapshots were fetched on 2026-08-22.

## Build prerequisites

- JDK 17
- Android SDK Platform 34 and Build Tools 34.0.0 for Termux:Boot
- Android SDK Platform 36, Build Tools 35.0.0, and NDK 29.0.14206865 for Termux
- ADB for device tests
- one signing key shared by Termux and every installed Termux plugin

Both upstream projects currently target SDK 28. Do not raise that value as part
of this proof of concept; API 29 applies the app-data `execve()` W^X restriction.

## Signing and migration warning

`termux-app` and `termux-boot` both declare `android:sharedUserId="com.termux"`.
Android therefore requires matching signing certificates. The checked-in upstream
debug keystores are byte-identical, but they are public, explicitly untrusted test
keys and must never be used as a private production identity.

Before replacing an F-Droid installation:

1. In existing Termux, save `$HOME`, `$PREFIX/etc`, `pkg list-installed`, SSH keys,
   and app-specific configuration to storage outside the app sandbox.
2. Verify that the backup can be read from another machine or app.
3. Uninstall Termux and every plugin signed by the old source.
4. Build and sign Termux, Termux:Boot, and required plugins with one private custom
   key, then install all of them from that set.
5. Restore normal Termux CE data only after launching and bootstrapping custom
   Termux. Never restore CE credentials into the BFU DE tree.

See [architecture](docs/architecture.md), [security](docs/security.md),
[testing](docs/testing.md), [rootfs installation](docs/rootfs-installation.md),
[Debian systemd plan](docs/debian-systemd.md), and [progress](docs/progress.md).
