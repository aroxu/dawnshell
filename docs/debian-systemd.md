# Debian systemd BFU plan

## End state

```text
Android init (host PID 1)
  -> LOCKED_BOOT_COMPLETED
  -> Termux:Boot direct-Boot-aware foreground service
  -> pre-authorized Magisk su
  -> root start-debian helper
  -> mount + PID + UTS + IPC + cgroup namespaces
  -> Debian 13 Trixie arm64 chroot
  -> /sbin/init (PID 1 in the Debian PID namespace)
  -> enabled systemd services
```

No network namespace is created, so Debian shares Android Wi-Fi, mobile, IP, and
Tailscale interfaces. First unlock dispatches normal Termux:Boot scripts but does
not stop or restart the BFU service, namespace, systemd, or Debian services.

## Storage

Termux CE paths are forbidden. `/data/local/debian` is only a candidate until a
BFU root process proves its directories and `bin/sh` mode are readable and the
rootfs can be written. If it fails, select another root-accessible device-encrypted path.
The app-owned DE `files/bfu/` tree remains for bootstrap/control files and logs,
not the full rootfs, so uninstalling Termux:Boot does not silently remove Debian.

## Launcher contract

The future root helper exposes `start-debian`, `stop-debian`, `restart-debian`, and
`status-debian`. Start must reject duplicate instances using live process identity
and namespace evidence, not a pid file alone. Within a new mount namespace it must:

1. `mount --make-rprivate /`.
2. Recursively bind `/dev` and `/sys` into the rootfs and mark those binds slave.
3. mount `/proc` so it reflects the new PID namespace.
4. mount a `mode=755,nosuid,nodev` tmpfs at `$ROOT/run` and create `/run/lock`.
5. execute `env container=termux chroot "$ROOT" /sbin/init`.

Host Android mount propagation and cgroup mounts must remain untouched. systemd's
behavior against the device's mixed cgroup v1/unified topology is a separate gate.
Stdout/stderr and lifecycle checkpoints must be persisted outside CE.

## Trixie systemd compatibility gate

Debian 13 ships systemd 257. Its upstream minimum Linux baseline is 3.15, so the
target 4.4.302 kernel is not rejected solely by version, but kernels below the
recommended 5.4 baseline are marked `old-kernel` and receive limited testing.
More importantly, systemd 257 refuses to boot on legacy/hybrid cgroup v1 by
default unless its documented legacy-force kernel-command-line conditions are
met. The target Android cgroup topology must therefore be captured and tested
inside the private namespace before `/sbin/init` is enabled.

The launcher must fail closed if it cannot provide a private, writable hierarchy
acceptable to systemd. It must not change Android's global kernel command line,
remount the host cgroup tree, or silently fall back to modifying host control
groups. See the upstream [systemd v257 requirements](https://github.com/systemd/systemd/blob/v257/README)
and [v257 release notes](https://github.com/systemd/systemd/blob/v257/NEWS).

## Ordered device gates

1. BFU `su -c id` returns `uid=0` and persists the result in DE.
2. BFU root validates the selected Debian rootfs structure, shell mode, and
   temporary read/write access.
3. Root helper creates mount/PID/UTS/IPC/cgroup namespaces and PID 1 sees its own
   `/proc`.
4. `chroot` executes Debian `/bin/sh`.
5. `/sbin/init` becomes namespace PID 1.
6. D-Bus and `systemctl` work and the default target is reached.
7. Enabled Debian `ssh.service` starts after cold boot before first unlock.

Each gate requires physical-device evidence before implementing assumptions for the
next. Gate 1 is proven. The current source implements the gate-2 probe and AFU
rootfs installer; locked-boot evidence for the installed tree is still pending.
