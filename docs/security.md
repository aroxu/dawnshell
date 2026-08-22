# Security model

## Invariants

1. BFU runtime and Debian never depend on Credential Encrypted storage. The only locked-state
   CE access is a bounded read attempt against a fixed, non-secret isolation
   sentinel; the default policy blocks startup if that content is readable.
2. App control data is created only from a Device Protected Context owned by
   Termux: BFU; the separately proven Debian rootfs is fixed at `/data/local/debian`.
3. No CE-to-DE automatic synchronization exists.
4. DE and the BFU rootfs must not contain user/client private SSH keys, Termux
   user keys, API tokens, Tailscale auth keys, plaintext passwords, cloud
   credentials, or personal secrets. Debian generates a dedicated BFU server
   host key in its rootfs; it must not be reused as a client identity. The app
   generates a separate Ed25519 client identity after unlock and stores its
   private half only in the app's CE files. Only its public line is copied to DE
   and Debian.
5. Root is required for the Debian launcher but is never assumed: each boot must
   prove `su -c id` returned `uid=0`, and failure cannot crash the BFU controller.
6. The Debian launcher does not create a network namespace or expose Android's
   controller mounts to systemd. Its named tracking cgroup and every bind mount
   are visible only through the private mount/cgroup namespace view.
7. The locked-boot standalone app process must prove that its provisioned CE sentinel
   content is unreadable before the rootfs/namespace launcher runs. The fixed
   sentinel path and verdict may be logged, but no user filename or content is.

## DE exposure

Device-encrypted storage is protected by verified-boot/device keys, not the user's
PIN-derived CE key. Physical/offline and privileged compromise assumptions are
therefore weaker than for normal Termux. DE contains only bootstrap/control files,
public authorized keys, and operational logs. The BFU rootfs contains generated
OpenSSH host keys and an installed copy of those public keys. Both areas are
available before PIN entry and require their own physical/offline threat review.

## Root and namespace restrictions

Magisk authorization must be granted to the standalone Termux: BFU UID before
reboot. The BFU path must never wait indefinitely for an authorization UI; the
probe is bounded and records only command path, exit status, timeout state, root
verdict, and sanitized `id` output.

Magisk stores superuser policy by numeric Linux UID. This app does not declare a
shared UID, so its policy is independent of Termux and Termux:Boot. The interactive
button still lists every package Android reports for the current UID before
calling `su`; normally only `me.aroxu.termux.bfu` is present. Do not approve if an
unexpected package appears. The button cannot
write Magisk's policy database; the operator must select permanent/forever in the
Magisk UI. A successful AFU check is never copied into `bfu-root.log` or treated
as locked-boot proof.

Reference: [Magisk superuser policy lookup keyed by UID](https://github.com/topjohnwu/Magisk/blob/99a6e2749f4d0e9da5d568208681561f90db4d61/native/src/core/su/db.rs).

The root launcher uses exact, validated paths and makes `/` recursively private
before bind mounts. It must not bind DE over CE, weaken FBE/SELinux, remount Android
cgroups globally, or treat a stale pid file as proof that Debian is running. A
lifetime `flock`, process start ticks, and executable inode identity protect
start/stop against PID reuse. Explicit stop runs systemd's supported container
manager `exit` operation inside the verified PID/mount namespaces; normal exit
does not enter Android's kernel halt path. `USER_UNLOCKED` never reaches that path.

The native helper is built for Android API 21/arm64 as PIE and has only Android
system `libc.so`/`libdl.so` dependencies. The build requires a non-empty helper
asset, and provisioning copies it to owner-only DE storage. Root accepts
only the exact, non-symlink, uid-0-owned, non-group/world-writable
`/data/local/debian` root. The bounded probe exits after the chroot proof. The
long-running mode exposes only a private `name=systemd` cgroup subtree, rejects
duplicate or identity-ambiguous instances, and keeps the supervisor independent
of the Android app process. The chroot root is a separate private bind mount.
That private mount clears Android `/data`'s `nosuid` flag so Debian `su` can use
its normal setuid binary, while retaining `nodev`; the host `/data` mount is never
remounted. Consequently, a Debian root shell has device-level root authority and
is not a container security boundary. `/sys` and `/proc/sys` are read-only, and
neither mode creates a network namespace.
The state file records all requested namespace inodes and requires the Debian net
namespace to equal Android's while the others differ.

Health and shutdown-test operations enter only namespace descriptors belonging to
the identity-verified live PID 1. Health runs a fixed, bounded set of local
systemd/D-Bus/socket checks. Shutdown-test accepts only `poweroff`, `reboot`, or
the literal `shutdown` selector; that selector maps only to a fixed
`/usr/sbin/shutdown --poweroff --no-wall now` invocation. It exists for ADB/root
validation and does not expose arbitrary command execution. Only the external
harness can prove that Android's boot ID stayed unchanged.

The rootfs accessibility gate writes only a random-per-process marker named
`.termux-bfu-access-probe.<pid>` at the rootfs top level, reads it back, and removes
it through an EXIT/signal trap. It does not modify Debian configuration, users,
services, mounts, or CE storage.

The AFU-only rootfs deletion control has one compile-time target:
`/data/local/debian`. It requires two confirmation dialogs and the literal word
`DELETE`, rejects symlinks or a resolved path mismatch, requests graceful
supervisor stop, refuses any remaining `systemd` process, and verifies absence
after deletion. It does not delete app DE settings/logs, staging siblings, normal
Termux data, or any caller-supplied path.

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
It also enables a dedicated oneshot proof unit whose only action is creating a
volatile marker under the namespace-private `/run`; health requires both its
active state and marker, without granting it Android host-side capabilities.

The SSH account is non-root. It may have a local password for interactive `su`,
but server policy denies
password, keyboard-interactive, empty-password, and root authentication. Public
keys are parsed in Java and revalidated with Debian `ssh-keygen`; key options are
not accepted. The app logs only key counts, never key bodies.

Local `root` and `debian` password updates are AFU-only. The activity clears both
input fields immediately, passes `account:password` only through stdin to the
root-owned Debian `chpasswd`, wipes its mutable buffers, and persists only the
account name and success/failure metadata. Password text is never placed in an
Intent, command line, preference, DE file, or operation log. Debian stores only
the normal salted password hash in `/etc/shadow`. Because the rootfs is available
before first unlock, use a unique strong password and treat offline hash cracking
as part of the DE threat model. OpenSSH remains public-key-only even after these
local passwords are set, and `PermitRootLogin no` remains mandatory.

The app generates the unencrypted purpose-specific Ed25519 client identity with
`SecureRandom` only after Android reports the user unlocked. Its atomic owner-only
record is in app CE, not DE. Configuration automatically validates and provisions
the public half; there is no manual authorized-key input.

Private-key export is always an explicit AFU action. The document-picker path
writes an OpenSSH private-key file to the operator's selected destination. The
convenience Termux import command necessarily contains the private key as base64,
so the UI requires confirmation, marks the clip sensitive on supported Android
versions, logs no key material, and clears that exact clipboard entry after 120
seconds. Exported files and pasted commands leave the app's protection boundary
and must be handled as credentials. Rotation destroys the app's previous identity,
updates DE public-key state, and requires Debian system reconfiguration before the
new key replaces the installed `authorized_keys`.

The target's IPC namespace is a documented compatibility exception, not a
container-security boundary. A captured kernel panic proves that Samsung's
4.4.302 kernel faults while creating a new IPC namespace, so the launcher never
requests `CLONE_NEWIPC`; its build rejects any reintroduction of that call. The
launcher still requires private mount/PID/UTS/cgroup namespaces and a shared
network namespace. Only the dedicated public-key-authenticated emergency account
and reviewed BFU services should run in this environment. A kernel with a fixed
IPC namespace implementation is required before claiming IPC isolation.

## Signing boundary

`me.aroxu.termux.bfu` has no shared UID, so its certificate does not need to match
Termux, Termux:Boot, or any plugin. Android still requires all future updates of
this package to use the same certificate. The checked-in debug key is public and
unsuitable for production; production builds require a private signing key.

## Logging

Use tag `TermuxBFU`. Allowed messages include lifecycle action, DE root, runtime
verification, child pid/status, and sanitized exit errors. Never log key contents,
environment dumps, full command lines containing credentials, or SSH packet data.
Automatic health diagnostics include unit names/states but deliberately do not
copy the arbitrary system journal into DE, where a future custom service might
have logged secrets.

## CE-readable ROM override

The default policy fails closed when the standalone app's provisioned CE sentinel
is readable before first unlock. Some legacy/custom-ROM storage stacks expose CE
contents while Android still reports the user as locked. An explicit
device-protected preference can permit BFU Debian startup only for this exact
sentinel-readable result. It does not apply to missing provisioning receipts,
probe errors, timeouts, root failures, or an unlock transition during probing.
Every use is persisted as `CE_ISOLATION_OVERRIDE_USED`.

This override does not decrypt or mount CE; it acknowledges that the ROM has
already made CE readable. It is disabled by default and weakens the original CE
isolation guarantee, so operators must treat BFU root/SSH access as capable of
reaching CE data on such a device.
