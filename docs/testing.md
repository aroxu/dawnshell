# Test plan

## Preflight

```sh
adb shell getprop ro.crypto.type
adb shell getprop ro.product.cpu.abi
adb shell dumpsys package com.termux.boot | grep -E 'targetSdk|userId|dataDir'
adb shell dumpsys user | grep -i unlocked
```

Expected: `file`, `arm64-v8a`, target SDK 28, and the intended shared UID/signing
set. Launch Termux:Boot once, enable BFU, enter at least one dedicated public key,
save, and exempt it from vendor battery restrictions where the ROM exposes that
control.

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

## Milestone 3: BFU SSH

After a server-only binary is added:

```sh
ssh -vv -p 2222 phone-address
```

From the session run `id`, `uname -a`, `uptime`, `ip addr`, and
`cat /proc/meminfo | head`. Password attempts must fail. Connecting before Wi-Fi is
ready may fail, but the daemon must remain alive and become reachable when an
interface obtains an address.

## First unlock handoff

Keep an SSH session open, unlock once, then verify:

- one `USER_UNLOCKED received` or AFU fallback;
- BFU child exits gracefully in handoff mode;
- one `Termux Boot handoff started` event;
- each regular `~/.termux/boot/*` file is scheduled once in sorted order;
- TermuxService starts only after `isUserUnlocked()` is true.

Persistent mode is a later setting: BFU stays on 2222 while normal Termux can use
8022.

## Reboot and isolation matrix

Run ten cold cycles. Record boot ID, BFU pid, listener pid, unlock time, AFU script
marker, and RSS. Fail on duplicate listener, duplicate AFU scripts, steadily rising
RSS, or a missed locked broadcast.

During BFU, verify CE remains unavailable. Do not change SELinux, mount DE over CE,
or grant root to the app for this test. Relevant denial is a pass for CE isolation,
not a defect to bypass.
