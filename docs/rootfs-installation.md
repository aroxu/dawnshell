# Debian rootfs installation

## Purpose and boundary

The launcher activity can prepare the gate-2 rootfs at
`/data/local/debian`. Installation is intentionally AFU-only: Android must be
unlocked because the bootstrap process borrows command-line tools from the
normal Termux prefix. The completed rootfs, staging tree, installer lock, and
future server runtime do not live in Termux CE storage.

The app does not execute Termux's packaged `debootstrap` script. That package
is adapted for unprivileged `proot` environments and replaces operations such
as ownership/account changes. Instead, installing the package supplies the
Android-compatible host tools (`wget`, `perl`, `gpgv`, `dpkg-deb`, and related
dependencies), while the app downloads and executes a checksum-pinned upstream
Debian debootstrap.

## One-time prerequisite

After launching the matching custom Termux APK, run while Android is unlocked:

```sh
pkg update
pkg install debootstrap util-linux
```

Then open Termux:Boot, keep **Enable Direct Boot Debian bootstrap** selected,
and press **Install Debian 12 arm64 rootfs**. Confirm the root operation. The
foreground service continues if the activity is backgrounded, but keeping the
activity visible shows the newest 48 KiB of output with a one-second refresh.

## Verified inputs

The app downloads over HTTPS from `deb.debian.org` and accepts only these exact
artifacts:

| Artifact | SHA-256 |
| --- | --- |
| `debootstrap_1.0.144.tar.gz` | `3e1bafd4bb813cf4d6c17a0adca449ca07603263a8ea40a67257d2d60c186f9a` |
| `debian-archive-keyring_2023.3+deb12u2_all.deb` | `f699e2f88dca05212f2a452b58475f2993cb6993dfbafb1d0205a3291eb8b4b8` |

Java verifies each download before publishing it into the app-owned DE cache.
The root helper verifies both digests again, extracts the Bookworm archive
keyring, and invokes debootstrap with `--force-check-sig`. A checksum or Debian
Release-signature failure is fatal.

Upstream debootstrap assumes host `dpkg` is `/usr/bin/dpkg`, a path Android does
not provide. The helper applies only a one-line portability substitution so the
host command resolves through the unlocked Termux `PATH`; all bootstrap package
selection, signature verification, extraction, ownership, and chroot behavior
remain upstream.

## Publication and idempotence

Installation runs as pre-authorized Magisk root inside a private mount namespace:

```text
verified downloads in <DE filesDir>/bfu/downloads/
  -> /data/local/debian.installing
  -> validate Bookworm, arm64, dpkg database, /bin/sh, root ownership
  -> write .termux-bfu-rootfs metadata marker
  -> atomic rename to /data/local/debian
```

The helper calls `mount --make-rprivate /` before debootstrap can create any
temporary mounts. It never overwrites an existing `/data/local/debian`. A valid
existing BFU rootfs is reported as `ALREADY_INSTALLED`; an unrecognized target
is left untouched and causes a hard failure.

`/data/local/.termux-bfu-debian-install.lock` prevents concurrent root
installers. A lock whose recorded host PID still belongs to this installer is
treated as active. A stale lock is renamed with a timestamp rather than deleted.
Likewise, a staging tree left by a killed process is preserved as
`/data/local/debian.failed.<epoch>` on the next attempt. A normal debootstrap
failure leaves `/data/local/debian.installing` available for diagnosis.

## Live and persistent logs

The UI polls these Device Protected files once per second:

```text
<DE filesDir>/debian-install.status
<DE filesDir>/debian-install.log
```

The log records download progress, both integrity checks, the selected `su`
binary, private-mount setup, upstream debootstrap stdout/stderr, validation, and
the final atomic promotion. It does not log environment dumps, credentials, or
private keys. The same files survive reboot and can be read after unlock with a
debuggable build:

```sh
adb shell run-as com.termux.boot cat \
  /data/user_de/0/com.termux.boot/files/debian-install.status
adb shell run-as com.termux.boot cat \
  /data/user_de/0/com.termux.boot/files/debian-install.log
```

The literal paths above are diagnostic examples for user 0. Runtime code always
derives the DE directory from `createDeviceProtectedStorageContext()`.

## Failure handling

- `missing ...; run in Termux: pkg install debootstrap util-linux`: install the
  AFU prerequisites and press the install button again.
- checksum or signature failure: do not bypass verification; retain the log and
  investigate the network/cache.
- an unverified `/data/local/debian` already exists: inspect and move it manually
  only after confirming its origin. The installer will not delete it.
- partial staging remains: preserve its `debootstrap/debootstrap.log` before any
  manual cleanup. The next app-driven attempt moves it aside automatically.
- Android is locked: the request is rejected because using Termux CE tooling at
  BFU would violate the storage boundary.

After `INSTALL_SUCCEEDED`, reboot without unlocking and run
`scripts/test-rootfs-bfu.sh`. Only that locked-boot evidence completes gate 2;
successful AFU installation alone does not prove BFU accessibility.
