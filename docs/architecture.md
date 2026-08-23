# Architecture

## Upstream findings

The original PoC was implemented in Termux:Boot, whose upstream AFU flow is
summarized below. The production BFU split is now a standalone app with package
`me.aroxu.dawnshell`, target SDK 28, and no shared UID.

Termux:Boot has this AFU-only flow:

```text
BOOT_COMPLETED
  -> BootReceiver
  -> /data/data/com.termux/files/home/.termux/boot/*
  -> one JobScheduler job per regular file
  -> BootJobService
  -> com.termux.app.TermuxService (com.termux.service_execute)
```

`BootReceiver` hardcodes the CE boot directory. `BootJobService` hardcodes the
Termux service class, action, URI scheme, and background extra. Termux's own
`TermuxConstants` likewise defines `/data/data/com.termux/files/usr` and
`/data/data/com.termux/files/home`; the source comments explicitly state that the
prefix is compiled into Termux binaries.

## Target lifecycle

```text
LOCKED_BOOT_COMPLETED
  -> directBootAware BootReceiver
  -> UserManager.isUserUnlocked() == false
  -> Device Protected SharedPreferences: enabled?
  -> directBootAware BfuBootService (foreground)
  -> createDeviceProtectedStorageContext()
  -> pre-authorized su
  -> root launcher
  -> Debian rootfs outside CE
  -> mount/PID/UTS/cgroup namespaces (IPC and network namespaces shared)
  -> direct Android NIC access + Tailscale fwmark route-table watcher
  -> chroot -> /sbin/init
  -> systemd is PID 1 inside the Debian PID namespace

USER_UNLOCKED (runtime receiver in BfuBootService)
  -> record the transition
  -> BFU service and Debian/systemd continue unchanged

BOOT_COMPLETED
  -> locked-state fallback that idempotently ensures the BFU service is started
```

`ACTION_USER_UNLOCKED` is registered dynamically because Android documents it as
registered-receiver-only; listing it in the manifest would not provide the event.
The manifest therefore contains `LOCKED_BOOT_COMPLETED` and `BOOT_COMPLETED`.
Normal Termux boot-script execution is intentionally absent and remains the
responsibility of the separate upstream Termux:Boot app.

## Storage boundaries

The BFU root is calculated only as:

```java
Context de = context.createDeviceProtectedStorageContext();
File root = new File(de.getFilesDir(), "bfu");
```

No `/data/user_de/0/...` string is used to calculate the runtime layout. The owner
package is `me.aroxu.dawnshell`, so a typical user-0 path is
`/data/user_de/0/me.aroxu.dawnshell/files/bfu`, but the Context result is
authoritative. The runtime does not inspect or coordinate with an older
Termux:Boot BFU implementation; migration is an explicit operator task.

The PoC creates:

```text
<DE filesDir>/bfu-boot.log
<DE filesDir>/bfu-root.log
<DE filesDir>/bfu-root-authorization.log
<DE filesDir>/bfu-ce-isolation.log
<DE filesDir>/bfu-rootfs.log
<DE filesDir>/bfu-debian-runtime.log
<DE filesDir>/debian-install.status
<DE filesDir>/debian-install.log
<DE filesDir>/debian-system-config.status
<DE filesDir>/debian-system-config.log
<DE filesDir>/debian-lifecycle.status
<DE filesDir>/bfu-operation.log
bfu/
  bin/bfu-namespace-probe-arm64
  etc/authorized_keys       # validated public keys only
  home/
  run/
    debian-lifecycle.log
    debian-supervisor.lock
    debian-supervisor.state
  scripts/test.sh
  scripts/probe-rootfs.sh
  scripts/install-debian-rootfs.sh
  scripts/configure-debian-systemd.sh
  downloads/              # checksum-pinned public Debian artifacts
  tmp/
```

`BootReceiver` appends `LOCKED_BOOT_COMPLETED <unix-epoch-ms>` to `bfu-boot.log`
before checking the BFU preference or starting the service. This marker proves the
manifest receiver ran with Device Protected Storage available even if logcat has
rotated or later service startup fails.

The `test.sh` file is mode 0700-equivalent through Java owner-only permission calls
and is invoked directly, not as `/system/bin/sh test.sh`. This intentionally tests
whether the target-28 app domain can `execve()` a writable DE file on the target ROM.

`BfuRootProbe` runs `su -c id` without a shell, enforces a 15-second timeout, and
requires both exit status 0 and a `uid=0` identity. It records the user-unlocked
state both before and after `su`, and fsyncs every result to `bfu-root.log`;
failure does not stop the foreground service.

The launcher activity exposes a separate interactive authorization action. It is
available only after unlock, allows up to 120 seconds for the Magisk UI, and
executes only `su -c id`. Its result is fsynced to
`bfu-root-authorization.log`, explicitly labelled as AFU setup rather than BFU
evidence. The app cannot force Magisk to grant access or determine whether the
operator selected a temporary or permanent duration.

While unlocked, provisioning writes a fixed, non-secret sentinel into this app's
CE files directory and a matching provisioning receipt into its DE storage.
After—and only after—the same-boot root result succeeds entirely while locked,
`BfuCeIsolationProbe` runs as the standalone app UID and tries to read that
exact sentinel. Debian launch fails closed when the DE receipt is absent or the
CE sentinel contents are readable. Merely listing an empty CE mount stub is not
treated as content access. The check never uses root, logs CE filenames beyond
the fixed sentinel path, or attempts to unlock, mount, copy, or bypass CE.

After the CE isolation gate succeeds,
`probe-rootfs.sh` runs through the same bounded `su` helper. It checks the candidate
`/data/local/debian`, `etc`, and readable/executable `bin/sh`, then creates, reads,
and removes an owner-private temporary marker in the rootfs. It does not execute a
Debian ELF or enter chroot, keeping storage accessibility separate from the later
dynamic-loader/chroot gate.

Rootfs preparation is a separate AFU operation launched explicitly from the
activity. A foreground-service worker downloads pinned public Debian artifacts,
streams child output into DE, and invokes a root helper. The helper borrows the
unlocked Termux prefix only as a host toolchain. It runs upstream debootstrap in
a private mount namespace and atomically promotes `/data/local/debian.installing`
only after architecture, dpkg state, shell, version, and root ownership checks.
No Termux path is embedded in the resulting Debian filesystem.

The second AFU operation installs Debian's systemd, D-Bus, and OpenSSH packages
inside that rootfs. It runs package management in a private mount namespace,
blocks package post-install service startup with a temporary `policy-rc.d`, and
configures an unprivileged `debian` SSH account. Password, keyboard-interactive,
empty-password, and root login are disabled. The service binds wildcard IPv4 TCP
22, so it can begin listening before Android finishes attaching an address. The
validated public keys originate in DE; BFU-only host keys and the installed key
copy live in the BFU-accessible Debian rootfs, never Termux CE. A separate enabled
oneshot service touches `/run/dawnshell-enabled-service.ready` during
`multi-user.target`, providing proof that systemd launched a configured unit other
than the SSH/D-Bus dependencies.

The launcher creates one random Ed25519 client identity after Android unlock.
Its atomic owner-only record lives under this app's normal CE `files/ssh/`
directory. The activity displays and provisions only the public line to DE, while
explicit export actions can write the OpenSSH private key through Android's
document provider or produce a time-limited sensitive Termux import command.
Locked-boot components never open the CE identity.

## Lifecycle and idempotence

- BFU is disabled by default and must be enabled once from the launcher activity.
- The activity saves only non-secret settings to Device Protected preferences and
  provisions the DE layout while the user is unlocked.
- The service promotes itself to foreground before filesystem or process work.
- A single-thread executor prevents duplicate probe executions in one service
  instance.
- `USER_UNLOCKED` never stops or restarts the BFU service; it records the event.
- `BOOT_COMPLETED` idempotently requests the BFU service and rechecks
  `UserManager`; a newly created service skips BFU startup probes if Android is
  already unlocked, so it cannot contaminate locked-boot evidence.
- `ACTION_USER_UNLOCKED` is registered dynamically by the foreground service;
  Android documents this action as unavailable to manifest receivers.
- The root supervisor is independent of the Android app process. Unlock and app
  UI recreation do not signal or restart Debian PID 1.

## Debian launcher boundary

The Android service remains a small lifecycle controller. Mount, namespace,
chroot, and systemd setup belongs in a separately testable root launcher. Its
bounded `probe` operation is an ARM64 PIE copied from the
APK into owner-only DE, then
executed through the already-proven BFU `su`. It depends only on Android's
`/system/bin/linker64`, `libc.so`, and `libdl.so`, not Termux CE tools.

The probe accepts only the exact, root-owned `/data/local/debian` path. It creates
private mount, PID, UTS, and cgroup namespaces, recursively privatizes `/`,
binds `/dev` and `/sys` as slave mounts, mounts PID-namespace `/proc` and private
tmpfs `/run`, and executes Debian `/bin/sh` through `chroot`. Success requires the
Debian shell to observe itself as PID 1 and `/proc/1/comm` as `sh`. The namespace
and all temporary mounts disappear when the bounded probe exits. IPC remains in
Android's namespace because the target Samsung 4.4 kernel panics inside
`mqueue_mount` while creating a new IPC namespace; the helper contains no
`unshare(CLONE_NEWIPC)` call.

The same helper now exposes `start`, `restart`, `status`, `health`, and `stop`.
Start acquires an
exclusive lock for the supervisor lifetime, records both process start ticks and
executable device/inode identity plus PID/mount/UTS/cgroup/IPC/network namespace
inodes, rejects verified orphan PID 1 instances, and waits for `/sbin/init` to
survive an initial grace period. The expected topology requires every requested
namespace to differ from Android PID 1 while IPC and network must match. A
host-side manager polls Android's selected route table and installs only priority
5200 IPv4/IPv6 rules for Tailscale's `0x80000/0xff0000` Linux bypass mark. This
precedes Tailscale's priority-5210 `main` lookup, avoiding Android's otherwise
terminal unreachable rule without veth, conntrack NAT, forwarding, or DNAT.
Wi-Fi, mobile, and USB Ethernet can hot-plug without restarting Debian; if no
default network exists, systemd and sshd remain running while the watcher retries.
The host-side manager also owns a root-only mode-0600 FIFO bind-mounted at
`/run/dawnshell-host-reboot`. Debian's `/usr/local/sbin/reboot` accepts only no
argument, `now`, or the non-mutating `--check`; a valid reboot request is executed
by the manager while it remains in Android's host PID namespace. Direct
`systemctl reboot` remains PID-namespace isolated.
Stop signals only an identity-verified supervisor; the supervisor asks systemd
to stop units and exit PID 1 through the container-specific `systemctl exit`
operation. A bounded fallback and final forced cleanup remain for a broken
manager, but normal target-device exit records `wait_status=0` without entering
Android's kernel halt path.

The rootfs is first bind-mounted onto itself and made private, so systemd shutdown
can remount or detach its own chroot root without changing Android's `/data`
mount. `/sys` and `/proc/sys` are read-only in the Debian view. Health opens the
already-verified PID, mount, and cgroup namespace descriptors, revalidates
identities to close PID-reuse races, moves its fixed helper into the delegated
cgroup subtrees, joins those namespaces, and forks a child in the Debian PID
namespace. It checks PID 1, D-Bus service/bus access, the default target,
`ssh.service`, TCP 22, and the delegated devices-controller view. It also
requires the independent boot-proof service to be active
and its volatile `/run` marker to exist. Both the configured default-target name
and the active state of `multi-user.target` are required, so configuration is not
mistaken for target reachability. Only fixed commands are accepted.

For the final physical test, `shutdown-test` permits only `poweroff`, `reboot`, or
`shutdown`. The first two invoke the corresponding `systemctl --no-block`
operation and the third invokes the fixed `/usr/sbin/shutdown --poweroff --no-wall
now` command inside those same verified namespaces. Each path waits for the
supervisor lock to be released. The host test script separately compares Android
boot IDs; the helper never claims Android isolation by itself.

For systemd 257 on this cgroup-v1 kernel, the helper first enters a private mount
namespace. Before `CLONE_NEWCGROUP`, it attaches `devices` to a v1 hierarchy and
mounts the private `name=systemd` hierarchy. Each hierarchy gets one dedicated
`dawnshell` child. The future Debian PID 1 is moved into both children before its
cgroup namespace is created. Only those child roots are bind-mounted at Debian
`/sys/fs/cgroup/devices` and `/sys/fs/cgroup/systemd`; neither hierarchy root nor
Android tasks are reachable from the chroot.

Controller-to-hierarchy attachment is kernel-global in cgroup v1 even though the
mount is visible only in the launcher's private mount namespace. Existing Android
tasks remain at the devices hierarchy root and their allow-all root policy is not
changed. Debian and Docker descendants can only narrow the permissions inherited
from the delegated child; they cannot grant a device denied by its parent. On
stop, the supervisor detaches the two Debian views, recursively removes descendant
cgroups, removes both `dawnshell` children, and then unmounts the source
hierarchies. This order avoids leaving an unmounted but still-active v1 hierarchy.
A process-local `SYSTEMD_PROC_CMDLINE` enables systemd 257's explicit legacy-force
path without changing Android `/proc/cmdline`.

This implements the devices-cgroup prerequisite only. Docker bridge, iptables,
and forwarding policy run in Android's intentionally shared network namespace and
need a separate restriction design before Docker networking is considered safe.

References: [Linux cgroup-v1 devices controller](https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v1/devices.html),
[Linux cgroup-v1 hierarchy lifecycle](https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v1/cgroups.html),
and [Docker cgroup metrics/runtime notes](https://docs.docker.com/engine/containers/runmetrics/).

## Platform constraints

Android's Direct Boot documentation requires `android:directBootAware=true` and DE
Context APIs. Android 10's target-29 behavior removes direct execution permission
for writable app home files, which is why upstream remains target 28. Android's
foreground-service documentation still lists locked/normal boot broadcasts as a
background-start exemption; newer boot/FGS-type restrictions principally apply to
higher target SDKs and restricted service types. This project does not assign an
unrelated FGS type merely to bypass policy.

References:

- https://developer.android.com/privacy-and-security/direct-boot
- https://developer.android.com/reference/android/content/Intent#ACTION_USER_UNLOCKED
- https://developer.android.com/about/versions/10/behavior-changes-10#execute-permission
- https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start
