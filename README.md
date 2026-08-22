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
- fails closed unless a root probe performed while locked also proves that the
  normal Termux CE home paths cannot be listed; the result is persisted in
  `files/bfu-ce-isolation.log` without recording directory contents;
- after BFU root succeeds, probes `/data/local/debian` directory, shell mode, and
  temporary read/write access and records `files/bfu-rootfs.log`;
- after the storage gate succeeds, runs a SHA-256-pinned ARM64 helper that creates
  private mount/PID/UTS/IPC/cgroup namespaces and proves Debian `/bin/sh` is PID 1
  with a matching private `/proc`; the result is stored in
  `files/bfu-debian-runtime.log`;
- offers an AFU-only, checksum-pinned Debian 13 Trixie arm64 rootfs installer that uses
  a private mount namespace and publishes only a fully validated staging tree;
- streams installer stdout/stderr to a DE-persistent log shown in a selectable,
  console-style view; live follow pauses while selecting text or reading older
  lines;
- validates bare SSH public-key lines in the app, rejects key options/private
  material, and stores the normalized `authorized_keys` source only below
  app-owned Device Protected Storage;
- offers an AFU-only Debian 13 configurator that installs systemd 257, D-Bus, and
  OpenSSH, creates the unprivileged `debian` account, disables password/root
  authentication, enables `ssh.service` on TCP 22 plus an independent oneshot
  boot-proof unit, and publishes a root-owned BFU-ready marker only after validation;
- provides idempotent native `start/restart/status/health/stop` controls protected by a
  lifetime `flock` plus `/proc` start-time and executable-inode identity checks;
- starts `/sbin/init` as PID 1 in private mount/PID/UTS/IPC/cgroup namespaces,
  exposes only a dedicated cgroup-v1 `name=systemd` subtree, and deliberately
  creates no network namespace;
- starts that supervisor automatically after the locked-boot root, rootfs, and
  namespace gates pass, while retaining explicit maintenance controls and live
  DE lifecycle logs in the activity;
- records and validates PID/mount/UTS/IPC/cgroup namespace identities, proves the
  network namespace is still Android's, and enters the live PID/mount namespaces
  for bounded `systemctl`, D-Bus, enabled-unit marker, `ssh.service`, and TCP 22
  health checks;
- creates a private bind mount for the chroot root, keeps `/sys` and `/proc/sys`
  read-only, and includes a root-only test operation for proving Debian
  `systemctl poweroff`, `systemctl reboot`, and `/usr/sbin/shutdown` cannot reboot
  Android;
- dynamically receives `USER_UNLOCKED` and hands off to the unchanged normal
  Termux boot-script scheduling path without stopping the BFU service;
- also handles `BOOT_COMPLETED` as an AFU fallback and uses the kernel boot ID
  (Android's boot counter as fallback) to dispatch the normal Termux script set
  at most once per Android boot;
- stores BFU settings in Device Protected SharedPreferences.

The former BFU Dropbear milestone has been superseded. Pre-authorized Magisk root
during BFU and Debian 13 Trixie installation are verified on-device. The source
now implements the long-lived systemd/OpenSSH stage, service health checks,
shutdown isolation harness, and ten-cycle evidence collector. Per the test plan,
all remaining physical gates will be run together after implementation is frozen;
source/build success is not counted as device proof. See
[rootfs installation](docs/rootfs-installation.md) and
[Debian systemd plan](docs/debian-systemd.md).

## Built APK pair

The staged debug pair uses the byte-identical upstream `testkey_untrusted.jks`
files. Termux is unchanged from 2026-08-22; Termux:Boot was rebuilt on 2026-08-23:

| APK | Target/ABI | SHA-256 |
| --- | --- | --- |
| `dist/termux-app_0.118.0_apt-android-7_arm64-v8a_debug.apk` | target 28 / arm64-v8a | `31B9A5166CC0C3912D3840D5F14A640C841E1F259886372A5173B0FF88E0A1C6` |
| `dist/termux-boot_0.8.1_bfu_debug.apk` | target 28 / embedded arm64 BFU helper | `CB10E33BCCA5EB133B622B75C44BF8D21F2B96D95FA2D1DDC2A69E5D216176B0` |

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
- Android NDK 29.0.14206865 to reproduce the Termux:Boot namespace helper
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
