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

The latest upstream Dropbear package is not a BFU binary. It depends on
`termux-auth` and zlib, is configured with `--disable-static`, and is patched with
multiple `@TERMUX_PREFIX@` paths. It cannot be copied into DE storage unchanged.

## BFU/AFU split

```text
LOCKED_BOOT_COMPLETED
  -> directBootAware BootReceiver
  -> UserManager.isUserUnlocked() == false
  -> Device Protected SharedPreferences: enabled?
  -> directBootAware BfuBootService (foreground)
  -> createDeviceProtectedStorageContext()
  -> <DE filesDir>/bfu
  -> minimal runtime only

USER_UNLOCKED (runtime receiver in BfuBootService)
  -> verify UserManager.isUserUnlocked()
  -> stop BFU child daemon (future Dropbear milestone)
  -> normal boot-script scheduler
  -> BootJobService
  -> TermuxService

BOOT_COMPLETED
  -> AFU fallback if the BFU service was killed before unlock
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
bfu/
  bin/
  etc/authorized_keys
  home/
  run/
  scripts/test.sh
  tmp/
```

The `test.sh` file is mode 0700-equivalent through Java owner-only permission calls
and is invoked directly, not as `/system/bin/sh test.sh`. This intentionally tests
whether the target-28 app domain can `execve()` a writable DE file on the target ROM.

## Lifecycle and idempotence

- BFU is disabled by default and must be enabled once from the launcher activity.
- The activity saves only non-secret settings to Device Protected preferences and
  provisions the DE layout while the user is unlocked.
- The service promotes itself to foreground before filesystem or process work.
- A single-thread executor prevents duplicate probe executions in one service
  instance.
- Dynamic `USER_UNLOCKED` and manifest `BOOT_COMPLETED` can both request AFU boot.
  A DE monotonic timestamp suppresses duplicate normal dispatches for 60 seconds.
- `BOOT_COMPLETED` rechecks `UserManager`; CE access is refused while locked.
- `BootJobService` is not Direct-Boot-aware and is never called by the locked path.

## Native executable decision

The current PoC keeps `targetSdkVersion=28` and tests DE execution first. For the
SSH milestone, package a server-only ARM64 Dropbear as an APK native library and
prefer executing the immutable file in `applicationInfo.nativeLibraryDir`. DE then
contains only host/public-key configuration, home, pid, logs, and temporary files.
This avoids making downloaded/copy-provisioned native code the long-term design and
also gives a fallback if Samsung/EvolutionX SELinux blocks DE `execve()` despite
target 28.

The custom Dropbear build must:

- target `arm64-v8a`, API 28 or lower, and produce PIE code;
- omit password, PAM, shadow, keyboard-interactive, agent forwarding, X11, SFTP,
  client tools, compression, syslog, utmp/wtmp/lastlog, and Termux dependencies;
- accept host key, pid file, authorized-keys file, shell, home, and port as runtime
  paths rather than compile-time `/data/...` constants;
- use `/system/bin/sh` and the restricted BFU environment;
- listen on port 2222 by default and survive a network interface appearing later;
- remain functional without root.

Whether a fully static Bionic executable or a self-contained APK-native executable
is more reliable on the Note 8 must be decided by device tests, not assumed from a
desktop Linux build.

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

