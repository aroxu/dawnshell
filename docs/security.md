# Security model

## Invariants

1. BFU runtime and Debian never depend on Credential Encrypted storage. The only locked-state
   CE access is a bounded read attempt against a fixed, non-secret isolation
   sentinel; the default policy blocks startup if that content is readable.
2. App control data is created only from a Device Protected Context owned by
   DawnShell; the separately proven Debian rootfs is fixed at `/data/local/debian`.
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
6. The Debian launcher intentionally shares Android's network namespace for
   native-NIC performance. It does not expose an Android cgroup hierarchy root
   to systemd. Automatic mode prefers a dedicated cgroup-v2
   `dawnshell/payload` only after a cgroup-device BPF attach probe succeeds, then
   falls back to dedicated `dawnshell` children of the `name=systemd` and
   devices-v1 hierarchies. Android tasks remain outside every delegated child.
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

Magisk authorization must be granted to the standalone DawnShell UID before
reboot. The BFU path must never wait indefinitely for an authorization UI; the
probe is bounded and records only command path, exit status, timeout state, root
verdict, and sanitized `id` output.

Magisk stores superuser policy by numeric Linux UID. This app does not declare a
shared UID, so its policy is independent of Termux and Termux:Boot. The interactive
button still lists every package Android reports for the current UID before
calling `su`; normally only `me.aroxu.dawnshell` is present. Do not approve if an
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

The native helper and bootstrap executables are built for Android API 24 as PIE
for ARMv7, ARM64, and x86_64 and have only Android system `libc.so`/`libdl.so`
dynamic dependencies. The build requires every ABI asset, and provisioning
copies only the device's selected ABI to owner-only DE storage. Root accepts
only the exact, non-symlink, uid-0-owned, non-group/world-writable
`/data/local/debian` root. The bounded probe exits after the chroot proof. The
long-running mode exposes only the resolved delegated v2 payload or v1
`name=systemd`/devices children, rejects duplicate or identity-ambiguous
instances, and keeps the
supervisor independent of the Android app process. Attaching a v1 controller to
a hierarchy is kernel-global, but the launcher never changes the root devices
allowlist and never moves Android tasks into the delegated child. The child can
only retain or remove permissions granted by its parent. The hierarchy root is
not bind-mounted into Debian. Shutdown recursively removes Docker/systemd
descendant cgroups and each delegated child before unmounting the private source
mount. The chroot root is a separate private bind mount.
That private mount clears Android `/data`'s `nosuid` flag so Debian `su` can use
its normal setuid binary, while retaining `nodev`; the host `/data` mount is never
remounted. Consequently, a Debian root shell has device-level root authority and
is not a container security boundary. `/sys` and `/proc/sys` are read-only. The
state file records all requested namespace inodes and requires the Debian network
and IPC namespaces to match Android's. The launcher adds no veth, NAT, forwarding,
or DNAT. Its only host route mutation is priority 5200, matching Tailscale's exact
`0x80000/0xff0000` bypass mark and looking up Android's current active table. The
IPv4/IPv6 rules are updated on uplink changes and removed when the
identity-verified supervisor exits.

The host reboot bridge is intentionally privileged. Its source FIFO is a fixed
file under the private DE control directory, owned by root with mode 0600, and is
bind-mounted only into the private Debian `/run`. The wrapper rejects non-root
callers and all arguments except no argument, `now`, and non-mutating `--check`.
The host manager accepts only the literal `ANDROID_REBOOT` token. A successful
request reboots the entire Android device and is not namespace-isolated.

Health and shutdown-test operations enter only namespace descriptors belonging to
the identity-verified live PID 1. Their helper is moved into the delegated
systemd/devices children before joining PID 1's cgroup namespace. Health runs a
fixed, bounded set of local systemd/D-Bus/socket/devices-cgroup checks.
Shutdown-test accepts only `poweroff`, `reboot`, or
the literal `shutdown` selector; that selector maps only to a fixed
`/usr/sbin/shutdown --poweroff --no-wall now` invocation. It exists for ADB/root
validation and does not expose arbitrary command execution. Only the external
harness can prove that Android's boot ID stayed unchanged.

The rootfs accessibility gate writes only a random-per-process marker named
`.dawnshell-access-probe.<pid>` at the rootfs top level, reads it back, and removes
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
true. It uses no Termux or other-package executable. BusyBox, Debian
`pkgdetails`, GnuPG `gpgv`, and the native launcher are built from the pinned
source archives recorded in `bfu-runtime/sources/SOURCES.lock`; the APK includes
the matching debootstrap source and Debian archive-keyring package. The root
helper rechecks both input digests and requires Debian Release signature,
Packages-index hash, and package hash validation. BusyBox package transport uses
HTTP because its internal TLS client does not authenticate peers; authenticated
Debian metadata and payload hashes provide the fail-closed supply-chain check.
There is no "skip verification" path.

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

Tailscale may run in kernel TUN mode inside the shared network namespace. Its
`tailscale0`, route rules, and netfilter state are consequently Android-global;
this mode is a performance choice, not a network isolation boundary. Never
store a reusable enrollment auth key in DE or the BFU rootfs. Interactive login
is preferred. Once enrolled, `/var/lib/tailscale/tailscaled.state` is necessarily
available during BFU and must be treated as a device credential with weaker
at-rest protection than CE data.

Docker is not a security boundary in the shared-network design. The default
managed policy disables Docker bridge, iptables/ip6tables, IP forwarding, and
masquerading and requires `--network host`. Explicit bridge modes first perform
read-only nft frontend and iptables rule-capability probes. Automatic mode
returns to safe host networking if `addrtype`, `MASQUERADE`, `conntrack`, or all
native nftables support is unavailable. A successful bridge selection still
necessarily permits Docker-created bridges, routes, forwarding, NAT, and
firewall rules to affect Android globally. The UI labels every bridge mode
dangerous and leaves host-only as the default. Bridge testing requires a
recovery path that does not depend on the same network connection.

The AFU policy writer refuses a pre-existing unmanaged
`/etc/docker/daemon.json`. Once it creates a managed file, the recorded SHA-256
must still match before replacement. This avoids destroying an operator's custom
configuration but does not make a dangerous bridge policy safe.

The target's IPC namespace is a documented compatibility exception, not a
container-security boundary. A captured kernel panic proves that Samsung's
4.4.302 kernel faults while creating a new IPC namespace, so the launcher never
requests `CLONE_NEWIPC`; its build rejects any reintroduction of that call. The
launcher still requires private mount/PID/UTS/cgroup namespaces and shared
IPC/network. Only the dedicated public-key-authenticated emergency account
and reviewed BFU services should run in this environment. A kernel with a fixed
IPC namespace implementation is required before claiming IPC isolation.

## Signing boundary

`me.aroxu.dawnshell` has no shared UID, so its certificate does not need to match
Termux, Termux:Boot, or any plugin. Android still requires all future updates of
this package to use the same certificate. The checked-in debug key is public and
unsuitable for production; production builds require a private signing key.

## Logging

Use tag `DawnShell`. Allowed messages include lifecycle action, DE root, runtime
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
