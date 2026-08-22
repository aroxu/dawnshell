# Test plan

## Preflight

```sh
adb shell getprop ro.crypto.type
adb shell getprop ro.product.cpu.abi
adb shell dumpsys package com.termux.boot | grep -E 'targetSdk|userId|dataDir'
adb shell dumpsys user | grep -i unlocked
```

Expected: `file`, `arm64-v8a`, target SDK 28, and the intended shared UID/signing
set. Launch Termux:Boot once, enable the Direct Boot Debian bootstrap, save, and
exempt it from vendor battery restrictions where the ROM exposes that control.

## Milestone 1: locked boot broadcast

1. Clear logcat and reboot.
2. Do not enter PIN/pattern.
3. Wait for ADB without unlocking and inspect logs.

```sh
adb logcat -c
adb reboot
adb wait-for-device
adb shell dumpsys user | grep -i unlocked
adb logcat -d -s TermuxBFU:I '*:S'
adb shell run-as com.termux.boot \
  cat /data/user_de/0/com.termux.boot/files/bfu-boot.log
```

Pass requires user 0 to remain locked and a new line in the DE marker:

```text
LOCKED_BOOT_COMPLETED <unix-epoch-milliseconds>
```

The marker is primary evidence because it survives logcat rotation and is written
before BFU enablement or service startup. `LOCKED_BOOT_COMPLETED received` in
logcat is supporting evidence.

## Milestone 2: DE executable

The same log must include:

```text
DE context initialized: /data/user_de/0/com.termux.boot/files
BFU runtime verified: .../files/bfu
DE executable probe succeeded: TermuxBFU DE executable OK; ...
```

Inspect package-owned files through `run-as` only on a debuggable build:

```sh
adb shell run-as com.termux.boot ls -la files/bfu/scripts files/bfu/etc
adb shell run-as com.termux.boot files/bfu/scripts/test.sh
```

Do not use root to make this test pass. A denial must be recorded with its AVC and
the nativeLibraryDir strategy tested next.

## Debian gate 1: BFU root

Open Termux:Boot while unlocked and press **Request / verify Magisk root
permission**. Verify the confirmation dialog lists only expected packages for
the shared UID, then choose Magisk's permanent/forever allow duration. The app's
AFU result must show `exit=0` and `root=true`; this is setup confirmation, not BFU
evidence. Then run:

```sh
./scripts/test-root-bfu.sh
```

The script records line counts before reboot, waits 30 seconds without ADB or an
unlock, then asks the operator to unlock so it can reconnect and read:

```text
/data/user_de/0/com.termux.boot/files/bfu-root.log
```

Pass requires the newest line to contain `exit=0`, `root=true`,
`user_unlocked_before=false`, `user_unlocked_after=false`, and `output=uid=0(`.
Those state fields prove the probe completed during BFU even though this ROM does
not expose ADB until first unlock. A timeout or denial is a real failed gate; do
not attempt to make an approval UI appear during BFU.

As a second read path, open Termux:Boot after unlock and press **Refresh BFU probe
results**. It reads the same Device Protected logs; it does not rerun `su` and
therefore cannot accidentally turn an AFU authorization into BFU evidence.

The interactive authorization result is stored separately at
`files/bfu-root-authorization.log`. Never use it as a substitute for the newest
post-reboot line in `files/bfu-root.log`.

## Debian gate 2: rootfs accessibility

While unlocked, install Termux prerequisites, then use the in-app installer:

```sh
pkg install debootstrap util-linux
```

Watch **Debian installation log (live)** until the status is `SUCCEEDED`. Confirm
the log contains both SHA-256 checks, a valid Debian Release signature, rootfs
validation, and `INSTALL_SUCCEEDED`. Then reboot and run:

```sh
./scripts/test-rootfs-bfu.sh
```

After the 30-second locked interval and first unlock, the newest
`bfu-rootfs.log` entry must include:

```text
rootfs=/data/local/debian
exit=0
accessible=true
user_unlocked_before=false
user_unlocked_after=false
output=Debian-rootfs-access-ok root=/data/local/debian shell=/data/local/debian/bin/sh rw=true
```

The probe checks storage access only. It deliberately does not directly execute
the Debian shell because its ELF interpreter and libraries require the later
chroot setup. On failure, preserve the `stage=...` output before changing the
candidate path or filesystem policy.

## Later Debian gates

After BFU root is proven, validate these one at a time:

1. mount/PID/UTS/IPC/cgroup namespaces are created without a network namespace;
   namespace PID 1 sees a matching private `/proc`.
2. `chroot` executes Debian `/bin/sh`.
3. `/sbin/init` becomes namespace PID 1.
4. D-Bus and `systemctl` work and the default target is reached.
5. enabled Debian `ssh.service` is reachable after cold boot before unlock.

Capture `/sys/fs/cgroup`, `/proc/cgroups`, and `/proc/self/cgroup` before changing
the launcher for systemd. Never repair a failure by remounting the host Android
cgroup hierarchy.

## First unlock handoff

Unlock once while the BFU service is active, then verify:

- one `USER_UNLOCKED received` or AFU fallback;
- one `Termux Boot handoff started` event;
- each regular `~/.termux/boot/*` file is scheduled once in sorted order;
- TermuxService starts only after `isUserUnlocked()` is true;
- the BFU foreground service remains active;
- once implemented, the same Debian systemd PID and namespace remain alive without
  restart.

## Reboot and isolation matrix

Run ten cold cycles. Record boot ID, BFU service pid, future systemd host/PID-
namespace identities, unlock time, AFU script marker, and RSS. Fail on duplicate
Debian instances, duplicate AFU scripts, steadily rising RSS, or a missed locked
broadcast.

During BFU, verify CE remains unavailable. Do not change SELinux, mount DE over CE,
or grant root to the app for this test. Relevant denial is a pass for CE isolation,
not a defect to bypass.
