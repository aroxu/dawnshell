# DawnShell

[한국어 문서](README.ko.md)

[![Build and release](https://github.com/aroxu/dawnshell/actions/workflows/build.yml/badge.svg)](https://github.com/aroxu/dawnshell/actions/workflows/build.yml)

New users should start with the [installation guide](docs/installation.md). See
the [user guide](docs/user-guide.md) for daily operation after setup.

Standalone Android Direct Boot controller for a root-owned Debian 13 Trixie
environment. Its Android package is `me.aroxu.dawnshell` and its launcher
name is **DawnShell**.

Android 7.0/API 24 is the minimum because Direct Boot and the bundled native
bootstrap runtime both target the first platform release that provides it.

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
- Rootfs installation and all management operations use the app's source-built,
  ABI-specific Android bootstrap runtime in DE. They never execute another
  package's binaries or read Termux CE storage.

## Standalone bootstrap runtime

Termux is not required to install, configure, boot, recover, or remove Debian.
The universal APK selects one of these mappings from `Build.SUPPORTED_ABIS`:

| Android ABI | Debian architecture |
| --- | --- |
| `armeabi-v7a` | `armhf` |
| `arm64-v8a` | `arm64` |
| `x86_64` | `amd64` |

For each ABI, the APK contains a Bionic PIE BusyBox toolbox, Debian
`base-installer`'s native `pkgdetails`, a statically dependency-linked `gpgv`,
and the DawnShell namespace launcher. The app also bundles pinned upstream
debootstrap source and Debian's public archive keyring. Debian Release
signatures, package indexes, and package hashes are verified during bootstrap.

Termux remains an optional, convenient on-device SSH client. The app's exported
private-key import and localhost SSH commands target Termux, but any OpenSSH
client can use the exported key instead.

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
  -> capability-negotiated cgroups
     (delegated v2 + device-BPF first, isolated v1 systemd/devices fallback)
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

## Kernel and Docker compatibility policies

DawnShell never selects a backend from `uname` or a kernel-version table. The
default cgroup policy tries a private delegated cgroup-v2 subtree first and
accepts it only after a temporary cgroup-device BPF program can be loaded and
attached. An unavailable mount, delegation, or BPF capability is cleaned up
before fallback to the cgroup-v1 `devices` plus `name=systemd` implementation.
The UI also exposes fail-closed force-v2 and force-v1 modes for diagnostics.

Docker networking defaults to **safe host-network-only**. Its managed daemon
configuration disables Docker bridge, iptables/ip6tables, forwarding, and
masquerading, so containers must use `--network host`. Automatic bridge mode
probes Docker 29's experimental native nftables backend, then `iptables-nft`,
then `iptables-legacy`. The iptables candidates must also pass read-only checks
for Docker's `addrtype`, `MASQUERADE`, and `conntrack` requirements. If every
bridge backend fails, automatic mode resolves to safe host networking; each
bridge backend can still be forced and then fails closed. Bridge modes are
dangerous because Debian shares Android's
network namespace: Docker can alter Android-global firewall, NAT, routes, and
forwarding and disrupt Wi-Fi, mobile data, USB Ethernet, VPNs, Tailscale, or SSH.

Applying Docker policy is a separate AFU action; saving the preference alone
does not mutate networking. DawnShell refuses to overwrite an unmanaged
`/etc/docker/daemon.json` and replaces its own file only while the recorded
SHA-256 still matches. The operation has a separate selectable live log.

## Build

Requirements:

- JDK 17
- Android SDK Platform 34
- Android NDK `29.0.14206865`
- Bash, GNU make, a host C compiler, GNU awk, patch, sed, tar, and coreutils
- On Windows, an MSYS2 environment containing those host tools

```sh
export JAVA_HOME=/path/to/jdk17
export ANDROID_HOME=/path/to/android-sdk
export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/29.0.14206865"
./scripts/build-all.sh
```

`scripts/build-bootstrap-runtime.sh` verifies every vendored source SHA-256,
then builds all three ABI directories before Gradle packages the APK. To rebuild
only selected targets, set `DAWNSHELL_BOOTSTRAP_ABIS` to a space-separated list.
`DAWNSHELL_SKIP_BOOTSTRAP_SOURCE_BUILD=1` is intended only for an APK rebuild
after already verified runtime assets exist.

Pinned source archives and URLs are recorded in
`bfu-runtime/sources/SOURCES.lock`; Android patches/configuration are kept under
`bfu-runtime/patches` and `bfu-runtime/config`. DawnShell code is MIT, while the
bundled command-line programs retain their upstream GPL/LGPL licenses; see
`bfu-runtime/THIRD_PARTY_NOTICES.md`.

Output:

```text
dist/dawnshell_0.2.0_debug.apk
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
poweroff/reboot/shutdown namespace isolation. Health requires either the
delegated unified-v2 root or the delegated v1 devices view and records the
resolved mode. It does not test normal
Termux:Boot handoff because that belongs to the separate upstream app.

The network manager follows the table selected by Android and routes Tailscale's
Linux bypass mark directly through it, without veth, NAT, or forwarding. Wi-Fi,
mobile data, and USB Ethernet can be hot-plugged without restarting Debian.
Android/ROM support must still bring the physical interface up and obtain its
address during BFU.

See [architecture](docs/architecture.md), [security](docs/security.md),
[testing](docs/testing.md), [rootfs installation](docs/rootfs-installation.md),
[Debian systemd](docs/debian-systemd.md), and [progress](docs/progress.md).
