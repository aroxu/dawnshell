# Debian rootfs installation

[한국어](rootfs-installation.ko.md) · [Glossary](glossary.md)

A rootfs is Debian's complete root file system. DawnShell installs Debian 13
Trixie at `/data/local/debian`.

## Preconditions

Android must be unlocked, root must be approved, the BFU runtime must be
provisioned, the device ABI must be supported, and no valid final rootfs may
already exist.

The APK contains source-built BusyBox, `pkgdetails`, statically linked `gpgv`,
Debian archive keys, and the namespace launcher for each supported ABI. See
[Google's ABI guide](https://developer.android.com/ndk/guides/abis).

## Installation sequence

1. Verify and provision the ABI-specific runtime.
2. Create `/data/local/debian.installing`.
3. Download Debian Release metadata and signatures.
4. Verify the official signature with `gpgv`.
5. Verify package indexes and package SHA-256 values.
6. Extract the base system into the staging tree.
7. Validate architecture, dpkg state, required files, permissions, and ownership.
8. Run a basic command inside the chroot.
9. Atomically rename the verified tree to `/data/local/debian`.
10. Write the ready marker.

Atomic publication ensures that a partial installation never appears as the
final rootfs.

## Failure handling

Failed staging trees are preserved and moved to
`/data/local/debian.failed.<timestamp>` on the next attempt. Never bypass a
signature or checksum error.

The current runtime checks BusyBox formatted `stat -c` support before any
download. If an older APK reports `stat: invalid option -- c`, update the APK and
retry; preserve the old staging tree for diagnosis.

## Removal

The danger-zone removal flow requires a stopped server, two confirmations, and a
literal `DELETE`. The only final target is `/data/local/debian`.

## Related documents

- [Installation guide](installation.md)
- [Security model](security.md)
- [Debian systemd](debian-systemd.md)
