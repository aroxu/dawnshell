# Debian rootfs installation

## Purpose and boundary

The launcher activity can prepare the gate-2 rootfs at
`/data/local/debian`. The bootstrap does not use Termux, another package, or CE
storage. It runs from the ABI-specific Bionic runtime that DawnShell provisions
under its Device Protected `files/bfu/` tree.

## One-time prerequisite

Open DawnShell and press **Request / verify Magisk root permission**.
Confirm that the package list contains only the standalone trusted app and choose
Magisk's permanent/forever allow duration. Keep **Enable Direct Boot Debian
bootstrap** selected and press **Install Debian 13 Trixie rootfs**. The
foreground service continues if the activity is backgrounded, but keeping the
activity visible shows the newest 48 KiB of output with a one-second refresh.

## Source-built host runtime and verified inputs

DawnShell maps Android ABIs to native Debian architectures as follows:

| Android ABI | Debian architecture |
| --- | --- |
| `armeabi-v7a` | `armhf` |
| `arm64-v8a` | `arm64` |
| `x86_64` | `amd64` |

`scripts/build-bootstrap-runtime.sh` compiles BusyBox 1.38.0, `pkgdetails` from
base-installer 1.226, GnuPG 2.4.9 `gpgv` with its static library dependencies,
and the native namespace launcher for all three ABIs. Each output is an Android
PIE with `/system/bin/linker` or `/system/bin/linker64`; the build rejects an
unexpected shared dependency or embedded fixed app-data path.

The APK contains these exact architecture-independent inputs:

| Artifact | SHA-256 |
| --- | --- |
| `debootstrap_1.0.141.tar.gz` | `232ec755f4b1f445f829996885846abba6f1b6fd55d049476ab26ddd8c4b4e1b` |
| `debian-archive-keyring_2025.1_all.deb` | `9ea7778e443144ca490668737a8ab22dd3e748bb99e805e22ec055abeb3c7fac` |

The gzip archive is named `debootstrap_1.0.141.tgz` only inside APK assets so
Android's asset packager does not transparently strip the `.gz` suffix. Its DE
runtime filename remains `debootstrap_1.0.141.tar.gz`.

Their source archives are SHA-256 checked before every native build, and APK
signing covers the resulting assets. Provisioning atomically copies them into
the app-owned DE directory. The root helper verifies both digests again,
extracts the Trixie archive
keyring, and invokes debootstrap with `--force-check-sig`. A checksum or Debian
Release-signature failure is fatal.

The package mirror uses HTTP because BusyBox's compact TLS client does not
authenticate peers. This does not disable authenticity checks: source-built
`gpgv` verifies Debian Release metadata, debootstrap verifies Packages indexes
against that signed metadata, and every `.deb` against its authenticated hash.
Transport tampering therefore fails closed. Upstream debootstrap's optional
host-`dpkg` lookup is avoided by supplying its documented `arch` file and
source-built native `pkgdetails` helper. The installer explicitly selects
debootstrap's upstream `ar` extractor: BusyBox `ar`, `xzcat`, and `tar` cover
Trixie's `.deb` format, while BusyBox's compact `dpkg-deb` is used only for its
supported keyring-package extraction path.

## Publication and idempotence

Installation runs as pre-authorized Magisk root inside a private mount namespace:

```text
APK assets -> verified files in <DE filesDir>/bfu/{bin,downloads}/
  -> /data/local/debian.installing
  -> validate Debian 13/Trixie, selected architecture, dpkg database,
     /bin/sh, root ownership
  -> write .dawnshell-rootfs metadata marker
  -> atomic rename to /data/local/debian
```

The helper calls `mount --make-rprivate /` before debootstrap can create any
temporary mounts. It never overwrites an existing `/data/local/debian`. A valid
existing Trixie BFU rootfs is reported as `ALREADY_INSTALLED`; a rootfs marked
for another suite and any unrecognized target are left untouched and cause a
hard failure. The installer never performs an in-place Debian release upgrade.

`/data/local/.dawnshell-debian-install.lock` prevents concurrent root
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

Open **Logs → Debian installation** for a dedicated full-screen monospaced view.
Long-press to select and copy text, or use the toolbar action to copy the whole
visible tail. Automatic refresh/follow pauses while a selection is active or the
view is scrolled above the bottom, then resumes when the selection is dismissed
or the view returns to the bottom.

The log records the selected Android/Debian architecture, integrity checks,
the selected `su` binary, private-mount setup, upstream debootstrap
stdout/stderr, validation, and
the final atomic promotion. It does not log environment dumps, credentials, or
private keys. If the root helper exits unsuccessfully, its last sanitized
`ERROR:` line is also included in the installer status instead of showing only
the numeric exit code. The same files survive reboot and can be read after
unlock with a debuggable build:

```sh
adb shell run-as me.aroxu.dawnshell cat \
  /data/user_de/0/me.aroxu.dawnshell/files/debian-install.status
adb shell run-as me.aroxu.dawnshell cat \
  /data/user_de/0/me.aroxu.dawnshell/files/debian-install.log
```

The literal paths above are diagnostic examples for user 0. Runtime code always
derives the DE directory from `createDeviceProtectedStorageContext()`.

## Failure handling

- `source-built ... is missing`: reprovision the runtime from the app. If it
  persists, retain the log because the installed APK is incomplete or does not
  contain the device ABI.
- checksum or signature failure: do not bypass verification; retain the log and
  investigate the network/cache.
- an unverified `/data/local/debian` already exists: inspect and move it manually
  only after confirming its origin. The installer will not delete it.
- partial staging remains: preserve its `debootstrap/debootstrap.log` before any
  manual cleanup. The next app-driven attempt moves it aside automatically.
- Android is locked: interactive installation remains AFU-only so Magisk policy,
  destructive storage publication, and progress UI are explicit. No CE tooling
  is involved.

After `INSTALL_SUCCEEDED`, reboot without unlocking and run
`scripts/test-rootfs-bfu.sh`. Only that locked-boot evidence completes gate 2;
successful AFU installation alone does not prove BFU accessibility.
