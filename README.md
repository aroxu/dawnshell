# DawnShell

Standalone Android Direct Boot controller for a root-owned Debian 13 Trixie
arm64 environment. Its Android package is `me.aroxu.dawnshell` and its launcher
name is **DawnShell**.

The app starts Debian systemd and public-key-only OpenSSH before the first Android
unlock. Debian remains alive after `USER_UNLOCKED`. It does not execute normal
Termux `~/.termux/boot` scripts and does not call `TermuxService`; use the upstream
Termux:Boot app separately if those AFU features are needed.

## Boundaries

- No `sharedUserId`; DawnShell has its own Android UID and Magisk policy.
- App control files, public authorized keys, and logs live under the app's Device
  Protected Storage returned by `createDeviceProtectedStorageContext()`.
- The Debian rootfs lives at `/data/local/debian` and is not copied into CE or DE.
- OpenSSH accepts only the configured public keys on TCP 22. Password and root
  SSH login remain disabled.
- AFU-only controls may set local `debian` and `root` passwords. `su root` then
  works through a setuid-enabled private rootfs mount; the Android host `/data`
  mount is never remounted.
- The initial rootfs installer currently uses an existing Termux `$PREFIX` only
  for AFU `debootstrap`, `mount`, and related bootstrap tools. BFU boot and the
  running Debian/systemd/OpenSSH environment do not depend on Termux CE storage.

## Termux requirement

**A working normal Termux installation is required by the currently supported
setup and management workflow.** DawnShell is a separate Android package and
its locked-boot runtime is independent, but the app currently uses tools from
`/data/data/com.termux/files/usr` for:

- the first Debian rootfs installation;
- Debian systemd/OpenSSH package installation and reconfiguration;
- localhost SSH access and operational diagnostics from the phone.

Prepare normal Termux after unlock with:

```sh
pkg install debootstrap util-linux mount-utils openssh
```

After Debian has been installed and configured, BFU systemd/OpenSSH can start
without launching Termux and without reading Termux CE storage. Nevertheless,
this project currently treats Termux as a required companion for supported
reinstallation, reconfiguration, recovery, and day-to-day administration. A
future bundled bootstrap toolchain would be required before claiming a fully
Termux-independent installation and management path.

## Implemented flow

```text
LOCKED_BOOT_COMPLETED
  -> directBootAware BootReceiver
  -> directBootAware foreground service
  -> app-owned CE-isolation sentinel check
  -> pre-authorized Magisk root probe
  -> /data/local/debian rootfs gate
  -> private mount/PID/UTS/cgroup namespaces
     (Android IPC and network retained for Samsung Linux 4.4 compatibility)
  -> direct shared-NIC networking with a managed Tailscale fwmark route shim
  -> Debian 13 systemd as namespace PID 1
  -> D-Bus + ssh.service + boot-proof service

USER_UNLOCKED
  -> event recorded
  -> the same Debian/systemd/SSH instance continues unchanged
```

The launcher uses a Material 3 dashboard for rootfs installation, system
configuration, lifecycle and account controls, and SSH key actions. Logs are
kept out of the dashboard: a live log index opens each stream in a dedicated
full-screen, selectable, copyable view that refreshes once per second without
pulling the reader away from older lines. The launcher also provides a copyable
localhost SSH command, a root-only `reboot now` bridge that reboots Android, and
a two-stage destructive control for permanently deleting exactly
`/data/local/debian` after stopping and verifying the supervisor. The client
private key is kept in this app's CE storage; only its public key enters DE and
Debian.

## Compatibility and migration

DawnShell intentionally has no compatibility or automatic migration layer for
the earlier BFU-enabled Termux:Boot build. Its package, DE/CE state, rootfs
markers, systemd units, hostname, control files, SSH identity, and APK names all
use the DawnShell namespace. Stop the old supervisor before performing a manual
migration; never start two supervisors against the same `/data/local/debian`.

## Build

Requirements:

- JDK 17
- Android SDK Platform 34
- Android NDK `29.0.14206865`
- Git Bash or another Bash environment on Windows

```sh
export JAVA_HOME=/path/to/jdk17
export ANDROID_HOME=/path/to/android-sdk
./scripts/build-all.sh
```

Output:

```text
dist/dawnshell_0.1.0_debug.apk
```

The debug keystore is public and unsuitable for production. Sign production
builds with a private key. Because the app has no shared UID, its signing key does
not need to match Termux or Termux:Boot.

`scripts/install.sh` only pushes the APK to `/sdcard/Download`; installation is
manual and the script never uninstalls apps or erases data.

## Validation

The final harness defaults to five cold cycles:

```sh
BFU_PHONE_HOST=PHONE_IP \
BFU_SSH_KEY=/path/to/dawnshell-ed25519 \
BFU_EXPECT_CE_READABLE_OVERRIDE=1 \
./scripts/test-final-bfu.sh
```

It verifies BFU SSH/systemd health, unlock continuity, one systemd instance,
provisioned-helper equality with the staged APK, process memory evidence, and
poweroff/reboot/shutdown namespace isolation. It does not test normal
Termux:Boot handoff because that belongs to the separate upstream app.

The network manager follows the table selected by Android and routes Tailscale's
Linux bypass mark directly through it, without veth, NAT, or forwarding. Wi-Fi,
mobile data, and USB Ethernet can be hot-plugged without restarting Debian.
Android/ROM support must still bring the physical interface up and obtain its
address during BFU.

See [architecture](docs/architecture.md), [security](docs/security.md),
[testing](docs/testing.md), [rootfs installation](docs/rootfs-installation.md),
[Debian systemd](docs/debian-systemd.md), and [progress](docs/progress.md).
