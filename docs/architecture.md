# Architecture

## Upstream findings

At the pinned upstream revisions, both Termux and Termux:Boot set
`targetSdkVersion=28` and declare the shared UID `com.termux`.

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
  -> mount/PID/UTS/IPC/cgroup namespaces (network namespace shared)
  -> chroot -> /sbin/init
  -> systemd is PID 1 inside the Debian PID namespace

USER_UNLOCKED (runtime receiver in BfuBootService)
  -> verify UserManager.isUserUnlocked()
  -> normal boot-script scheduler
  -> BootJobService
  -> TermuxService
  -> BFU service and Debian/systemd continue unchanged

BOOT_COMPLETED
  -> idempotently ensure BFU service is started
  -> AFU handoff if the user is unlocked
```

`ACTION_USER_UNLOCKED` is registered dynamically because Android documents it as
registered-receiver-only; listing it in the manifest would not provide a handoff.
The manifest therefore contains `LOCKED_BOOT_COMPLETED` and `BOOT_COMPLETED`.

## Storage boundaries

The BFU root is calculated only as:

```java
Context de = context.createDeviceProtectedStorageContext();
File root = new File(de.getFilesDir(), "bfu");
```

No `/data/user_de/0/...` string is used by runtime code. The expected owner package
is `com.termux.boot`, so a typical user-0 path is
`/data/user_de/0/com.termux.boot/files/bfu`, but the Context result is authoritative.

The PoC creates:

```text
<DE filesDir>/bfu-boot.log
<DE filesDir>/bfu-root.log
<DE filesDir>/bfu-root-authorization.log
<DE filesDir>/bfu-rootfs.log
<DE filesDir>/bfu-debian-runtime.log
<DE filesDir>/debian-install.status
<DE filesDir>/debian-install.log
<DE filesDir>/debian-system-config.status
<DE filesDir>/debian-system-config.log
<DE filesDir>/debian-lifecycle.status
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
failure does not stop the foreground service or AFU handoff.

The launcher activity exposes a separate interactive authorization action. It is
available only after unlock, allows up to 120 seconds for the Magisk UI, and
executes only `su -c id`. Its result is fsynced to
`bfu-root-authorization.log`, explicitly labelled as AFU setup rather than BFU
evidence. The app cannot force Magisk to grant access or determine whether the
operator selected a temporary or permanent duration.

After—and only after—the same-boot root result succeeds entirely while locked,
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
copy live in the BFU-accessible Debian rootfs, never Termux CE.

## Lifecycle and idempotence

- BFU is disabled by default and must be enabled once from the launcher activity.
- The activity saves only non-secret settings to Device Protected preferences and
  provisions the DE layout while the user is unlocked.
- The service promotes itself to foreground before filesystem or process work.
- A single-thread executor prevents duplicate probe executions in one service
  instance.
- `USER_UNLOCKED` never stops the BFU service. It only dispatches normal Termux
  scripts, with the existing 60-second duplicate suppression.
- Dynamic `USER_UNLOCKED` and manifest `BOOT_COMPLETED` can both request AFU boot.
  A DE monotonic timestamp suppresses duplicate normal dispatches for 60 seconds.
- `BOOT_COMPLETED` idempotently requests the BFU service and rechecks
  `UserManager`; CE access is refused while locked.
- `BootJobService` is not Direct-Boot-aware and is never called by the locked path.
- `ACTION_USER_UNLOCKED` is registered dynamically by the foreground service;
  Android documents this action as unavailable to manifest receivers.
- The root supervisor is independent of the Android app process. Unlock, normal
  Termux handoff, and app UI recreation do not signal or restart Debian PID 1.

## Debian launcher boundary

The Android service remains a small lifecycle controller. Mount, namespace,
chroot, and systemd setup belongs in a separately testable root launcher. Its
bounded `probe` operation is an ARM64 PIE copied from the
APK into DE, SHA-256 checked both at build time and at provisioning time, then
executed through the already-proven BFU `su`. It depends only on Android's
`/system/bin/linker64`, `libc.so`, and `libdl.so`, not Termux CE tools.

The probe accepts only the exact, root-owned `/data/local/debian` path. It creates
private mount, PID, UTS, IPC, and cgroup namespaces, recursively privatizes `/`,
binds `/dev` and `/sys` as slave mounts, mounts PID-namespace `/proc` and private
tmpfs `/run`, and executes Debian `/bin/sh` through `chroot`. Success requires the
Debian shell to observe itself as PID 1 and `/proc/1/comm` as `sh`. The namespace
and all temporary mounts disappear when the bounded probe exits.

The same helper now exposes `start`, `status`, and `stop`. Start acquires an
exclusive lock for the supervisor lifetime, records both process start ticks and
executable device/inode identity, rejects verified orphan PID 1 instances, and
waits for `/sbin/init` to survive an initial grace period. Stop signals only an
identity-verified supervisor; the supervisor asks systemd to halt with
`SIGRTMIN+3` before a bounded forced cleanup.

For systemd 257 on this cgroup-v1 kernel, the helper mounts a private
`name=systemd` hierarchy, creates a dedicated `termux-bfu` child, moves only the
future Debian PID 1 into it, enters a cgroup namespace rooted there, and bind
mounts only that view at Debian `/sys/fs/cgroup/systemd`. Android controller
mounts are hidden from systemd rather than delegated. A process-local
`SYSTEMD_PROC_CMDLINE` enables systemd 257's explicit legacy-force path without
changing Android `/proc/cmdline`. No operation creates a network namespace.

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
