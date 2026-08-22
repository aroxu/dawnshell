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
<DE filesDir>/bfu-rootfs.log
bfu/
  bin/
  etc/
  home/
  run/
  scripts/test.sh
  scripts/probe-rootfs.sh
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

After—and only after—the same-boot root result succeeds entirely while locked,
`probe-rootfs.sh` runs through the same bounded `su` helper. It checks the candidate
`/data/local/debian`, `etc`, and readable/executable `bin/sh`, then creates, reads,
and removes an owner-private temporary marker in the rootfs. It does not execute a
Debian ELF or enter chroot, keeping storage accessibility separate from the later
dynamic-loader/chroot gate.

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

## Debian launcher boundary

The Android service will remain a small lifecycle controller. Mount, namespace,
chroot, and systemd setup belongs in a separately testable root launcher with
`start`, `stop`, `restart`, and `status` operations. The first rootfs candidate is
`/data/local/debian`, but it is not accepted until a BFU root-access probe proves it
is executable and writable on the target ROM. The launcher must never use Termux CE
paths.

The launcher creates mount, PID, UTS, IPC, and cgroup namespaces but deliberately
does not create a network namespace. It first makes `/` recursively private, then
prepares private `/dev`, `/sys`, PID-namespace `/proc`, and tmpfs `/run` mounts
before executing `env container=termux chroot "$ROOT" /sbin/init`. Full ordering,
cgroup constraints, and milestone gates are in `debian-systemd.md`.

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
