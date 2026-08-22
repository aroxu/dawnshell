# Security model

## Invariants

1. Termux CE storage is never accessed while `UserManager.isUserUnlocked()` is
   false.
2. App control data is created only from a Device Protected Context owned by
   Termux:Boot; the separately proven Debian rootfs is fixed at `/data/local/debian`.
3. No CE-to-DE automatic synchronization exists.
4. DE and the BFU rootfs must not contain user/client private SSH keys, Termux
   user keys, API tokens, Tailscale auth keys, reusable passwords, cloud
   credentials, or personal secrets. Debian generates a dedicated BFU server
   host key in its rootfs; it must not be reused as a client identity.
5. Root is required for the Debian launcher but is never assumed: each boot must
   prove `su -c id` returned `uid=0`, and failure cannot crash the BFU controller.
6. The Debian launcher does not create a network namespace or expose Android's
   controller mounts to systemd. Its named tracking cgroup and every bind mount
   are visible only through the private mount/cgroup namespace view.

## DE exposure

Device-encrypted storage is protected by verified-boot/device keys, not the user's
PIN-derived CE key. Physical/offline and privileged compromise assumptions are
therefore weaker than for normal Termux. DE contains only bootstrap/control files,
public authorized keys, and operational logs. The BFU rootfs contains generated
OpenSSH host keys and an installed copy of those public keys. Both areas are
available before PIN entry and require their own physical/offline threat review.

## Root and namespace restrictions

Magisk authorization must be granted to the Termux/Termux:Boot shared UID before
reboot. The BFU path must never wait indefinitely for an authorization UI; the
probe is bounded and records only command path, exit status, timeout state, root
verdict, and sanitized `id` output.

Magisk stores superuser policy by numeric Linux UID. Since the installed Termux
family declares shared UID `com.termux`, a permanent allow applies to Termux,
Termux:Boot, and any other correctly signed package sharing that UID. The
interactive button lists all packages Android reports for the current UID before
calling `su`. Do not approve if an unexpected package appears. The button cannot
write Magisk's policy database; the operator must select permanent/forever in the
Magisk UI. A successful AFU check is never copied into `bfu-root.log` or treated
as locked-boot proof.

Reference: [Magisk superuser policy lookup keyed by UID](https://github.com/topjohnwu/Magisk/blob/99a6e2749f4d0e9da5d568208681561f90db4d61/native/src/core/su/db.rs).

The root launcher uses exact, validated paths and makes `/` recursively private
before bind mounts. It must not bind DE over CE, weaken FBE/SELinux, remount Android
cgroups globally, or treat a stale pid file as proof that Debian is running. A
lifetime `flock`, process start ticks, and executable inode identity protect
start/stop against PID reuse. Explicit stop sends systemd's container halt signal;
`USER_UNLOCKED` never reaches that path.

The native helper is built for Android API 21/arm64 as PIE and has only Android
system `libc.so`/`libdl.so` dependencies. Gradle verifies its pinned SHA-256 and the
app verifies the same digest after copying it to owner-only DE storage. Root accepts
only the exact, non-symlink, uid-0-owned, non-group/world-writable
`/data/local/debian` root. The bounded probe exits after the chroot proof. The
long-running mode exposes only a private `name=systemd` cgroup subtree, rejects
duplicate or identity-ambiguous instances, and keeps the supervisor independent
of the Android app process. Neither mode creates a network namespace.

The rootfs accessibility gate writes only a random-per-process marker named
`.termux-bfu-access-probe.<pid>` at the rootfs top level, reads it back, and removes
it through an EXIT/signal trap. It does not modify Debian configuration, users,
services, mounts, or CE storage.

## Rootfs supply chain

Rootfs installation is allowed only after `UserManager.isUserUnlocked()` is
true. Termux CE binaries are disposable AFU build tools, never BFU runtime
dependencies. The installer pins the SHA-256 of Trixie's debootstrap source and
Debian archive-keyring package, restricts downloads to HTTPS on
`deb.debian.org`, rechecks both digests as root, and requires Debian Release
signature validation. It never offers a "skip verification" path.

The final rootfs path is not recursively deleted or overwritten. Installation
uses a staging sibling on the same filesystem, validates it, and performs an
atomic rename. Interrupted trees and stale locks are preserved under timestamped
names for inspection. The operational log may reveal package names and paths but
must never contain repository credentials, proxy secrets, passwords, or private
keys.

Systemd/OpenSSH configuration is also AFU-only. Package installation temporarily
uses plain HTTP only for the first signed APT transaction when the minbase tree
does not yet contain CA certificates; Debian Release signatures remain mandatory.
After `ca-certificates` is installed, sources are replaced with HTTPS and updated
again. Package service startup is blocked with a temporary, restored
`policy-rc.d`. The BFU-ready marker is published only after `sshd -t`, effective
public-key-only policy checks, host-key generation, and `ssh.service` enablement.

The SSH account is non-root and has no usable password. Server policy denies
password, keyboard-interactive, empty-password, and root authentication. Public
keys are parsed in Java and revalidated with Debian `ssh-keygen`; key options are
not accepted. The app logs only key counts, never key bodies.

## Signing boundary

The Android shared UID makes signing part of the security architecture. F-Droid,
GitHub debug, and a custom key are different trust domains. Mixing them is expected
to fail with shared-user/signature errors. The correct deployment set is custom
Termux plus custom Termux:Boot (and every required plugin), all signed by one
private key.

The upstream `testkey_untrusted.jks` files in the pinned Termux and Termux:Boot
trees have the same SHA-256 file hash
`A2BA19F2417DE94DD3BDFB6CEECE070CDC5F9B492AF09CD5900058E860B18C7D`.
That is useful for local debug interoperability only; the password is public in
Gradle files and the key is unsuitable for production.

## Logging

Use tag `TermuxBFU`. Allowed messages include lifecycle action, DE root, runtime
verification, child pid/status, and sanitized exit errors. Never log key contents,
environment dumps, full command lines containing credentials, or SSH packet data.
