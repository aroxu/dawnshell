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

The same locked startup now fails closed unless `files/bfu-ce-isolation.log`
gains a fresh entry containing all of:

```text
ce_isolated=true
user_unlocked_before=false
user_unlocked_after=false
output=TERMUX_CE_ISOLATED paths_unreadable=true
```

The probe asks root only whether the two canonical Termux home directories can be
listed and discards listing output. Any successful listing is a hard failure; do
not weaken FBE or hide the result to continue booting Debian.

## Debian gate 2: rootfs accessibility

While unlocked, install Termux prerequisites, then use the in-app installer:

```sh
pkg install debootstrap util-linux mount-utils
```

Watch **Debian installation log (live)** until the status is `SUCCEEDED`. Confirm
the log contains both SHA-256 checks, a valid Debian Release signature, rootfs
validation for Debian 13/Trixie arm64, and `INSTALL_SUCCEEDED`. Also verify
`/data/local/debian/.termux-bfu-rootfs` contains `suite=trixie`. Then reboot and run:

```sh
./scripts/test-rootfs-bfu.sh
```

If an older build failed after `Unpacking the base system` with a missing
`https:__..._Packages` path, install the updated Termux:Boot APK and press the
installer once more. The installer preserves the old partial tree as
`/data/local/debian.failed.<epoch>` and creates a fresh staging tree; do not
manually delete either tree before collecting diagnostics. Any new failure must
show `DEBOOTSTRAP_LOG_TAIL_BEGIN` through `DEBOOTSTRAP_LOG_TAIL_END` in the app.

For every dark console in the activity, verify that a drag scrolls inside the
console while more lines remain, then hands the gesture to the whole page at its
top or bottom edge. Long-press, select multiple lines, and copy them. While a
selection is active or the console is scrolled up, one-second live refreshes
must not replace the visible text.

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

## Debian gate 3: namespaces and chroot

Install the APK containing the ARM64 namespace helper, keep BFU enabled, and run:

```sh
./scripts/test-debian-runtime-bfu.sh
```

The script performs a cold boot, requires a fresh DE result produced while locked,
and expects:

```text
exit=0
timeout=false
namespace_chroot=true
user_unlocked_before=false
user_unlocked_after=false
output=BFU_DEBIAN_NAMESPACE_OK pid=1 proc1=sh arch=arm64 debian=13
```

The helper uses no Termux CE executable. It creates mount/PID/UTS/IPC/cgroup
namespaces but no network namespace, makes `/` recursively private, mounts private
`/proc` and `/run`, enters the verified rootfs, and exits. A failure includes an
exact `stage=` such as `unshare_cgroup`, `proc_mount`, `chroot`, or
`exec_debian_shell`; preserve that line before changing code or device policy.

This is a one-shot proof, not the long-running Debian service. Success completes
the launcher/chroot gate; it does not prove systemd 257 compatibility.

## Debian gates 4–7: systemd, D-Bus, and BFU SSH

While Android is unlocked, paste at least one dedicated public key into the BFU
`authorized_keys` editor and press **Configure Debian 13 systemd + SSH**. The
configuration status must become `SUCCEEDED`; its live selectable log must end in
both `CONFIGURE_SUCCEEDED` lines. This operation stops a prior test instance,
installs packages, validates `sshd`, enables `ssh.service`, publishes the ready
marker, and starts systemd once for AFU validation.

Press **Refresh Debian systemd status**. A successful launcher status contains
`BFU_DEBIAN_RUNNING`, identity-valid supervisor/init, valid namespace topology,
and a native health line proving D-Bus, `ssh.service`, and TCP 22.
Then confirm from another computer:

```sh
ssh -p 22 -i /path/to/bfu_key debian@PHONE_IP
systemctl is-system-running
systemctl is-active dbus.service
systemctl is-active ssh.service
busctl --system --no-pager list
cat /proc/1/comm
ss -ltn
```

The decisive cold-boot test is:

```sh
BFU_PHONE_HOST=PHONE_IP \
BFU_SSH_KEY=/path/to/bfu_key \
./scripts/test-systemd-ssh-bfu.sh
```

Do not unlock while it waits. Pass requires SSH on TCP 22, `/proc/1/comm` equal
to `systemd`, working D-Bus, `multi-user.target`, `ssh.service=active`, and a
listening `:22` socket. The script then asks for the first unlock, proves PID 1
start ticks plus machine ID remain identical, checks the locked DE health proof,
and installs a temporary normal Termux boot script whose current-boot marker must
appear after unlock. The temporary script and marker are removed on success.

On failure, copy the **Debian systemd lifecycle log** before changing anything.
Stages such as `cgroup_v1_name_systemd_mount`, `cgroup_move_pid1`,
`cgroup_view_bind`, `exec_systemd`, or `systemd_early_exit` identify the exact
gate. Debian 13's systemd 257 requires the explicit cgroup-v1 legacy-force path;
never repair a failure by remounting or delegating Android's host controller tree.

## First unlock handoff

Unlock once while the BFU service is active, then verify:

- one `USER_UNLOCKED received` or AFU fallback;
- one `Termux Boot handoff started` event;
- each regular `~/.termux/boot/*` file is scheduled once in sorted order;
- TermuxService starts only after `isUserUnlocked()` is true;
- the BFU foreground service remains active;
- the same Debian systemd PID and namespace remain alive without restart.

## Reboot and isolation matrix

After code/APK work is frozen, run the complete physical session:

```sh
BFU_PHONE_HOST=PHONE_IP \
BFU_SSH_KEY=/path/to/bfu_key \
BFU_CYCLES=10 \
./scripts/test-final-bfu.sh
```

Each cycle cold-boots, waits for the complete BFU SSH health check before asking
for unlock, verifies unchanged Debian PID 1 across `USER_UNLOCKED`, proves exactly
one normal Termux handoff, and records Android boot ID, app PID/RSS, supervisor,
and init host PID under ignored `test-results/`. Repeated boot IDs and a strictly
monotonic PSS increase over 32 MiB fail the harness.

After the cycles, the wrapper runs `test-systemd-shutdown-isolation.sh`. It checks
native status, explicit restart/stop/start, then invokes Debian `systemctl
poweroff` and `systemctl reboot` through the restricted root helper. Every action
must leave Android's boot ID unchanged and Debian SSH must recover after restart.

During BFU, verify CE remains unavailable even to the already pre-authorized root
probe. Do not change SELinux, mount DE over CE, or use root to alter FBE state.
The inability to list CE is the required result, not a defect to bypass.
