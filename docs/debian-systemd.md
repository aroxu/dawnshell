# Debian 13 systemd BFU implementation

## End state

```text
Android init (host PID 1)
  -> LOCKED_BOOT_COMPLETED
  -> Termux: BFU direct-Boot-aware foreground service
  -> pre-authorized Magisk su
  -> root start-debian helper
  -> private mount + PID + UTS + cgroup namespaces
  -> Android IPC + network namespaces retained
  -> Debian 13 Trixie arm64 chroot
  -> /sbin/init (PID 1 in the Debian PID namespace)
  -> enabled systemd services
```

No IPC or network namespace is created on the target, so Debian shares Android's
IPC namespace plus Wi-Fi, mobile, IP, and Tailscale interfaces. The IPC exception
is mandatory: pstore proves the Samsung 4.4.302 kernel panics in
`copy_ipcs -> mq_init_ns -> mqueue_mount -> mount_ns` when this process requests
`CLONE_NEWIPC`. First unlock is recorded but does not stop or restart the BFU
service, namespace, systemd, or Debian services. Normal Termux:Boot is a separate
app and is not invoked by this package.

## Storage

Termux CE paths are forbidden. `/data/local/debian` is accepted only after a
BFU root process proves its directories and `bin/sh` mode are readable and the
rootfs can be written. The launcher rejects every other root path.
The app-owned DE `files/bfu/` tree remains for bootstrap/control files and logs,
not the full rootfs, so uninstalling Termux: BFU does not silently remove Debian.

## Launcher contract

The APK first implements a destructive-state-free `probe` as a small
ARM64 Android-native helper. It exercises every namespace and mount operation,
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
5. presents a private `name=systemd` cgroup-v1 subtree while hiding Android's
   controller mounts;
6. executes `env container=termux-bfu chroot "$ROOT" /sbin/init`.

Host Android mount propagation remains untouched. The helper never makes host
mounts shared and never creates a network namespace. Lifecycle checkpoints and
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
`.termux-bfu-systemd-ready` marker is written last and removed before any
reconfiguration attempt, so a partial setup fails closed.

The launcher activity also copies two optional normal-Termux commands. The first
creates `~/.ssh/termux-bfu-ed25519` in Termux CE and prints its public half; the
operator pastes that public line into this app. The second connects to
`debian@127.0.0.1:22`, so it is independent of the phone's current Wi-Fi address.
No client private-key bytes enter app DE, the Debian rootfs, logs, or clipboard.

After unlock, the activity can set local passwords for `root` and `debian` by
feeding `chpasswd` through stdin. It does not enable SSH password or root login.
The local root password is intentionally powerful: `su root` uses Debian's setuid
binary on the private rootfs mount and becomes Android uid 0 within the retained
Android network and IPC namespaces.

After the initial PID 1 grace period, the launcher records all namespace inodes
and rejects the instance unless PID/mount/UTS/cgroup are private while IPC and
network both match Android. Java then polls the fixed native `health` operation until it
proves systemd PID 1, active D-Bus service and bus, `multi-user.target`, active
`ssh.service`, an active independent boot-proof service with its `/run` marker,
and a TCP 22 listener. It checks both that `multi-user.target` is configured as
default and that the target unit is actually active. The locked/unlocked state
surrounding that health proof is written to DE.

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

The launcher must fail closed if it cannot provide a private, writable hierarchy
acceptable to systemd. It does not remount Android's cgroup controller tree or
silently fall back to delegating it. Failure to mount the isolated named
hierarchy is a hard start failure. See the upstream [systemd v257 requirements](https://github.com/systemd/systemd/blob/v257/README)
and [v257 release notes](https://github.com/systemd/systemd/blob/v257/NEWS).

## Ordered device gates

1. BFU `su -c id` returns `uid=0` and persists the result in DE.
2. BFU root validates the selected Debian rootfs structure, shell mode, and
   temporary read/write access.
3. Root helper creates mount/PID/UTS/cgroup namespaces, retains Android IPC and
   network namespaces, and PID 1 sees its own `/proc`.
4. `chroot` executes Debian `/bin/sh` as namespace PID 1.
5. `/sbin/init` becomes namespace PID 1.
6. D-Bus and `systemctl` work and the default target is reached.
7. Enabled Debian `ssh.service` and the independent boot-proof service start after
   cold boot before first unlock.

Gates 1 and the Debian 13 rootfs installation have been proven on the target.
The source implements every remaining gate. Per the agreed test order, gates 2
through 7, unlock continuity, ten cold cycles, and shutdown isolation will be run
together with `scripts/test-final-bfu.sh` after the APK is frozen; implementation
is not treated as proof of BFU SSH reachability.
