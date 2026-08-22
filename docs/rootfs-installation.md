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
pkg install debootstrap util-linux mount-utils
```

Then open Termux: BFU and press **Request / verify Magisk root permission**.
Confirm that the package list contains only the standalone trusted app and choose
Magisk's permanent/forever allow duration. Keep **Enable Direct Boot Debian
bootstrap** selected and press **Install Debian 13 Trixie arm64 rootfs**. The
foreground service continues if the activity is backgrounded, but keeping the
activity visible shows the newest 48 KiB of output with a one-second refresh.

## Verified inputs

The app downloads over HTTPS from `deb.debian.org` and accepts only these exact
artifacts:

| Artifact | SHA-256 |
| --- | --- |
| `debootstrap_1.0.141.tar.gz` | `232ec755f4b1f445f829996885846abba6f1b6fd55d049476ab26ddd8c4b4e1b` |
| `debian-archive-keyring_2025.1_all.deb` | `9ea7778e443144ca490668737a8ab22dd3e748bb99e805e22ec055abeb3c7fac` |

Java verifies each download before publishing it into the app-owned DE cache.
The root helper verifies both digests again, extracts the Trixie archive
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
  -> validate Debian 13/Trixie, arm64, dpkg database, /bin/sh, root ownership
  -> write .termux-bfu-rootfs metadata marker
  -> atomic rename to /data/local/debian
```

The helper calls `mount --make-rprivate /` before debootstrap can create any
temporary mounts. It never overwrites an existing `/data/local/debian`. A valid
existing Trixie BFU rootfs is reported as `ALREADY_INSTALLED`; a rootfs marked
for another suite and any unrecognized target are left untouched and cause a
hard failure. The installer never performs an in-place Debian release upgrade.

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

The log is displayed in a fixed-height, monospaced console with a contrasting
background. Long-press it to select and copy text. Automatic refresh/follow
pauses while a selection is active or the console is scrolled above the bottom,
then resumes when the selection is dismissed or the view returns to the bottom.

The log records download progress, both integrity checks, the selected `su`
binary, private-mount setup, upstream debootstrap stdout/stderr, validation, and
the final atomic promotion. It does not log environment dumps, credentials, or
private keys. If the root helper exits unsuccessfully, its last sanitized
`ERROR:` line is also included in the installer status instead of showing only
the numeric exit code. The same files survive reboot and can be read after
unlock with a debuggable build:

```sh
adb shell run-as me.aroxu.termux.bfu cat \
  /data/user_de/0/me.aroxu.termux.bfu/files/debian-install.status
adb shell run-as me.aroxu.termux.bfu cat \
  /data/user_de/0/me.aroxu.termux.bfu/files/debian-install.log
```

The literal paths above are diagnostic examples for user 0. Runtime code always
derives the DE directory from `createDeviceProtectedStorageContext()`.

## Failure handling

- `missing ...; run in Termux: pkg install debootstrap util-linux mount-utils`:
  install the
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
