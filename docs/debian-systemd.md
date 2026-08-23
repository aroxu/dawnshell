# Debian 13 systemd BFU implementation

## End state

```text
Android init (host PID 1)
  -> LOCKED_BOOT_COMPLETED
  -> DawnShell direct-Boot-aware foreground service
  -> pre-authorized Magisk su
  -> root start-debian helper
  -> private mount + PID + UTS + cgroup namespaces
  -> Android IPC + network namespaces retained
  -> shared NIC + Tailscale bypass-mark route shim
  -> Debian 13 Trixie armhf, arm64, or amd64 chroot matching the Android ABI
  -> /sbin/init (PID 1 in the Debian PID namespace)
  -> enabled systemd services
```

No IPC or network namespace is created on the target. Debian directly sees
Android's Wi-Fi, mobile, USB Ethernet, IP addresses, and `tailscale0`. A manager
tracks Android's selected default table and maintains a priority-5200 route rule
only for Tailscale's `0x80000/0xff0000` bypass mark. No veth, NAT, forwarding, or
port DNAT is used. The IPC exception
is mandatory: pstore proves the Samsung 4.4.302 kernel panics in
`copy_ipcs -> mq_init_ns -> mqueue_mount -> mount_ns` when this process requests
`CLONE_NEWIPC`. First unlock is recorded but does not stop or restart the BFU
service, namespace, systemd, or Debian services. Normal Termux:Boot is a separate
app and is not invoked by this package.

For intentional whole-device maintenance, the configurator installs a root-only
host bridge command at `/usr/local/sbin/reboot`. `su root` followed by `reboot
now` writes a fixed token to a mode-0600 FIFO in private `/run`; the pre-chroot
manager validates that token and invokes Android's `/system/bin/reboot` from the
host PID namespace. `reboot --check` validates the bridge without rebooting.
`systemctl reboot` retains its existing namespace-isolation behavior.

## Storage

Termux CE paths are forbidden. `/data/local/debian` is accepted only after a
BFU root process proves its directories and `bin/sh` mode are readable and the
rootfs can be written. The launcher rejects every other root path.
The app-owned DE `files/bfu/` tree remains for bootstrap/control files and logs,
not the full rootfs, so uninstalling DawnShell does not silently remove Debian.

## Launcher contract

The APK first implements a destructive-state-free `probe` as a small
ABI-matched Android-native helper. It exercises every namespace and mount operation,
executes Debian `/bin/sh` as namespace PID 1, records the result in DE, and exits.
This separates launcher/kernel/SELinux failures from the systemd gate.

The same helper exposes `start`, `restart`, `status`, `health`, and `stop`. Start rejects duplicates
using a lifetime advisory lock and live `/proc` identity (PID start ticks plus
executable device/inode), not a pid file alone. Within a new mount namespace it:

1. `mount --make-rprivate /`.
2. Bind the rootfs onto itself as a private mount, retain `nodev` while clearing
   `nosuid` only on that private root so Debian `su` works, then recursively bind
   `/dev` and `/sys`, mark those binds slave, and make Debian `/sys` read-only.
3. mount `/proc` so it reflects the new PID namespace.
4. mount a `mode=755,nosuid,nodev` tmpfs at `$ROOT/run` and create `/run/lock`.
5. before creating the cgroup namespace, attempts a delegated cgroup-v2 payload
   and cgroup-device BPF probe; if unavailable in automatic mode, mounts
   cgroup-v1 `name=systemd` and `devices` hierarchies instead. Debian PID 1 moves
   into only the resolved delegated subtree and sees no Android hierarchy root;
6. executes `env container=dawnshell chroot "$ROOT" /sbin/init`.

Host Android mount propagation remains untouched. The helper never makes host
mounts shared. Lifecycle checkpoints and
command results are persisted in DE. `USER_UNLOCKED` only records the transition
and does not issue `start`, `stop`, or `restart`.

Explicit maintenance stop forks a command inside the verified Debian PID/mount
namespaces and requests `systemctl --no-block exit`. This is systemd's supported
container-manager exit path: units stop normally and PID 1 exits without asking
the Android kernel to halt. The Samsung 4.4 target completes this path with
`wait_status=0`; a bounded signal/kill fallback remains only for a wedged manager.

An AFU-only configurator installs `systemd`, `systemd-sysv`, `dbus`, and
`openssh-server`, creates user `debian`, generates dedicated BFU host keys, copies
validated public keys from app DE, and enables `ssh.service` at TCP 22. It also
enables an independent oneshot service that creates a volatile marker in private
`/run` at `multi-user.target`; this proves configured enabled services ran rather
than inferring that only from SSH. It masks units that would write Android-owned
kernel, module, udev, sysctl, clock, or network state. The
`.dawnshell-systemd-ready` marker is written last and removed before any
reconfiguration attempt, so a partial setup fails closed.

The app generates the client identity in its own CE storage and automatically
provisions its public half. The first optional normal-Termux command installs the
explicitly exported private half as `~/.ssh/dawnshell-ed25519`; the second
connects to `debian@127.0.0.1:22`, so it is independent of the phone's current
Wi-Fi address. No client private-key bytes enter app DE, the Debian rootfs, or
logs. The optional one-line import helper does place the key in a sensitive
clipboard entry, which is cleared after 120 seconds if unchanged; document export
avoids the clipboard.

After unlock, the activity can set local passwords for `root` and `debian` by
feeding `chpasswd` through stdin. It does not enable SSH password or root login.
The local root password is intentionally powerful: `su root` uses Debian's setuid
binary on the private rootfs mount and becomes Android uid 0 within the retained
Android network and IPC namespaces.

After the initial PID 1 grace period, the launcher records all namespace inodes
and rejects the instance unless PID/mount/UTS/cgroup are private while IPC and
network match Android. Java then polls the fixed native `health` operation until it
proves systemd PID 1, active D-Bus service and bus, `multi-user.target`, active
`ssh.service`, an active independent boot-proof service with its `/run` marker,
a TCP 22 listener, and a writable delegated cgroup root. The health helper first
moves itself into the resolved v2 payload or v1 children and joins PID 1's cgroup
namespace, so `/proc/self/cgroup` reports `/` from the delegated view. It checks
both that `multi-user.target` is configured as default and that the target unit
is actually active. The locked/unlocked state surrounding that health proof is
written to DE.

The final harness also calls the helper's restricted `shutdown-test` with each of
`poweroff`, `reboot`, and `shutdown`. It executes `systemctl --no-block` for the
first two and a fixed `/usr/sbin/shutdown --poweroff --no-wall now` for the third
inside the verified Debian PID/mount namespaces, then waits for the lifetime lock
to release. The host script compares `/proc/sys/kernel/random/boot_id` before and
after and restarts Debian; this is how namespace reboot isolation is tested
without trusting the helper's own process outcome.

## Trixie systemd compatibility gate

Debian 13 ships systemd 257. Its upstream minimum Linux baseline is 3.15, so the
target 4.4.302 kernel is not rejected solely by version, but kernels below the
recommended 5.4 baseline are marked `old-kernel` and receive limited testing.
More importantly, systemd 257 refuses to boot on legacy/hybrid cgroup v1 by
default unless its documented legacy-force conditions are met. The launcher sets
both required flags through systemd's process-local `SYSTEMD_PROC_CMDLINE`
override. It does not modify Android's actual kernel command line.

The launcher must fail closed if it cannot provide a private, writable delegated
view acceptable to systemd and Docker. Automatic mode first probes cgroup v2,
including an actual cgroup-device BPF attach, then cleans it completely before a
v1 fallback. Force-v2 and force-v1 skip fallback by design. On the 4.4 target,
`devices` initially has `hierarchy=0`; the fallback attaches it before
`CLONE_NEWCGROUP`, creates one child, and exposes only that child. Because v1
controller attachment is global, cleanup removes all Debian descendants and the
child before unmount. It never binds Android's hierarchy root into Debian or
moves/restricts Android tasks. See the upstream
[systemd v257 requirements](https://github.com/systemd/systemd/blob/v257/README),
[Linux devices-controller delegation rules](https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v1/devices.html),
and [v257 release notes](https://github.com/systemd/systemd/blob/v257/NEWS).

## Docker network compatibility

The app stores the selected policy in Device Protected preferences, but applies
it only from the explicit AFU button. `host` publishes a managed
`/etc/docker/daemon.json` with bridge, firewall, forwarding, masquerading, and
userland proxy disabled. `auto` first validates Docker 29's experimental native
nftables backend and performs a read-only nft ruleset query, then probes
`iptables-nft`, then `iptables-legacy`. Both iptables probes issue read-only
`-C` checks for `addrtype`, `MASQUERADE`, and `conntrack`, which Docker's bridge
startup requires. If all bridge probes fail, `auto` publishes the safe host-only
configuration with `resolved_backend=none`; all three bridge backends can be
forced and fail closed. Bridge modes intentionally leave
IPv6 Docker firewall management disabled because Android kernel support varies.

Applying while Debian is running records its state, stops the identity-verified
PID 1, writes policy in a private AFU mount namespace, then restores the previous
running state. Existing unmanaged daemon configuration and externally modified
managed configuration are preserved and reported as failures.

## Ordered device gates

1. BFU `su -c id` returns `uid=0` and persists the result in DE.
2. BFU root validates the selected Debian rootfs structure, shell mode, and
   temporary read/write access.
3. Root helper creates mount/PID/UTS/cgroup namespaces, negotiates v2 then v1
   delegated cgroups before the cgroup namespace, retains Android IPC and
   network, starts the bypass-mark watcher, and PID 1 sees its own `/proc`.
4. `chroot` executes Debian `/bin/sh` as namespace PID 1.
5. `/sbin/init` becomes namespace PID 1.
6. D-Bus and `systemctl` work and the default target is reached.
7. Enabled Debian `ssh.service` and the independent boot-proof service start after
   cold boot before first unlock.

Gates 1 and the Debian 13 rootfs installation have been proven on the target.
The source implements every remaining gate. Per the agreed test order, gates 2
through 7, unlock continuity, five cold cycles, and shutdown isolation will be run
together with `scripts/test-final-bfu.sh` after the APK is frozen; implementation
is not treated as proof of BFU SSH reachability.
